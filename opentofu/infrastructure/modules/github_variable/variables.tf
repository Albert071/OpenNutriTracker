variable "repository" {
  description = "Name of the GitHub repository where the variable lives (e.g. \"OpenNutriTracker\")."
  type        = string
}

variable "variable_name" {
  description = "Name of the GitHub Actions variable. Reachable from a workflow as `vars.<variable_name>`."
  type        = string
}

variable "value" {
  description = "Plaintext value of the variable. Unlike secrets, GitHub does not seal or mask this — variables are intended for non-sensitive workflow config (URLs, bucket names, region identifiers) that benefits from being legible in workflow logs."
  type        = string
}
