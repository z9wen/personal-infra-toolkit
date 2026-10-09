resource "random_password" "mysql_admin" {
  length           = 24
  special          = true
  override_special = "-_=+.#%"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_mysql_flexible_server" "this" {
  name                   = "${var.name}-mysql-${random_string.suffix.result}"
  resource_group_name    = azurerm_resource_group.this.name
  location               = azurerm_resource_group.this.location
  administrator_login    = "mysqladmin"
  administrator_password = random_password.mysql_admin.result
  sku_name               = var.mysql_sku
  version                = "8.0.21"

  # Private access: no public endpoint, reachable only inside the VNet.
  delegated_subnet_id = azurerm_subnet.mysql.id
  private_dns_zone_id = azurerm_private_dns_zone.mysql.id

  backup_retention_days        = 7
  geo_redundant_backup_enabled = false

  storage {
    size_gb           = 20
    auto_grow_enabled = true
  }

  tags = local.tags

  # The server cannot be created until its DNS zone is linked to the VNet.
  depends_on = [azurerm_private_dns_zone_virtual_network_link.mysql]

  lifecycle {
    # Azure picks an availability zone when none is set.
    ignore_changes = [zone]
  }
}

resource "azurerm_mysql_flexible_database" "app" {
  name                = "app"
  resource_group_name = azurerm_resource_group.this.name
  server_name         = azurerm_mysql_flexible_server.this.name
  charset             = "utf8mb4"
  collation           = "utf8mb4_unicode_ci"
}
