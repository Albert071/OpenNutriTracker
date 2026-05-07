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
  }

  # State lives in a private R2 bucket (`opennutritracker-tf-state`)
  # bootstrapped outside this config. Auth comes from the standard
  # AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY env vars (sourced from
  # GitHub Actions secrets in CI). The bucket is *not* attached to a
  # public domain and has no public-access setting enabled.
  #
  # The state object is also encrypted at rest at the OpenTofu layer
  # via PBKDF2-derived AES-256-GCM — see `encryption.tf` for the
  # configuration. R2 already encrypts at rest server-side; the
  # second layer protects against credential leakage that could let
  # an attacker pull the bucket's bytes (the state file contains the
  # raw Cloudflare API token value among other sensitive resource
  # attributes).
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
  }
}

# Auth comes from the CLOUDFLARE_API_TOKEN env var. The token must
# carry enough scope to manage the entire opennutritracker.org zone
# (DNS, cache rules, custom domains) and any R2 bucket on the
# account, plus permission to mint and revoke other API tokens —
# this OpenTofu config generates downstream tokens for the workflow
# rather than having anyone create them by hand.
provider "cloudflare" {}

# Auth comes from the GITHUB_TOKEN env var. The token needs `repo`
# scope on simonoppowa/OpenNutriTracker (or whichever repo the
# workflow lives in) so OpenTofu can write Actions secrets.
provider "github" {
  owner = var.github_owner
}
