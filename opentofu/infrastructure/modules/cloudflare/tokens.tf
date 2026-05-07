# All downstream API tokens managed in code so their permissions are
# visible in PR diffs. The bootstrap CF token (used by this OpenTofu
# config itself) is NOT managed here — that one is created manually
# in the dashboard, since you can't have OpenTofu mint the credential
# OpenTofu needs to authenticate.

# Permission group IDs from /user/tokens/permission_groups, looked up
# once and pinned here so the resource definitions stay legible.
locals {
  perm_group_r2_bucket_object_write = "2efd5506f9c8494dacb1fa10a3e7d5b6"
  perm_group_cache_purge            = "e17beae8b8cb423a99b1730f21238bed"
}

# Catalog upload token — bucket-scoped, object read+write only.
# Consumed by .github/workflows/build_catalog.yml via the R2_*
# GitHub Actions secrets generated at the root.
resource "cloudflare_api_token" "catalog_upload" {
  name   = "github-actions-catalog-upload"
  status = "active"
  policies = [
    {
      effect = "allow"
      permission_groups = [
        { id = local.perm_group_r2_bucket_object_write },
      ]
      resources = jsonencode({
        "com.cloudflare.edge.r2.bucket.${var.account_id}_default_${cloudflare_r2_bucket.catalog.name}" = "*"
      })
    },
  ]
}

# Cache-purge token — zone-scoped to opennutritracker.org, purge only.
# After each catalog upload the workflow invalidates the just-uploaded
# URLs at the edge so users don't see up to a week of stale data
# while waiting for the long edge TTL to expire naturally.
resource "cloudflare_api_token" "cache_purge" {
  name   = "github-actions-catalog-purge"
  status = "active"
  policies = [
    {
      effect = "allow"
      permission_groups = [
        { id = local.perm_group_cache_purge },
      ]
      resources = jsonencode({
        "com.cloudflare.api.account.zone.${var.zone_id_opennutritracker_org}" = "*"
      })
    },
  ]
}
