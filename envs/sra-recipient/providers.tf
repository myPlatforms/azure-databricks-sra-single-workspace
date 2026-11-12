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
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
}

# Azure: az CLI login (az login --tenant <tenant>) unless ARM_* env vars are set.
provider "azurerm" {
  features {
    # The UC root storage account has public network access disabled, so the
    # machine running Terraform cannot reach its data plane. Without this the
    # provider fails reading blob / queue properties on every refresh.
    storage {
      data_plane_available = false
    }
  }
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id
}

# Account level: NCC, network policy, metastore, assignment.
# profile = a ~/.databrickscfg entry for accounts.azuredatabricks.net; null falls
# back to unified auth (DATABRICKS_* env vars, then az CLI).
provider "databricks" {
  alias      = "account"
  host       = "https://accounts.azuredatabricks.net"
  account_id = var.databricks_account_id
  profile    = var.databricks_account_profile
}

# Workspace level (second apply): IP access list, catalog, legacy access setting.
# The URL does not exist until the workspace is created: leave workspace_url null on
# the first apply, then set it from the workspace_url output and apply again.
provider "databricks" {
  alias   = "workspace"
  host    = var.workspace_url
  profile = var.databricks_workspace_profile
}
