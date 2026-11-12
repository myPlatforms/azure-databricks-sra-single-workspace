# ---------------------------------------------------------------------------
# Source database for Lakeflow Connect PostgreSQL CDC
#
#   source VNet (vnet_name) -- peering -- provider workspace VNet (envs/sra-provider)
#     snet-pg : delegated to PostgreSQL Flexible Server (VNet integration, no public access)
#   private DNS zone <name>.private.postgres.database.azure.com linked to both VNets,
#   so the ingestion gateway (classic compute in the workspace VNet) resolves the server.
# ---------------------------------------------------------------------------

data "terraform_remote_state" "workspace" {
  backend = "local"
  config = {
    path = var.workspace_state_path
  }
}

locals {
  ws = data.terraform_remote_state.workspace.outputs

  # Classic compute subnets of the workspace = the only clients allowed on 5432.
  databricks_cidrs = [local.ws.databricks_subnet_cidrs.host, local.ws.databricks_subnet_cidrs.container]
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

resource "azurerm_virtual_network" "ingestion" {
  name                = var.vnet_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

resource "azurerm_subnet" "pg" {
  name                 = "snet-pg"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.ingestion.name
  address_prefixes     = [var.pg_subnet_cidr]

  delegation {
    name = "postgresql"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_network_security_group" "pg" {
  name                = "nsg-snet-pg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

# The default AllowVnetInBound rule covers every peered VNet. Narrow 5432 to the
# Databricks classic subnets; other inbound VNet traffic (server management inside
# the subnet) keeps the default rules.
resource "azurerm_network_security_rule" "pg_from_databricks" {
  name                        = "Allow-PostgreSQL-from-Databricks"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "5432"
  source_address_prefixes     = local.databricks_cidrs
  destination_address_prefix  = var.pg_subnet_cidr
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.pg.name
}

resource "azurerm_network_security_rule" "pg_deny_other_vnet" {
  name                        = "Deny-PostgreSQL-from-other-VNet"
  priority                    = 200
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "5432"
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = var.pg_subnet_cidr
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.pg.name
}

resource "azurerm_subnet_network_security_group_association" "pg" {
  subnet_id                 = azurerm_subnet.pg.id
  network_security_group_id = azurerm_network_security_group.pg.id
}

resource "azurerm_virtual_network_peering" "ingestion_to_workspace" {
  name                         = "peer-${azurerm_virtual_network.ingestion.name}-to-${local.ws.virtual_network_name}"
  resource_group_name          = azurerm_resource_group.this.name
  virtual_network_name         = azurerm_virtual_network.ingestion.name
  remote_virtual_network_id    = local.ws.vnet_id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
}

resource "azurerm_virtual_network_peering" "workspace_to_ingestion" {
  name                         = "peer-${local.ws.virtual_network_name}-to-${azurerm_virtual_network.ingestion.name}"
  resource_group_name          = local.ws.resource_group_name
  virtual_network_name         = local.ws.virtual_network_name
  remote_virtual_network_id    = azurerm_virtual_network.ingestion.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
}

# ---------------------------------------------------------------------------
# Private DNS
# ---------------------------------------------------------------------------

resource "azurerm_private_dns_zone" "pg" {
  # Flexible Server requires a zone ending in .postgres.database.azure.com.
  name                = "${var.prefix}.private.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "pg_ingestion" {
  name                 = "${var.prefix}-ingestion"
  private_dns_zone_id  = azurerm_private_dns_zone.pg.id
  virtual_network_id   = azurerm_virtual_network.ingestion.id
  registration_enabled = false
  tags                 = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "pg_workspace" {
  name                 = "${var.prefix}-workspace"
  private_dns_zone_id  = azurerm_private_dns_zone.pg.id
  virtual_network_id   = local.ws.vnet_id
  registration_enabled = false
  tags                 = var.tags
}

# ---------------------------------------------------------------------------
# PostgreSQL Flexible Server (private access)
# ---------------------------------------------------------------------------

resource "random_string" "server_suffix" {
  length  = 6
  special = false
  upper   = false
}

# Alphanumerics plus "-_" only: the values end up in connection strings and JSON.
resource "random_password" "admin" {
  length           = 24
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  special          = true
  override_special = "-_"
}

resource "random_password" "replication" {
  length           = 24
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  special          = true
  override_special = "-_"
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                = "${var.prefix}-${random_string.server_suffix.result}"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  version             = var.pg_version
  sku_name            = var.pg_sku_name
  storage_mb          = var.pg_storage_mb

  administrator_login    = var.admin_login
  administrator_password = random_password.admin.result

  delegated_subnet_id           = azurerm_subnet.pg.id
  private_dns_zone_id           = azurerm_private_dns_zone.pg.id
  public_network_access_enabled = false

  backup_retention_days        = 7
  geo_redundant_backup_enabled = false

  authentication {
    password_auth_enabled         = true
    active_directory_auth_enabled = false
  }

  tags = var.tags

  lifecycle {
    # Azure picks a zone when none is given.
    ignore_changes = [zone]
  }

  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.pg_ingestion,
    azurerm_subnet_network_security_group_association.pg,
  ]
}

# Logical replication for the Lakeflow Connect PostgreSQL connector (pgoutput slot).
# Parameter updates on one server conflict when sent in parallel, so they are chained.
resource "azurerm_postgresql_flexible_server_configuration" "wal_level" {
  name      = "wal_level"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "logical"
}

resource "azurerm_postgresql_flexible_server_configuration" "max_replication_slots" {
  name      = "max_replication_slots"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = tostring(var.max_replication_slots)

  depends_on = [azurerm_postgresql_flexible_server_configuration.wal_level]
}

resource "azurerm_postgresql_flexible_server_configuration" "max_wal_senders" {
  name      = "max_wal_senders"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = tostring(var.max_wal_senders)

  depends_on = [azurerm_postgresql_flexible_server_configuration.max_replication_slots]
}

# Docs recommend a finite value so an idle slot cannot grow WAL without bound.
resource "azurerm_postgresql_flexible_server_configuration" "max_slot_wal_keep_size" {
  count = var.max_slot_wal_keep_size_mb != null ? 1 : 0

  name      = "max_slot_wal_keep_size"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = tostring(var.max_slot_wal_keep_size_mb)

  depends_on = [azurerm_postgresql_flexible_server_configuration.max_wal_senders]
}

resource "azurerm_postgresql_flexible_server_database" "this" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.this.id
  charset   = "UTF8"
  collation = "en_US.utf8"

  depends_on = [
    azurerm_postgresql_flexible_server_configuration.max_wal_senders,
    azurerm_postgresql_flexible_server_configuration.max_slot_wal_keep_size,
  ]
}
