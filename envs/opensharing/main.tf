# ---------------------------------------------------------------------------
# OpenSharing Databricks-to-Databricks: provider workspace -> recipient workspace
# (another region, same account)
# with SecureConnect, because the provider's UC storage has public network access
# disabled (private endpoints only).
#
#   step A    OpenSharing NCC (NOT bound to any workspace) + blob/dfs private endpoint
#             rules to the provider's UC storage, approved on the storage account;
#             share with tables (WITH HISTORY) and filtered views.
#   UI (B, C) account console: allow OpenSharing outside the organization and attach
#             the NCC to the provider metastore ("OpenSharing Network connectivity
#             configuration"); Catalog Explorer > OpenSharing > Settings: "Enable
#             SecureConnect for new recipients". No Terraform resource for either
#             (provider 1.141).
#   step D    recipient (sharing identifier of the recipient metastore) + grant.
#   step E    catalog from the share on the recipient side.
#
# Docs: opensharing/secureconnect-provider - "An NCC attached to a workspace can't be
# attached to a metastore", "SecureConnect also requires both a blob and a dfs
# private endpoint rule".
# ---------------------------------------------------------------------------

data "terraform_remote_state" "provider_ws" {
  backend = "local"
  config  = { path = var.provider_state_path }
}

data "terraform_remote_state" "recipient_ws" {
  backend = "local"
  config  = { path = var.recipient_state_path }
}

locals {
  p = data.terraform_remote_state.provider_ws.outputs

  # /subscriptions/<sub>/resourceGroups/<rg>/... of the provider workspace
  subscription_id = split("/", local.p.workspace_resource_id)[2]
  uc_storage_id = join("/", [
    "/subscriptions", local.subscription_id,
    "resourceGroups", local.p.resource_group_name,
    "providers/Microsoft.Storage/storageAccounts", local.p.uc_storage_account_name,
  ])

  r = data.terraform_remote_state.recipient_ws.outputs

  share_name = coalesce(var.share_name, "${var.name_prefix}_share")

  # Sharing identifier of the recipient metastore: azure:<region>:<metastore id>.
  recipient_global_metastore_id = coalesce(
    var.recipient_global_metastore_id,
    "azure:${local.r.location}:${local.r.metastore_id}",
  )
}

# ---------------------------------------------------------------------------
# Step A - SecureConnect networking on the provider
# ---------------------------------------------------------------------------

resource "databricks_mws_network_connectivity_config" "sharing" {
  provider = databricks.account
  name     = "${replace(var.name_prefix, "_", "-")}-opensharing-ncc"
  region   = local.p.location
}

resource "databricks_mws_ncc_private_endpoint_rule" "sharing" {
  provider = databricks.account
  for_each = toset(["blob", "dfs"])

  network_connectivity_config_id = databricks_mws_network_connectivity_config.sharing.network_connectivity_config_id
  resource_id                    = local.uc_storage_id
  group_id                       = each.key
}

# Approves only the connections of these two NCC endpoints (by endpoint name).
resource "terraform_data" "approve_sharing_private_endpoints" {
  triggers_replace = [for r in databricks_mws_ncc_private_endpoint_rule.sharing : r.rule_id]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = "${path.module}/../../modules/azure-databricks-hardened/scripts/approve_private_endpoints.sh '${local.uc_storage_id}' ${join(" ", [for r in databricks_mws_ncc_private_endpoint_rule.sharing : r.endpoint_name])}"
  }
}

# ---------------------------------------------------------------------------
# Step A - share (provider metastore)
# ---------------------------------------------------------------------------

resource "databricks_share" "this" {
  provider = databricks.provider
  name     = local.share_name
  comment  = "Shared to ${var.recipient_name} via SecureConnect"

  dynamic "object" {
    for_each = var.shared_tables
    content {
      name                        = "${var.source_schema}.${object.value}"
      data_object_type            = "TABLE"
      history_data_sharing_status = "ENABLED"
    }
  }

  # Views filter rows and columns on the provider side before they leave the region.
  dynamic "object" {
    for_each = var.shared_views
    content {
      name             = "${var.source_schema}.${object.value}"
      data_object_type = "VIEW"
    }
  }
}

# ---------------------------------------------------------------------------
# Step D - recipient + grant (after the UI steps)
# ---------------------------------------------------------------------------

resource "databricks_recipient" "this" {
  count    = var.enable_recipient ? 1 : 0
  provider = databricks.provider

  name                               = var.recipient_name
  comment                            = "Recipient metastore ${local.recipient_global_metastore_id}"
  authentication_type                = "DATABRICKS"
  data_recipient_global_metastore_id = local.recipient_global_metastore_id
}

resource "databricks_grants" "share" {
  count    = var.enable_recipient ? 1 : 0
  provider = databricks.provider
  share    = databricks_share.this.name

  grant {
    principal  = databricks_recipient.this[0].name
    privileges = ["SELECT"]
  }
}

# ---------------------------------------------------------------------------
# Step E - recipient side: catalog from the share
# ---------------------------------------------------------------------------

resource "databricks_catalog" "shared" {
  count    = var.recipient_provider_name != null ? 1 : 0
  provider = databricks.recipient

  name          = var.recipient_catalog_name
  provider_name = var.recipient_provider_name
  share_name    = databricks_share.this.name
  comment       = "Read-only catalog from the ${databricks_share.this.name} share (${local.p.location})"

  depends_on = [databricks_grants.share]
}
