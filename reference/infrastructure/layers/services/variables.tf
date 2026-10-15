variable "subscription_id" {
  description = "The Azure subscription ID"
  type        = string
}

variable "environment" {
  description = "The deployment environment (e.g. dev, prod)"
  type        = string
}

variable "project_name" {
  description = "Name of the project used for resource naming"
  type        = string
}

variable "app_instance" {
  description = "Optional application instance suffix used to distinguish multiple apps within an environment."
  type        = string
  default     = ""
}

variable "project_short" {
  description = "Project suffix/short name used for observability resources."
  type        = string
  default     = "em-dkip-webapp-dev"
}

variable "resource_group_name" {
  description = "Name of the existing resource group"
  type        = string
}

variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "Germany West Central"
}

variable "tags" {
  description = "Common tags for all resources"
  type        = map(string)
}

# GitLab Remote State Variables
variable "gitlab_api_url" {
  description = "The base API URL for GitLab"
  type        = string
  default     = "https://git.eon-cds.de/api/v4"
}

variable "gitlab_project_id" {
  description = "The ID of the GitLab project for remote state access"
  type        = string
  default     = ""
}

variable "gitlab_username" {
  description = "GitLab username for remote state authentication"
  type        = string
  default     = "gitlab-ci-token"
}

variable "gitlab_token" {
  description = "GitLab PAT or CI job token for remote state authentication"
  type        = string
  sensitive   = true
  default     = ""
}

# Application Specific Variables

variable "image_tag" {
  description = "The tag of the container image to deploy (e.g., git commit SHA)."
  type        = string
}

variable "app_image" {
  description = "Full image path for the API container"
  type        = string
}

variable "bastion_name" {
  description = "Optional existing Bastion host name to reference for operational outputs."
  type        = string
  default     = ""
}

variable "bastion_resource_group_name" {
  description = "Resource group containing the existing Bastion host. Empty uses resource_group_name."
  type        = string
  default     = ""
}

variable "enable_jump_host" {
  description = "Enable deployment of a jump host VM for Bastion-mediated private DB access. Accepts string 'true'/'false' to allow TF_VAR_* env var injection from CI."
  type        = string
  default     = "false"
}

variable "jump_host_vm_size" {
  description = "VM size for the jump host."
  type        = string
  default     = "Standard_B2s"
}

variable "jump_host_os_disk_size_gb" {
  description = "OS disk size in GiB for the jump host."
  type        = number
  default     = 30
}

variable "jump_host_os_disk_storage_account_type" {
  description = "OS disk storage tier for the jump host VM."
  type        = string
  default     = "StandardSSD_LRS"

  validation {
    condition = contains([
      "Standard_LRS",
      "StandardSSD_LRS",
      "Premium_LRS",
      "PremiumV2_LRS",
      "UltraSSD_LRS",
    ], var.jump_host_os_disk_storage_account_type)
    error_message = "jump_host_os_disk_storage_account_type must be a valid Azure managed disk SKU."
  }
}

variable "jump_host_admin_username" {
  description = "Admin username for SSH on the jump host."
  type        = string
  default     = "azureuser"
}

variable "jump_host_enable_public_ip" {
  description = "Attach a public IP to the jump host (generally false when using Bastion). Accepts string 'true'/'false' to allow TF_VAR_* env var injection from CI."
  type        = string
  default     = "false"
}

variable "jump_host_subnet_id" {
  description = "Optional subnet ID for the jump host. If empty, app_subnet_id from networking remote state is used."
  type        = string
  default     = ""
}

variable "jump_host_allow_direct_ssh" {
  description = "Allow direct SSH ingress to jump host from configured CIDRs. Accepts string 'true'/'false' to allow TF_VAR_* env var injection from CI."
  type        = string
  default     = "false"
}

variable "jump_host_direct_ssh_cidrs" {
  description = "CIDRs allowed for direct SSH when jump_host_allow_direct_ssh is true."
  type        = list(string)
  default     = []
}

variable "jump_host_direct_ssh_cidrs_json" {
  description = "Optional JSON array override for direct SSH CIDRs (e.g. [\"10.0.0.1/32\"])."
  type        = string
  default     = ""
}

variable "custom_domain_name" {
  description = "Custom domain name to bind to the Web App (e.g. dev.jahresausschaltplanung.enviam-gruppe.de). Leave empty to skip."
  type        = string
  default     = ""
}

variable "databricks_connections" {
  description = "A list of Databricks SQL Warehouse connection configurations."
  type = list(object({
    name            = string
    server_hostname = string
    http_path       = string
    catalog         = string
    schema          = string
    oauth_scope     = optional(string, "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d/.default")
  }))
  default = []
}

variable "app_deployment_type" {
  description = "The type of deployment to use: 'webapp' (App Service) or 'containerapp' (Azure Container Apps)."
  type        = string
  default     = "containerapp"

  validation {
    condition     = contains(["webapp", "containerapp"], var.app_deployment_type)
    error_message = "app_deployment_type must be either 'webapp' or 'containerapp'."
  }
}

variable "fallback_image" {
  description = "Public fallback image used for initial container app deployment when no custom image is present in the registry."
  type        = string
  default     = "mcr.microsoft.com/azuredocs/aci-helloworld:latest"
}

variable "use_fallback_image" {
  description = "Whether to deploy the container app with the public fallback image. Accepts string 'true'/'false' to allow TF_VAR_* injection from CI."
  type        = string
  default     = "false"
}

variable "artifactory_username" {
  description = "The username for the container registry (Artifactory/JFrog)"
  type        = string
  default     = ""
}

variable "jfrog_registry" {
  description = "JFrog Artifactory registry host used to pull the container image (e.g. 'repo.eon-cds.de/dkipac1grideegcockpit-docker')."
  type        = string
  default     = ""
}

variable "artifactory_registry" {
  description = "Artifactory Docker registry host and repository path."
  type = object({
    server     = string
    repository = string
  })
  default = null
}

variable "artifactory_password" {
  description = "The password/token for the container registry (Artifactory/JFrog)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "registry_mode" {
  description = "Container registry source: 'JFrog' uses corporate Artifactory, 'ACR' uses the Azure Container Registry from the base layer."
  type        = string
  default     = "JFrog"

  validation {
    condition     = contains(["JFrog", "ACR"], var.registry_mode)
    error_message = "registry_mode must be 'JFrog' or 'ACR'."
  }
}

# --- OpenTelemetry Sidecar Configuration ---

variable "enable_otel_sidecar" {
  type        = bool
  description = "Deploy the OpenTelemetry Collector as a sidecar container alongside the application in ACA."
  default     = true
}

variable "otel_collector_image" {
  type        = string
  description = "Container image for the OpenTelemetry Collector sidecar."
  default     = "otel/opentelemetry-collector-contrib:0.118.0"
}

variable "new_relic_license_key" {
  type        = string
  description = "New Relic ingestion license key for OTel export."
  sensitive   = true
  default     = ""
}

variable "new_relic_otlp_endpoint" {
  type        = string
  description = "New Relic OTLP HTTP endpoint."
  default     = "https://otlp.eu01.nr-data.net"
}
