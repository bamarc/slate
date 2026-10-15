# ==============================================================================
# DO NOT TOUCH/EDIT THIS FILE DIRECTLY!
# This file is AUTO-GENERATED from the global tfvars file above the layers:
#   infrastructure/layers/dev.tfvars
#
# Run the sync script to update all layers:
#   ./infrastructure/layers/sync_tfvars.py
# ==============================================================================

# Global dev.tfvars - Shared across all infrastructure layers

# ------------------------------------------------------------------------------
# Core Azure Settings
# ------------------------------------------------------------------------------
subscription_id     = "${{ values.subscriptionIdDev }}"                                                   # (R)
environment         = "dev"                                                # (R)
project_name        = "${{ values.projectName }}"                                 # (R)
resource_group_name = "${{ values.resourceGroupDev }}"      # (R)
location            = "${{ values.locationDev }}"                               # (O) Default: "Germany West Central"

tags = { # (R)
  "Environment"         = "dev"
  "ManagedBy"           = "opentofu"
  "Project"             = "${{ values.projectName }}"
  "application-id"      = "${{ values.aplId }}"
  "application-manager" = "${{ values.contactPerson }}"
  "environment-id"      = "${{ values.itcIdDev or values.jiraTicket }}"
}

# ------------------------------------------------------------------------------
# GitLab Remote State Access
# ------------------------------------------------------------------------------
# gitlab_api_url    = "https://git.eon-cds.de/api/v4"                      # (O) Default: "https://git.eon-cds.de/api/v4"
# gitlab_project_id = ""                                                   # (O) Default: ""
# gitlab_username   = "gitlab-ci-token"                                    # (O) Default: "gitlab-ci-token"

# ------------------------------------------------------------------------------
# Base Layer Settings
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Networking Layer Settings
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Data Layer Settings
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Services Layer Settings
# ------------------------------------------------------------------------------
app_deployment_type = "containerapp"                                       # (O) Default: "containerapp" ("webapp" or "containerapp")
app_instance        = "api"                                                # (R)
use_fallback_image  = "true"                                               # (O) Default: "true"
fallback_image      = "mcr.microsoft.com/azuredocs/aci-helloworld:latest"  # (O)
registry_mode       = "JFrog"                                              # (O) Default: "JFrog" ("JFrog" or "ACR")
project_short       = "em-dkip-${{ values.projectName }}-dev"                                 # (O) Default: "em-dkip-webapp-dev"
app_image           = "${{ values.projectName }}"                                 # (R)
image_tag           = "latest"                                             # (R)
jfrog_registry      = "${{ values.jfrogRegistry }}"                                    # (R)
artifactory_registry = {                                                   # (R)
  server     = "repo.eon-cds.de"
  repository = "${{ values.jfrogRepositoryKey }}"
}
artifactory_username = ""                                                  # (O) Default: ""

# Bastion / Jump Host Config
bastion_name                           = "Bastion-bas01"                  # (O) Default: ""
bastion_resource_group_name            = "RG-Network-RUN"                 # (O) Default: ""
enable_jump_host                       = "true"                           # (O) Default: "false"
jump_host_vm_size                      = "Standard_D2s_v5"                # (O) Default: "Standard_D2s_v5"
jump_host_os_disk_size_gb              = 30                               # (O) Default: 30
jump_host_os_disk_storage_account_type = "StandardSSD_LRS"                # (O) Default: "StandardSSD_LRS"
jump_host_admin_username               = "azureuser"                      # (O) Default: "azureuser"
jump_host_enable_public_ip             = "false"                          # (O) Default: "false"
jump_host_subnet_id                    = ""                               # (O) Default: ""
jump_host_allow_direct_ssh             = "false"                          # (O) Default: "false"
jump_host_direct_ssh_cidrs             = []                               # (O) Default: []
jump_host_direct_ssh_cidrs_json        = ""                               # (O) Default: ""

# Databricks Config
databricks_connections = [                                                # (O) Default: []
  {
    name            = "dev_warehouse"
    server_hostname = ""
    http_path       = ""
    catalog         = ""
    schema          = ""
    oauth_scope     = ""
  }
]
custom_domain_name      = ""                                              # (O) Default: ""
enable_otel_sidecar     = true                                            # (O) Default: true
otel_collector_image    = "otel/opentelemetry-collector-contrib:0.118.0"  # (O)
new_relic_otlp_endpoint = "https://otlp.eu01.nr-data.net"                # (O)
new_relic_license_key   = ""                                              # (O) Injected via Key Vault or CI secret
