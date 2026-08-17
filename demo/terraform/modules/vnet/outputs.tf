output "id" { value = azurerm_virtual_network.this.id }
output "name" { value = azurerm_virtual_network.this.name }
output "subnet_ids" { value = { for k, s in azurerm_subnet.this : k => s.id } }
