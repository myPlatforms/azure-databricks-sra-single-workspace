output "workspace_url" {
  value = local.ws.workspace_url
}

output "load_job_id" {
  description = "Sample database: run before step 2 (databricks jobs run-now <id>)."
  value       = one(databricks_job.load[*].id)
}

output "changes_job_id" {
  value = one(databricks_job.changes[*].id)
}

output "connection_name" {
  value = one(databricks_connection.pg[*].name)
}

output "gateway_pipeline_id" {
  value = one(databricks_pipeline.gateway[*].id)
}

output "ingestion_pipeline_id" {
  value = one(databricks_pipeline.ingestion[*].id)
}

output "ingestion_schedule_job_id" {
  value = one(databricks_job.ingestion_schedule[*].id)
}

output "destination" {
  value = "${local.catalog}.${databricks_schema.destination.name}"
}
