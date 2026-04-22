resource "azapi_resource" "this" {
  location  = var.location
  name      = var.name
  parent_id = var.parent_id
  type      = "Microsoft.Network/virtualNetworks@2025-05-01"
  body = {
    properties = {
      addressSpace = {
        addressPrefixes = var.address_space
      }
    }
  }
  create_headers         = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  delete_headers         = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  read_headers           = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  response_export_values = []
  tags                   = var.tags
  update_headers         = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
}

resource "azapi_resource" "lock" {
  count = var.lock != null ? 1 : 0

  name      = coalesce(var.lock.name, "lock-${var.lock.kind}")
  parent_id = azapi_resource.this.id
  type      = "Microsoft.Authorization/locks@2020-05-01"
  body = {
    properties = {
      level = var.lock.kind
      notes = var.lock.kind == "CanNotDelete" ? "Cannot delete the resource or its child resources." : "Cannot delete or modify the resource or its child resources."
    }
  }
  create_headers         = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  delete_headers         = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  read_headers           = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  response_export_values = []
  update_headers         = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
}

locals {
  role_definition_names              = toset([for ra in var.role_assignments : ra.role_definition_id_or_name if !strcontains(lower(ra.role_definition_id_or_name), lower(local.role_definition_resource_substring))])
  role_definition_resource_substring = "/providers/Microsoft.Authorization/roleDefinitions"
}

data "azapi_resource_list" "role_definitions" {
  for_each = local.role_definition_names

  parent_id = var.parent_id
  type      = "Microsoft.Authorization/roleDefinitions@2022-04-01"
  query_parameters = {
    "$filter" = ["roleName eq '${each.value}'"]
  }
  response_export_values = ["value"]
}

locals {
  role_definition_id_lookup = {
    for name in local.role_definition_names :
    name => one([for r in data.azapi_resource_list.role_definitions[name].output.value : r.id])
  }
}

resource "azapi_resource" "role_assignment" {
  for_each = var.role_assignments

  name = uuidv5("dns", join("|", [
    azapi_resource.this.id,
    each.value.principal_id,
    each.value.role_definition_id_or_name,
  ]))
  parent_id = azapi_resource.this.id
  type      = "Microsoft.Authorization/roleAssignments@2022-04-01"
  body = {
    properties = merge(
      {
        principalId      = each.value.principal_id
        roleDefinitionId = strcontains(lower(each.value.role_definition_id_or_name), lower(local.role_definition_resource_substring)) ? each.value.role_definition_id_or_name : local.role_definition_id_lookup[each.value.role_definition_id_or_name]
      },
      each.value.description != null ? { description = each.value.description } : {},
      each.value.condition != null ? { condition = each.value.condition } : {},
      each.value.condition_version != null ? { conditionVersion = each.value.condition_version } : {},
      each.value.delegated_managed_identity_resource_id != null ? { delegatedManagedIdentityResourceId = each.value.delegated_managed_identity_resource_id } : {},
      each.value.principal_type != null ? { principalType = each.value.principal_type } : {},
    )
  }
  create_headers         = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  delete_headers         = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  read_headers           = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
  response_export_values = []
  update_headers         = var.enable_telemetry ? { "User-Agent" : local.avm_azapi_header } : null
}
