output "resource_group_name" {
  value = local.resource_group_name
}

output "workspace_name" {
  value = azurerm_databricks_workspace.this.name
}

output "workspace_id" {
  description = "Databricks workspace ID (numeric)."
  value       = azurerm_databricks_workspace.this.workspace_id
}

output "workspace_resource_id" {
  value = azurerm_databricks_workspace.this.id
}

output "workspace_url" {
  description = "Set var.workspace_url to this value for the second apply."
  value       = "https://${azurerm_databricks_workspace.this.workspace_url}"
}

output "managed_resource_group_name" {
  value = local.managed_resource_group_name
}

output "vnet_id" {
  value = azurerm_virtual_network.this.id
}

output "subnet_ids" {
  value = {
    host        = azurerm_subnet.host.id
    container   = azurerm_subnet.container.id
    privatelink = azurerm_subnet.privatelink.id
    png         = one(azurerm_subnet.png[*].id)
    workload_vm = one(azurerm_subnet.workload_vm[*].id)
    workload_db = one(azurerm_subnet.workload_db[*].id)
  }
}

output "nat_public_ip" {
  description = "Fixed egress IP of classic compute and workload VMs. Allow-list it on external systems."
  value       = azurerm_public_ip.nat.ip_address
}

output "backend_private_endpoint_ip" {
  value = azurerm_private_endpoint.backend.private_service_connection[0].private_ip_address
}

output "ncc_id" {
  value = databricks_mws_network_connectivity_config.this.network_connectivity_config_id
}

output "network_policy_id" {
  value = databricks_account_network_policy.this.network_policy_id
}

output "private_network_gateway" {
  value = var.enable_private_network_gateway ? {
    name         = databricks_private_network_gateway.this[0].name
    state        = databricks_private_network_gateway.this[0].state
    destinations = local.png_destinations
  } : null
}

output "internal_dns_zone_name" {
  value = var.internal_dns_zone_name
}

output "metastore_id" {
  value = local.effective_metastore_id
}

output "uc_storage_account_name" {
  value = var.create_metastore ? azurerm_storage_account.uc[0].name : null
}

output "uc_access_connector_id" {
  value = var.create_metastore ? azurerm_databricks_access_connector.uc[0].id : null
}

output "uc_private_endpoint_rules" {
  description = "connection_state must be ESTABLISHED for serverless to use them."
  value = {
    for k, r in databricks_mws_ncc_private_endpoint_rule.uc : k => {
      endpoint_name    = r.endpoint_name
      connection_state = r.connection_state
    }
  }
}

output "catalog_name" {
  value = length(databricks_catalog.this) > 0 ? databricks_catalog.this[0].name : null
}

output "workspace_storage_account_name" {
  description = "Set only when workspace_storage_firewall_enabled (null = Azure-generated name)."
  value       = local.workspace_storage_account_name
}

output "workspace_storage_private_endpoint_rules" {
  description = "NCC rules to the firewalled workspace storage; connection_state must be ESTABLISHED."
  value = {
    for k, r in databricks_mws_ncc_private_endpoint_rule.workspace_storage : k => {
      endpoint_name    = r.endpoint_name
      connection_state = r.connection_state
    }
  }
}

output "storage_private_endpoint_ips" {
  description = "Classic compute private endpoints to the workspace / UC storage accounts."
  value = merge(
    { for k, pe in azurerm_private_endpoint.workspace_storage : "workspace-${k}" => pe.private_service_connection[0].private_ip_address },
    { for k, pe in azurerm_private_endpoint.uc_storage : "uc-${k}" => pe.private_service_connection[0].private_ip_address },
  )
}

output "virtual_network_name" {
  value = azurerm_virtual_network.this.name
}

output "databricks_subnet_cidrs" {
  description = "host / container CIDRs: allow these on databases reached from classic compute (e.g. the ingestion gateway)."
  value = {
    host      = var.subnet_cidrs.host
    container = var.subnet_cidrs.container
  }
}
