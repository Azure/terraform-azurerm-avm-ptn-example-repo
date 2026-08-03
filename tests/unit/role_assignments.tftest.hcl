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
  address_space    = ["10.0.0.0/16"]
  location         = "uksouth"
  name             = "vnet-unit-test"
  parent_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-unit-test"
  enable_telemetry = false
}

run "uses_a_fully_qualified_role_definition_id_verbatim" {
  command = apply

  variables {
    role_assignments = {
      reader = {
        role_definition_id_or_name = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
        principal_id               = "11111111-1111-1111-1111-111111111111"
      }
    }
  }

  assert {
    condition     = length(azapi_resource.role_assignment) == 1
    error_message = "One role assignment must be created for each entry in var.role_assignments."
  }

  assert {
    condition     = azapi_resource.role_assignment["reader"].body.properties.roleDefinitionId == var.role_assignments["reader"].role_definition_id_or_name
    error_message = "A fully qualified role definition ID must be used without a lookup."
  }

  assert {
    condition     = azapi_resource.role_assignment["reader"].body.properties.principalId == var.role_assignments["reader"].principal_id
    error_message = "The principal ID must be forwarded to the role assignment."
  }

  assert {
    condition     = length(local.role_definition_names) == 0
    error_message = "A fully qualified role definition ID must not trigger a role definition name lookup."
  }
}

run "omits_optional_role_assignment_properties_when_unset" {
  command = apply

  variables {
    role_assignments = {
      reader = {
        role_definition_id_or_name = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
        principal_id               = "11111111-1111-1111-1111-111111111111"
      }
    }
  }

  assert {
    condition     = !can(azapi_resource.role_assignment["reader"].body.properties.description)
    error_message = "An unset description must be omitted from the request body entirely."
  }

  assert {
    condition     = !can(azapi_resource.role_assignment["reader"].body.properties.condition)
    error_message = "An unset condition must be omitted from the request body entirely."
  }
}

run "forwards_optional_role_assignment_properties_when_set" {
  command = apply

  variables {
    role_assignments = {
      contributor = {
        role_definition_id_or_name = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c"
        principal_id               = "22222222-2222-2222-2222-222222222222"
        description                = "Grants contributor access."
        principal_type             = "ServicePrincipal"
        condition                  = "@Resource[Microsoft.Network/virtualNetworks] StringEquals 'x'"
        condition_version          = "2.0"
      }
    }
  }

  assert {
    condition     = azapi_resource.role_assignment["contributor"].body.properties.description == "Grants contributor access."
    error_message = "A supplied description must be forwarded to the role assignment."
  }

  assert {
    condition     = azapi_resource.role_assignment["contributor"].body.properties.principalType == "ServicePrincipal"
    error_message = "A supplied principal type must be forwarded to the role assignment."
  }

  assert {
    condition     = azapi_resource.role_assignment["contributor"].body.properties.conditionVersion == "2.0"
    error_message = "A supplied condition version must be forwarded to the role assignment."
  }
}

run "creates_one_role_assignment_per_map_entry" {
  command = apply

  variables {
    role_assignments = {
      reader = {
        role_definition_id_or_name = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7"
        principal_id               = "11111111-1111-1111-1111-111111111111"
      }
      contributor = {
        role_definition_id_or_name = "/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c"
        principal_id               = "22222222-2222-2222-2222-222222222222"
      }
    }
  }

  assert {
    condition     = length(azapi_resource.role_assignment) == 2
    error_message = "Each role assignment map entry must produce its own resource."
  }

  assert {
    condition     = azapi_resource.role_assignment["reader"].name != azapi_resource.role_assignment["contributor"].name
    error_message = "Each role assignment must get a distinct deterministic name."
  }
}
