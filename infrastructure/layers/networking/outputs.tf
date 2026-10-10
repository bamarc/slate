output "service_plan_id" {
  value       = module.networking.service_plan_id
  description = "The ID of the App Service Plan."
}

output "db_subnet_id" {
  value       = module.networking.db_subnet_id
  description = "The subnet ID delegated for PostgreSQL Flexible Server."
}

output "jump_subnet_id" {
  value       = module.networking.jump_subnet_id
  description = "The subnet ID for the Jump Host."
}

output "app_subnet_id" {
  value       = module.networking.app_subnet_id
  description = "The subnet ID delegated for Web App integration."
}

output "postgres_dns_zone_id" {
  value       = module.networking.postgres_dns_zone_id
  description = "The private DNS zone ID for PostgreSQL Flexible Server."
}
