terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.12"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {
    postgresql_flexible_server {
      # wal_level is a static parameter: the server must restart for it to apply.
      restart_server_on_configuration_value_change = true
    }
  }
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}
