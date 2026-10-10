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
ac1_branch          = "ac2-shared"                                          # (O) Default: "ac2-shared"
fachbereich         = "${{ values.domain }}"                                                   # (O) Default: "d"
product_name        = "${{ values.projectName }}"                                              # (O) Default: "webapp"
project_name_prefix = "em-dkip"                                             # (O) Default: "em-dkip"

# ------------------------------------------------------------------------------
# Networking Layer Settings
# ------------------------------------------------------------------------------

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

# Bastion / Jump Host Config

# Databricks Config
