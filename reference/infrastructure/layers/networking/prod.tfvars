# ==============================================================================
# DO NOT TOUCH/EDIT THIS FILE DIRECTLY!
# This file is AUTO-GENERATED from the global tfvars file above the layers:
#   infrastructure/layers/prod.tfvars
#
# Run the sync script to update all layers:
#   ./infrastructure/layers/sync_tfvars.py
# ==============================================================================

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

# ------------------------------------------------------------------------------
# Services Layer Settings
# ------------------------------------------------------------------------------
app_deployment_type = "containerapp"                                        # (O) Default: "containerapp" ("webapp" or "containerapp")

# Bastion / Jump Host Config

# Databricks Config
