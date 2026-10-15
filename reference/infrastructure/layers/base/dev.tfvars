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
ac1_branch          = "ac2-shared"                                         # (O) Default: "ac2-shared"
fachbereich         = "${{ values.domain }}"                                                  # (O) Default: "d"
product_name        = "${{ values.projectName }}"                                             # (O) Default: "webapp"
project_name_prefix = "em-dkip"                                            # (O) Default: "em-dkip"
gitlab_project_path = "${{ values.repoPath }}" # (R)

# ------------------------------------------------------------------------------
# Networking Layer Settings
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# Data Layer Settings
# ------------------------------------------------------------------------------
container_name           = "app"                                           # (O) Default: "app"

# ------------------------------------------------------------------------------
# Services Layer Settings
# ------------------------------------------------------------------------------

# Bastion / Jump Host Config

# Databricks Config
