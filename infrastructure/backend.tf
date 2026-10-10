# GitLab HTTP Backend Configuration
#
# The OpenTofu state of this repository is stored in GitLab itself.
# The concrete target environment is selected via a matching *.http.tfbackend file,
# so that CI and manual usage follow the same flow.
#
# Normal case:
# - Deployments run via the GitLab pipeline.
# - Local init/plan/apply calls are only intended for emergencies.
#
# ============================================================================
# LOCAL (emergency / manual maintenance)
# ============================================================================
#
# 1. Generate GitLab Personal Access Token:
#    https://git.eon-cds.de/-/user_settings/personal_access_tokens
#    Scopes: api, read_repository, write_repository
#
# 2. Set environment variables:
#
#    export TF_HTTP_USERNAME="<gitlab-username>"
#    export TF_HTTP_PASSWORD="<personal-access-token>"
#
# 3. Initialize backend for the target environment:
#
#    tofu -chdir=infrastructure init -reconfigure -backend-config=dev.http.tfbackend
#
#    tofu -chdir=infrastructure plan -var-file=dev.tfvars
#
# 4. For prod use the same logic with prod.http.tfbackend and prod.tfvars.
#
# ============================================================================
# CI/CD (standard path)
# ============================================================================
#
# The backend files point to the following GitLab states:
# - dev   -> https://git.eon-cds.de/api/v4/projects/${{ values.gitlabProjectId }}/terraform/state/dev
# - prod  -> https://git.eon-cds.de/api/v4/projects/${{ values.gitlabProjectId }}/terraform/state/prod
#
# GitLab project ID for troubleshooting: ${{ values.gitlabProjectId }}

terraform {
  backend "http" {
  }
}
