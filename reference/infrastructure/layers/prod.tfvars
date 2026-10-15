# Global prod.tfvars - Shared across all infrastructure layers

# ------------------------------------------------------------------------------
# Core Azure Settings
# ------------------------------------------------------------------------------
subscription_id     = "${{ values.subscriptionIdProd }}"                                                    # (R)
environment         = "prod"                                                # (R)
project_name        = "${{ values.projectName }}"                                  # (R)
resource_group_name = "${{ values.resourceGroupProd }}"     # (R)
location            = "${{ values.locationProd }}"                                # (O) Default: "Germany West Central"

tags = { # (R)
  "Environment"         = "prod"
  "ManagedBy"           = "opentofu"
  "Project"             = "${{ values.projectName }}"
  "application-id"      = "${{ values.aplId }}"
  "application-manager" = "${{ values.contactPerson }}"
  "environment-id"      = "${{ values.itcIdProd or values.jiraTicket }}"
}

# ------------------------------------------------------------------------------
# GitLab Remote State Access
# ------------------------------------------------------------------------------
# gitlab_api_url    = "https://git.eon-cds.de/api/v4"                       # (O) Default: "https://git.eon-cds.de/api/v4"
# gitlab_project_id = ""                                                    # (O) Default: ""
# gitlab_username   = "gitlab-ci-token"                                     # (O) Default: "gitlab-ci-token"

# ------------------------------------------------------------------------------
# Base Layer Settings
# ------------------------------------------------------------------------------
ac1_branch          = "ac2-shared"                                          # (O) Default: "ac2-shared"
fachbereich         = "${{ values.domain }}"                                                   # (O) Default: "d"
product_name        = "${{ values.projectName }}"                                              # (O) Default: "webapp"
project_name_prefix = "em-dkip"                                             # (O) Default: "em-dkip"
gitlab_project_path = "${{ values.repoPath }}" # (R)

# ------------------------------------------------------------------------------
# Networking Layer Settings
# ------------------------------------------------------------------------------
service_plan_sku_name            = "P1v3"                                   # (O) Default: "B1"
networking_mode                  = "Atlantis"                               # (O) Default: "Standalone" ("Standalone" or "Atlantis")
atlantis_subscription_id         = "${{ values.networkSubscriptionIdProd }}"                                       # (O) Default: ""
atlantis_vnet_rg                 = "${{ values.atlantisVnetRgProd }}"                                       # (O) Default: ""
atlantis_vnet_name               = "${{ values.atlantisVnetNameProd }}"                                       # (O) Default: ""
atlantis_db_subnet_name          = "${{ values.atlantisDbSubnetNameProd }}"                                       # (O) Default: ""
atlantis_app_subnet_name         = "${{ values.atlantisAppSubnetNameProd }}"                                       # (O) Default: ""
atlantis_jump_subnet_name        = ""                                       # (O) Default: ""
atlantis_postgres_dns_zone_name  = "private.postgres.database.azure.com"    # (O) Default: ""
create_postgres_dns_in_atlantis  = "false"                                 # (O) Default: "false"
postgres_dns_resource_group_name = ""                                       # (O) Default: ""

# ------------------------------------------------------------------------------
# Data Layer Settings
# ------------------------------------------------------------------------------
database_sku_name        = "GP_Standard_D2ds_v4"                            # (R)
database_suffix          = "${{ values.databaseSuffix }}"                                               # (O) Default: ""
database_prevent_destroy = true                                             # (R)
container_name           = "app"                                            # (O) Default: "app"

# ------------------------------------------------------------------------------
# Services Layer Settings
# ------------------------------------------------------------------------------
app_deployment_type = "containerapp"                                        # (O) Default: "containerapp" ("webapp" or "containerapp")
app_instance        = "api"                                                 # (R)
use_fallback_image  = "true"                                                # (O) Default: "true"
fallback_image      = "mcr.microsoft.com/azuredocs/aci-helloworld:latest"   # (O)
registry_mode       = "JFrog"                                               # (O) Default: "JFrog" ("JFrog" or "ACR")
project_short       = "em-dkip-${{ values.projectName }}-prod"                                 # (O) Default: "em-dkip-webapp-prod"
app_image           = "${{ values.projectName }}"                                  # (R)
image_tag           = "latest"                                              # (R)
jfrog_registry      = "${{ values.jfrogRegistry }}"                                     # (R)
artifactory_registry = {                                                    # (R)
  server     = "repo.eon-cds.de"
  repository = "${{ values.jfrogRepositoryKey }}"
}
artifactory_username = ""                                                   # (O) Default: ""

# Bastion / Jump Host Config
bastion_name                           = "Bastion-bas01"                   # (O) Default: ""
bastion_resource_group_name            = "RG-Network-RUN"                  # (O) Default: ""
enable_jump_host                       = "true"                            # (O) Default: "false"
jump_host_vm_size                      = "Standard_D2s_v5"                 # (O) Default: "Standard_D2s_v5"
jump_host_os_disk_size_gb              = 30                                # (O) Default: 30
jump_host_os_disk_storage_account_type = "StandardSSD_LRS"                 # (O) Default: "StandardSSD_LRS"
jump_host_admin_username               = "azureuser"                       # (O) Default: "azureuser"
jump_host_enable_public_ip             = "false"                           # (O) Default: "false"
jump_host_subnet_id                    = ""                                # (O) Default: ""
jump_host_allow_direct_ssh             = "false"                           # (O) Default: "false"
jump_host_direct_ssh_cidrs             = []                                # (O) Default: []
jump_host_direct_ssh_cidrs_json        = ""                                # (O) Default: ""

# Databricks Config
databricks_connections = [                                                 # (O) Default: []
  {
    name            = "prod_warehouse"
    server_hostname = ""
    http_path       = ""
    catalog         = ""
    schema          = ""
    oauth_scope     = ""
  }
]
custom_domain_name      = ""                                               # (O) Default: ""
enable_otel_sidecar     = true                                             # (O) Default: true
otel_collector_image    = "otel/opentelemetry-collector-contrib:0.118.0"   # (O)
new_relic_otlp_endpoint = "https://otlp.eu01.nr-data.net"                 # (O)
new_relic_license_key   = ""                                               # (O) Injected via Key Vault or CI secret
