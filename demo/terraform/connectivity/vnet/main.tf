resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

locals {
  tags = {
    Environment = "Connectivity"
    CostCenter  = "CC-4711"
    Department  = "Platform"
  }
}

module "vnet" {
  source              = "../../modules/vnet"
  name                = "ctso-conn-weu-vnet"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = ["10.101.0.0/16"]
  tags                = local.tags

  subnets = {
    "snet-aks"      = { prefixes = ["10.101.8.0/22"] }
    "snet-endpoint" = { prefixes = ["10.101.12.0/24"] }
  }
}

# Source-region resolver. The DR posture strips this until the DR resolver exists.
resource "azurerm_virtual_network_dns_servers" "this" {
  virtual_network_id = module.vnet.id
  dns_servers        = ["10.101.1.4"]
}
