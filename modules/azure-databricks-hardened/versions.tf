terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.0"
    }
    # Two provider configurations are passed in by the caller:
    #   databricks           - account level (accounts.azuredatabricks.net)
    #   databricks.workspace - workspace level, for IP access lists / workspace conf
    # The workspace host is only knowable after the workspace exists, so the caller
    # supplies it as a variable. See var.workspace_url.
    databricks = {
      source = "databricks/databricks"
      # databricks_private_network_gateway first shipped in v1.137.0.
      version               = ">= 1.137.0"
      configuration_aliases = [databricks.workspace]
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.11"
    }
  }
}
