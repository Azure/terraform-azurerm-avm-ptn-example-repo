terraform {
  required_version = "~> 1.5"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.21"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}

provider "azurerm" {
  features {}
}

module "regions" {
  source  = "Azure/avm-utl-regions/azurerm"
  version = "0.9.2"
}

locals {
  all_regions = { for region in module.regions.regions : region.name => region.name }
  resource_group_names = {
    for key, value in local.all_regions : key => "rg-${key}-${random_string.resource_group_name_suffix[key].result}"
  }
}

resource "random_string" "resource_group_name_suffix" {
  for_each = local.all_regions

  length  = 4
  special = false
  upper   = false
}

resource "azapi_resource" "this" {
  for_each = local.all_regions

  location = each.key
  name     = local.resource_group_names[each.key]
  type     = "Microsoft.Resources/resourceGroups@2025-04-01"
}
