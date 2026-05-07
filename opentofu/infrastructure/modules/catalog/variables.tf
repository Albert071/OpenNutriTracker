variable "bucket" {
  description = "Name of the catalog R2 bucket. Threaded through from `module.cloudflare.bucket_name` so a renamed bucket flows automatically."
  type        = string
}

variable "build_output_dir" {
  description = "Path to the directory containing the freshly-built catalog chunks and manifests, relative to the root config. The build pipeline writes this; OpenTofu reads from it on every plan and hashes each file to decide whether an upload is needed."
  type        = string
}

variable "object_prefix" {
  description = "Prefix to apply to every uploaded object's key. The Flutter client expects URLs of the form 'https://<cdn>/v1/<filename>', so the default puts everything under 'v1/'. Bumping this becomes a way to publish a forward-incompatible catalog without disturbing the live one."
  type        = string
  default     = "v1/"
}
