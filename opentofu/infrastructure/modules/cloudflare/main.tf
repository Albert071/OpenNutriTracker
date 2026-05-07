# Encapsulates the entire Cloudflare-side surface of the catalog
# infrastructure: the R2 bucket and its custom domain, the zone-level
# cache rule that fixes R2's missing Cache-Control header, and the
# two downstream API tokens that the build workflow consumes via
# sealed GitHub secrets.
#
# Even though this module only has one consumer, the contract it
# exposes (its variables and outputs) is more rigorous documentation
# of "what crosses the Cloudflare boundary" than a comment block at
# the top of three sibling files would be. Future readers can glance
# at `outputs.tf` and know exactly what the rest of the config gets
# to depend on.

terraform {
  required_providers {
    # Without an explicit declaration the bare name `cloudflare`
    # resolves to whatever default the child module would otherwise
    # pick, and the `providers = { ... }` argument in the root's
    # `module` block then refuses the inheritance with a "different
    # provider type" error.
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}
