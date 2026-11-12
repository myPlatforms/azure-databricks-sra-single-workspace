# ---------------------------------------------------------------------------
# Resource group
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "this" {
  count    = var.create_resource_group ? 1 : 0
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

data "azurerm_resource_group" "this" {
  count = var.create_resource_group ? 0 : 1
  name  = var.resource_group_name
}

# ---------------------------------------------------------------------------
# VNet
# ---------------------------------------------------------------------------

resource "azurerm_virtual_network" "this" {
  name                = "${var.prefix}-vnet"
  location            = local.location
  resource_group_name = local.resource_group_name
  address_space       = [var.vnet_cidr]
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# NSGs
# Databricks subnets: network_security_group_rules_required = NoAzureDatabricksRules,
# so Databricks adds no rules of its own. The Azure default rules
# (AllowVnetInBound / AllowVnetOutBound / AllowInternetOutBound) already cover
# node-to-node traffic, the private endpoint, and outbound via the NAT gateway.
# ---------------------------------------------------------------------------

resource "azurerm_network_security_group" "databricks" {
  name                = "${var.prefix}-databricks-nsg"
  location            = local.location
  resource_group_name = local.resource_group_name
  tags                = var.tags
}

resource "azurerm_network_security_group" "png" {
  count               = var.create_png_subnet ? 1 : 0
  name                = "${var.prefix}-png-nsg"
  location            = local.location
  resource_group_name = local.resource_group_name
  tags                = var.tags
}

resource "azurerm_network_security_group" "workload_vm" {
  count               = var.create_workload_subnets ? 1 : 0
  name                = "${var.prefix}-workload-vm-nsg"
  location            = local.location
  resource_group_name = local.resource_group_name
  tags                = var.tags
}

resource "azurerm_network_security_group" "workload_db" {
  count               = var.create_workload_subnets ? 1 : 0
  name                = "${var.prefix}-workload-db-nsg"
  location            = local.location
  resource_group_name = local.resource_group_name
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# Databricks subnets (host = "public", container = "private")
# ---------------------------------------------------------------------------

resource "azurerm_subnet" "host" {
  name                 = "${var.prefix}-host"
  resource_group_name  = local.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.subnet_cidrs.host]

  # Outbound goes through the NAT gateway, not Azure default outbound access.
  default_outbound_access_enabled = false

  dynamic "service_endpoint" {
    for_each = var.storage_service_endpoint_enabled ? ["Microsoft.Storage.Global"] : []
    content {
      service = service_endpoint.value
    }
  }

  delegation {
    name = "databricks"
    service_delegation {
      name    = "Microsoft.Databricks/workspaces"
      actions = local.databricks_delegation_actions
    }
  }
}

resource "azurerm_subnet" "container" {
  name                 = "${var.prefix}-container"
  resource_group_name  = local.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.subnet_cidrs.container]

  default_outbound_access_enabled = false

  dynamic "service_endpoint" {
    for_each = var.storage_service_endpoint_enabled ? ["Microsoft.Storage.Global"] : []
    content {
      service = service_endpoint.value
    }
  }

  delegation {
    name = "databricks"
    service_delegation {
      name    = "Microsoft.Databricks/workspaces"
      actions = local.databricks_delegation_actions
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "host" {
  subnet_id                 = azurerm_subnet.host.id
  network_security_group_id = azurerm_network_security_group.databricks.id
}

resource "azurerm_subnet_network_security_group_association" "container" {
  subnet_id                 = azurerm_subnet.container.id
  network_security_group_id = azurerm_network_security_group.databricks.id
}

# ---------------------------------------------------------------------------
# Private endpoint subnet
# ---------------------------------------------------------------------------

resource "azurerm_subnet" "privatelink" {
  name                            = "${var.prefix}-privatelink"
  resource_group_name             = local.resource_group_name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [var.subnet_cidrs.privatelink]
  default_outbound_access_enabled = false
}

# ---------------------------------------------------------------------------
# Private network gateway subnet: dedicated, delegated to Databricks
# ---------------------------------------------------------------------------

resource "azurerm_subnet" "png" {
  count                           = var.create_png_subnet ? 1 : 0
  name                            = "${var.prefix}-png"
  resource_group_name             = local.resource_group_name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [var.subnet_cidrs.png]
  default_outbound_access_enabled = false

  delegation {
    name = "databricks"
    service_delegation {
      name    = "Microsoft.Databricks/workspaces"
      actions = local.databricks_delegation_actions
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "png" {
  count                     = var.create_png_subnet ? 1 : 0
  subnet_id                 = azurerm_subnet.png[0].id
  network_security_group_id = azurerm_network_security_group.png[0].id
}

# ---------------------------------------------------------------------------
# Workload subnets: Azure VMs and Azure databases outside Databricks
# ---------------------------------------------------------------------------

resource "azurerm_subnet" "workload_vm" {
  count                           = var.create_workload_subnets ? 1 : 0
  name                            = "${var.prefix}-workload-vm"
  resource_group_name             = local.resource_group_name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [var.subnet_cidrs.workload_vm]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet" "workload_db" {
  count                           = var.create_workload_subnets ? 1 : 0
  name                            = "${var.prefix}-workload-db"
  resource_group_name             = local.resource_group_name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [var.subnet_cidrs.workload_db]
  default_outbound_access_enabled = false

  # No delegation on purpose. VNet-integrated PostgreSQL / MySQL Flexible Server
  # needs this subnet delegated to its own service; Azure SQL / private-endpoint
  # based databases need no delegation. Changing it later is an in-place update
  # as long as the subnet is empty.
  lifecycle {
    ignore_changes = [delegation]
  }
}

resource "azurerm_subnet_network_security_group_association" "workload_vm" {
  count                     = var.create_workload_subnets ? 1 : 0
  subnet_id                 = azurerm_subnet.workload_vm[0].id
  network_security_group_id = azurerm_network_security_group.workload_vm[0].id
}

resource "azurerm_subnet_network_security_group_association" "workload_db" {
  count                     = var.create_workload_subnets ? 1 : 0
  subnet_id                 = azurerm_subnet.workload_db[0].id
  network_security_group_id = azurerm_network_security_group.workload_db[0].id
}

# ---------------------------------------------------------------------------
# NAT gateway: classic compute egress (PyPI, Maven, ...) with one fixed public IP
# ---------------------------------------------------------------------------

resource "azurerm_public_ip" "nat" {
  name                = "${var.prefix}-nat-pip"
  location            = local.location
  resource_group_name = local.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "this" {
  name                    = "${var.prefix}-nat"
  location                = local.location
  resource_group_name     = local.resource_group_name
  sku_name                = "Standard"
  idle_timeout_in_minutes = 10
  tags                    = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "host" {
  subnet_id      = azurerm_subnet.host.id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

resource "azurerm_subnet_nat_gateway_association" "container" {
  subnet_id      = azurerm_subnet.container.id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

resource "azurerm_subnet_nat_gateway_association" "workload_vm" {
  count          = var.create_workload_subnets && var.nat_gateway_on_workload_vm ? 1 : 0
  subnet_id      = azurerm_subnet.workload_vm[0].id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

# ---------------------------------------------------------------------------
# Internal DNS zone for workload VMs / DBs (also the gateway's default destination)
# ---------------------------------------------------------------------------

resource "azurerm_private_dns_zone" "internal" {
  count               = var.internal_dns_zone_name != null ? 1 : 0
  name                = var.internal_dns_zone_name
  resource_group_name = local.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "internal" {
  count                = var.internal_dns_zone_name != null ? 1 : 0
  name                 = "${var.prefix}-internal"
  private_dns_zone_id  = azurerm_private_dns_zone.internal[0].id
  virtual_network_id   = azurerm_virtual_network.this.id
  registration_enabled = true
  tags                 = var.tags
}
