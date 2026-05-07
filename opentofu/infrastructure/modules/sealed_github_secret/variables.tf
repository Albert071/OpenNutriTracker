variable "repository" {
  description = "Name of the GitHub repository where the secret lives (e.g. \"OpenNutriTracker\")."
  type        = string
}

variable "secret_name" {
  description = "Name of the GitHub Actions secret to publish."
  type        = string
}

variable "plaintext" {
  description = "The raw secret value. Never enters OpenTofu state in cleartext: only the libsodium-sealed ciphertext (in `github_actions_secret.this`) and a one-way SHA-256 of the plaintext (in `terraform_data.plaintext_hash`) do. A change in this value triggers a destroy-then-create of the secret resource."
  type        = string
  sensitive   = true
}

variable "public_key" {
  description = "Libsodium public key for the destination repository, retrieved once at the root from the github_actions_public_key data source and threaded through to every module instance."
  type        = string
}

variable "key_id" {
  description = "Identifier GitHub returns alongside the public key. Required by the github_actions_secret resource so GitHub can verify the ciphertext was sealed against the right key."
  type        = string
}
