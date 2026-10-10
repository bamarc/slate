output "keyvault_id" {
  value = module.keyvault.id
}

output "keyvault_url" {
  value       = module.keyvault.vault_uri
  description = "The URI of the Key Vault (e.g. https://kv-ojap-dev-xxxx.vault.azure.net/). Used by the Python app to fetch secrets directly via Managed Identity."
}

output "shared_identity_id" {
  value       = azurerm_user_assigned_identity.shared_app_identity.id
  description = "The resource ID of the User-Assigned Managed Identity (used in identity block and key_vault_reference_identity_id)."
}

output "shared_identity_principal_id" {
  value       = azurerm_user_assigned_identity.shared_app_identity.principal_id
  description = "The Principal ID (Object ID) of the Managed Identity -- used for Key Vault access policies."
}

output "shared_identity_client_id" {
  value       = azurerm_user_assigned_identity.shared_app_identity.client_id
  description = "The Client ID of the User-Assigned Managed Identity. Required by azure-identity ManagedIdentityCredential(client_id=...) to target this specific identity."
}

output "shared_identity_name" {
  value       = azurerm_user_assigned_identity.shared_app_identity.name
  description = "The name of the shared User-Assigned Managed Identity."
}

output "keyvault_name" {
  value       = local.keyvault_name
  description = "Name of the Key Vault used by downstream layers."
}

output "resource_group_name" {
  value       = azurerm_resource_group.rg.name
  description = "Name of the shared application resource group."
}
