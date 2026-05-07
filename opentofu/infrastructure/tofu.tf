# Run with OpenTofu (the `tofu` binary). The `terraform { … }`
# config-block name is the one OpenTofu inherits from the HCL spec;
# it does not imply running the proprietary Terraform CLI.
terraform {
  required_version = "~> 1.11.0"
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
    # Used by the `catalog` module to upload chunks to R2 via the
    # S3-compatible API (R2 has no native object resource in the
    # cloudflare provider). Configured in `providers.tf` to point
    # at R2's endpoint rather than a real AWS account.
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }

  # State lives in a private R2 bucket (`opennutritracker-tf-state`)
  # bootstrapped outside this config. Auth comes from the standard
  # AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY env vars (sourced from
  # GitHub Actions secrets in CI). The bucket is *not* attached to a
  # public domain and has no public-access setting enabled.
  #
  # The state object is also encrypted at rest at the OpenTofu layer
  # via the `encryption` block below — see the comments there for
  # the choice of cipher and key derivation. R2 already encrypts at
  # rest server-side; this second layer protects against credential
  # leakage that could let an attacker pull the bucket's bytes (the
  # state file contains the raw Cloudflare API token value among
  # other sensitive resource attributes).
  backend "s3" {
    bucket = "opennutritracker-tf-state"
    key    = "cloudflare/terraform.tfstate"
    region = "auto"
    endpoints = {
      s3 = "https://a153d41f71b3aab3d15561bce23110ec.r2.cloudflarestorage.com"
    }
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_path_style              = true

    # S3-native state locking: writes a small companion object
    # at `<key>.tflock` using a conditional `If-None-Match: *`
    # PUT and deletes it on release. R2 has supported the
    # required conditional-write semantics since October 2024,
    # and OpenTofu 1.10+ has supported this option, so no
    # DynamoDB stand-in is needed. The lockfile is metadata
    # only — no resource attributes — so leaving it
    # unencrypted is fine and matches how the S3 backend
    # documents the feature.
    use_lockfile = true
  }

  # State-file encryption at the OpenTofu layer.
  #
  # The state object lives at `s3://opennutritracker-tf-state/
  # cloudflare/terraform.tfstate` and contains sensitive resource
  # attributes — notably the raw value of
  # `cloudflare_api_token.catalog_upload`, which has bucket-write
  # permissions on the catalog R2. R2 already encrypts at rest
  # server-side, but that protection is transparent to anyone who
  # can present valid R2 credentials. This second layer means an
  # attacker who pulls the state bytes still cannot read them
  # without also having the passphrase.
  #
  # The passphrase comes from `var.state_passphrase`, mirrored to
  # the `TF_VAR_STATE_PASSPHRASE` GitHub Actions secret and the
  # local `.env` (gitignored). It is the *only* thing standing
  # between key loss and state loss — keep an offline copy in a
  # password manager.
  encryption {
    # Source-of-truth for the AES key. PBKDF2 with SHA-512 turns
    # the passphrase into a 32-byte AES-256 key over 600,000
    # iterations. 600k is the published OWASP recommendation as
    # of 2024 and well above OpenTofu's hard minimum of 200k.
    key_provider "pbkdf2" "state" {
      passphrase    = var.state_passphrase
      key_length    = 32
      iterations    = 600000
      salt_length   = 32
      hash_function = "sha512"
    }

    # AES-256-GCM. Authenticated encryption: corruption or tampering
    # of the ciphertext fails decryption, so we cannot silently
    # accept a swapped state.
    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.state
    }

    state {
      method = method.aes_gcm.state
      # `enforced` is the lockdown setting: refuse any operation
      # that would read or write unencrypted state. Without it a
      # misconfiguration could silently regress to plaintext on
      # the next apply.
      enforced = true
    }
  }
}
