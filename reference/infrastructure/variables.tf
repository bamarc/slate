variable "environment" {
  description = "Target environment for this deployment"
  type        = string
}

variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "germanywestcentral"
}

variable "project_name" {
  description = "Project name for naming and tags"
  type        = string
  default     = "${{ values.projectName }}"
}
