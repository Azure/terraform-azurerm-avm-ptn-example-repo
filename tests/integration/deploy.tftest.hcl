variables {
  enable_telemetry = false
}

run "setup" {
  module {
    source = "./tests/integration/setup"
  }
}

run "deploys_a_virtual_network_into_the_target_resource_group" {
  variables {
    address_space = ["10.0.0.0/16"]
    location      = run.setup.location
    name          = run.setup.virtual_network_name
    parent_id     = run.setup.resource_group_id
    tags = {
      environment = "integration-test"
    }
  }

  assert {
    condition     = output.name == run.setup.virtual_network_name
    error_message = "The name output must report the deployed virtual network name."
  }

  assert {
    condition     = output.resource_id == "${run.setup.resource_group_id}/providers/Microsoft.Network/virtualNetworks/${run.setup.virtual_network_name}"
    error_message = "The resource_id output must be the ARM ID of the virtual network inside the target resource group."
  }

  assert {
    condition     = azapi_resource.this.location == run.setup.location
    error_message = "The virtual network must be deployed to the resource group region."
  }
}

run "updates_the_address_space_and_tags_in_place" {
  variables {
    address_space = ["10.0.0.0/16", "10.1.0.0/16"]
    location      = run.setup.location
    name          = run.setup.virtual_network_name
    parent_id     = run.setup.resource_group_id
    tags = {
      environment = "integration-test"
      updated     = "true"
    }
  }

  assert {
    condition     = output.resource_id == "${run.setup.resource_group_id}/providers/Microsoft.Network/virtualNetworks/${run.setup.virtual_network_name}"
    error_message = "Updating the address space and tags must not replace the virtual network."
  }

  assert {
    condition     = length(azapi_resource.this.body.properties.addressSpace.addressPrefixes) == 2
    error_message = "The added address prefix must be applied to the existing virtual network."
  }

  assert {
    condition     = azapi_resource.this.tags["updated"] == "true"
    error_message = "The added tag must be applied to the existing virtual network."
  }
}
