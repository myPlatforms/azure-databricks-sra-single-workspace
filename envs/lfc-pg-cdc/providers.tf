terraform {
  required_providers {
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.141"
    }
  }
}

# Provider workspace (envs/sra-provider). Its IP access list must allow the machine
# running Terraform (client_allowed_cidrs there).
provider "databricks" {
  host    = data.terraform_remote_state.workspace.outputs.workspace_url
  profile = var.databricks_workspace_profile
}
