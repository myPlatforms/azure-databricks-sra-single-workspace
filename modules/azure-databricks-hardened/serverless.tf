# ---------------------------------------------------------------------------
# Network connectivity configuration (NCC): regional, account level
# ---------------------------------------------------------------------------

resource "databricks_mws_network_connectivity_config" "this" {
  name   = "${var.prefix}-ncc"
  region = var.location
}

resource "databricks_mws_ncc_binding" "this" {
  network_connectivity_config_id = databricks_mws_network_connectivity_config.this.network_connectivity_config_id
  workspace_id                   = azurerm_databricks_workspace.this.workspace_id
}

# ---------------------------------------------------------------------------
# Serverless egress control (network policy), attached to the workspace
# ---------------------------------------------------------------------------

locals {
  serverless_storage_accounts = compact([
    var.create_metastore ? local.uc_storage_account_name : null,
    local.workspace_storage_account_name,
  ])
}

resource "databricks_account_network_policy" "this" {
  network_policy_id = "${var.prefix}-np"
  account_id        = var.databricks_account_id

  egress = {
    network_access = {
      restriction_mode = var.network_policy_restriction_mode
      allowed_internet_destinations = var.network_policy_restriction_mode == "RESTRICTED_ACCESS" ? [
        for fqdn in local.serverless_allowed_fqdns : {
          destination               = fqdn
          internet_destination_type = "DNS_NAME"
        }
      ] : null
      # The metastore root account (and the firewalled workspace storage account),
      # for both endpoints serverless uses.
      allowed_storage_destinations = var.network_policy_restriction_mode == "RESTRICTED_ACCESS" && length(local.serverless_storage_accounts) > 0 ? flatten([
        for account in local.serverless_storage_accounts : [
          for svc in ["dfs", "blob"] : {
            storage_destination_type = "AZURE_STORAGE"
            azure_storage_account    = account
            azure_storage_service    = svc
          }
        ]
      ]) : null
      policy_enforcement = {
        enforcement_mode            = var.network_policy_enforcement_mode
        dry_run_mode_product_filter = var.network_policy_enforcement_mode == "DRY_RUN" && length(var.network_policy_dry_run_products) > 0 ? var.network_policy_dry_run_products : null
      }
    }
  }
}

resource "databricks_workspace_network_option" "this" {
  workspace_id      = azurerm_databricks_workspace.this.workspace_id
  network_policy_id = databricks_account_network_policy.this.network_policy_id
}

# ---------------------------------------------------------------------------
# Private network gateway (Public Preview): serverless compute -> resources in
# this VNet (workload subnets) and networks connected to it.
# ---------------------------------------------------------------------------

# Destroy order: gateway -> this wait -> subnet. Gateway delete returns before
# its NICs are gone from the delegated subnet, so deleting the subnet right away
# can fail with "subnet in use".
resource "time_sleep" "png_subnet_release" {
  count            = var.enable_private_network_gateway ? 1 : 0
  destroy_duration = var.png_destroy_wait

  depends_on = [
    azurerm_subnet.png,
    azurerm_subnet_network_security_group_association.png,
  ]
}

resource "databricks_private_network_gateway" "this" {
  count = var.enable_private_network_gateway ? 1 : 0

  parent                             = "accounts/${var.databricks_account_id}/network-connectivity-configs/${databricks_mws_network_connectivity_config.this.network_connectivity_config_id}"
  display_name                       = "${var.prefix}-png"
  bandwidth_tier_gigabits_per_second = var.png_bandwidth_gbps
  traffic_mode                       = var.png_traffic_mode

  azure_cloud_connection = {
    gateway_subnet = {
      resource_id = azurerm_subnet.png[0].id
    }
  }

  destinations = var.png_traffic_mode == "SPECIFIC_DESTINATIONS" ? [
    for name in local.png_destinations : {
      destination_type = "DNS_NAME"
      value            = name
    }
  ] : null

  private_dns_resolvers = length(var.png_dns_resolver_ips) > 0 ? [
    for ip in var.png_dns_resolver_ips : {
      resolver_type = "IP_ADDRESS"
      value         = ip
    }
  ] : null

  lifecycle {
    precondition {
      condition     = var.create_png_subnet
      error_message = "enable_private_network_gateway needs the gateway subnet: set create_png_subnet = true."
    }
    precondition {
      condition     = var.png_traffic_mode == "ALL_TRAFFIC" || length(local.png_destinations) > 0
      error_message = "SPECIFIC_DESTINATIONS needs at least one destination: set png_destinations or internal_dns_zone_name."
    }
    precondition {
      condition     = length(var.png_dns_resolver_ips) <= 2 && length(local.png_destinations) <= 100
      error_message = "A gateway supports at most 2 DNS resolvers and 100 destinations."
    }
  }

  depends_on = [
    time_sleep.png_subnet_release,
    # The internal zone must be linked before the gateway tries to resolve names in it.
    azurerm_private_dns_zone_virtual_network_link.internal,
  ]
}
