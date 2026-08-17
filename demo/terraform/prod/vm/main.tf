# Excluded by agentic-dr/profile/scope-rules.md: IaaS VMs are not lifted and shifted.
resource "azurerm_linux_virtual_machine" "legacy" {
  name                  = "ctso-prod-weu-legacy-vm"
  location              = "westeurope"
  resource_group_name   = "ctso-prod-weu-legacy-rg"
  size                  = "Standard_D2s_v5"
  admin_username        = "azureuser"
  network_interface_ids = []
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }
  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }
}
