# DR root for the `law` component. Generated from the prod root at terraform/prod/law.
# State workspace: tfc-dr-law (created out of band; its working directory must be set by hand).
terraform {
  required_version = ">= 1.12.2"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

# subscription_id stays a variable: the DR pipeline injects it at runtime via OIDC.
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}
