output "name" {
  description = "Resource name."
  value       = azurerm_resource_group.this.name
}

output "resource_id" {
  description = "Resource ID."
  value       = azurerm_resource_group.this.id
}
