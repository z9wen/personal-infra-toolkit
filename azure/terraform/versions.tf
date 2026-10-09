terraform {
  required_version = ">= 1.11"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Local state keeps this demo self-contained. For shared use, switch to an
  # "azurerm" backend in a Storage Account with blob lease locking.
}

provider "azurerm" {
  # The subscription comes from ARM_SUBSCRIPTION_ID or the Azure CLI login.
  features {}
}
