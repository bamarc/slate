output "bastion_reference" {
  value = var.bastion_name != "" ? {
    id                  = null
    name                = var.bastion_name
    resource_group_name = local.bastion_resource_group_name
  } : null
  description = "Configured Bastion host metadata when bastion_name is set (no live lookup)."
}

output "jumphost_connection_info" {
  value = var.enable_jump_host ? {
    vm_id          = module.jumphost[0].vm_id
    admin_username = module.jumphost[0].admin_username
    private_ip     = module.jumphost[0].private_ip
    public_ip      = module.jumphost[0].public_ip
    ssh_hint       = "Use Azure Bastion to connect to the jump host private IP, then connect to PostgreSQL private endpoint."
  } : null
  description = "Connection metadata for the optional jump host."
}

output "jumphost_ssh_private_key_pem" {
  value       = var.enable_jump_host ? module.jumphost[0].ssh_private_key_pem : null
  sensitive   = true
  description = "Generated SSH private key for the optional jump host."
}

output "jumphost_ssh_private_key_secret_name" {
  value       = var.enable_jump_host ? azurerm_key_vault_secret.jumphost_ssh_private_key[0].name : null
  description = "Key Vault secret name containing the generated jump host SSH private key."
}

output "jumphost_ssh_private_key_secret_id" {
  value       = var.enable_jump_host ? azurerm_key_vault_secret.jumphost_ssh_private_key[0].id : null
  description = "Key Vault secret ID containing the generated jump host SSH private key."
}

output "app_url" {
  value       = var.app_deployment_type == "containerapp" ? (length(module.containerapp) > 0 ? "https://${module.containerapp[0].fqdn}" : null) : (length(module.webapp) > 0 ? "https://${module.webapp[0].default_hostname}" : null)
  description = "The public URL of the deployed application."
}
