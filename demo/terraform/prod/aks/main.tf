resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

locals {
  tags = {
    Environment = "Production"
    CostCenter  = "CC-4711"
    Department  = "Platform"
  }
}

# Cross-root dependency, by name, in the live subscription. In a cold region this resolves
# nothing until the connectivity vnet root has been applied.
data "azurerm_subnet" "aks" {
  name                 = "snet-aks"
  virtual_network_name = "ctso-conn-weu-vnet"
  resource_group_name  = "ctso-conn-weu-network-rg"
}

# Second cross-root dependency: the telemetry sink the cluster ships diagnostics to.
data "azurerm_log_analytics_workspace" "this" {
  name                = "ctso-prod-weu-law"
  resource_group_name = "ctso-prod-weu-observability-rg"
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = "ctso-prod-weu-aks"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = "ctso-prod-weu-aks"
  tags                = local.tags

  default_node_pool {
    name           = "system"
    node_count     = var.node_count
    vm_size        = "Standard_D4s_v5"
    vnet_subnet_id = data.azurerm_subnet.aks.id
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"
    service_cidr   = "10.100.240.0/20"
    dns_service_ip = "10.100.240.10"
  }

  oms_agent {
    log_analytics_workspace_id = data.azurerm_log_analytics_workspace.this.id
  }
}

# A principal id pinned in code rather than looked up. Nothing here can derive its DR equivalent,
# so a Builder must defer it rather than invent one.
resource "azurerm_role_assignment" "cluster_admin" {
  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service Cluster Admin Role"
  principal_id         = "00000000-0000-0000-0000-0000000000c7"
}
