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

variable "database_sku_name" {
  description = "PostgreSQL Flexible Server SKU name (for example B_Standard_B1ms, GP_Standard_D2ds_v4)."
  type        = string
}

variable "database_prevent_destroy" {
  description = "Whether database resources must be protected from destruction."
  type        = bool
}

variable "database_suffix" {
  description = "Optional suffix to append to PostgreSQL server name to resolve DNS reservation conflicts"
  type        = string
  default     = ""
}

variable "container_name" {
  description = "Name of the initial storage container"
  type        = string
  default     = "app"
}

variable "ac1_branch" {
  description = "Bereichs- oder Segmentkennung fuer das Naming"
  type        = string
  default     = "ac2-shared"
}

variable "fachbereich" {
  description = "Fachbereich-Kuerzel fuer das Naming"
  type        = string
  default     = "d"
}

variable "product_name" {
  description = "Workload- oder Produktname fuer das Naming"
  type        = string
  default     = "webapp"
}

variable "project_name_prefix" {
  description = "Namenspraefix fuer enviaM-Ressourcen"
  type        = string
  default     = "em-dkip"
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
