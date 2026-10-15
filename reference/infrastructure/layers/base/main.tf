provider "azurerm" {
  features {}
  subscription_id     = var.subscription_id
  storage_use_azuread = true
  use_oidc            = true
}

terraform {
  backend "http" {} # Configured via GitLab CI
}

locals {
  keyvault_name = "kv-${var.project_name}-${var.environment}-${random_id.kv_suffix.hex}"
}

# APPLICATION RESOURCE GROUP
resource "azurerm_resource_group" "rg" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [location]
  }
}

# MANAGED IDENTITY FOR WEBAPPS
resource "azurerm_user_assigned_identity" "shared_app_identity" {
  name                = "mi-${var.project_name}-${var.environment}-shared"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  tags                = var.tags

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [location]
  }
}

resource "random_id" "kv_suffix" {
  byte_length = 2
}

module "keyvault" {
  source                    = "git.eon-cds.de/repos/envia-spark-keyvault/azurerm"
  version                   = "1.0.3"
  vault_name                = local.keyvault_name
  resource_group_name       = azurerm_resource_group.rg.name
  location                  = var.location
  tags                      = var.tags
  admin_object_ids          = var.keyvault_admin_object_ids
  secrets_reader_object_ids = [azurerm_user_assigned_identity.shared_app_identity.principal_id]
}

module "oidc_secrets" {
  source       = "git.eon-cds.de/repos/envia-spark-manual-secrets/azurerm"
  version      = "1.0.3"
  key_vault_id = module.keyvault.id
  secret_names = [
    "${var.environment}-${var.project_name}-client-id",
    "${var.environment}-${var.project_name}-tenant-id",
    "${var.environment}-${var.project_name}-client-secret"
  ]
}

# ── GitLab CI OIDC Federation ────────────────────────────────────────────────
# Allows GitLab CI pipelines to authenticate with Azure via OIDC Workload
# Identity Federation — no client secrets required. The audience must match
# the 'aud' value set in the CI job's id_tokens block.
module "gitlab_oidc" {
  source              = "git.eon-cds.de/repos/envia-spark-gitlab-oidc/azurerm"
  version             = "1.0.3"
  resource_group_name = azurerm_resource_group.rg.name
  uami_id             = azurerm_user_assigned_identity.shared_app_identity.id
  gitlab_url          = "https://git.eon-cds.de"
  subjects = [
    {
      name    = "dev"
      subject = "project_path:${var.gitlab_project_path}:ref_type:branch:ref:dev"
    },
    {
      name    = "main"
      subject = "project_path:${var.gitlab_project_path}:ref_type:branch:ref:main"
    },
  ]
}
