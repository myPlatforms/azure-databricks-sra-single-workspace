variable "subscription_id" {
  type = string
}

variable "tenant_id" {
  type    = string
  default = null
}

variable "workspace_state_path" {
  description = "Local state of the workspace stack whose VNet gets peered (outputs vnet_id, virtual_network_name, resource_group_name, databricks_subnet_cidrs)."
  type        = string
  default     = "../sra-provider/terraform.tfstate"
}

variable "location" {
  description = "Same region as the provider workspace."
  type        = string
}

variable "resource_group_name" {
  type = string
}

variable "prefix" {
  description = "Name prefix for the server (<prefix>-<random>) and its private DNS zone."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "vnet_name" {
  type    = string
  default = "vnet-ingestion"
}

variable "vnet_cidr" {
  description = "Must not overlap the workspace VNet (peering)."
  type        = string
}

variable "pg_subnet_cidr" {
  description = "Delegated to Microsoft.DBforPostgreSQL/flexibleServers, used by nothing else."
  type        = string
}

variable "pg_version" {
  description = "Lakeflow Connect supports PostgreSQL 13 and later."
  type        = string
  default     = "16"
}

variable "pg_sku_name" {
  type    = string
  default = "GP_Standard_D2ds_v5"
}

variable "pg_storage_mb" {
  type    = number
  default = 32768
}

variable "admin_login" {
  type    = string
  default = "pgadmin"
}

variable "database_name" {
  type    = string
  default = "adventureworks"
}

variable "replication_user" {
  description = "Created by the source setup job of envs/lfc-pg-cdc (sample) or by the database team, not by Terraform (Terraform cannot reach the private server)."
  type        = string
  default     = "databricks_replication"
}

variable "max_replication_slots" {
  type    = number
  default = 10
}

variable "max_wal_senders" {
  type    = number
  default = 10
}

variable "max_slot_wal_keep_size_mb" {
  description = "Cap on WAL kept for a lagging slot (MB). Leave null on Azure Database for PostgreSQL: the parameter is read-only there, fixed at -1 (Lakeflow Connect PostgreSQL limitations)."
  type        = number
  default     = null
}
