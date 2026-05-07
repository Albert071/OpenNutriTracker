# GitHub Actions secrets that the catalog-build workflow consumes.
# Values are derived from cloudflare_api_token.catalog_upload in
# tokens.tf so a token rotation flows through automatically on the
# next `tofu apply`.
#
# Note on `encrypted_value` vs `plaintext_value`: the latter would
# leave the raw secret in the OpenTofu state file (only protected
# by R2 bucket access). We seal each value against the repo's
# public key with scripts/seal.py before it lands in any resource
# block, so what enters state is libsodium ciphertext.

data "github_actions_public_key" "repo" {
  repository = var.github_repo
}

locals {
  catalog_token_value       = cloudflare_api_token.catalog_upload.value
  catalog_access_key_id     = cloudflare_api_token.catalog_upload.id
  catalog_secret_access_key = sha256(local.catalog_token_value)
  r2_endpoint               = "https://${var.account_id}.r2.cloudflarestorage.com"

  # Map of secret-name -> plaintext value to publish.
  secrets = {
    R2_ACCESS_KEY_ID       = local.catalog_access_key_id
    R2_SECRET_ACCESS_KEY   = local.catalog_secret_access_key
    R2_ENDPOINT            = local.r2_endpoint
    R2_BUCKET              = cloudflare_r2_bucket.catalog.name
    CLOUDFLARE_PURGE_TOKEN = cloudflare_api_token.cache_purge.value
    CLOUDFLARE_ZONE_ID     = var.zone_id_opennutritracker_org
    CDN_HOST               = cloudflare_r2_custom_domain.catalog.domain
  }
}

# One sealing call per secret. The `external` data source shells out
# to scripts/seal.py and returns the libsodium-sealed ciphertext.
data "external" "sealed" {
  for_each = local.secrets

  program = ["python3", "${path.module}/scripts/seal.py"]
  query = {
    public_key = data.github_actions_public_key.repo.key
    plaintext  = each.value
  }
}

resource "github_actions_secret" "r2" {
  for_each = local.secrets

  repository      = var.github_repo
  secret_name     = each.key
  value_encrypted = data.external.sealed[each.key].result["ciphertext"]
  key_id          = data.github_actions_public_key.repo.key_id
}
