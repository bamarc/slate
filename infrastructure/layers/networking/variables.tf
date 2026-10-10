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

variable "service_plan_sku_name" {
  description = "App Service Plan SKU name (for example B1, P1v3)."
  type        = string
  default     = "B1"
}

variable "networking_mode" {
  description = "How networking is resolved: create managed resources or Atlantis existing IDs"
  type        = string
  default     = "Standalone"
}

variable "atlantis_subscription_id" {
  description = "Azure subscription ID hosting the Atlantis-provisioned VNet and DNS zone"
  type        = string
  default     = ""
}

variable "atlantis_vnet_rg" {
  description = "Resource group containing the Atlantis-provisioned VNet"
  type        = string
  default     = ""
}

variable "atlantis_vnet_name" {
  description = "Name of the Atlantis-provisioned VNet"
  type        = string
  default     = ""
}

variable "atlantis_db_subnet_name" {
  description = "Name of the DB subnet in the Atlantis VNet"
  type        = string
  default     = ""
}

variable "atlantis_app_subnet_name" {
  description = "Name of the App (ACA) subnet in the Atlantis VNet"
  type        = string
  default     = ""
}

variable "atlantis_jump_subnet_name" {
  description = "Name of the Jump subnet in the Atlantis VNet"
  type        = string
  default     = ""
}

variable "atlantis_postgres_dns_zone_name" {
  description = "Name of the PostgreSQL Flexible Server private DNS zone (typically 'private.postgres.database.azure.com')"
  type        = string
  default     = ""
}

variable "create_postgres_dns_in_atlantis" {
  description = "When networking_mode is Atlantis, create and link PostgreSQL private DNS zone in this layer instead of providing existing_postgres_dns_zone_id. Accepts string 'true'/'false' to allow TF_VAR_* env var injection from CI."
  type        = string
  default     = "false"
}

variable "postgres_dns_resource_group_name" {
  description = "Resource group for self-deployed PostgreSQL private DNS zone. Defaults to resource_group_name if empty."
  type        = string
  default     = ""
}

variable "app_deployment_type" {
  description = "The type of deployment to use: 'webapp' (App Service) or 'containerapp' (Azure Container Apps)."
  type        = string
  default     = "webapp"

  validation {
    condition     = contains(["webapp", "containerapp"], var.app_deployment_type)
    error_message = "app_deployment_type must be either 'webapp' or 'containerapp'."
  }
}
