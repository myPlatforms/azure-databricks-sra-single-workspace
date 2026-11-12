variable "subscription_id" {
  description = "Subscription of the PostgreSQL network objects."
  type        = string
}

variable "tenant_id" {
  type    = string
  default = null
}

variable "workspace_state_path" {
  description = "State of the provider workspace stack (output png_subnet_cidr)."
  type        = string
  default     = "../sra-provider/terraform.tfstate"
}

variable "pg_state_path" {
  description = "State of envs/pg-source. null = existing database: set the pg_* names below."
  type        = string
  default     = "../pg-source/terraform.tfstate"
}

variable "pg_resource_group_name" {
  description = "Overrides the envs/pg-source value."
  type        = string
  default     = null
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
  description = "NSG on the PostgreSQL subnet."
  type        = string
  default     = null
}

variable "rule_priority" {
  description = "Must be lower (evaluated earlier) than the database stack's deny rule for other VNet sources (200 in envs/pg-source)."
  type        = number
  default     = 110
}
