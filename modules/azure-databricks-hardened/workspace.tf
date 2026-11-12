# ---------------------------------------------------------------------------
# Workspace: VNet injection + Secure Cluster Connectivity (no public IP)
# Hardened connectivity: public network access stays enabled (users come in over
# the internet, gated by IP access lists), classic compute talks to the control
# plane through the databricks_ui_api private endpoint below.
# ---------------------------------------------------------------------------

resource "azurerm_databricks_workspace" "this" {
  name                        = local.workspace_name
  resource_group_name         = local.resource_group_name
  location                    = local.location
  sku                         = "premium"
  managed_resource_group_name = local.managed_resource_group_name

  public_network_access_enabled = var.public_network_access_enabled
  # Required for classic compute Private Link: Databricks adds no NSG rules and
  # the compute plane reaches the control plane only through the private endpoint.
  network_security_group_rules_required = "NoAzureDatabricksRules"

  # Workspace storage firewall (SRA "private DBFS"). null when off so existing
  # workspaces see no diff on these optional attributes.
  default_storage_firewall_enabled = var.workspace_storage_firewall_enabled ? true : null
  access_connector_id              = var.workspace_storage_firewall_enabled ? azurerm_databricks_access_connector.workspace[0].id : null

  custom_parameters {
    # Fixed name only when the private endpoints need it; otherwise Azure generates one.
    storage_account_name = local.workspace_storage_account_name
    no_public_ip         = true
    virtual_network_id   = azurerm_virtual_network.this.id
    public_subnet_name   = azurerm_subnet.host.name
    private_subnet_name  = azurerm_subnet.container.name

    public_subnet_network_security_group_association_id  = azurerm_subnet_network_security_group_association.host.id
    private_subnet_network_security_group_association_id = azurerm_subnet_network_security_group_association.container.id
  }

  tags = var.tags

  depends_on = [
    # Clusters started before the NAT gateway is attached get no outbound path.
    azurerm_subnet_nat_gateway_association.host,
    azurerm_subnet_nat_gateway_association.container,
    # Destroy order: the NCC and the network policy cannot be deleted while a
    # workspace still uses them (the binding / network option deletes do not
    # detach). Depending on them here makes Terraform delete the workspace first.
    databricks_mws_network_connectivity_config.this,
    databricks_account_network_policy.this,
  ]
}

# ---------------------------------------------------------------------------
# Classic compute plane Private Link (back-end): databricks_ui_api endpoint in the
# workspace VNet + privatelink.azuredatabricks.net zone linked to the VNet.
# No browser_authentication endpoint: that one is only for inbound (front-end)
# Private Link, which Hardened connectivity does not use.
# ---------------------------------------------------------------------------

resource "azurerm_private_dns_zone" "databricks" {
  name                = "privatelink.azuredatabricks.net"
  resource_group_name = local.resource_group_name
  tags                = var.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "databricks" {
  name                 = "${var.prefix}-databricks"
  private_dns_zone_id  = azurerm_private_dns_zone.databricks.id
  virtual_network_id   = azurerm_virtual_network.this.id
  registration_enabled = false
  tags                 = var.tags
}

resource "azurerm_private_endpoint" "backend" {
  name                          = "${var.prefix}-pe-backend"
  location                      = local.location
  resource_group_name           = local.resource_group_name
  subnet_id                     = azurerm_subnet.privatelink.id
  custom_network_interface_name = "${var.prefix}-pe-backend-nic"

  private_service_connection {
    name                           = "${var.prefix}-backend"
    private_connection_resource_id = azurerm_databricks_workspace.this.id
    is_manual_connection           = false
    subresource_names              = ["databricks_ui_api"]
  }

  private_dns_zone_group {
    name                 = "databricks"
    private_dns_zone_ids = [azurerm_private_dns_zone.databricks.id]
  }

  tags = var.tags
}
