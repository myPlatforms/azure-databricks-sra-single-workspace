# ---------------------------------------------------------------------------
# 부록 A - recipient workspace (another region) -> the provider-region PostgreSQL,
# private only
#
#   classic    : recipient VNet --global VNet peering--> source VNet --> PostgreSQL
#   serverless : private network gateway on the recipient NCC (envs/sra-recipient,
#                png_destinations = server FQDN) -> recipient VNet -> same peering
#   DNS        : the PostgreSQL private DNS zone gets a link to the recipient VNet
#   NSG        : PostgreSQL subnet allows 5432 from recipient host/container + gateway subnet
#
# Like envs/pg-png-access, nothing here edits envs/pg-source: the peering, zone link
# and NSG rule are separate resources on its objects (what a client team requests
# from the database owner).
#
# Databricks side (recipient workspace): a UC connection for Lakehouse Federation
# reads (reader role), a secret scope with the writer role, and a job that writes
# results back to PostgreSQL from serverless (psycopg) and classic (Spark JDBC) tasks.
# ---------------------------------------------------------------------------

data "terraform_remote_state" "client_ws" {
  backend = "local"
  config  = { path = var.client_state_path }
}

data "terraform_remote_state" "pg" {
  count   = var.pg_state_path != null ? 1 : 0
  backend = "local"
  config  = { path = var.pg_state_path }
}

locals {
  ws = data.terraform_remote_state.client_ws.outputs

  from_state = var.pg_state_path != null
  pg_state   = local.from_state ? data.terraform_remote_state.pg[0].outputs : null

  # Database-side objects: envs/pg-source outputs unless set explicitly.
  pg = {
    resource_group_name   = coalesce(var.pg_resource_group_name, try(local.pg_state.resource_group_name, null))
    vnet_name             = coalesce(var.pg_vnet_name, try(local.pg_state.vnet_name, null))
    subnet_name           = coalesce(var.pg_subnet_name, try(local.pg_state.pg_subnet_name, null))
    nsg_name              = coalesce(var.pg_nsg_name, try(local.pg_state.pg_nsg_name, null))
    private_dns_zone_name = coalesce(var.pg_private_dns_zone_name, try(local.pg_state.private_dns_zone_name, null))
    host                  = coalesce(var.pg_host, try(local.pg_state.pg_fqdn, null))
    port                  = coalesce(var.pg_port, try(local.pg_state.pg_port, null), 5432)
    database              = coalesce(var.pg_database, try(local.pg_state.database_name, null))
  }

  # Least-privilege roles from the database team; the server admin only for the
  # sample database when use_admin_credentials = true.
  admin  = var.use_admin_credentials ? { user = try(local.pg_state.admin_login, null), password = try(local.pg_state.admin_password, null) } : null
  reader = var.use_admin_credentials ? local.admin : var.pg_reader
  writer = var.use_admin_credentials ? local.admin : var.pg_writer

  client_cidrs = compact([
    local.ws.databricks_subnet_cidrs.host,
    local.ws.databricks_subnet_cidrs.container,
    try(local.ws.png_subnet_cidr, null),
  ])

  secret_scope    = coalesce(var.secret_scope, "${var.name_prefix}-pg")
  connection_name = coalesce(var.connection_name, "${replace(var.name_prefix, "-", "_")}_pg")
  workspace_dir   = coalesce(var.workspace_dir, "/Shared/${var.name_prefix}/recipient-pg-access")
  create_schema   = var.use_admin_credentials || var.create_target_schema
}

resource "terraform_data" "credentials_check" {
  lifecycle {
    precondition {
      condition     = var.use_admin_credentials ? local.from_state : (var.pg_reader != null && var.pg_writer != null)
      error_message = "Set pg_reader and pg_writer (roles from the database team). use_admin_credentials = true works only with the sample database (pg_state_path)."
    }
  }
}

data "azurerm_virtual_network" "ingestion" {
  name                = local.pg.vnet_name
  resource_group_name = local.pg.resource_group_name
}

data "azurerm_subnet" "pg" {
  name                 = local.pg.subnet_name
  virtual_network_name = local.pg.vnet_name
  resource_group_name  = local.pg.resource_group_name
}

data "azurerm_private_dns_zone" "pg" {
  name                = local.pg.private_dns_zone_name
  resource_group_name = local.pg.resource_group_name
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

resource "azurerm_virtual_network_peering" "client_to_ingestion" {
  name                         = "peer-${local.ws.virtual_network_name}-to-${local.pg.vnet_name}"
  resource_group_name          = local.ws.resource_group_name
  virtual_network_name         = local.ws.virtual_network_name
  remote_virtual_network_id    = data.azurerm_virtual_network.ingestion.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
}

resource "azurerm_virtual_network_peering" "ingestion_to_client" {
  name                         = "peer-${local.pg.vnet_name}-to-${local.ws.virtual_network_name}"
  resource_group_name          = local.pg.resource_group_name
  virtual_network_name         = local.pg.vnet_name
  remote_virtual_network_id    = local.ws.vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
}

resource "azurerm_private_dns_zone_virtual_network_link" "client" {
  name                 = "${var.name_prefix}-client"
  private_dns_zone_id  = data.azurerm_private_dns_zone.pg.id
  virtual_network_id   = local.ws.vnet_id
  registration_enabled = false
}

# Before the database stack's deny rule for other VNet sources (priority 200).
resource "azurerm_network_security_rule" "pg_from_client" {
  name                        = "Allow-PostgreSQL-from-${var.name_prefix}"
  priority                    = var.rule_priority
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "5432"
  source_address_prefixes     = local.client_cidrs
  destination_address_prefix  = data.azurerm_subnet.pg.address_prefixes[0]
  resource_group_name         = local.pg.resource_group_name
  network_security_group_name = local.pg.nsg_name
}

# ---------------------------------------------------------------------------
# Databricks (recipient workspace)
# ---------------------------------------------------------------------------

resource "databricks_secret_scope" "pg" {
  name = local.secret_scope
}

# Writer role: USAGE, CREATE on the target schema only (guide 부록 A.2).
resource "databricks_secret" "pg" {
  for_each = toset(["pg-host", "pg-database", "pg-user", "pg-password"])

  scope = databricks_secret_scope.pg.id
  key   = each.key
  string_value = {
    "pg-host"     = local.pg.host
    "pg-database" = local.pg.database
    "pg-user"     = try(local.writer.user, "")
    "pg-password" = try(local.writer.password, "")
  }[each.key]

  depends_on = [terraform_data.credentials_check]
}

# Lakehouse Federation (read, reader role). remote_query / foreign catalog from
# serverless go through the private network gateway, from classic through the peering.
resource "databricks_connection" "pg" {
  name            = local.connection_name
  connection_type = "POSTGRESQL"
  comment         = "PostgreSQL in the provider region (private only) - read-only role"
  options = {
    host     = local.pg.host
    port     = tostring(local.pg.port)
    user     = try(local.reader.user, "")
    password = try(local.reader.password, "")
  }

  depends_on = [terraform_data.credentials_check]
}

resource "databricks_directory" "sample" {
  path = local.workspace_dir
}

resource "databricks_notebook" "write" {
  path     = "${databricks_directory.sample.path}/03_write_to_pg"
  source   = "${path.module}/../../samples/opensharing/03_write_to_pg.py"
  language = "PYTHON"
}

data "databricks_spark_version" "lts" {
  long_term_support = true
}

data "databricks_current_user" "me" {}

locals {
  write_parameters = {
    secret_scope  = databricks_secret_scope.pg.name
    source_table  = var.source_table
    create_schema = tostring(local.create_schema)
    loaded_by     = var.name_prefix
  }
}

# Two tasks, same notebook: one per network path.
resource "databricks_job" "write" {
  name = "${var.name_prefix}-write-to-pg"

  environment {
    environment_key = "psycopg"
    spec {
      environment_version = "4"
      dependencies        = ["psycopg[binary]>=3.2,<4"]
    }
  }

  job_cluster {
    job_cluster_key = "classic"
    new_cluster {
      spark_version      = data.databricks_spark_version.lts.id
      node_type_id       = var.job_node_type_id
      num_workers        = 0
      data_security_mode = "SINGLE_USER"
      single_user_name   = data.databricks_current_user.me.user_name
      spark_conf = {
        "spark.databricks.cluster.profile" = "singleNode"
        "spark.master"                     = "local[*]"
      }
      custom_tags = { "ResourceClass" = "SingleNode" }
    }
  }

  task {
    task_key        = "serverless_psycopg"
    environment_key = "psycopg"
    notebook_task {
      notebook_path = databricks_notebook.write.path
      base_parameters = merge(local.write_parameters, {
        target_table = "${var.target_schema}.${var.target_table_base}_serverless"
        writer       = "psycopg"
      })
    }
  }

  task {
    task_key        = "classic_jdbc"
    job_cluster_key = "classic"
    notebook_task {
      notebook_path = databricks_notebook.write.path
      base_parameters = merge(local.write_parameters, {
        target_table = "${var.target_schema}.${var.target_table_base}_classic"
        writer       = "jdbc"
      })
    }
  }

  depends_on = [databricks_secret.pg]
}
