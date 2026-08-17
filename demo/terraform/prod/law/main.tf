resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

locals {
  tags = {
    Environment = "Production"
    CostCenter  = "CC-4711"
    Department  = "Platform"
  }
}

module "law" {
  source              = "../../modules/law"
  name                = "ctso-prod-weu-law"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}
