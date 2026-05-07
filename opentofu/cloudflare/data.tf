# Read-only inputs the rest of the config depends on.
#
# `github_actions_public_key.repo` gives us the libsodium public
# key we need to seal each secret value against before it can be
# stored in `github_actions_secret`.
#
# `external.sealed` shells out to `scripts/seal.py` once per
# entry in `local.secrets` and returns the libsodium ciphertext.
# It runs on every plan, but `github_actions_secret.r2` ignores
# drift on `value_encrypted` and keys real rotations off
# `terraform_data.r2_secret_plaintext_hash`, so the
# non-deterministic ciphertext does not show up as plan churn.
# See `github.tf` for the locals it reads from and the resource
# block that consumes it.

data "github_actions_public_key" "repo" {
  repository = var.github_repo
}

data "external" "sealed" {
  for_each = local.secrets

  program = ["python3", "${path.module}/scripts/seal.py"]
  query = {
    public_key = data.github_actions_public_key.repo.key
    plaintext  = each.value
  }
}
