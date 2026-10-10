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
  description = "Name of the resource group"
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

variable "keyvault_admin_object_ids" {
  description = "List of Object IDs (Users, Groups, or Service Principals) to grant full Key Vault access."
  type        = list(string)
  default     = []
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

variable "container_name" {
  description = "Name des initialen Storage Containers"
  type        = string
  default     = "app"
}

variable "gitlab_project_path" {
  description = "Full GitLab project path used in the OIDC subject claim (e.g. repos/group/project). Configures Azure Workload Identity Federation so GitLab CI pipelines can authenticate without a client secret."
  type        = string
}
