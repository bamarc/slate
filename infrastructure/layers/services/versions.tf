terraform {
  required_version = ">= 1.5"

  required_providers {
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.64.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8.1"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.2.1"
    }
  }
}
