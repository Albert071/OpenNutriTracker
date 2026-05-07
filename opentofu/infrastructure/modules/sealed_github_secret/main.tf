# Encapsulates the seal-and-rotate pattern for a single GitHub
# Actions secret. The root module iterates this via `for_each` to
# publish the entries in `local.secrets`.

terraform {
  required_providers {
    # Without these declarations the bare names `github` and
    # `external` resolve to `hashicorp/*` defaults and the
    # `providers = { ... }` argument in the root's `module` block
    # then refuses the inheritance with a "different provider type"
    # error.
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}
#
# The two non-obvious bits live inside the `lifecycle` block on the
# secret resource:
#
# * `ignore_changes = [value_encrypted]` because libsodium's
#   `crypto_box_seal` is non-deterministic — the ciphertext on disk
#   differs from the ciphertext in state on every plan, even when
#   the plaintext is unchanged. Without this, every plan would show
#   every secret as drifting, which is cosmetic noise that drowns
#   out real rotations in the apply summary.
#
# * `replace_triggered_by = [terraform_data.plaintext_hash]` keys
#   real rotations off a stable hash of the plaintext. When the
#   plaintext genuinely changes, the hash changes, the secret is
#   destroyed-and-recreated with a freshly-sealed value. When it
#   does not, nothing happens. The destroy-then-create gap is
#   sub-second and only opens during a real rotation, so a workflow
#   colliding with it is vanishingly unlikely.

# Seal the plaintext against the libsodium key. `path.root` resolves
# to the consuming module's directory, so seal.py keeps living next
# to the rest of the cloudflare config rather than duplicating
# inside this module.
data "external" "sealed" {
  program = ["python3", "${path.root}/scripts/seal.py"]
  query = {
    public_key = var.public_key
    plaintext  = var.plaintext
  }
}

resource "terraform_data" "plaintext_hash" {
  input = sha256(var.plaintext)
}

resource "github_actions_secret" "this" {
  repository      = var.repository
  secret_name     = var.secret_name
  value_encrypted = data.external.sealed.result["ciphertext"]
  key_id          = var.key_id

  lifecycle {
    ignore_changes       = [value_encrypted]
    replace_triggered_by = [terraform_data.plaintext_hash]
  }
}
