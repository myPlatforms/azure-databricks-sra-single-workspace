terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.12"
    }
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.141"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}

# Recipient workspace (the client of the provider-region database).
provider "databricks" {
  host      = data.terraform_remote_state.client_ws.outputs.workspace_url
  auth_type = "azure-cli"
}
