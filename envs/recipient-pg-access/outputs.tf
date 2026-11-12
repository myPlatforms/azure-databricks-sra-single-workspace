output "allowed_sources" {
  value = local.client_cidrs
}

output "connection_name" {
  value = databricks_connection.pg.name
}

output "write_job_id" {
  value = databricks_job.write.id
}
