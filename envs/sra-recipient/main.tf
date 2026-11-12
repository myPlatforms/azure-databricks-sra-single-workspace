# ---------------------------------------------------------------------------
# Single-workspace Security Reference Architecture (no hub-spoke)
#
#   front-end   : public (internet), limited by the workspace IP access list
#   back-end    : classic compute -> control plane over Private Link (SCC, no public IP)
#   storage     : workspace storage (DBFS root) firewall + private endpoints,
#                 UC root storage with public network access disabled + private endpoints,
#                 serverless -> both through NCC private endpoints
#   egress      : classic via NAT gateway (fixed IP), serverless via restricted network policy
#   governance  : dedicated metastore, legacy features disabled
# ---------------------------------------------------------------------------

module "workspace" {
  source = "../../modules/azure-databricks-hardened"

  providers = {
    azurerm              = azurerm
    databricks           = databricks.account
    databricks.workspace = databricks.workspace
  }

  prefix                = var.prefix
  workspace_name        = var.workspace_name
  location              = var.location
  resource_group_name   = var.resource_group_name
  create_resource_group = true
  databricks_account_id = var.databricks_account_id
  tags                  = var.tags

  # Databricks-only VNet: workloads (e.g. the source database) live in their own,
  # peered VNet.
  vnet_cidr               = var.vnet_cidr
  subnet_cidrs            = merge(var.subnet_cidrs, { png = var.png_subnet_cidr })
  create_workload_subnets = false

  # Serverless -> private resources reached from this VNet (e.g. a VNet-integrated
  # PostgreSQL in the peered VNet, which cannot take a private endpoint).
  # Public Preview: enable it on the account console Previews page first.
  create_png_subnet              = var.enable_private_network_gateway
  enable_private_network_gateway = var.enable_private_network_gateway
  png_bandwidth_gbps             = var.png_bandwidth_gbps
  png_destinations               = var.png_destinations

  # Front-end public, back-end private.
  public_network_access_enabled = true

  # Storage private.
  workspace_storage_firewall_enabled       = true
  uc_storage_public_network_access_enabled = false
  uc_storage_private_endpoints_enabled     = true
  storage_allowed_ips                      = []
  uc_storage_bypass_azure_services         = var.uc_storage_bypass_azure_services

  # Serverless egress.
  network_policy_restriction_mode = "RESTRICTED_ACCESS"
  network_policy_enforcement_mode = var.network_policy_enforcement_mode
  serverless_allowed_fqdns        = var.serverless_allowed_fqdns

  # Unity Catalog: dedicated metastore on its own ADLS Gen2 account.
  create_metastore        = true
  metastore_force_destroy = var.metastore_force_destroy
  metastore_delta_sharing = var.metastore_delta_sharing
  catalog_name            = var.catalog_name

  # Second apply.
  workspace_url         = var.workspace_url
  ip_access_list_cidrs  = var.client_allowed_cidrs
  disable_legacy_access = var.disable_legacy_access
}
