# The catalog bucket. Created in Western Europe to keep RTT short for
# the maintainer, but R2 itself is multi-region under the covers and
# the public CDN serves from the nearest Cloudflare edge regardless.
resource "cloudflare_r2_bucket" "catalog" {
  account_id = var.account_id
  name       = "opennutritracker-catalog"
  location   = "WEUR"
}

# Custom domain on opennutritracker.org — the canonical app-facing
# host. The Flutter client points here for catalog downloads.
resource "cloudflare_r2_custom_domain" "catalog" {
  account_id  = var.account_id
  bucket_name = cloudflare_r2_bucket.catalog.name
  domain      = "catalog.opennutritracker.org"
  zone_id     = var.zone_id_opennutritracker_org
  enabled     = true
  min_tls     = "1.2"
}
