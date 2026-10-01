mock_provider "azapi" {}
mock_provider "modtm" {}
mock_provider "random" {}

variables {
  address_space    = ["10.0.0.0/16", "10.1.0.0/16"]
  location         = "uksouth"
  name             = "vnet-unit-test"
  parent_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-unit-test"
  enable_telemetry = false
}

run "creates_a_virtual_network_from_the_required_inputs" {
  command = plan

  assert {
    condition     = azapi_resource.this.type == "Microsoft.Network/virtualNetworks@2025-05-01"
    error_message = "The module must deploy a virtual network resource type."
  }

  assert {
    condition     = azapi_resource.this.name == var.name
    error_message = "The resource name must come from var.name."
  }

  assert {
    condition     = azapi_resource.this.parent_id == var.parent_id
    error_message = "The resource must be parented to var.parent_id."
  }

  assert {
    condition     = azapi_resource.this.location == var.location
    error_message = "The resource must be deployed to var.location."
  }
}

run "passes_every_address_prefix_through_to_the_request_body" {
  command = plan

  assert {
    condition     = azapi_resource.this.body.properties.addressSpace.addressPrefixes == var.address_space
    error_message = "All address prefixes must be forwarded to the virtual network body."
  }
}

run "creates_no_optional_resources_by_default" {
  command = plan

  assert {
    condition     = length(azapi_resource.lock) == 0
    error_message = "No lock must be created when var.lock is null."
  }

  assert {
    condition     = length(azapi_resource.role_assignment) == 0
    error_message = "No role assignments must be created when var.role_assignments is empty."
  }
}

run "applies_tags_when_supplied" {
  command = plan

  variables {
    tags = {
      environment = "test"
      owner       = "avm"
    }
  }

  assert {
    condition     = azapi_resource.this.tags == var.tags
    error_message = "Tags must be forwarded to the virtual network."
  }
}
