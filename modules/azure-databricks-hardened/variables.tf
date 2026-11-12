# ---------------------------------------------------------------------------
# Identity / placement
# ---------------------------------------------------------------------------

variable "prefix" {
  description = "Name prefix for every Azure and Databricks object (e.g. \"sra-provider\")."
  type        = string
}

variable "workspace_name" {
  description = "Azure Databricks workspace name. Defaults to var.prefix."
  type        = string
  default     = null
}

variable "location" {
  description = "Azure region, e.g. koreacentral."
  type        = string
}

variable "resource_group_name" {
  description = "Resource group that holds the VNet, NSGs, NAT gateway, private endpoint and the workspace."
  type        = string
}

variable "create_resource_group" {
  description = "Create the resource group. Set false to use an existing one."
  type        = bool
  default     = true
}

variable "managed_resource_group_name" {
  description = "Databricks-managed resource group. Databricks recommends a \"managed\" prefix. Defaults to managed-<workspace_name>."
  type        = string
  default     = null
}

variable "databricks_account_id" {
  description = "Databricks account ID (accounts.azuredatabricks.net)."
  type        = string
}

variable "tags" {
  description = "Tags on every Azure resource. Workspace tags also propagate to the managed resource group and cluster VMs."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

variable "vnet_cidr" {
  description = "VNet address space."
  type        = string
  default     = "10.40.0.0/16"
}

variable "subnet_cidrs" {
  description = <<-EOT
    Subnet CIDRs inside vnet_cidr.
      host        - Databricks public (host) subnet, delegated. /26 minimum, /22 leaves room for ~1000 nodes.
      container   - Databricks private (container) subnet, delegated. Same size as host.
      privatelink - private endpoints (classic compute Private Link, and later storage / DB endpoints).
      png         - private network gateway, delegated to Microsoft.Databricks/workspaces, dedicated, /28 or larger.
      workload_vm - VMs and private endpoints for workloads outside Databricks.
      workload_db - Azure databases. Created without delegation; delegate it later if the database
                    type needs VNet integration (e.g. PostgreSQL / MySQL Flexible Server private access).
    png / workload_vm / workload_db may be omitted when create_png_subnet / create_workload_subnets
    is false.
  EOT
  type = object({
    host        = string
    container   = string
    privatelink = string
    png         = optional(string)
    workload_vm = optional(string)
    workload_db = optional(string)
  })
  default = {
    host        = "10.40.0.0/22"
    container   = "10.40.4.0/22"
    privatelink = "10.40.8.0/27"
    png         = "10.40.8.32/28"
    workload_vm = "10.40.9.0/24"
    workload_db = "10.40.10.0/24"
  }
}

variable "create_png_subnet" {
  description = "Create the dedicated private network gateway subnet. Required when enable_private_network_gateway = true."
  type        = bool
  default     = true
}

variable "create_workload_subnets" {
  description = "Create the workload_vm / workload_db subnets (and their NSGs) for Azure VMs and databases next to Databricks. false = Databricks-only VNet; put workloads in a separate, peered VNet."
  type        = bool
  default     = true
}

variable "nat_gateway_on_workload_vm" {
  description = "Attach the NAT gateway to the workload_vm subnet too, so VMs get outbound internet (OS updates, packages)."
  type        = bool
  default     = true
}

variable "storage_service_endpoint_enabled" {
  description = "Add the Microsoft.Storage.Global service endpoint to the Databricks subnets so classic compute reaches Azure Storage (incl. artifact storage in other regions) over the Azure backbone."
  type        = bool
  default     = true
}

variable "internal_dns_zone_name" {
  description = "Private DNS zone linked to the VNet with auto-registration, for VMs / DBs in the workload subnets. The private network gateway routes this suffix by default. Set null to skip."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Workspace
# ---------------------------------------------------------------------------

variable "public_network_access_enabled" {
  description = "Hardened connectivity keeps user access on the internet, gated by IP access lists / context-based ingress. false = Isolated (needs inbound Private Link, not in this module)."
  type        = bool
  default     = true
}

# ---------------------------------------------------------------------------
# Private storage (Security Reference Architecture)
# ---------------------------------------------------------------------------

variable "workspace_storage_firewall_enabled" {
  description = <<-EOT
    Firewall support for the workspace storage account (DBFS root / workspace system data, in the
    managed resource group). Databricks blocks public network access on it; classic compute reaches
    it through dfs / blob private endpoints in the privatelink subnet, serverless through the NCC
    private endpoints created here. Needs an access connector outside the managed RG (created here).
    Turning it on for an existing workspace is an in-place update that deletes the managed-RG
    access connector (remap external locations that used it first).
  EOT
  type        = bool
  default     = false
}

variable "workspace_storage_account_name" {
  description = "Name of the workspace storage account. Set only with workspace_storage_firewall_enabled (the private endpoints need the name up front). null = dbstorage<hash>. Changing it replaces the workspace."
  type        = string
  default     = null
}

variable "uc_storage_bypass_azure_services" {
  description = <<-EOT
    Firewall exception "Allow Azure services on the trusted services list" on the UC root storage.
    The access connector already has a resource instance rule, which is what Unity Catalog uses.
    Learn recommends turning the exception off once that rule exists: with it on, every access
    connector in the tenant and other trusted Azure services can reach the account. Default true
    keeps the behaviour this sample was validated with; set false in production, then re-run the
    external location Test connection and a serverless query.
  EOT
  type        = bool
  default     = true
}

variable "uc_storage_public_network_access_enabled" {
  description = <<-EOT
    true  = UC root storage keeps its public endpoint with a Deny-by-default firewall (Databricks
            subnets by service endpoint, access connector by resource instance rule, storage_allowed_ips).
    false = public network access disabled; classic compute uses the private endpoints from
            uc_storage_private_endpoints_enabled, serverless the NCC private endpoints. The machine running
            Terraform then cannot reach the data plane, so the caller's azurerm provider must set
            features { storage { data_plane_available = false } }.
  EOT
  type        = bool
  default     = true
}

variable "uc_storage_private_endpoints_enabled" {
  description = "Create dfs / blob private endpoints to the UC root storage in the privatelink subnet for classic compute."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Serverless: NCC, network policy, private network gateway
# ---------------------------------------------------------------------------

variable "network_policy_restriction_mode" {
  description = "Serverless egress: RESTRICTED_ACCESS or FULL_ACCESS."
  type        = string
  default     = "RESTRICTED_ACCESS"

  validation {
    condition     = contains(["RESTRICTED_ACCESS", "FULL_ACCESS"], var.network_policy_restriction_mode)
    error_message = "network_policy_restriction_mode must be RESTRICTED_ACCESS or FULL_ACCESS."
  }
}

variable "network_policy_enforcement_mode" {
  description = "ENFORCED blocks denied destinations; DRY_RUN only logs them to system.access.outbound_network."
  type        = string
  default     = "ENFORCED"

  validation {
    condition     = contains(["ENFORCED", "DRY_RUN"], var.network_policy_enforcement_mode)
    error_message = "network_policy_enforcement_mode must be ENFORCED or DRY_RUN."
  }
}

variable "network_policy_dry_run_products" {
  description = "Products kept in dry-run when enforcement_mode = DRY_RUN: DBSQL, ML_SERVING. Empty = all products."
  type        = list(string)
  default     = []
}

variable "serverless_allowed_fqdns" {
  description = "Internet FQDNs serverless compute may reach under RESTRICTED_ACCESS. Wildcards are not accepted."
  type        = list(string)
  default     = ["pypi.org", "files.pythonhosted.org"]
}

variable "enable_private_network_gateway" {
  description = "Create a private network gateway on the NCC (Public Preview: enable it on the account console Previews page first; check the billing start date in the Azure Databricks release notes)."
  type        = bool
  default     = true
}

variable "png_bandwidth_gbps" {
  description = "Private network gateway bandwidth tier: 10, 30, 50 or 100. No server-side default."
  type        = number
  default     = 10

  validation {
    condition     = contains([10, 30, 50, 100], var.png_bandwidth_gbps)
    error_message = "png_bandwidth_gbps must be 10, 30, 50 or 100."
  }
}

variable "png_traffic_mode" {
  description = "SPECIFIC_DESTINATIONS (route only png_destinations) or ALL_TRAFFIC."
  type        = string
  default     = "SPECIFIC_DESTINATIONS"

  validation {
    condition     = contains(["SPECIFIC_DESTINATIONS", "ALL_TRAFFIC"], var.png_traffic_mode)
    error_message = "png_traffic_mode must be SPECIFIC_DESTINATIONS or ALL_TRAFFIC."
  }
}

variable "png_destinations" {
  description = "DNS names routed through the gateway (suffix match: db.example.internal also matches a.db.example.internal). Defaults to internal_dns_zone_name. Ignored for ALL_TRAFFIC."
  type        = list(string)
  default     = null
}

variable "png_dns_resolver_ips" {
  description = "Custom DNS resolver IPs reachable from the gateway subnet (max 2). Empty = Azure-provided DNS, which also resolves private DNS zones linked to the VNet."
  type        = list(string)
  default     = []
}

variable "png_destroy_wait" {
  description = "Wait after deleting the gateway before deleting its subnet. Gateway delete returns immediately while its NIC (in a Databricks subscription, attached to this subnet) is cleaned up; this can take more than 30 minutes, so be ready to run terraform destroy again."
  type        = string
  default     = "300s"
}

# ---------------------------------------------------------------------------
# Unity Catalog
# ---------------------------------------------------------------------------

variable "create_metastore" {
  description = "Create a dedicated metastore with its own ADLS Gen2 root storage and access connector, and assign it to the workspace."
  type        = bool
  default     = true
}

variable "metastore_id" {
  description = "Used only when create_metastore = false: existing metastore in the same region to assign. null = leave it to automatic assignment."
  type        = string
  default     = null
}

variable "metastore_name" {
  description = "Defaults to <prefix>-metastore."
  type        = string
  default     = null
}

variable "metastore_owner" {
  description = "Metastore owner (user, group or SP application ID). null = the identity running Terraform."
  type        = string
  default     = null
}

variable "metastore_force_destroy" {
  description = "Let terraform destroy remove the metastore / starter catalog even when they still hold objects."
  type        = bool
  default     = false
}

variable "metastore_delta_sharing" {
  description = <<-EOT
    OpenSharing settings of the dedicated metastore. scope = INTERNAL (sharing only to
    metastores in this account, the default) or INTERNAL_AND_EXTERNAL ("Allow OpenSharing
    with parties outside your organization"). In the account console the OpenSharing NCC
    field used by SecureConnect only appears with INTERNAL_AND_EXTERNAL.
    recipient_token_lifetime_seconds applies to Databricks-to-Open tokens only.
  EOT
  type = object({
    scope                            = string
    recipient_token_lifetime_seconds = optional(number)
    organization_name                = optional(string)
  })
  default = null

  validation {
    condition     = var.metastore_delta_sharing == null || contains(["INTERNAL", "INTERNAL_AND_EXTERNAL"], try(var.metastore_delta_sharing.scope, ""))
    error_message = "metastore_delta_sharing.scope must be INTERNAL or INTERNAL_AND_EXTERNAL."
  }
}

variable "uc_file_events_roles_enabled" {
  description = "Grant the UC access connector the file events roles (Storage Queue Data Contributor and Storage Account Contributor on the UC storage account, EventGrid EventSubscription Contributor on its resource group), so Databricks can set up managed file events for Auto Loader and file arrival triggers. Requires the Microsoft.EventGrid resource provider in the subscription."
  type        = bool
  default     = true
}

variable "uc_storage_account_name" {
  description = "ADLS Gen2 account for the metastore root. null = <prefix>uc<hash>."
  type        = string
  default     = null
}

variable "storage_allowed_ips" {
  description = "Public IPs allowed through the UC storage firewall: the machine running Terraform needs it (the provider reads data-plane properties on refresh). IPs or CIDRs; /32 is converted to a plain IP (storage rules reject /31 and /32)."
  type        = list(string)
  default     = []
}

variable "catalog_name" {
  description = "Starter catalog created on the second apply. null = none."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# Second apply: workspace-level settings
# ---------------------------------------------------------------------------

variable "workspace_url" {
  description = "Workspace URL (https://adb-...azuredatabricks.net). null on the first apply; set it from the workspace_url output to create the workspace-level objects."
  type        = string
  default     = null
}

variable "ip_access_list_cidrs" {
  description = "IPs / CIDRs allowed to reach the workspace UI and API. The NAT gateway public IP is added automatically. Empty = no IP access list."
  type        = list(string)
  default     = []
}

variable "disable_legacy_access" {
  description = "Second apply: disable legacy features (DBFS root and mounts, Hive metastore, no-isolation shared clusters, Databricks Runtime < 13.3) as in the Security Reference Architecture."
  type        = bool
  default     = false
}
