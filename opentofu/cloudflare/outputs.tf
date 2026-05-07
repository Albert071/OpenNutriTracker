output "bucket_name" {
  description = "Name of the R2 bucket holding the catalog .db.gz files."
  value       = cloudflare_r2_bucket.catalog.name
}

output "cdn_url" {
  description = "App-facing CDN host for catalog downloads."
  value       = "https://${cloudflare_r2_custom_domain.catalog.domain}"
}
