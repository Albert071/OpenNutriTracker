variable "account_id" {
  description = "Cloudflare account ID hosting the catalog R2 bucket. Set via TF_VAR_account_id (sourced from a GitHub secret in CI). Not actually a credential — Cloudflare account IDs appear in dashboard URLs and API endpoints — but historically supplied via the secrets pipeline because that was the existing trough for tofu inputs."
  type        = string
}

variable "zone_id_opennutritracker_org" {
  description = "Cloudflare zone ID for opennutritracker.org. Set via TF_VAR_zone_id_opennutritracker_org (sourced from a GitHub secret in CI). Like the account ID it is a public identifier rather than a secret; the value is published to the build workflow as a `github_actions_variable` so the workflow can reach the cache-purge endpoint."
  type        = string
}

variable "github_owner" {
  description = "GitHub org or user that owns the repo whose Actions secrets we write."
  type        = string
  default     = "simonoppowa"
}

variable "github_repo" {
  description = "GitHub repository name (without owner) where the catalog-build workflow lives."
  type        = string
  default     = "OpenNutriTracker"
}

variable "edge_cache_seconds" {
  description = "How long Cloudflare's edge holds catalog responses before considering them stale and revalidating against origin. Kept long (1 week) because cold chunks should not get evicted just for being unrequested for a couple of days; the post-apply cache-purge step in build_catalog.yml handles freshness on rebuild instead of relying on TTL expiry."
  type        = number
  default     = 604800 # 7 days
}

variable "browser_cache_seconds" {
  description = "Cache-Control max-age sent to HTTP clients. Deliberately short (2 minutes) so HTTP clients converge on freshly-purged catalog content within minutes of each rebuild's apply rather than serving up to a day of stale bytes from their own cache. Revalidations land on Cloudflare's edge — which holds chunks for `edge_cache_seconds` — and either return 304 (unchanged content) or the fresh body, so this short value does not increase R2 origin reads. The two-minute floor exists mostly to support the future in-app cache-refresh notification feature that will poll the manifest periodically."
  type        = number
  default     = 120 # 2 minutes
}

variable "catalog_build_output_dir" {
  description = "Path to the directory holding the freshly-built catalog chunks and manifests. The path is consumed by `fileset()` inside the catalog module, where relative paths resolve to the working directory rather than the module dir, so safest is to pass an absolute path. CI sets this to wherever the build pipeline writes to; left empty by default so a `tofu plan` against a clean checkout sees no catalog objects (and the catalog module's `for_each` iterates over nothing) until the build has actually run."
  type        = string
  default     = ""
}

variable "state_passphrase" {
  description = "Passphrase used by OpenTofu to derive the AES-256 key that encrypts the state file at rest in the opentofu-tf-state R2 bucket. Set via TF_VAR_state_passphrase (mirrored to the TF_VAR_STATE_PASSPHRASE GitHub Actions secret). Losing this value means losing the ability to decrypt the state — keep a copy in a password manager outside the repo."
  type        = string
  sensitive   = true
}
