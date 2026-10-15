// layers/data/main
provider "azurerm" {

  features {}
  subscription_id     = var.subscription_id
  storage_use_azuread = true
  use_oidc            = true
}

terraform {
  backend "http" {}
}

# 1. READ BASE INFRASTRUCTURE
data "terraform_remote_state" "base" {
  backend = "http"
  config = {
    address  = "${var.gitlab_api_url}/projects/${var.gitlab_project_id}/terraform/state/${var.environment}-base"
    username = var.gitlab_username
    password = var.gitlab_token
  }
}

# 2. READ NETWORKING INFRASTRUCTURE
data "terraform_remote_state" "networking" {
  backend = "http"
  config = {
    address  = "${var.gitlab_api_url}/projects/${var.gitlab_project_id}/terraform/state/${var.environment}-networking"
    username = var.gitlab_username
    password = var.gitlab_token
  }
}

data "azurerm_client_config" "current" {}

locals {
  environment                  = var.environment
  keyvault_id                  = data.terraform_remote_state.base.outputs.keyvault_id
  db_subnet_id                 = data.terraform_remote_state.networking.outputs.db_subnet_id
  postgres_dns_zone_id         = data.terraform_remote_state.networking.outputs.postgres_dns_zone_id
  shared_identity_principal_id = data.terraform_remote_state.base.outputs.shared_identity_principal_id
  shared_identity_name         = data.terraform_remote_state.base.outputs.shared_identity_name
}

# Generate Password for DB
resource "random_password" "db_password" {
  length           = 24
  special          = true
  override_special = "!#%^*-_"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
}

# Store Password for DB in Keyvault
resource "azurerm_key_vault_secret" "db_password" {
  name         = "db-password-${local.environment}"
  value        = random_password.db_password.result
  key_vault_id = local.keyvault_id
}

# DATABASE
module "database" {
  source              = "git.eon-cds.de/repos/envia-spark-database/azurerm"
  version             = "1.0.4"
  project_name        = var.project_name
  environment         = local.environment
  resource_group_name = var.resource_group_name
  location            = var.location
  admin_username      = "pgadmin"
  admin_password      = random_password.db_password.result
  sku_name            = var.database_sku_name
  prevent_destroy     = var.database_prevent_destroy
  tags                = var.tags

  ac1_branch          = var.ac1_branch
  fachbereich         = var.fachbereich
  project_name_prefix = var.project_name_prefix
  product_name        = var.product_name
  stage               = local.environment
  db_name             = var.project_name
  suffix              = var.database_suffix

  db_subnet_id          = local.db_subnet_id
  private_dns_zone_id   = local.postgres_dns_zone_id
  entra_admin_object_id = local.shared_identity_principal_id
  entra_admin_name      = local.shared_identity_name
  tenant_id             = data.azurerm_client_config.current.tenant_id

  depends_on = [data.terraform_remote_state.networking]
}

# STORAGE ACCOUNT & BLOB CONTAINER
module "storage_account" {
  source              = "git.eon-cds.de/repos/envia-spark-storage-account/azurerm"
  version             = "1.0.3"
  container_name      = var.container_name
  project_name_prefix = var.project_name_prefix
  ac1_branch          = var.ac1_branch
  business_unit       = var.fachbereich
  product_name        = var.product_name
  resource_group_name = var.resource_group_name
  stage               = local.environment
  location            = var.location
  tags                = var.tags
  prevent_destroy     = var.database_prevent_destroy
}
