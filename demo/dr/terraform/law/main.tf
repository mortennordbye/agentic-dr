resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

locals {
  tags = {
    Environment = "DR"
    CostCenter  = "CC-4711"
    Department  = "Platform"
  }
}

# Telemetry sink for the DR estate. Consumers (the DR aks root) resolve it by name through a
# data lookup, so the name below is the contract: ctso-dr-prod-neu-law in the DR observability RG.
module "law" {
  source              = "../../../terraform/modules/law"
  name                = "ctso-dr-prod-neu-law"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}
