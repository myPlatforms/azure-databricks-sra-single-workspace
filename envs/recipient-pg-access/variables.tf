variable "subscription_id" {
  description = "Subscription of the recipient workspace VNet and the PostgreSQL network objects (one subscription in this sample)."
  type        = string
}

variable "tenant_id" {
  type    = string
  default = null
}

variable "client_state_path" {
  description = "Recipient workspace stack (outputs workspace_url, vnet_id, virtual_network_name, resource_group_name, databricks_subnet_cidrs, png_subnet_cidr)."
  type        = string
  default     = "../sra-recipient/terraform.tfstate"
}

variable "pg_state_path" {
  description = "State of envs/pg-source. null = existing database: set the pg_* values below."
  type        = string
  default     = "../pg-source/terraform.tfstate"
}

variable "pg_resource_group_name" {
  type    = string
  default = null
}

variable "pg_vnet_name" {
  type    = string
  default = null
}

variable "pg_subnet_name" {
  type    = string
  default = null
}

variable "pg_nsg_name" {
  type    = string
  default = null
}

variable "pg_private_dns_zone_name" {
  description = "<name>.private.postgres.database.azure.com zone of the VNet-integrated server."
  type        = string
  default     = null
}

variable "pg_host" {
  type    = string
  default = null
}

variable "pg_port" {
  type    = number
  default = null
}

variable "pg_database" {
  type    = string
  default = null
}

variable "pg_reader" {
  description = "Role for the UC connection (Lakehouse Federation reads): SELECT on the schemas it needs."
  type = object({
    user     = string
    password = string
  })
  default   = null
  sensitive = true
}

variable "pg_writer" {
  description = "Role for the write job: USAGE, CREATE on target_schema only (GRANT USAGE, CREATE ON SCHEMA <target_schema> TO <writer>)."
  type = object({
    user     = string
    password = string
  })
  default   = null
  sensitive = true
}

variable "use_admin_credentials" {
  description = "Sample database only: use the server admin of envs/pg-source for both instead of pg_reader / pg_writer."
  type        = bool
  default     = false
}

variable "name_prefix" {
  description = "Prefix of the network rule, zone link, secret scope, connection and job (letters, digits, dashes)."
  type        = string
}

variable "secret_scope" {
  description = "null = <name_prefix>-pg."
  type        = string
  default     = null
}

variable "connection_name" {
  description = "null = <name_prefix>_pg (dashes become underscores)."
  type        = string
  default     = null
}

variable "workspace_dir" {
  description = "null = /Shared/<name_prefix>/recipient-pg-access."
  type        = string
  default     = null
}

variable "rule_priority" {
  description = "Must come before (be lower than) the database stack's deny rule for other VNet sources (200)."
  type        = number
  default     = 120
}

variable "source_table" {
  description = "Read in the recipient workspace and aggregated before the write, e.g. the shared view <shared-catalog>.<share-schema>.v_orders_europe."
  type        = string
}

variable "target_schema" {
  description = "PostgreSQL schema the job writes to."
  type        = string
  default     = "reporting"
}

variable "target_table_base" {
  description = "Tables <target_schema>.<base>_serverless and <base>_classic."
  type        = string
  default     = "orders_daily"
}

variable "create_target_schema" {
  description = "Let the job run CREATE SCHEMA IF NOT EXISTS (needs CREATE on the database). Leave false when the database team created the schema. Always true with use_admin_credentials."
  type        = bool
  default     = false
}

variable "job_node_type_id" {
  type    = string
  default = "Standard_D4ads_v5"
}
