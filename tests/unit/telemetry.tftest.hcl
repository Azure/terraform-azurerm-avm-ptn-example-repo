// azapi validates that parent_id is a real Azure resource ID, so the generated
// mock ID has to be a well-formed one.
mock_provider "azapi" {
  mock_data "azapi_client_config" {
    defaults = {
      subscription_id          = "00000000-0000-0000-0000-000000000000"
      subscription_resource_id = "/subscriptions/00000000-0000-0000-0000-000000000000"
      tenant_id                = "11111111-1111-1111-1111-111111111111"
    }
  }

  mock_resource "azapi_resource" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-unit-test/providers/Microsoft.Network/virtualNetworks/vnet-unit-test"
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
    condition     = length(terraform_data.telemetry) == 0 && length(azapi_resource.telemetry) == 0
    error_message = "Disabling telemetry must create neither a stable instance ID nor an Azure deployment."
  }

  assert {
    condition     = length(data.azapi_client_config.telemetry) == 0
    error_message = "The client config must not be read when telemetry is disabled."
  }
}

run "uses_enabled_telemetry_default_for_null" {
  command = apply

  variables {
    enable_telemetry = null
  }

  assert {
    condition     = var.enable_telemetry && length(terraform_data.telemetry) == 1 && length(azapi_resource.telemetry) == 1
    error_message = "A null input must use the default enabled telemetry setting."
  }
}

run "reports_telemetry_in_deployment_name_when_enabled" {
  command = apply

  variables {
    enable_telemetry = true
  }

  assert {
    condition     = length(terraform_data.telemetry) == 1 && length(azapi_resource.telemetry) == 1
    error_message = "Enabling telemetry must create a stable instance ID and an Azure deployment."
  }

  assert {
    condition = (
      azapi_resource.telemetry[0].type == "Microsoft.Resources/deployments@2025-04-01" &&
      azapi_resource.telemetry[0].parent_id == "/subscriptions/00000000-0000-0000-0000-000000000000" &&
      azapi_resource.telemetry[0].location == var.location
    )
    error_message = "Telemetry must deploy at the active subscription scope using var.location."
  }

  assert {
    condition = (
      can(regex("^46d3xtrf[.]ptn[.]f91d5a4[.]0-0-0[.]x[.][0-9a-f]{4}$", azapi_resource.telemetry[0].name)) &&
      endswith(azapi_resource.telemetry[0].name, substr(sha1(terraform_data.telemetry[0].id), 0, 4))
    )
    error_message = "Telemetry must report the metadata prefix, local version, source, and stable instance suffix in its name."
  }

  assert {
    condition = (
      azapi_resource.telemetry[0].body.properties.mode == "Incremental" &&
      length(azapi_resource.telemetry[0].body.properties.template.resources) == 0 &&
      can(formatdate("YYYY-MM-DD", azapi_resource.telemetry[0].body.properties.template.outputs.apply_id.value))
    )
    error_message = "Telemetry must write an empty deployment whose output updates on normal applies."
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
