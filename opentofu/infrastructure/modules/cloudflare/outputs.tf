output "bucket_name" {
  description = "Name of the R2 bucket holding the catalog .db.gz chunks. Used by the workflow's upload step and surfaced in the root's outputs."
  value       = cloudflare_r2_bucket.catalog.name
}

output "custom_domain" {
  description = "App-facing host on the opennutritracker.org zone (catalog.opennutritracker.org). Used as both the cache rule's match expression and the CDN URL the Flutter client downloads from."
  value       = cloudflare_r2_custom_domain.catalog.domain
}

output "catalog_upload_token_id" {
  description = "Identifier of the catalog-upload token. Used as the R2 access key id when the workflow signs S3 requests against R2."
  value       = cloudflare_api_token.catalog_upload.id
}

output "r2_endpoint" {
  description = "S3-compatible endpoint URL for the catalog R2 bucket. Built from the account id at this layer because the R2 endpoint shape is a Cloudflare convention, not a root-composition concern."
  value       = "https://${var.account_id}.r2.cloudflarestorage.com"
}

output "r2_secret_access_key" {
  description = "S3-compatible secret access key for the catalog R2 bucket. Cloudflare R2's S3 API accepts the SHA-256 of the API token value as the secret. Documented Cloudflare behaviour, encapsulated here so the root doesn't have to know about it."
  value       = sha256(cloudflare_api_token.catalog_upload.value)
  sensitive   = true
}

output "cache_purge_token_value" {
  description = "Raw value of the cache-purge token. Sealed at the root and published to the workflow as CLOUDFLARE_PURGE_TOKEN."
  value       = cloudflare_api_token.cache_purge.value
  sensitive   = true
}
