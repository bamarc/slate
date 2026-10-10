output "db_fqdn" {
  value       = module.database.fqdn
  description = "The fully qualified domain name for database connections."
}

output "db_name" {
  value       = module.database.database_name
  description = "The name of the created database."
}

output "db_app_identity_user" {
  value       = module.database.app_identity_db_user
  description = "The shared UAMI PostgreSQL Entra role used by application services."
}

output "storage_account_id" {
  value       = module.storage_account.storage_account_id
  description = "The Azure Resource ID of the created storage account."
}

output "storage_account_name" {
  value       = module.storage_account.storage_account_name
  description = "The name of the created storage account."
}

output "storage_container_name" {
  value       = module.storage_account.storage_container_name
  description = "The name of the created blob container."
}
