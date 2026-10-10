// layers/services/main
provider "azurerm" {
  features {}
  subscription_id     = var.subscription_id
  storage_use_azuread = true
  use_oidc            = true
}

provider "azapi" {
  use_oidc = true
}

terraform {
  backend "http" {}
}

# 1. READ BASE INFRASTRUCTURE
data "terraform_remote_state" "base" {
  backend = "http"
  config = {
    # GitLab Terraform State URL pattern
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

# 3. READ DATA INFRASTRUCTURE
data "terraform_remote_state" "data" {
  backend = "http"
  config = {
    address  = "${var.gitlab_api_url}/projects/${var.gitlab_project_id}/terraform/state/${var.environment}-data"
    username = var.gitlab_username
    password = var.gitlab_token
  }
}

locals {
  environment = var.environment
  # Registry configuration
  use_acr                      = var.registry_mode == "ACR"
  reg_server                   = var.jfrog_registry != "" ? split("/", var.jfrog_registry)[0] : (var.artifactory_registry != null ? var.artifactory_registry.server : "")
  reg_user                     = var.artifactory_username != "" ? var.artifactory_username : var.gitlab_username
  reg_pass                     = var.artifactory_password != "" ? var.artifactory_password : var.gitlab_token
  app_image                    = var.jfrog_registry != "" ? "${var.jfrog_registry}/${var.app_image}" : (var.artifactory_registry != null ? "${var.artifactory_registry.server}/${var.artifactory_registry.repository}/${var.app_image}" : var.app_image)
  keyvault_id                  = data.terraform_remote_state.base.outputs.keyvault_id
  shared_identity_id           = data.terraform_remote_state.base.outputs.shared_identity_id
  shared_identity_principal_id = data.terraform_remote_state.base.outputs.shared_identity_principal_id
  # Client ID needed by the Python app to target the User-Assigned MI via azure-identity SDK
  shared_identity_client_id = data.terraform_remote_state.base.outputs.shared_identity_client_id

  app_name = "${var.project_name}-${local.environment}${var.app_instance != "" ? "-${var.app_instance}" : ""}"

  bastion_resource_group_name = var.bastion_resource_group_name != "" ? var.bastion_resource_group_name : var.resource_group_name
  jump_host_subnet_id         = var.jump_host_subnet_id != "" ? var.jump_host_subnet_id : data.terraform_remote_state.networking.outputs.jump_subnet_id
  jump_host_direct_ssh_cidrs_effective = var.jump_host_direct_ssh_cidrs_json != "" ? try(
    tolist(jsondecode(var.jump_host_direct_ssh_cidrs_json)),
    var.jump_host_direct_ssh_cidrs
  ) : var.jump_host_direct_ssh_cidrs

  # tobool() coerces the string "true"/"false" supplied via TF_VAR_* env vars.
  # CI passes all variables as strings; the bool type rejects them directly.
  # An empty string (GitLab variable unset, or ${VAR:-default} not expanded in
  # the variables: block) is normalised to "false" before conversion.
  enable_jump_host           = tobool(var.enable_jump_host == "" ? "false" : var.enable_jump_host)
  jump_host_enable_public_ip = tobool(var.jump_host_enable_public_ip == "" ? "false" : var.jump_host_enable_public_ip)
  jump_host_allow_direct_ssh = tobool(var.jump_host_allow_direct_ssh == "" ? "false" : var.jump_host_allow_direct_ssh)
}

# 3a. OPTIONAL: Existing Bastion metadata is treated as configuration-only.
# We intentionally avoid an Azure read here to prevent hard plan failures when
# Bastion is in another subscription/tenant or temporarily unavailable.

data "azurerm_key_vault_secret" "oidc_client_id" {
  name         = "${local.environment}-${var.project_name}-client-id"
  key_vault_id = local.keyvault_id
}

data "azurerm_key_vault_secret" "oidc_tenant_id" {
  name         = "${local.environment}-${var.project_name}-tenant-id"
  key_vault_id = local.keyvault_id
}

data "azurerm_key_vault_secret" "oidc_client_secret" {
  name         = "${local.environment}-${var.project_name}-client-secret"
  key_vault_id = local.keyvault_id
}

# 3c. OBSERVABILITY (Log Analytics Workspace & Application Insights)
module "observability" {
  source              = "git.eon-cds.de/repos/envia-spark-observability/azurerm"
  version             = "1.0.3"
  project_short       = var.project_short
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

# 3e. DATAFACTORY CONNECTION MULTI-CONNECTION MODULE
module "datafactory_connection" {
  source      = "git.eon-cds.de/repos/envia-spark-datafactory-connection/azurerm"
  version     = "1.0.3"
  connections = var.databricks_connections
}

# 4a. WEB APP DEPLOYMENT (App Service)
module "webapp" {
  count               = var.app_deployment_type == "webapp" ? 1 : 0
  source              = "git.eon-cds.de/repos/envia-spark-webapp/azurerm"
  version             = "1.0.3"
  name                = local.app_name
  resource_group_name = var.resource_group_name
  service_plan_id     = data.terraform_remote_state.networking.outputs.service_plan_id
  location            = var.location

  user_assigned_identity_id           = local.shared_identity_id
  user_assigned_identity_principal_id = local.shared_identity_principal_id

  registry_server   = local.reg_server
  registry_username = local.reg_user
  registry_password = local.reg_pass

  # OIDC / Easy Auth — on the single combined app
  oidc_client_id     = data.azurerm_key_vault_secret.oidc_client_id.value
  oidc_tenant_id     = data.azurerm_key_vault_secret.oidc_tenant_id.value
  oidc_client_secret = data.azurerm_key_vault_secret.oidc_client_secret.value

  image_name  = local.app_image
  image_tag   = var.image_tag
  target_port = 80 # nginx listens on 80, proxies /api/ to uvicorn on 8000 internally
  tags        = var.tags

  app_subnet_id = data.terraform_remote_state.networking.outputs.app_subnet_id

  custom_domain_name = var.custom_domain_name

  # Observability
  log_analytics_workspace_id       = module.observability.log_analytics_workspace_id
  app_insights_connection_string   = module.observability.app_insights_connection_string
  app_insights_instrumentation_key = module.observability.app_insights_instrumentation_key

  env_vars = merge(
    {
      "DB_HOST"                     = data.terraform_remote_state.data.outputs.db_fqdn
      "DB_USER"                     = data.terraform_remote_state.data.outputs.db_app_identity_user
      "DB_NAME"                     = data.terraform_remote_state.data.outputs.db_name
      "DB_SSLMODE"                  = "require"
      "MANAGED_IDENTITY_CLIENT_ID"  = local.shared_identity_client_id
      "DB_AUTH_MODE"                = "entra"
      "ENV"                         = local.environment
      "BLOB_STORAGE_ACCOUNT_URL"    = "https://${data.terraform_remote_state.data.outputs.storage_account_name}.blob.core.windows.net"
      "BLOB_STORAGE_CONTAINER_NAME" = data.terraform_remote_state.data.outputs.storage_container_name
      "OTEL_SERVICE_NAME"           = "${var.project_name}-api"
      "OTEL_RESOURCE_ATTRIBUTES"    = "service.version=1.1.0,deployment.environment=${local.environment}"
    },
    module.datafactory_connection.env_vars
  )
}

# 4b. CONTAINER APP DEPLOYMENT (Azure Container Apps)
module "containerapp" {
  count               = var.app_deployment_type == "containerapp" ? 1 : 0
  source              = "git.eon-cds.de/repos/envia-spark-container-app/azurerm"
  version             = "1.0.3"
  name                = local.app_name
  environment_name    = "${var.project_name}-${local.environment}"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags

  user_assigned_identity_id = local.shared_identity_id

  registry_server   = local.reg_server
  registry_username = local.reg_user
  registry_password = local.reg_pass

  # OIDC / Easy Auth — on the container app
  enable_easy_auth   = true
  oidc_client_id     = data.azurerm_key_vault_secret.oidc_client_id.value
  oidc_tenant_id     = data.azurerm_key_vault_secret.oidc_tenant_id.value
  oidc_client_secret = data.azurerm_key_vault_secret.oidc_client_secret.value

  # Fallback image handling
  use_fallback_image = tobool(var.use_fallback_image == "" ? "false" : var.use_fallback_image)
  fallback_image     = var.fallback_image

  image_name  = local.app_image
  image_tag   = var.image_tag
  target_port = 80 # nginx listens on 80, proxies /api/ to uvicorn on 8000 internally

  app_subnet_id = data.terraform_remote_state.networking.outputs.app_subnet_id

  # Observability
  log_analytics_workspace_id     = module.observability.log_analytics_workspace_id
  app_insights_connection_string = module.observability.app_insights_connection_string
  enable_otel_sidecar            = var.enable_otel_sidecar
  otel_collector_image           = var.otel_collector_image
  new_relic_license_key          = var.new_relic_license_key
  new_relic_otlp_endpoint        = var.new_relic_otlp_endpoint

  env_vars = merge(
    {
      "DB_HOST"                     = data.terraform_remote_state.data.outputs.db_fqdn
      "DB_USER"                     = data.terraform_remote_state.data.outputs.db_app_identity_user
      "DB_NAME"                     = data.terraform_remote_state.data.outputs.db_name
      "DB_SSLMODE"                  = "require"
      "MANAGED_IDENTITY_CLIENT_ID"  = local.shared_identity_client_id
      "DB_AUTH_MODE"                = "entra"
      "ENV"                         = local.environment
      "BLOB_STORAGE_ACCOUNT_URL"    = "https://${data.terraform_remote_state.data.outputs.storage_account_name}.blob.core.windows.net"
      "BLOB_STORAGE_CONTAINER_NAME" = data.terraform_remote_state.data.outputs.storage_container_name
      "OTEL_SERVICE_NAME"           = "${var.project_name}-api"
      "OTEL_RESOURCE_ATTRIBUTES"    = "service.version=1.1.0,deployment.environment=${local.environment}"
    },
    module.datafactory_connection.env_vars
  )
}

# 5. OPTIONAL: JUMP HOST FOR PRIVATE DATABASE ACCESS VIA BASTION
module "jumphost" {
  count                        = local.enable_jump_host ? 1 : 0
  source                       = "git.eon-cds.de/repos/envia-spark-jumphost/azurerm"
  version                      = "1.0.3"
  name                         = "${var.project_name}-${local.environment}-jump"
  resource_group_name          = var.resource_group_name
  location                     = var.location
  subnet_id                    = local.jump_host_subnet_id
  vm_size                      = var.jump_host_vm_size
  os_disk_size_gb              = var.jump_host_os_disk_size_gb
  os_disk_storage_account_type = var.jump_host_os_disk_storage_account_type
  admin_username               = var.jump_host_admin_username
  enable_public_ip             = local.jump_host_enable_public_ip
  allow_direct_ssh             = local.jump_host_allow_direct_ssh
  direct_ssh_cidrs             = local.jump_host_direct_ssh_cidrs_effective
  tags                         = var.tags
}

# Persist generated jump host SSH key in Key Vault for operational access
# without requiring Terraform state reads.
resource "azurerm_key_vault_secret" "jumphost_ssh_private_key" {
  count        = local.enable_jump_host ? 1 : 0
  name         = "jumpserver-ssh-key-${local.environment}"
  value        = module.jumphost[0].ssh_private_key_pem
  key_vault_id = local.keyvault_id
  content_type = "application/x-pem-file"
}
