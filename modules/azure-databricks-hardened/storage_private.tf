# ---------------------------------------------------------------------------
# Private storage, as in the Databricks Security Reference Architecture (SRA)
#
#   workspace storage (managed RG, DBFS root / system data)
#     default_storage_firewall_enabled + access connector outside the managed RG
#     classic  -> dfs / blob private endpoints in the privatelink subnet
#     serverless -> NCC private endpoints (approved on the storage account)
#   UC root storage (this module's ADLS account)
#     public network access off (var.uc_storage_public_network_access_enabled = false)
#     classic  -> dfs / blob private endpoints in the privatelink subnet
#     serverless -> NCC private endpoints (unity_catalog.tf)
#
# Both share the privatelink.{dfs,blob}.core.windows.net zones linked to the VNet.
# ---------------------------------------------------------------------------

locals {
  storage_private_dns_enabled = var.workspace_storage_firewall_enabled || var.uc_storage_private_endpoints_enabled
  uc_private_endpoints        = var.create_metastore && var.uc_storage_private_endpoints_enabled

  # 3-24 lowercase alphanumerics, globally unique; known before the workspace exists
  # so the private endpoints can target it.
  workspace_storage_account_name = var.workspace_storage_firewall_enabled ? coalesce(
    var.workspace_storage_account_name,
    "dbstorage${substr(md5("${var.resource_group_name}/${var.prefix}/workspace"), 0, 13)}",
  ) : null

  workspace_storage_account_id = var.workspace_storage_firewall_enabled ? join("", [
    azurerm_databricks_workspace.this.managed_resource_group_id,
    "/providers/Microsoft.Storage/storageAccounts/",
    local.workspace_storage_account_name,
  ]) : null

  storage_subresources = toset(["dfs", "blob"])
}

resource "azurerm_private_dns_zone" "storage" {
  for_each = local.storage_private_dns_enabled ? local.storage_subresources : toset([])

  name                = "privatelink.${each.key}.core.windows.net"
  resource_group_name = local.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "storage" {
  for_each = azurerm_private_dns_zone.storage

  name                 = "${var.prefix}-${each.key}"
  private_dns_zone_id  = each.value.id
  virtual_network_id   = azurerm_virtual_network.this.id
  registration_enabled = false
  tags                 = var.tags
}

# ---------------------------------------------------------------------------
# Workspace storage account
# ---------------------------------------------------------------------------

# Docs: "You can't use the Azure Databricks access connector in the managed resource
# group." Databricks maps this connector to the workspace storage account itself.
resource "azurerm_databricks_access_connector" "workspace" {
  count = var.workspace_storage_firewall_enabled ? 1 : 0

  name                = "${var.prefix}-ws-connector"
  resource_group_name = local.resource_group_name
  location            = local.location

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

resource "azurerm_private_endpoint" "workspace_storage" {
  for_each = var.workspace_storage_firewall_enabled ? local.storage_subresources : toset([])

  name                          = "${var.prefix}-pe-ws-${each.key}"
  location                      = local.location
  resource_group_name           = local.resource_group_name
  subnet_id                     = azurerm_subnet.privatelink.id
  custom_network_interface_name = "${var.prefix}-pe-ws-${each.key}-nic"

  private_service_connection {
    name                           = "${var.prefix}-ws-${each.key}"
    private_connection_resource_id = local.workspace_storage_account_id
    is_manual_connection           = false
    subresource_names              = [each.key]
  }

  private_dns_zone_group {
    name                 = "storage"
    private_dns_zone_ids = [azurerm_private_dns_zone.storage[each.key].id]
  }

  tags = var.tags
}

resource "databricks_mws_ncc_private_endpoint_rule" "workspace_storage" {
  for_each = var.workspace_storage_firewall_enabled ? local.storage_subresources : toset([])

  network_connectivity_config_id = databricks_mws_network_connectivity_config.this.network_connectivity_config_id
  resource_id                    = local.workspace_storage_account_id
  group_id                       = each.key

  # The NCC must be bound before Databricks accepts rules for workspace storage.
  depends_on = [databricks_mws_ncc_binding.this]
}

# The classic endpoints are auto-approved (same tenant); the NCC endpoints stay
# Pending until approved. The script approves only the NCC endpoints (by name).
resource "terraform_data" "approve_workspace_storage_private_endpoints" {
  count = var.workspace_storage_firewall_enabled ? 1 : 0

  triggers_replace = [for r in databricks_mws_ncc_private_endpoint_rule.workspace_storage : r.rule_id]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.module}/scripts/approve_private_endpoints.sh '${local.workspace_storage_account_id}' ${join(" ", [for r in databricks_mws_ncc_private_endpoint_rule.workspace_storage : r.endpoint_name])}"
  }

  depends_on = [azurerm_private_endpoint.workspace_storage]
}

# ---------------------------------------------------------------------------
# UC root storage: classic compute private endpoints
# ---------------------------------------------------------------------------

resource "azurerm_private_endpoint" "uc_storage" {
  for_each = local.uc_private_endpoints ? local.storage_subresources : toset([])

  name                          = "${var.prefix}-pe-uc-${each.key}"
  location                      = local.location
  resource_group_name           = local.resource_group_name
  subnet_id                     = azurerm_subnet.privatelink.id
  custom_network_interface_name = "${var.prefix}-pe-uc-${each.key}-nic"

  private_service_connection {
    name                           = "${var.prefix}-uc-${each.key}"
    private_connection_resource_id = azurerm_storage_account.uc[0].id
    is_manual_connection           = false
    subresource_names              = [each.key]
  }

  private_dns_zone_group {
    name                 = "storage"
    private_dns_zone_ids = [azurerm_private_dns_zone.storage[each.key].id]
  }

  tags = var.tags
}
