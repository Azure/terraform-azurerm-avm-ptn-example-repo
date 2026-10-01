mock_provider "azapi" {}
mock_provider "modtm" {}
mock_provider "random" {}

variables {
  address_space    = ["10.0.0.0/16"]
  location         = "uksouth"
  name             = "vnet-unit-test"
  parent_id        = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-unit-test"
  enable_telemetry = false
}

run "derives_the_lock_name_from_the_kind_when_none_is_supplied" {
  command = plan

  variables {
    lock = {
      kind = "CanNotDelete"
    }
  }

  assert {
    condition     = azapi_resource.lock[0].name == "lock-CanNotDelete"
    error_message = "An unnamed lock must fall back to 'lock-<kind>'."
  }

  assert {
    condition     = azapi_resource.lock[0].body.properties.level == "CanNotDelete"
    error_message = "The lock level must come from var.lock.kind."
  }

  assert {
    condition     = azapi_resource.lock[0].body.properties.notes == "Cannot delete the resource or its child resources."
    error_message = "A CanNotDelete lock must carry the delete-scoped note."
  }

  assert {
    condition     = azapi_resource.lock[0].type == var.resource_types.authorization_locks
    error_message = "The lock resource must use the configured resource type."
  }
}

run "honours_an_explicit_lock_name" {
  command = plan

  variables {
    lock = {
      kind = "ReadOnly"
      name = "my-custom-lock"
    }
  }

  assert {
    condition     = azapi_resource.lock[0].name == "my-custom-lock"
    error_message = "An explicit lock name must win over the derived default."
  }

  assert {
    condition     = azapi_resource.lock[0].body.properties.notes == "Cannot delete or modify the resource or its child resources."
    error_message = "A ReadOnly lock must carry the modify-scoped note."
  }
}

run "honours_explicit_lock_notes" {
  command = plan

  variables {
    lock = {
      kind  = "ReadOnly"
      notes = "Managed by the platform team."
    }
  }

  assert {
    condition     = azapi_resource.lock[0].body.properties.notes == "Managed by the platform team."
    error_message = "Explicit lock notes must override the generated default."
  }
}

run "rejects_an_unsupported_lock_kind" {
  command = plan

  variables {
    lock = {
      kind = "NotALockKind"
    }
  }

  expect_failures = [var.lock]
}
