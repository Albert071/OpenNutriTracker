# Root-module outputs.
#
# The only thing the root surfaces today is the long-lived catalog
# access token. After the first apply, retrieve it with:
#
#   tofu output -raw catalog_access_token
#
# and paste it into the gitignored local `.env` as
# `CATALOG_ACCESS_TOKEN=...`. CI consumes the same value via the
# `CATALOG_ACCESS_TOKEN` GitHub Actions secret published by the
# `module.secret` for_each over `local.secrets`.

output "catalog_access_token" {
  description = "Shared bearer token the OpenNutriTracker app sends in the X-Catalog-Access header on every catalog request. Long-lived; rotation is emergency-only via `tofu taint random_password.catalog_access_token`."
  value       = random_password.catalog_access_token.result
  sensitive   = true
}
