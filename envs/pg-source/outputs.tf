output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "vnet_id" {
  value = azurerm_virtual_network.ingestion.id
}

# Names of the database-side network objects: envs/pg-png-access and
# envs/recipient-pg-access add rules, peerings and zone links to them.
output "vnet_name" {
  value = azurerm_virtual_network.ingestion.name
}

output "pg_subnet_name" {
  value = azurerm_subnet.pg.name
}

output "pg_subnet_cidr" {
  value = azurerm_subnet.pg.address_prefixes[0]
}

output "pg_nsg_name" {
  value = azurerm_network_security_group.pg.name
}

output "private_dns_zone_name" {
  value = azurerm_private_dns_zone.pg.name
}

output "pg_server_name" {
  value = azurerm_postgresql_flexible_server.this.name
}

output "pg_fqdn" {
  description = "Resolves to the private IP only from VNets linked to the private DNS zone."
  value       = azurerm_postgresql_flexible_server.this.fqdn
}

output "pg_port" {
  value = 5432
}

output "database_name" {
  value = azurerm_postgresql_flexible_server_database.this.name
}

output "admin_login" {
  value = var.admin_login
}

output "admin_password" {
  value     = random_password.admin.result
  sensitive = true
}

output "replication_user" {
  value = var.replication_user
}

output "replication_password" {
  value     = random_password.replication.result
  sensitive = true
}
