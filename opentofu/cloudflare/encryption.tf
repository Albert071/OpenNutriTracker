# State-file encryption at the OpenTofu layer.
#
# The state object lives at `s3://opennutritracker-tf-state/cloudflare/
# terraform.tfstate` and contains sensitive resource attributes —
# notably the raw value of `cloudflare_api_token.catalog_upload`,
# which has bucket-write permissions on the catalog R2. R2 already
# encrypts at rest server-side, but that protection is transparent
# to anyone who can present valid R2 credentials. This second layer
# means an attacker who pulls the state bytes still cannot read them
# without also having the passphrase.
#
# The passphrase comes from var.state_passphrase, mirrored to the
# TF_VAR_STATE_PASSPHRASE GitHub Actions secret and the local .env
# (gitignored). It is the *only* thing standing between key loss and
# state loss — keep an offline copy in a password manager.

terraform {
  encryption {
    # Source-of-truth for the AES key. PBKDF2 with SHA-512 turns the
    # passphrase into a 32-byte AES-256 key over 600,000 iterations.
    # 600k is the published OWASP recommendation as of 2024 and well
    # above OpenTofu's hard minimum of 200k.
    key_provider "pbkdf2" "state" {
      passphrase    = var.state_passphrase
      key_length    = 32
      iterations    = 600000
      salt_length   = 32
      hash_function = "sha512"
    }

    # AES-256-GCM. Authenticated encryption — corruption or
    # tampering of the ciphertext fails decryption, so we cannot
    # silently accept a swapped state.
    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }

    state {
      method   = method.aes_gcm.state
      # `enforced` is the lockdown setting: refuse any operation that
      # would read or write unencrypted state. Without it a
      # misconfiguration could silently regress to plaintext on the
      # next apply.
      enforced = true
    }
  }
}
