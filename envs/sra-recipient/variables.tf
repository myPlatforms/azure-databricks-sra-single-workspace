variable "subscription_id" {
  type = string
}

variable "tenant_id" {
  description = "Microsoft Entra tenant ID or domain. null = az CLI default."
  type        = string
  default     = null
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "prefix" {
  description = "Name prefix for Azure and Databricks objects (letters, digits, dashes)."
  type        = string
}

variable "workspace_name" {
  type    = string
  default = null
}

variable "tags" {
  description = "Tags on every Azure resource; workspace tags also reach the managed RG and cluster VMs."
  type        = map(string)
  default     = {}
}

variable "vnet_cidr" {
  type = string
}

variable "subnet_cidrs" {
  description = "host / container (delegated to Databricks) and privatelink (backend + 4 storage private endpoints, /28 or larger)."
  type = object({
    host        = string
    container   = string
    privatelink = string
  })
}

variable "enable_private_network_gateway" {
  description = "Private network gateway on the NCC (Public Preview): serverless reaches png_destinations through png_subnet_cidr and this VNet's peerings."
  type        = bool
  default     = false
}

variable "png_subnet_cidr" {
  description = "Dedicated gateway subnet (/28 or larger) inside vnet_cidr. Used when enable_private_network_gateway = true."
  type        = string
  default     = null
}

variable "png_bandwidth_gbps" {
  type    = number
  default = 10
}

variable "png_destinations" {
  description = "Exact FQDNs routed through the gateway (suffix match: keep them specific, e.g. <server>.postgres.database.azure.com). Also added to the serverless network policy allow list."
  type        = list(string)
  default     = []
}

variable "databricks_account_id" {
  type = string
}

variable "databricks_account_profile" {
  description = "~/.databrickscfg profile for accounts.azuredatabricks.net. null = unified auth."
  type        = string
  default     = null
}

variable "databricks_workspace_profile" {
  description = "~/.databrickscfg profile for the workspace. null = unified auth (az CLI)."
  type        = string
  default     = null
}

variable "network_policy_enforcement_mode" {
  type    = string
  default = "ENFORCED"
}

variable "serverless_allowed_fqdns" {
  type    = list(string)
  default = ["pypi.org", "files.pythonhosted.org"]
}

variable "metastore_force_destroy" {
  description = "Set true and apply before terraform destroy, so the metastore and catalog go even when they hold objects."
  type        = bool
  default     = false
}

variable "metastore_delta_sharing" {
  description = "See the module variable. Set INTERNAL_AND_EXTERNAL on a provider metastore that uses SecureConnect."
  type = object({
    scope                            = string
    recipient_token_lifetime_seconds = optional(number)
    organization_name                = optional(string)
  })
  default = null
}

variable "catalog_name" {
  type    = string
  default = null
}

variable "client_allowed_cidrs" {
  description = "Workspace IP access list (second apply). The NAT gateway IP is added by the module."
  type        = list(string)
  default     = []
}

variable "disable_legacy_access" {
  type    = bool
  default = true
}

variable "workspace_url" {
  description = "null on the first apply; then the workspace_url output (kept in runtime.auto.tfvars)."
  type        = string
  default     = null
}

variable "uc_storage_bypass_azure_services" {
  description = "Trusted Azure services exception on the UC root storage firewall. Learn recommends false once the access connector resource instance rule exists (the module adds it)."
  type        = bool
  default     = true
}
