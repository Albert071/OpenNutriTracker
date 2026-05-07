# GitHub Actions secrets that the catalog-build workflow consumes.
# Values are derived from cloudflare_api_token.catalog_upload in
# tokens.tf so a token rotation flows through automatically on the
# next `tofu apply`. The libsodium sealing happens in `data.tf`;
# this file carries the `local.secrets` map and the resource
# blocks that read from it.

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

# Track a stable hash of each secret's plaintext so we can tell real
# changes apart from the cosmetic re-seal noise. `crypto_box_seal`
# is non-deterministic — encrypting the same plaintext twice
# produces two different ciphertexts — so without this hash every
# `tofu plan` would show all seven secrets being updated, even
# though nothing has actually changed inside GitHub. The hash lives
# in OpenTofu state; on the next plan we compute it again and only
# trigger a replacement of the secret when the plaintext genuinely
# differs from last time.
resource "terraform_data" "r2_secret_plaintext_hash" {
  for_each = local.secrets

  input = sha256(each.value)
}

resource "github_actions_secret" "r2" {
  for_each = local.secrets

  repository      = var.github_repo
  secret_name     = each.key
  value_encrypted = data.external.sealed[each.key].result["ciphertext"]
  key_id          = data.github_actions_public_key.repo.key_id

  lifecycle {
    # Ignore drift on the sealed ciphertext itself — it is
    # non-deterministic and any difference between state and the
    # current sealing call is expected and meaningless.
    ignore_changes = [value_encrypted]
    # Recreate the secret only when the plaintext hash above
    # actually changes. The recreate is a destroy-then-create,
    # which means a brief window where the secret is missing in
    # GitHub. In practice that window is sub-second and only
    # opens when someone has actually rotated a value (a
    # Cloudflare token, a bucket name), so a CI run colliding
    # with the gap is vanishingly unlikely.
    replace_triggered_by = [terraform_data.r2_secret_plaintext_hash[each.key]]
  }
}
