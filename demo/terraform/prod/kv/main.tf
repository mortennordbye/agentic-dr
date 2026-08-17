# Excluded by agentic-dr/profile/scope-rules.md: the DR equivalent is a pre-staged replication
# target that references the source region, so it cannot be generator output.
resource "azurerm_key_vault" "this" {
  name                = "ctso-prod-weu-kv"
  location            = "westeurope"
  resource_group_name = "ctso-prod-weu-platform-rg"
  tenant_id           = "00000000-0000-0000-0000-00000000000f"
  sku_name            = "standard"
}
