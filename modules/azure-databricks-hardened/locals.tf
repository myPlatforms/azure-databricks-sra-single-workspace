locals {
  workspace_name              = coalesce(var.workspace_name, var.prefix)
  managed_resource_group_name = coalesce(var.managed_resource_group_name, "managed-${local.workspace_name}")

  resource_group_name = var.create_resource_group ? azurerm_resource_group.this[0].name : data.azurerm_resource_group.this[0].name
  resource_group_id   = var.create_resource_group ? azurerm_resource_group.this[0].id : data.azurerm_resource_group.this[0].id
  location            = var.location

  # Delegation actions Azure adds on its own. Listing them keeps plan from
  # showing a perpetual diff on the delegated subnets.
  databricks_delegation_actions = [
    "Microsoft.Network/virtualNetworks/subnets/join/action",
    "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action",
    "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action",
  ]

  png_destinations = (
    var.png_traffic_mode == "ALL_TRAFFIC" ? [] :
    var.png_destinations != null ? var.png_destinations :
    var.internal_dns_zone_name != null ? [var.internal_dns_zone_name] : []
  )

  # The serverless egress policy is evaluated before the private network gateway,
  # so gateway destinations must also be on the allow list or they are dropped.
  serverless_allowed_fqdns = distinct(concat(
    var.serverless_allowed_fqdns,
    var.enable_private_network_gateway ? local.png_destinations : [],
  ))

  workspace_level = var.workspace_url != null
}
