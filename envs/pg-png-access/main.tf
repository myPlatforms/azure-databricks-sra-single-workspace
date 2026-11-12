# ---------------------------------------------------------------------------
# Serverless -> PostgreSQL through the private network gateway: the one change on
# the database side. Kept out of envs/pg-source on purpose - it models the request
# a workspace team sends to the team that owns the database network.
#
#   allow  TCP 5432  from <gateway subnet of the provider workspace VNet>  to <PG subnet>
#
# The PG NSG is declared without inline rules, so a rule managed here does not show
# up as drift in the database stack. Its priority must come before (be lower than)
# the database stack's deny rule for other VNet sources (200).
#
# Database objects: from the envs/pg-source state (pg_state_path), or - for an
# existing database - from the pg_* variables.
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
  png_subnet_cidr = try(data.terraform_remote_state.workspace.outputs.png_subnet_cidr, null)

  pg_state = try(data.terraform_remote_state.pg[0].outputs, {})
  pg = {
    resource_group_name = coalesce(var.pg_resource_group_name, try(local.pg_state.resource_group_name, null))
    vnet_name           = coalesce(var.pg_vnet_name, try(local.pg_state.vnet_name, null))
    subnet_name         = coalesce(var.pg_subnet_name, try(local.pg_state.pg_subnet_name, null))
    nsg_name            = coalesce(var.pg_nsg_name, try(local.pg_state.pg_nsg_name, null))
  }
}

data "azurerm_subnet" "pg" {
  name                 = local.pg.subnet_name
  virtual_network_name = local.pg.vnet_name
  resource_group_name  = local.pg.resource_group_name
}

resource "azurerm_network_security_rule" "pg_from_private_network_gateway" {
  name                        = "Allow-PostgreSQL-from-Databricks-PNG"
  priority                    = var.rule_priority
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "5432"
  source_address_prefix       = local.png_subnet_cidr
  destination_address_prefix  = data.azurerm_subnet.pg.address_prefixes[0]
  resource_group_name         = local.pg.resource_group_name
  network_security_group_name = local.pg.nsg_name

  lifecycle {
    precondition {
      condition     = local.png_subnet_cidr != null
      error_message = "The workspace stack has no private network gateway subnet (enable_private_network_gateway = false)."
    }
  }
}
