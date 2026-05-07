# Encapsulates the publication of a single GitHub Actions variable.
# The root module iterates this via `for_each` to publish the
# entries in `local.config_variables`.
#
# This module is the deliberately-thin counterpart to
# `sealed_github_secret`. Variables don't need libsodium sealing,
# they don't need a hash-based rotation gate, and they don't have
# the non-deterministic-ciphertext drift problem. So the module is
# a single resource and three variables — its job is symmetry with
# the secret module rather than encapsulation of any tricky
# behaviour. Future readers see the same shape ("a workflow value
# is a module call") whether the value is sensitive or not.

terraform {
  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}

resource "github_actions_variable" "this" {
  repository    = var.repository
  variable_name = var.variable_name
  value         = var.value
}
