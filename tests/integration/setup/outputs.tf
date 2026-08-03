output "location" {
  description = "The region the test resource group was created in."
  value       = azapi_resource.resource_group.location
}

output "resource_group_id" {
  description = "The resource ID of the test resource group, for use as the module parent_id."
  value       = azapi_resource.resource_group.id
}

output "virtual_network_name" {
  description = "A CAF compliant, unique virtual network name for the module under test."
  value       = module.naming.virtual_network.name_unique
}
