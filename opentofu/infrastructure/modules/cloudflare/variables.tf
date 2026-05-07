variable "account_id" {
  description = "Cloudflare account ID hosting the catalog R2 bucket."
  type        = string
  sensitive   = true
}

variable "zone_id_opennutritracker_org" {
  description = "Cloudflare zone ID for opennutritracker.org. Scope for the cache rule and the cache-purge API token."
  type        = string
  sensitive   = true
}

variable "edge_cache_seconds" {
  description = "How long the catalog .db.gz files stay cached at the edge."
  type        = number
}

variable "browser_cache_seconds" {
  description = "How long client browsers can hold catalog .db.gz files."
  type        = number
}
