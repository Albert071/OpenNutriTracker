# Catalog data plane: one `aws_s3_object` per file the build
# pipeline produced. The `for_each` walks the build-output
# directory at plan time, hashes every file, and OpenTofu
# compares those hashes against state. The upload that follows
# on apply is delta-only: a chunk whose content has not changed
# since the last apply produces no diff and no API call. A chunk
# that has changed (or is new) gets one upload, retried by the
# AWS provider's multipart machinery if the API hiccups.
#
# The plan output is the documentation of what is about to land:
# every changed object appears with its key and a `~ source_hash`
# diff, so a reviewer reads exactly which chunks are about to
# move before the apply runs.
#
# Two filesets feed the resource: the `*.manifest.json` files and
# the `*.db.gz.part-*` chunks. They are merged into a single map
# keyed by the final S3 key (with the `v1/` prefix already
# applied) so `for_each` works on a stable identifier; the only
# reason they are split before merging is so the Content-Type
# header can be set correctly per-file.

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

locals {
  # An empty `build_output_dir` is the "no build has run yet" case
  # (a clean checkout, a PR plan that intentionally skipped the
  # build). We fall through to empty filesets so the catalog module
  # contributes no resources to the plan rather than erroring on a
  # missing directory. Once the build has run and the variable
  # points at a populated directory, fileset enumerates the files
  # and the resource for_each picks up where state left off.
  have_build = var.build_output_dir != ""

  manifest_files = local.have_build ? fileset(var.build_output_dir, "*.manifest.json") : toset([])
  chunk_files    = local.have_build ? fileset(var.build_output_dir, "*.db.gz.part-*") : toset([])

  objects = merge(
    {
      for f in local.manifest_files :
      "${var.object_prefix}${f}" => {
        source       = "${var.build_output_dir}/${f}"
        content_type = "application/json"
      }
    },
    {
      for f in local.chunk_files :
      "${var.object_prefix}${f}" => {
        source       = "${var.build_output_dir}/${f}"
        content_type = "application/octet-stream"
      }
    },
  )
}

resource "aws_s3_object" "catalog" {
  for_each = local.objects

  bucket       = var.bucket
  key          = each.key
  source       = each.value.source
  content_type = each.value.content_type

  # `source_hash` is the canonical "has the content changed"
  # signal for `aws_s3_object`. Setting it to filesha256() of
  # the local file means OpenTofu re-uploads only when the
  # bytes have actually changed, regardless of mtime, etag
  # quirks, or whether the AWS provider's default etag handling
  # has trouble with multipart-uploaded objects (which it does,
  # historically, on R2).
  source_hash = filesha256(each.value.source)
}
