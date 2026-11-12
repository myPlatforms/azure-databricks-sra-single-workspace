# ---------------------------------------------------------------------------
# Second apply (workspace_url set): workspace ingress control
# Hardened connectivity keeps the UI/API on the internet; the IP access list is
# what limits who reaches it. Misconfigured lists lock you out, so the list is
# only created when ip_access_list_cidrs is non-empty, and the NAT gateway IP is
# always added so anything leaving the VNet over the internet still gets in.
# ---------------------------------------------------------------------------

locals {
  ip_access_list_enabled = local.workspace_level && length(var.ip_access_list_cidrs) > 0
}

resource "databricks_workspace_conf" "ip_access_list" {
  count    = local.ip_access_list_enabled ? 1 : 0
  provider = databricks.workspace

  custom_config = {
    "enableIpAccessLists" = "true"
  }

  # The allow list must exist before enforcement is switched on, otherwise the
  # session that applies it is blocked.
  depends_on = [databricks_ip_access_list.allow]
}

resource "databricks_ip_access_list" "allow" {
  count    = local.ip_access_list_enabled ? 1 : 0
  provider = databricks.workspace

  label     = "${var.prefix}-allow"
  list_type = "ALLOW"
  ip_addresses = distinct(concat(
    var.ip_access_list_cidrs,
    [azurerm_public_ip.nat.ip_address],
  ))
}

# ---------------------------------------------------------------------------
# Second apply: disable legacy features (SRA default)
# ---------------------------------------------------------------------------

resource "databricks_disable_legacy_access_setting" "this" {
  count    = local.workspace_level && var.disable_legacy_access ? 1 : 0
  provider = databricks.workspace

  disable_legacy_access {
    value = true
  }
}
