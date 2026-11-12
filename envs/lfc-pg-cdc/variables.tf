variable "workspace_state_path" {
  description = "State of the provider workspace stack (outputs workspace_url, catalog_name)."
  type        = string
  default     = "../sra-provider/terraform.tfstate"
}

variable "pg_state_path" {
  description = "State of envs/pg-source (sample database). null = existing database: set pg_connection."
  type        = string
  default     = "../pg-source/terraform.tfstate"
}

variable "pg_connection" {
  description = "Existing database (pg_state_path = null): server FQDN, database and the replication user the database team created (guide 1.7)."
  type = object({
    host                 = string
    port                 = optional(number, 5432)
    database             = string
    replication_user     = string
    replication_password = string
  })
  default   = null
  sensitive = true

  validation {
    condition     = var.pg_connection == null || try(length(var.pg_connection.host) > 0, false)
    error_message = "pg_connection.host must be set."
  }
}

variable "databricks_workspace_profile" {
  description = "~/.databrickscfg profile for the workspace. null = unified auth (az CLI)."
  type        = string
  default     = null
}

variable "name_prefix" {
  description = "Prefix of the connection, pipelines, jobs and secret scopes (letters, digits, dashes)."
  type        = string
}

variable "catalog_name" {
  description = "Target catalog. null = the starter catalog of envs/sra-provider."
  type        = string
  default     = null
}

variable "destination_schema" {
  description = "Schema of the destination streaming tables."
  type        = string
}

variable "staging_schema" {
  description = "Schema of the gateway staging volume."
  type        = string
  default     = "lfc_staging"
}

variable "source_schemas" {
  description = "PostgreSQL schemas to ingest (all tables in each). Default = the AdventureWorks sample."
  type        = list(string)
  default     = ["person", "production", "purchasing", "sales"]
}

variable "publication_name" {
  type    = string
  default = "databricks_publication"
}

variable "slot_name" {
  type    = string
  default = "databricks_slot"
}

variable "enable_sample_jobs" {
  description = "Sample database only: secret scopes, notebooks and the load / changes jobs (they use the server admin). Set false for an existing database, or after the demo."
  type        = bool
  default     = true
}

variable "secret_scope" {
  description = "Sample jobs: scope name (the admin scope gets an -admin suffix). null = <name_prefix>-pg."
  type        = string
  default     = null
}

variable "workspace_dir" {
  description = "Sample jobs: workspace folder of the notebooks. null = /Shared/<name_prefix>/adventureworks-pg."
  type        = string
  default     = null
}

variable "job_node_type_id" {
  description = "Single-node cluster for the sample notebooks."
  type        = string
  default     = "Standard_D4ads_v5"
}

variable "enable_ingestion" {
  description = "Step 2: UC connection, ingestion gateway and ingestion pipeline. The publication and slot must exist first."
  type        = bool
  default     = false
}

variable "gateway_driver_node_type_id" {
  description = "Docs: at least 8 cores. Standard_D8as_v4 is a low-cost 8-core option."
  type        = string
  default     = "Standard_D8as_v4"
}

variable "gateway_worker_node_type_id" {
  description = "Workers do not affect gateway performance: smallest size."
  type        = string
  default     = "Standard_D4a_v4"
}

variable "gateway_num_workers" {
  type    = number
  default = 1
}

variable "ingestion_continuous" {
  description = "false = triggered (run it on a schedule); true = continuous serverless."
  type        = bool
  default     = false
}

variable "ingestion_schedule_cron" {
  description = "Quartz cron for a job that runs the triggered ingestion pipeline, e.g. \"0 0 * * * ?\" (hourly). null = no job."
  type        = string
  default     = null
}

variable "ingestion_schedule_timezone" {
  type    = string
  default = "UTC"
}
