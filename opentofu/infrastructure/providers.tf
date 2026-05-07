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

# AWS provider configured against R2's S3-compatible endpoint
# rather than a real AWS account. R2 ignores `region` (objects
# are multi-region under the covers) but the AWS SDK requires a
# value, so we pass `auto`. The `skip_*` flags disable the
# AWS-specific account / IAM checks the provider would otherwise
# run on every plan.
#
# Auth comes from the catalog-upload Cloudflare API token by way
# of the `cloudflare` module: the token id is the S3 access key,
# and the SHA-256 of the token value is the S3 secret access key.
# Both are surfaced as module outputs, so a token rotation in the
# tokens.tf flows through here automatically.
provider "aws" {
  region                      = "auto"
  access_key                  = module.cloudflare.catalog_upload_token_id
  secret_key                  = module.cloudflare.r2_secret_access_key
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true

  endpoints {
    s3 = module.cloudflare.r2_endpoint
  }

  # R2's S3 API requires path-style addressing rather than
  # virtual-hosted-style.
  s3_use_path_style = true
}
