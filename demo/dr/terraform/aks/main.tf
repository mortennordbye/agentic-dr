resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

locals {
  tags = {
    Environment = "DR"
    CostCenter  = "CC-4711"
    Department  = "Platform"
  }
}

# Cross-root dependency, by name, in the DR subscription. The lookup target is renamed to the DR
# VNet/RG produced by the `vnet` DR root; it resolves only once that root has been applied, so a
# cold plan-only run is partial by design.
data "azurerm_subnet" "aks" {
  name                 = "snet-aks"
  virtual_network_name = "ctso-dr-conn-neu-vnet"
  resource_group_name  = "ctso-dr-conn-neu-network-rg"
}

# Second cross-root dependency: the telemetry sink the cluster ships diagnostics to, renamed to the
# workspace the `law` DR root produces.
data "azurerm_log_analytics_workspace" "this" {
  name                = "ctso-dr-prod-neu-law"
  resource_group_name = "ctso-dr-prod-neu-observability-rg"
}

resource "azurerm_kubernetes_cluster" "this" {
  name                = "ctso-dr-prod-neu-aks"
  location            = var.location
  resource_group_name = azurerm_resource_group.this.name
  dns_prefix          = "ctso-dr-prod-neu-aks"
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

  # Cluster-internal service range moved onto the DR production IP plan (10.200.0.0/16).
  network_profile {
    network_plugin = "azure"
    service_cidr   = "10.200.240.0/20"
    dns_service_ip = "10.200.240.10"
  }

  oms_agent {
    log_analytics_workspace_id = data.azurerm_log_analytics_workspace.this.id
  }
}

# The source root pins the cluster-admin principal id in code rather than looking it up. Nothing
# available at codegen derives its DR equivalent, so the value is deferred to the Orchestrator and
# the assignment is skipped until a DR principal id is supplied.
resource "azurerm_role_assignment" "cluster_admin" {
  count                = var.cluster_admin_principal_id == null ? 0 : 1
  scope                = azurerm_kubernetes_cluster.this.id
  role_definition_name = "Azure Kubernetes Service Cluster Admin Role"
  principal_id         = var.cluster_admin_principal_id # DR-DEFER: aks cluster_admin role assignment principal_id
}
