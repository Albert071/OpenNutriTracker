# Read-only inputs the rest of the config depends on.
#
# `github_actions_public_key.repo` gives us the libsodium public
# key we need to seal each secret value against before it can be
# stored in `github_actions_secret`. We look it up once here and
# pass it to every `module.secret` instance, since the lookup is
# the same across every secret destined for the same repo.
#
# The libsodium sealing itself happens inside the
# `sealed_github_secret` module — see
# `modules/sealed_github_secret/main.tf`.

data "github_actions_public_key" "repo" {
  repository = var.github_repo
}
