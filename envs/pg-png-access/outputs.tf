output "rule" {
  value = "${azurerm_network_security_rule.pg_from_private_network_gateway.source_address_prefix} -> ${azurerm_network_security_rule.pg_from_private_network_gateway.destination_address_prefix}:5432"
}
