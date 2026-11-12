# ---------------------------------------------------------------------------
# Lakeflow Connect PostgreSQL CDC on the provider workspace - Standard setup
# (ingestion gateway + ingestion pipeline), as documented for PostgreSQL.
#
# Step 1 (enable_ingestion = false)
#   target / staging schemas.
#   Sample database only (enable_sample_jobs = true, envs/pg-source):
#     two secret scopes (connection + replication user / admin user), the sample
#     notebooks and two jobs on classic compute in the workspace VNet:
#       load job    -> AdventureWorks load + source setup (replication user, grants,
#                      replica identity, publication, slot)
#       changes job -> INSERT / UPDATE / DELETE on the source for the CDC demo
#     Run the load job before step 2.
#   Existing database: the database team does the source setup from the Lakeflow
#   Connect docs (guide 1.7) and hands over the replication user (pg_connection).
#
# Step 2 (enable_ingestion = true)
#   UC connection (replication user) -> ingestion gateway (classic, continuous, in the
#   workspace VNet: reaches the server over the peering) -> ingestion pipeline
#   (serverless, reads the staging volume, writes streaming tables), optionally
#   scheduled by a job.
# ---------------------------------------------------------------------------

data "terraform_remote_state" "workspace" {
  backend = "local"
  config = {
    path = var.workspace_state_path
  }
}

data "terraform_remote_state" "pg" {
  count   = var.pg_state_path != null ? 1 : 0
  backend = "local"
  config = {
    path = var.pg_state_path
  }
}

locals {
  ws = data.terraform_remote_state.workspace.outputs

  from_state = var.pg_state_path != null
  pg_state   = local.from_state ? data.terraform_remote_state.pg[0].outputs : null

  # Replication user: the only credentials stored in the UC connection.
  pg = local.from_state ? {
    host                 = local.pg_state.pg_fqdn
    port                 = local.pg_state.pg_port
    database             = local.pg_state.database_name
    replication_user     = local.pg_state.replication_user
    replication_password = local.pg_state.replication_password
    } : {
    host                 = var.pg_connection.host
    port                 = var.pg_connection.port
    database             = var.pg_connection.database
    replication_user     = var.pg_connection.replication_user
    replication_password = var.pg_connection.replication_password
  }

  # Null outputs are dropped from remote state, hence try().
  catalog       = coalesce(var.catalog_name, try(local.ws.catalog_name, null))
  secret_scope  = coalesce(var.secret_scope, "${var.name_prefix}-pg")
  sample_dir    = "${path.module}/../../samples/adventureworks-pg"
  workspace_dir = coalesce(var.workspace_dir, "/Shared/${var.name_prefix}/adventureworks-pg")
  sample_jobs   = var.enable_sample_jobs ? 1 : 0
}

data "databricks_current_user" "me" {}

# ---------------------------------------------------------------------------
# Unity Catalog: destination and staging schemas
# ---------------------------------------------------------------------------

resource "databricks_schema" "destination" {
  catalog_name  = local.catalog
  name          = var.destination_schema
  comment       = "Lakeflow Connect PostgreSQL CDC target"
  force_destroy = true
}

resource "databricks_schema" "staging" {
  catalog_name  = local.catalog
  name          = var.staging_schema
  comment       = "Lakeflow Connect ingestion gateway staging volume"
  force_destroy = true
}

# ---------------------------------------------------------------------------
# Sample database only: secrets, notebooks, jobs
# ---------------------------------------------------------------------------

# Connection details + replication user (the setup notebook creates that user).
resource "databricks_secret_scope" "pg" {
  count = local.sample_jobs
  name  = local.secret_scope

  lifecycle {
    precondition {
      condition     = local.from_state
      error_message = "enable_sample_jobs needs the sample database (pg_state_path): the jobs load AdventureWorks with the server admin."
    }
  }
}

resource "databricks_secret" "pg" {
  for_each = var.enable_sample_jobs ? toset(["pg-host", "pg-database", "pg-replication-user", "pg-replication-password"]) : toset([])

  scope = databricks_secret_scope.pg[0].id
  key   = each.key
  string_value = {
    "pg-host"                 = local.pg.host
    "pg-database"             = local.pg.database
    "pg-replication-user"     = local.pg.replication_user
    "pg-replication-password" = local.pg.replication_password
  }[each.key]
}

# Server admin: a scope of its own, so its ACL can be narrower. Set
# enable_sample_jobs = false once the demo is over to remove it from the workspace.
resource "databricks_secret_scope" "pg_admin" {
  count = local.sample_jobs
  name  = "${local.secret_scope}-admin"
}

resource "databricks_secret" "pg_admin" {
  for_each = var.enable_sample_jobs ? toset(["pg-admin-user", "pg-admin-password"]) : toset([])

  scope = databricks_secret_scope.pg_admin[0].id
  key   = each.key
  string_value = {
    "pg-admin-user"     = try(local.pg_state.admin_login, null)
    "pg-admin-password" = try(local.pg_state.admin_password, null)
  }[each.key]
}

resource "databricks_directory" "sample" {
  count = local.sample_jobs
  path  = local.workspace_dir
}

resource "databricks_workspace_file" "aw_loader" {
  count  = local.sample_jobs
  path   = "${databricks_directory.sample[0].path}/aw_loader.py"
  source = "${local.sample_dir}/aw_loader.py"
}

resource "databricks_notebook" "load" {
  count    = local.sample_jobs
  path     = "${databricks_directory.sample[0].path}/01_load_adventureworks"
  source   = "${local.sample_dir}/01_load_adventureworks.py"
  language = "PYTHON"
}

resource "databricks_notebook" "changes" {
  count    = local.sample_jobs
  path     = "${databricks_directory.sample[0].path}/02_generate_changes"
  source   = "${local.sample_dir}/02_generate_changes.py"
  language = "PYTHON"
}

data "databricks_spark_version" "lts" {
  long_term_support = true
}

locals {
  # Classic compute is required: only the workspace VNet (peered) reaches the server.
  job_cluster = {
    spark_version      = data.databricks_spark_version.lts.id
    node_type_id       = var.job_node_type_id
    num_workers        = 0
    data_security_mode = "SINGLE_USER"
    single_user_name   = data.databricks_current_user.me.user_name
    spark_conf = {
      "spark.databricks.cluster.profile" = "singleNode"
      "spark.master"                     = "local[*]"
    }
    custom_tags = {
      "ResourceClass" = "SingleNode"
    }
  }
}

resource "databricks_job" "load" {
  count = local.sample_jobs
  name  = "${var.name_prefix}-load-adventureworks"

  job_cluster {
    job_cluster_key = "classic"
    new_cluster {
      spark_version      = local.job_cluster.spark_version
      node_type_id       = local.job_cluster.node_type_id
      num_workers        = local.job_cluster.num_workers
      data_security_mode = local.job_cluster.data_security_mode
      single_user_name   = local.job_cluster.single_user_name
      spark_conf         = local.job_cluster.spark_conf
      custom_tags        = local.job_cluster.custom_tags
    }
  }

  task {
    task_key        = "load"
    job_cluster_key = "classic"
    notebook_task {
      notebook_path = databricks_notebook.load[0].path
      base_parameters = {
        secret_scope       = databricks_secret_scope.pg[0].name
        admin_secret_scope = databricks_secret_scope.pg_admin[0].name
        publication        = var.publication_name
        slot               = var.slot_name
        drop_existing      = "false"
      }
    }
  }

  depends_on = [databricks_secret.pg, databricks_secret.pg_admin, databricks_workspace_file.aw_loader]
}

resource "databricks_job" "changes" {
  count = local.sample_jobs
  name  = "${var.name_prefix}-generate-cdc-changes"

  job_cluster {
    job_cluster_key = "classic"
    new_cluster {
      spark_version      = local.job_cluster.spark_version
      node_type_id       = local.job_cluster.node_type_id
      num_workers        = local.job_cluster.num_workers
      data_security_mode = local.job_cluster.data_security_mode
      single_user_name   = local.job_cluster.single_user_name
      spark_conf         = local.job_cluster.spark_conf
      custom_tags        = local.job_cluster.custom_tags
    }
  }

  task {
    task_key        = "changes"
    job_cluster_key = "classic"
    notebook_task {
      notebook_path = databricks_notebook.changes[0].path
      base_parameters = {
        secret_scope       = databricks_secret_scope.pg[0].name
        admin_secret_scope = databricks_secret_scope.pg_admin[0].name
        new_orders         = "5"
        person_updates     = "10"
      }
    }
  }

  depends_on = [databricks_secret.pg, databricks_secret.pg_admin]
}

# ---------------------------------------------------------------------------
# Step 2: connection, gateway, ingestion pipeline
# ---------------------------------------------------------------------------

resource "databricks_connection" "pg" {
  count = var.enable_ingestion ? 1 : 0

  name            = "${var.name_prefix}-pg"
  connection_type = "POSTGRESQL"
  comment         = "Azure Database for PostgreSQL (private access) - replication user"
  options = {
    host     = local.pg.host
    port     = tostring(local.pg.port)
    user     = local.pg.replication_user
    password = local.pg.replication_password
  }
}

# Classic compute in the workspace VNet ("the ingestion gateway must run on classic
# compute") and continuous: it must keep consuming the replication slot or WAL piles
# up on the source. Driver of at least 8 cores; workers are not used by the gateway.
resource "databricks_pipeline" "gateway" {
  count = var.enable_ingestion ? 1 : 0

  name       = "${var.name_prefix}-pg-gateway"
  catalog    = local.catalog
  schema     = databricks_schema.staging.name
  continuous = true

  gateway_definition {
    connection_name         = databricks_connection.pg[0].name
    gateway_storage_catalog = local.catalog
    gateway_storage_schema  = databricks_schema.staging.name
    gateway_storage_name    = "${var.name_prefix}-pg-gateway"
  }

  cluster {
    label               = "default"
    driver_node_type_id = var.gateway_driver_node_type_id
    node_type_id        = var.gateway_worker_node_type_id
    num_workers         = var.gateway_num_workers
  }

  event_log {
    name = "event_log_pg_gateway"
  }
}

resource "databricks_pipeline" "ingestion" {
  count = var.enable_ingestion ? 1 : 0

  name       = "${var.name_prefix}-pg-ingestion"
  catalog    = local.catalog
  schema     = databricks_schema.destination.name
  continuous = var.ingestion_continuous
  serverless = true

  ingestion_definition {
    ingestion_gateway_id = databricks_pipeline.gateway[0].id
    source_type          = "POSTGRESQL"

    # Every source schema into one destination schema (table names must be unique
    # across them).
    dynamic "objects" {
      for_each = var.source_schemas
      content {
        schema {
          source_catalog      = local.pg.database
          source_schema       = objects.value
          destination_catalog = local.catalog
          destination_schema  = databricks_schema.destination.name
        }
      }
    }

    source_configurations {
      catalog {
        source_catalog = local.pg.database
        postgres {
          slot_config {
            slot_name        = var.slot_name
            publication_name = var.publication_name
          }
        }
      }
    }
  }

  event_log {
    name = "event_log_pg_ingestion"
  }
}

# Triggered ingestion pipeline on a schedule. The gateway is continuous and is not
# part of this job.
resource "databricks_job" "ingestion_schedule" {
  count = var.enable_ingestion && var.ingestion_schedule_cron != null ? 1 : 0
  name  = "${var.name_prefix}-pg-ingestion-schedule"

  schedule {
    quartz_cron_expression = var.ingestion_schedule_cron
    timezone_id            = var.ingestion_schedule_timezone
  }

  task {
    task_key = "refresh"
    pipeline_task {
      pipeline_id = databricks_pipeline.ingestion[0].id
    }
  }

  lifecycle {
    precondition {
      condition     = !var.ingestion_continuous
      error_message = "ingestion_schedule_cron is for a triggered pipeline (ingestion_continuous = false)."
    }
  }
}
