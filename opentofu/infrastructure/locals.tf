# Root-module locals.
#
# `secrets` and `config_variables` are the two maps the root
# `main.tf` iterates over to publish workflow-facing values into
# GitHub. The split mirrors what is actually sensitive about each
# entry: credentials and signed tokens go through `module.secret`
# (sealed and rotation-gated); URLs, identifiers, and bucket names
# go through `module.variable` (plaintext, legible in workflow
# logs). All values come from `module.cloudflare`'s outputs so a
# token rotation or a renamed bucket flows through automatically
# on the next `tofu apply` and the build workflow picks up the
# correct values without anyone having to chase them.

locals {
  # Sensitive: credentials the build workflow uses to authenticate
  # against R2 and Cloudflare. Sealed against the repo's libsodium
  # public key before they enter state.
  secrets = {
    R2_ACCESS_KEY_ID       = module.cloudflare.catalog_upload_token_id
    R2_SECRET_ACCESS_KEY   = module.cloudflare.r2_secret_access_key
    CLOUDFLARE_PURGE_TOKEN = module.cloudflare.cache_purge_token_value
    # Consumed by the eventual automated APK release pipeline so
    # envied can obfuscate the value into the APK at build time.
    # The same value lives in the gitignored local `.env` for the
    # current manual-build workflow.
    CATALOG_ACCESS_TOKEN   = random_password.catalog_access_token.result
  }

  # Non-sensitive: the configuration the build workflow consults to
  # know where to upload to and what host to purge. Published as
  # plain `github_actions_variable` entries so they are legible in
  # workflow logs and trivially overridable from a manual run.
  config_variables = {
    R2_BUCKET          = module.cloudflare.bucket_name
    R2_ENDPOINT        = module.cloudflare.r2_endpoint
    CDN_HOST           = module.cloudflare.custom_domain
    CLOUDFLARE_ZONE_ID = var.zone_id_opennutritracker_org
  }
}
