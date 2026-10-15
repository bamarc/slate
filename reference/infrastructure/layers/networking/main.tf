// layers/networking/main
provider "azurerm" {

  features {}
  subscription_id     = var.subscription_id
  storage_use_azuread = true
  use_oidc            = true
}

terraform {
  backend "http" {}
}

locals {
  environment = var.environment

  # If atlantis_vnet_rg is empty, Atlantis mode is disabled
  # and the module's own existing_* defaults take over.
  # VNet/subnet IDs use atlantis_subscription_id (separate networking subscription).
  # DNS zone ID uses the main subscription_id and resource_group_name.
  atlantis_vnet_id        = var.atlantis_vnet_rg != "" ? "/subscriptions/${var.atlantis_subscription_id}/resourceGroups/${var.atlantis_vnet_rg}/providers/Microsoft.Network/virtualNetworks/${var.atlantis_vnet_name}" : ""
  atlantis_db_subnet_id   = var.atlantis_vnet_rg != "" ? "${local.atlantis_vnet_id}/subnets/${var.atlantis_db_subnet_name}" : ""
  atlantis_app_subnet_id  = var.atlantis_vnet_rg != "" ? "${local.atlantis_vnet_id}/subnets/${var.atlantis_app_subnet_name}" : ""
  atlantis_jump_subnet_id = var.atlantis_vnet_rg != "" ? "${local.atlantis_vnet_id}/subnets/${var.atlantis_jump_subnet_name}" : ""
  atlantis_dns_zone_id    = var.atlantis_vnet_rg != "" ? "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}/providers/Microsoft.Network/privateDnsZones/${var.atlantis_postgres_dns_zone_name}" : ""
  create_postgres_dns_in_atlantis = tobool(var.create_postgres_dns_in_atlantis == "" ? "false" : var.create_postgres_dns_in_atlantis)
}

module "networking" {
  source                = "git.eon-cds.de/repos/envia-spark-networking/azurerm"
  version               = "1.0.3"
  env_name              = "${var.project_name}-${local.environment}"
  project_name          = var.project_name
  environment           = local.environment
  resource_group_name   = var.resource_group_name
  location              = var.location
  tags                  = var.tags
  service_plan_sku_name = var.service_plan_sku_name
  networking_mode       = var.networking_mode

  create_postgres_dns_in_atlantis_mode = local.create_postgres_dns_in_atlantis
  postgres_dns_resource_group_name     = var.postgres_dns_resource_group_name
  existing_vnet_id                     = local.atlantis_vnet_id
  existing_db_subnet_id                = local.atlantis_db_subnet_id
  existing_app_subnet_id               = local.atlantis_app_subnet_id
  existing_jump_subnet_id              = local.atlantis_jump_subnet_id
  existing_postgres_dns_zone_id        = local.atlantis_dns_zone_id
}
