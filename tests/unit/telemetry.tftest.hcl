// azapi validates that parent_id is a real Azure resource ID, so the generated
// mock ID has to be a well-formed one.
mock_provider "azapi" {
  mock_resource "azapi_resource" {
    defaults = {
      id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-unit-test/providers/Microsoft.Network/virtualNetworks/vnet-unit-test"
    }
  }
}
mock_provider "modtm" {}
mock_provider "random" {}

variables {
  address_space = ["10.0.0.0/16"]
  location      = "uksouth"
  name          = "vnet-unit-test"
  parent_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-unit-test"
}

run "creates_no_telemetry_resources_when_disabled" {
  command = plan

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
    condition     = azapi_resource.this.create_headers == null
    error_message = "Telemetry headers must be omitted when telemetry is disabled."
  }
}

run "sends_telemetry_headers_when_enabled" {
  command = apply

  variables {
    enable_telemetry = true
  }

  assert {
    condition     = length(modtm_telemetry.telemetry) == 1
    error_message = "A telemetry resource must be created when telemetry is enabled."
  }

  assert {
    condition     = azapi_resource.this.create_headers != null
    error_message = "Telemetry headers must be attached when telemetry is enabled."
  }

  assert {
    condition     = alltrue([for h in [azapi_resource.this.create_headers, azapi_resource.this.read_headers, azapi_resource.this.update_headers, azapi_resource.this.delete_headers] : h == azapi_resource.this.create_headers])
    error_message = "The same telemetry header must be sent on every request verb."
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
