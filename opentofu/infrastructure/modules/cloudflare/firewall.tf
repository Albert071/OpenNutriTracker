# Per-zone WAF Custom Rule that gates the catalog domain behind a
# shared bearer token. Any request to catalog.opennutritracker.org
# whose `X-Catalog-Access` header does not carry the expected value
# is blocked at the edge before R2 is touched — so random crawlers
# and drive-by downloaders cannot pull a 500 MiB sqlite of OFF data
# without going through the app, and a blocked request costs us
# nothing on R2 reads or egress.
#
# The token is minted by the root `random_password.catalog_access_token`
# resource and threaded in via `var.catalog_access_token`. It is a
# long-lived shared secret: the same value needs to keep working
# across every APK release, because users on older APKs still need
# to be able to download fresh catalog rebuilds. Rotation is
# reserved for emergencies and triggered by a deliberate
# `tofu taint random_password.catalog_access_token` followed by
# `tofu apply` and a new APK build.
#
# Free-plan compatibility: Custom Rules with the `block` action are
# available at every Cloudflare tier including Free, which allows up
# to 5 Custom Rules per zone. The existing `cloudflare_ruleset.cache`
# lives in the `http_request_cache_settings` phase and does not
# count toward that quota, so this rule is the first and only entry
# in the firewall-custom phase. Rule evaluation runs as part of
# standard WAF processing — no per-request fee, no metered
# execution, no Worker invocation.
resource "cloudflare_ruleset" "catalog_access" {
  zone_id     = var.zone_id_opennutritracker_org
  kind        = "zone"
  phase       = "http_request_firewall_custom"
  name        = "catalog-access-gate"
  description = "Require the X-Catalog-Access bearer token on ${var.catalog_host}"

  rules = [
    {
      description = "Block catalog requests missing the access token"
      expression  = "(http.host eq \"${var.catalog_host}\") and (not any(http.request.headers[\"x-catalog-access\"][*] eq \"${var.catalog_access_token}\"))"
      action      = "block"
      enabled     = true
    },
  ]
}
