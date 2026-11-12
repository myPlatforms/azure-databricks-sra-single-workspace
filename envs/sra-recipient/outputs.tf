output "workspace_url" {
  value = module.workspace.workspace_url
}

output "workspace_id" {
  value = module.workspace.workspace_id
}

output "workspace_resource_id" {
  value = module.workspace.workspace_resource_id
}

output "resource_group_name" {
  value = module.workspace.resource_group_name
}

output "managed_resource_group_name" {
  value = module.workspace.managed_resource_group_name
}

output "location" {
  value = var.location
}

output "vnet_id" {
  value = module.workspace.vnet_id
}

output "virtual_network_name" {
  value = module.workspace.virtual_network_name
}

output "databricks_subnet_cidrs" {
  value = module.workspace.databricks_subnet_cidrs
}

output "png_subnet_cidr" {
  description = "Source range of serverless traffic through the private network gateway: allow it on the destination (e.g. NSG of the database subnet)."
  value       = var.enable_private_network_gateway ? var.png_subnet_cidr : null
}

output "private_network_gateway" {
  value = module.workspace.private_network_gateway
}

output "nat_public_ip" {
  value = module.workspace.nat_public_ip
}

output "backend_private_endpoint_ip" {
  value = module.workspace.backend_private_endpoint_ip
}

output "storage_private_endpoint_ips" {
  value = module.workspace.storage_private_endpoint_ips
}

output "workspace_storage_account_name" {
  value = module.workspace.workspace_storage_account_name
}

output "uc_storage_account_name" {
  value = module.workspace.uc_storage_account_name
}

output "ncc_id" {
  value = module.workspace.ncc_id
}

output "ncc_private_endpoint_rules" {
  value = {
    uc        = module.workspace.uc_private_endpoint_rules
    workspace = module.workspace.workspace_storage_private_endpoint_rules
  }
}

output "network_policy_id" {
  value = module.workspace.network_policy_id
}

output "metastore_id" {
  value = module.workspace.metastore_id
}

output "catalog_name" {
  value = module.workspace.catalog_name
}
