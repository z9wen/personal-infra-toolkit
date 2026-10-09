output "vm_public_ip" {
  value = azurerm_public_ip.app.ip_address
}

output "ssh_command" {
  value = "ssh azureuser@${azurerm_public_ip.app.ip_address}"
}

output "vm_internal_fqdn" {
  description = "Auto-registered private DNS name of the VM."
  value       = "${local.vm_name}.${azurerm_private_dns_zone.internal.name}"
}

output "mysql_fqdn" {
  value = azurerm_mysql_flexible_server.this.fqdn
}

output "mysql_alias" {
  description = "Stable internal name applications should use."
  value       = "${azurerm_private_dns_cname_record.db.name}.${azurerm_private_dns_zone.internal.name}"
}

output "mysql_admin_login" {
  value = azurerm_mysql_flexible_server.this.administrator_login
}

output "mysql_admin_password" {
  value     = random_password.mysql_admin.result
  sensitive = true
}

output "mysql_database" {
  value = azurerm_mysql_flexible_database.app.name
}
