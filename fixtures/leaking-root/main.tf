# Fixture: a DR root that leaked the source estate. engine/lint.sh must exit 1 on this directory.
#
# Every violation below is a real failure mode a Component Builder can produce by doing a blind
# find/replace instead of a semantic transform. One fixture per class would be tidier; one fixture
# with all of them is what actually catches a lint that silently stopped loading a pattern kind.

terraform {
  required_version = ">= 1.12.2"
}

provider "azurerm" {
  features {}
  # violation: subscription hardcoded instead of left to the runtime OIDC variable
  subscription_id = "00000000-0000-0000-0000-000000000001"
}

module "vnet" {
  # violation: source-depth module path, not rewritten for the DR root's extra nesting
  source = "../../modules/vnet"

  # violation: source region left in place
  name     = "ctso-prod-weu-vnet"
  location = "westeurope"

  # violation: source CIDR, so DR would build on top of the source IP plan
  address_space = ["10.100.0.0/16"]

  # violation: network_contributor_principal_id omitted entirely, silently inheriting the source
  # identity from the module default. This is why that check is a presence check.

  tags = {
    # violation: Environment tag not flipped to the DR value
    Environment = "Production"
  }
}

resource "azurerm_dns_a_record" "resolver" {
  # violation: source-region DNS resolver
  records = ["10.101.1.4"]
}
