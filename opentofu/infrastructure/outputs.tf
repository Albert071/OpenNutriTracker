output "bucket_name" {
  description = "Name of the R2 bucket holding the catalog .db.gz files."
  value       = module.cloudflare.bucket_name
}

output "cdn_url" {
  description = "App-facing CDN host for catalog downloads."
  value       = "https://${module.cloudflare.custom_domain}"
}
