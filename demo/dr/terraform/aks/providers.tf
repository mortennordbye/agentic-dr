terraform {
  required_version = ">= 1.12.2"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

# subscription_id stays a runtime variable injected by the DR pipeline (OIDC) — never hardcoded.
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}
