module "naming" {
  source  = "Azure/avm-utl-naming/azure"
  version = "0.2.0"
}

resource "azapi_resource" "this" {
  location               = var.location
  name                   = module.naming.resource_group.name_unique
  type                   = "Microsoft.Resources/resourceGroups@2025-04-01"
  response_export_values = []
}

module "test" {
  source = "../../"

  address_space    = ["10.10.0.0/16"]
  location         = azapi_resource.this.location
  name             = module.naming.virtual_network.name_unique
  parent_id        = azapi_resource.this.id
  enable_telemetry = var.enable_telemetry
  lock = {
    kind = "CanNotDelete"
  }
  tags = {
    environment = "test"
    workload    = "example"
  }
}
