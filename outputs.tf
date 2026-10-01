output "name" {
  description = "Resource name."
  value       = azapi_resource.this.name
}

output "requested_address_space" {
  description = "The virtual network address space requested by the caller. This value is taken directly from the configured input and does not represent values normalized or read back from Azure."
  value       = var.address_space
}

output "resource_id" {
  description = "Resource ID."
  value       = azapi_resource.this.id
}
