# Per-zone cache rule. R2 doesn't set Cache-Control on objects by
# default, so without this rule Cloudflare would mark every response
# DYNAMIC and the edge would never serve a hit.
resource "cloudflare_ruleset" "cache" {
  zone_id     = var.zone_id_opennutritracker_org
  kind        = "zone"
  phase       = "http_request_cache_settings"
  name        = "default"
  description = "Cache food-database R2 contents at edge and browser"

  rules = [
    {
      description = "Cache catalog.opennutritracker.org for ${var.edge_cache_seconds}s at edge"
      expression  = "(http.host eq \"${cloudflare_r2_custom_domain.catalog.domain}\")"
      action      = "set_cache_settings"
      action_parameters = {
        cache = true
        edge_ttl = {
          mode    = "override_origin"
          default = var.edge_cache_seconds
        }
        browser_ttl = {
          mode    = "override_origin"
          default = var.browser_cache_seconds
        }
      }
    }
  ]
}
