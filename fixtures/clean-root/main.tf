# Fixture: a correctly generated DR root. engine/lint.sh must exit 0 on this directory.
#
# Provenance comment naming the source estate on purpose: lint.sh strips HCL comments before
# matching, so mentioning westeurope or ctso-prod- here must NOT trip the lint. If this fixture
# starts failing, the comment-stripping regressed.
# Generated from the source root at terraform/prod/storage (westeurope, ctso-prod-*).

terraform {
  required_version = ">= 1.12.2"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

module "vnet" {
  source = "../../../terraform/modules/vnet"

  name                                = "ctso-dr-prod-neu-vnet"
  location                            = "northeurope"
  address_space                       = ["10.200.0.0/16"]
  network_contributor_principal_id    = "00000000-0000-0000-0000-0000000000b1"

  tags = {
    Environment = "DR"
    CostCenter  = "42"
  }
}

resource "azurerm_storage_account" "this" {
  name                = "ctsodrprodneusa"
  location            = "northeurope"
  resource_group_name = azurerm_resource_group.this.name

  # DR-DEFER: firewall private IP of the DR hub
  # (the hub applies after this root; the value cannot exist at codegen time)
}
