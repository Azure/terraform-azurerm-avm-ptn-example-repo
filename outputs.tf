output "name" {
  description = "Resource name."
  value       = azurerm_virtual_network.this.name
}

output "resource_id" {
  description = "Resource ID."
  value       = azurerm_virtual_network.this.id
}
