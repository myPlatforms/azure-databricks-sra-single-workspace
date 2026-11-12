terraform {
  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.141"
    }
  }
}

# Account level: the OpenSharing NCC and its private endpoint rules.
provider "databricks" {
  alias      = "account"
  host       = "https://accounts.azuredatabricks.net"
  account_id = var.databricks_account_id
  profile    = var.databricks_account_profile
}

# Provider side: share, recipient, grants.
provider "databricks" {
  alias = "provider"
  host  = data.terraform_remote_state.provider_ws.outputs.workspace_url
  # Set here, not via DATABRICKS_AUTH_TYPE: that env var would also override the
  # account provider's profile.
  auth_type = "azure-cli"
}

# Recipient side: catalog created from the share.
provider "databricks" {
  alias = "recipient"
  host  = data.terraform_remote_state.recipient_ws.outputs.workspace_url
  # Set here, not via DATABRICKS_AUTH_TYPE: that env var would also override the
  # account provider's profile.
  auth_type = "azure-cli"
}
