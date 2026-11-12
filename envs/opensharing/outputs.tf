output "opensharing_ncc_id" {
  description = "Attach this NCC to the provider metastore in the account console (Catalog > metastore > OpenSharing NCC)."
  value       = databricks_mws_network_connectivity_config.sharing.network_connectivity_config_id
}

output "opensharing_ncc_name" {
  value = databricks_mws_network_connectivity_config.sharing.name
}

output "private_endpoint_rules" {
  value = { for k, r in databricks_mws_ncc_private_endpoint_rule.sharing : k => r.connection_state }
}

output "share_name" {
  value = databricks_share.this.name
}

output "recipient" {
  value = one(databricks_recipient.this[*].name)
}

output "recipient_catalog" {
  value = one(databricks_catalog.shared[*].name)
}

output "recipient_global_metastore_id" {
  value = local.recipient_global_metastore_id
}
