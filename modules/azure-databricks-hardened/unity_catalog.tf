# ---------------------------------------------------------------------------
# Unity Catalog: dedicated metastore on a dedicated ADLS Gen2 account
#
#   storage account (firewall Deny) + container
#   access connector (system-assigned MI) -> Storage Blob Data Contributor
#   metastore (storage_root) -> root credential (data access) -> assignment
#   serverless path: NCC private endpoints (dfs, blob) -> approved on the account
# ---------------------------------------------------------------------------

locals {
  uc_storage_account_name = coalesce(
    var.uc_storage_account_name,
    # 3-24 lowercase alphanumerics, globally unique. Deterministic per RG + prefix.
    substr("${replace(lower(var.prefix), "/[^a-z0-9]/", "")}uc${substr(md5("${var.resource_group_name}/${var.prefix}"), 0, 8)}", 0, 24)
  )
  metastore_name = coalesce(var.metastore_name, "${var.prefix}-metastore")
  metastore_root = var.create_metastore ? "abfss://${azurerm_storage_container.metastore[0].name}@${azurerm_storage_account.uc[0].name}.dfs.core.windows.net/" : null

  effective_metastore_id = var.create_metastore ? databricks_metastore.this[0].id : var.metastore_id
  # Known at plan time, unlike effective_metastore_id (count needs that).
  assign_metastore = var.create_metastore || var.metastore_id != null
}

resource "azurerm_storage_account" "uc" {
  count = var.create_metastore ? 1 : 0

  name                     = local.uc_storage_account_name
  resource_group_name      = local.resource_group_name
  location                 = local.location
  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "LRS"
  is_hns_enabled           = true

  min_tls_version                  = "TLS1_2"
  https_traffic_only_enabled       = true
  public_network_access            = var.uc_storage_public_network_access_enabled ? "Enabled" : "Disabled"
  allow_nested_items_to_be_public  = false
  cross_tenant_replication_enabled = false

  # With the public endpoint on, only listed sources get through (with it off, these
  # rules are inert and every client comes in over a private endpoint):
  #   - Databricks host/container subnets (service endpoint Microsoft.Storage.Global)
  #   - the access connector (resource instance rule; Databricks control plane)
  #   - storage_allowed_ips (whoever runs Terraform: the provider reads data-plane
  #     properties of the account on every refresh)
  # Serverless reaches it through the NCC private endpoints below.
  network_rules {
    default_action = "Deny"
    bypass         = var.uc_storage_bypass_azure_services ? ["AzureServices"] : ["None"]
    # Storage rules take plain IPs or /0-/30 CIDRs; /32 entries become plain IPs.
    ip_rules                   = [for c in var.storage_allowed_ips : trimsuffix(c, "/32")]
    virtual_network_subnet_ids = [azurerm_subnet.host.id, azurerm_subnet.container.id]

    private_link_access {
      endpoint_resource_id = azurerm_databricks_access_connector.uc[0].id
    }
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = var.storage_service_endpoint_enabled
      error_message = "The UC storage firewall allows the Databricks subnets by service endpoint; keep storage_service_endpoint_enabled = true."
    }
    precondition {
      condition     = var.uc_storage_public_network_access_enabled || var.uc_storage_private_endpoints_enabled
      error_message = "With uc_storage_public_network_access_enabled = false, classic compute needs uc_storage_private_endpoints_enabled = true."
    }
  }
}

resource "azurerm_storage_container" "metastore" {
  count = var.create_metastore ? 1 : 0

  name                  = "metastore"
  storage_account_id    = azurerm_storage_account.uc[0].id
  container_access_type = "private"
}

resource "azurerm_databricks_access_connector" "uc" {
  count = var.create_metastore ? 1 : 0

  name                = "${var.prefix}-uc-connector"
  resource_group_name = local.resource_group_name
  location            = local.location

  identity {
    type = "SystemAssigned"
  }

  tags = var.tags
}

resource "azurerm_role_assignment" "uc_blob" {
  count = var.create_metastore ? 1 : 0

  scope                = azurerm_storage_account.uc[0].id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_databricks_access_connector.uc[0].identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# File events (on by default for new external locations, including the auto-created
# metastore_root_location): Databricks creates a storage queue + Event Grid
# subscription and reads file-change metadata from the queue. Needed for Auto Loader
# managed file events and file arrival triggers. Scopes per the Learn docs
# ("Set up file events for an external location"): queue + account roles on the
# storage account, Event Grid on the resource group that holds it.
locals {
  uc_file_event_roles = var.create_metastore && var.uc_file_events_roles_enabled ? {
    queue   = { role = "Storage Queue Data Contributor", scope = azurerm_storage_account.uc[0].id }
    account = { role = "Storage Account Contributor", scope = azurerm_storage_account.uc[0].id }
    events  = { role = "EventGrid EventSubscription Contributor", scope = local.resource_group_id }
  } : {}
}

resource "azurerm_role_assignment" "uc_file_events" {
  for_each = local.uc_file_event_roles

  scope                = each.value.scope
  role_definition_name = each.value.role
  principal_id         = azurerm_databricks_access_connector.uc[0].identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# Role assignments take a while to propagate; the root credential is validated
# against the storage account when it is created.
resource "time_sleep" "uc_role_propagation" {
  count           = var.create_metastore ? 1 : 0
  create_duration = "60s"
  depends_on      = [azurerm_role_assignment.uc_blob, azurerm_role_assignment.uc_file_events]
}

# storage_root cannot be changed later - the provider replaces the metastore instead.
resource "databricks_metastore" "this" {
  count = var.create_metastore ? 1 : 0

  name          = local.metastore_name
  region        = var.location
  storage_root  = local.metastore_root
  owner         = var.metastore_owner
  force_destroy = var.metastore_force_destroy

  # OpenSharing outside the metastore's own account (also what makes the account
  # console show the "OpenSharing NCC" field that SecureConnect needs). null = the
  # provider's defaults (INTERNAL, 1-year token lifetime).
  delta_sharing_scope                               = try(var.metastore_delta_sharing.scope, null)
  delta_sharing_recipient_token_lifetime_in_seconds = try(var.metastore_delta_sharing.recipient_token_lifetime_seconds, null)
  delta_sharing_organization_name                   = try(var.metastore_delta_sharing.organization_name, null)
}

resource "databricks_metastore_data_access" "this" {
  count = var.create_metastore ? 1 : 0

  metastore_id = databricks_metastore.this[0].id
  name         = "${var.prefix}-uc-connector"
  is_default   = true

  azure_managed_identity {
    access_connector_id = azurerm_databricks_access_connector.uc[0].id
  }

  # skip_validation only matters at creation and is not read back; ignoring it
  # keeps an imported credential from being replaced.
  lifecycle {
    ignore_changes = [skip_validation]
  }

  depends_on = [time_sleep.uc_role_propagation]
}

resource "databricks_metastore_assignment" "this" {
  count        = local.assign_metastore ? 1 : 0
  workspace_id = azurerm_databricks_workspace.this.workspace_id
  metastore_id = local.effective_metastore_id

  depends_on = [databricks_metastore_data_access.this]
}

# ---------------------------------------------------------------------------
# Serverless -> UC storage: NCC private endpoints, approved on the storage side
# ---------------------------------------------------------------------------

resource "databricks_mws_ncc_private_endpoint_rule" "uc" {
  for_each = var.create_metastore ? toset(["dfs", "blob"]) : toset([])

  network_connectivity_config_id = databricks_mws_network_connectivity_config.this.network_connectivity_config_id
  resource_id                    = azurerm_storage_account.uc[0].id
  group_id                       = each.value
}

# Databricks creates the endpoints in its own subscription; the connection shows
# up as Pending on the storage account and must be approved there. Re-runs when
# the set of rules changes. Requires the az CLI on the machine running Terraform.
resource "terraform_data" "approve_uc_private_endpoints" {
  count = var.create_metastore ? 1 : 0

  triggers_replace = [for r in databricks_mws_ncc_private_endpoint_rule.uc : r.rule_id]

  # Approves only the connections of these NCC endpoints (by endpoint name).
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.module}/scripts/approve_private_endpoints.sh '${azurerm_storage_account.uc[0].id}' ${join(" ", [for r in databricks_mws_ncc_private_endpoint_rule.uc : r.endpoint_name])}"
  }

  depends_on = [azurerm_private_endpoint.uc_storage]
}

# ---------------------------------------------------------------------------
# Second apply: starter catalog on the metastore root
# ---------------------------------------------------------------------------

resource "databricks_catalog" "this" {
  count    = local.workspace_level && var.catalog_name != null && local.assign_metastore ? 1 : 0
  provider = databricks.workspace

  name          = var.catalog_name
  comment       = "Starter catalog for ${local.workspace_name}"
  force_destroy = var.metastore_force_destroy

  depends_on = [databricks_metastore_assignment.this]
}
