terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.31.0"
    }
  }

  required_version = ">=1.2.3"
}

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy = true
    }
  }
}

data "azurerm_client_config" "current" {}

output "current_client_id" {
  value = data.azurerm_client_config.current.client_id
}

output "current_tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "current_subscription_id" {
  value = data.azurerm_client_config.current.subscription_id
}

output "current_object_id" {
  value = data.azurerm_client_config.current.object_id
}

resource "azurerm_resource_group" "spoke-rg" {
  name     = "rg-${var.customer-name}-${var.env-prefix}-${var.location-prefix}-01"
  location = var.location
  tags = {
    Environment   = var.environment
    CreatedBy     = var.createdby
    CreationDate  = var.creationdate
  }
}

resource "azurerm_virtual_network" "spoke-vnet" {
  name                = "vnet-${var.customer-name}-${var.env-prefix}-${var.location-prefix}-01"
  location            = var.location
  resource_group_name = azurerm_resource_group.spoke-rg.name
  address_space       = [var.spoke-vnet-address-space]

  tags = {
    Environment = var.environment
    CreatedBy   = var.createdby
    CreationDate = var.creationdate
  }
}

resource "azurerm_subnet" "aks-default-nodepool-subnet" {
  name                 = "snet-aks-default-np"
  resource_group_name  = azurerm_resource_group.spoke-rg.name
  virtual_network_name = azurerm_virtual_network.spoke-vnet.name
  address_prefixes     = [var.aks-default-subnet-address-space]
}

resource "azurerm_subnet" "aks-acquisition-nodepool-subnet" {
  name                 = "snet-aks-acquisition-np"
  resource_group_name  = azurerm_resource_group.spoke-rg.name
  virtual_network_name = azurerm_virtual_network.spoke-vnet.name
  address_prefixes     = [var.aks-acquisition-subnet-address-space]
}

resource "azurerm_subnet" "aks-imageprocessing-nodepool-subnet" {
  name                 = "snet-aks-imageprocessing-np"
  resource_group_name  = azurerm_resource_group.spoke-rg.name
  virtual_network_name = azurerm_virtual_network.spoke-vnet.name
  address_prefixes     = [var.aks-imageprocessing-subnet-address-space]
}

resource "azurerm_subnet" "appsvc-outbound-subnet" {
  name                 = "snet-appservices-outbound"
  resource_group_name  = azurerm_resource_group.spoke-rg.name
  virtual_network_name = azurerm_virtual_network.spoke-vnet.name
  address_prefixes     = [var.appsvc-subnet-address-space]
}

resource "azurerm_subnet" "pe-subnet" {
  name                 = "snet-private-endpoints"
  resource_group_name  = azurerm_resource_group.spoke-rg.name
  virtual_network_name = azurerm_virtual_network.spoke-vnet.name
  address_prefixes     = [var.pe-subnet-address-space]
  private_endpoint_network_policies_enabled  = true
  private_link_service_network_policies_enabled  = true
}

resource "azurerm_route_table" "rt-hub-firewall" {
  name                          = "route-to-hub-firewall"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.spoke-rg.name
  disable_bgp_route_propagation = false

  route {
    name                        = "route_internal_traffic_in_vnet"
    address_prefix              = var.spoke-vnet-address-space
    next_hop_type               = "VnetLocal"
  }

  route {
    name                        = "route_all_traffic_to_fw"
    address_prefix              = "0.0.0.0/0"
    next_hop_type               = "VirtualAppliance"
    next_hop_in_ip_address      = var.firewall-private-ip
  }

  tags = {
    Environment  = var.environment,
    CreatedBy    = var.createdby,
    CreationDate = var.creationdate
  }
}

resource "azurerm_subnet_route_table_association" "aks-default-subnet-to-route-table" {
  subnet_id      = azurerm_subnet.aks-default-nodepool-subnet.id
  route_table_id = azurerm_route_table.rt-hub-firewall.id
}

resource "azurerm_subnet_route_table_association" "aks-imageprocessing-subnet-to-route-table" {
  subnet_id      = azurerm_subnet.aks-imageprocessing-nodepool-subnet.id
  route_table_id = azurerm_route_table.rt-hub-firewall.id
}

resource "azurerm_subnet_route_table_association" "aks-acquisition-subnet-to-route-table" {
  subnet_id      = azurerm_subnet.aks-acquisition-nodepool-subnet.id
  route_table_id = azurerm_route_table.rt-hub-firewall.id
}

resource "azurerm_kubernetes_cluster" "private-aks" {
  name                       = "aks-${var.customer-name}-${var.env-prefix}-${var.location-prefix}-01"
  location                   = var.location
  resource_group_name        = azurerm_resource_group.spoke-rg.name
  dns_prefix                 = "aks-${var.customer-name}-web"
  private_cluster_enabled    = true
  oidc_issuer_enabled        = true
  workload_identity_enabled  = true
  
  sku_tier            = "Paid"
  node_resource_group = "rg-aksnode-${var.customer-name}-${var.env-prefix}-${var.location-prefix}-01"
  azure_policy_enabled = true

  default_node_pool {
    name       = "systempool"
    enable_auto_scaling = true
    min_count  = 3
    max_count  = 5
    node_count = 3
    max_pods   = 30
    os_disk_size_gb = 128
    os_disk_type = "Managed"
    zones = [1, 2, 3]
    vm_size        = var.aks-system-nodepool-vm-size
    vnet_subnet_id = azurerm_subnet.aks-default-nodepool-subnet.id
    type           = "VirtualMachineScaleSets" 
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin       = "azure"
    network_policy       = "calico"
    load_balancer_sku    = "standard"
    outbound_type        = "userDefinedRouting"  
    dns_service_ip       = "172.17.192.10"
    docker_bridge_cidr   = "172.17.196.0/24"
    service_cidr         = "172.17.192.0/22" 
  }

  oms_agent {
    log_analytics_workspace_id = var.la-workspace-resource-id
  }  
  
  tags = {
    Environment  = var.environment,
    CreatedBy    = var.createdby,
    CreationDate = var.creationdate
  }
}