# Composition root.
#
# Four child modules together describe the catalog system:
#
# * `cloudflare` — everything on the Cloudflare side: the R2 bucket
#   and its custom domain, the cache rule, and the two downstream
#   API tokens the build workflow consumes. The provider is passed
#   through explicitly because `cloudflare_*` resources in the
#   child module would otherwise resolve to the unconfigured default
#   provider.
#
# * `secret` — one instance per entry in `local.secrets`. The module
#   encapsulates the libsodium seal, the plaintext-hash rotation
#   gate, and the resulting `github_actions_secret`. Provider is
#   also passed explicitly here, otherwise the github provider's
#   `owner` setting fails to inherit and API calls 404 against the
#   human token user instead of the repo owner.
#
# * `variable` — one instance per entry in `local.config_variables`.
#   The non-sensitive twin of `secret`: same shape, no seal, no
#   rotation gate. Used for URLs, bucket names, zone identifiers —
#   anything the build workflow needs to know but does not need to
#   keep secret. Publishing these as `github_actions_variable`
#   rather than `github_actions_secret` makes them legible in
#   workflow logs.
#
# * `catalog` — the data plane. Each file the build pipeline
#   produces becomes an `aws_s3_object` in R2; OpenTofu hashes
#   them at plan time and uploads only the chunks whose content
#   has changed. Replaces the previous bash-and-boto3 upload step
#   with a delta-driven, plan-reviewable upload path.

module "cloudflare" {
  source = "./modules/cloudflare"

  providers = {
    cloudflare = cloudflare
  }

  account_id                   = var.account_id
  zone_id_opennutritracker_org = var.zone_id_opennutritracker_org
  edge_cache_seconds           = var.edge_cache_seconds
  browser_cache_seconds        = var.browser_cache_seconds
}

module "secret" {
  for_each = local.secrets
  source   = "./modules/sealed_github_secret"

  providers = {
    github   = github
    external = external
  }

  repository  = var.github_repo
  secret_name = each.key
  plaintext   = each.value
  public_key  = data.github_actions_public_key.repo.key
  key_id      = data.github_actions_public_key.repo.key_id
}

module "variable" {
  for_each = local.config_variables
  source   = "./modules/github_variable"

  providers = {
    github = github
  }

  repository    = var.github_repo
  variable_name = each.key
  value         = each.value
}

module "catalog" {
  source = "./modules/catalog"

  bucket           = module.cloudflare.bucket_name
  build_output_dir = var.catalog_build_output_dir
}
