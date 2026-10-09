# Zone the MySQL server registers its private A record in. Azure requires the
# name to end in .mysql.database.azure.com.
resource "azurerm_private_dns_zone" "mysql" {
  name                = "${var.name}.private.mysql.database.azure.com"
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "mysql" {
  name                 = "link-mysql-${var.name}"
  private_dns_zone_id  = azurerm_private_dns_zone.mysql.id
  virtual_network_id   = azurerm_virtual_network.this.id
  registration_enabled = false
  tags                 = local.tags
}

# Internal names for the workload. With auto-registration on, every VM in the
# VNet gets an A record (<vm-name>.infra.internal) that follows its private IP.
resource "azurerm_private_dns_zone" "internal" {
  name                = var.internal_dns_zone
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "internal" {
  name                 = "link-internal-${var.name}"
  private_dns_zone_id  = azurerm_private_dns_zone.internal.id
  virtual_network_id   = azurerm_virtual_network.this.id
  registration_enabled = true
  tags                 = local.tags
}

# Stable alias so applications use db.infra.internal instead of the generated
# server hostname; swapping servers only changes this record.
resource "azurerm_private_dns_cname_record" "db" {
  name                = "db"
  private_dns_zone_id = azurerm_private_dns_zone.internal.id
  ttl                 = 300
  record              = azurerm_mysql_flexible_server.this.fqdn
  tags                = local.tags
}
