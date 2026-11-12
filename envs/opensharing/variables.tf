variable "databricks_account_id" {
  type = string
}

variable "databricks_account_profile" {
  type    = string
  default = null
}

variable "provider_state_path" {
  description = "Provider workspace stack (outputs workspace_url, workspace_resource_id, resource_group_name, uc_storage_account_name, location)."
  type        = string
  default     = "../sra-provider/terraform.tfstate"
}

variable "recipient_state_path" {
  description = "Recipient workspace stack (outputs workspace_url, location, metastore_id)."
  type        = string
  default     = "../sra-recipient/terraform.tfstate"
}

variable "name_prefix" {
  description = "Prefix of the OpenSharing NCC (underscores become dashes) and the default share name."
  type        = string
}

variable "share_name" {
  description = "null = <name_prefix>_share."
  type        = string
  default     = null
}

variable "source_schema" {
  description = "<catalog>.<schema> on the provider holding the shared objects (samples/opensharing/01_prepare_share_data.sql)."
  type        = string
}

variable "shared_tables" {
  description = "Managed Delta tables in source_schema, shared WITH HISTORY. Default = the sample."
  type        = list(string)
  default     = ["salesterritory", "customer", "product", "salesorderheader", "salesorderdetail"]
}

variable "shared_views" {
  type    = list(string)
  default = ["v_orders_europe"]
}

variable "enable_recipient" {
  description = "Step D. Turn on after attaching the OpenSharing NCC to the provider metastore and enabling SecureConnect for new recipients (UI)."
  type        = bool
  default     = false
}

variable "recipient_name" {
  type = string
}

variable "recipient_global_metastore_id" {
  description = "Sharing identifier of the recipient metastore. null = azure:<location>:<metastore_id> from the recipient stack."
  type        = string
  default     = null
}

variable "recipient_provider_name" {
  description = "Step E. Name of the provider object in the recipient metastore (databricks providers list on the recipient workspace). null = skip."
  type        = string
  default     = null
}

variable "recipient_catalog_name" {
  description = "Read-only catalog created from the share on the recipient side."
  type        = string
}
