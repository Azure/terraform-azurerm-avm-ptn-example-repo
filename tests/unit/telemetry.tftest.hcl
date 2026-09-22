// azapi validates that parent_id is a real Azure resource ID, so the generated
// mock ID has to be a well-formed one.
mock_provider "azapi" {
  mock_data "azapi_client_config" {
    defaults = {
      subscription_id = "00000000-0000-0000-0000-000000000000"
      tenant_id       = "11111111-1111-1111-1111-111111111111"
    }
  }

  mock_resource "azapi_resource" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-unit-test/providers/Microsoft.Network/virtualNetworks/vnet-unit-test"
    }
  }
}
mock_provider "modtm" {
  mock_data "modtm_module_source" {
    defaults = {
      module_source  = "registry.terraform.io/Azure/avm-ptn-example-repo/azurerm"
      module_version = "0.1.0"
    }
  }
}
mock_provider "random" {
  mock_resource "random_uuid" {
    defaults = {
      result = "22222222-2222-2222-2222-222222222222"
    }
  }
}

variables {
  address_space = ["10.0.0.0/16"]
  location      = "uksouth"
  name          = "vnet-unit-test"
  parent_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-unit-test"
}

run "creates_no_telemetry_resources_when_disabled" {
  command = apply

  variables {
    enable_telemetry = false
  }

  assert {
    condition     = length(modtm_telemetry.telemetry) == 0
    error_message = "No telemetry resource must be created when telemetry is disabled."
  }

  assert {
    condition     = length(data.azapi_client_config.telemetry) == 0
    error_message = "The client config must not be read when telemetry is disabled."
  }

  assert {
    condition     = length(data.modtm_module_source.telemetry) == 0
    error_message = "The module source must not be read when telemetry is disabled."
  }

  assert {
    condition     = length(random_uuid.telemetry) == 0
    error_message = "No telemetry UUID must be created when telemetry is disabled."
  }
}

run "uses_enabled_telemetry_default_for_null" {
  command = apply

  variables {
    enable_telemetry = null
  }

  assert {
    condition     = var.enable_telemetry && length(modtm_telemetry.telemetry) == 1
    error_message = "A null input must use the default enabled telemetry setting."
  }
}

run "records_telemetry_metadata_when_enabled" {
  command = apply

  variables {
    enable_telemetry = true
  }

  assert {
    condition     = length(modtm_telemetry.telemetry) == 1
    error_message = "A telemetry resource must be created when telemetry is enabled."
  }

  assert {
    condition = modtm_telemetry.telemetry[0].tags == tomap({
      subscription_id = "00000000-0000-0000-0000-000000000000"
      tenant_id       = "11111111-1111-1111-1111-111111111111"
      module_source   = "registry.terraform.io/Azure/avm-ptn-example-repo/azurerm"
      module_version  = "0.1.0"
      random_id       = "22222222-2222-2222-2222-222222222222"
      location        = var.location
    })
    error_message = "Telemetry must contain only the expected client, module, UUID, and location metadata."
  }

  assert {
    condition = alltrue([
      for headers in [
        azapi_resource.this.create_headers,
        azapi_resource.this.read_headers,
        azapi_resource.this.update_headers,
        azapi_resource.this.delete_headers,
      ] : headers == null
    ])
    error_message = "Telemetry must not add the retired AzAPI request headers."
  }
}

run "exposes_the_deployed_resource_through_outputs" {
  command = apply

  variables {
    enable_telemetry = false
  }

  assert {
    condition     = output.name == var.name
    error_message = "The name output must expose the deployed resource name."
  }

  assert {
    condition     = output.resource_id == azapi_resource.this.id
    error_message = "The resource_id output must expose the deployed resource ID."
  }
}
