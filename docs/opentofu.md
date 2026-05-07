# OpenTofu deployment

Long-form reference for the Cloudflare-side infrastructure that backs the offline catalog. The HCL itself lives in `opentofu/cloudflare/` with the same notes as inline comments; this file is where to come when you want the shape of the whole thing in one place.

## Contents

- [Overview](#overview)
- [What OpenTofu manages](#what-opentofu-manages)
- [What OpenTofu does not manage](#what-opentofu-does-not-manage)
- [State](#state)
  - [Backend](#backend)
  - [Encryption](#encryption)
  - [What the passphrase guards](#what-the-passphrase-guards)
  - [Recovery if the passphrase is lost](#recovery-if-the-passphrase-is-lost)
  - [Rotating the passphrase](#rotating-the-passphrase)
- [Secrets matrix](#secrets-matrix)
  - [Manually-managed (bootstrap)](#manually-managed-bootstrap)
  - [Tofu-managed (regenerated on apply)](#tofu-managed-regenerated-on-apply)
- [Sealing GitHub Actions secrets](#sealing-github-actions-secrets)
- [Running an apply](#running-an-apply)
  - [Locally](#locally)
  - [In CI](#in-ci)
- [Adding things](#adding-things)
  - [A new Cloudflare resource](#a-new-cloudflare-resource)
  - [A new bootstrap secret](#a-new-bootstrap-secret)
  - [Bootstrapping from scratch](#bootstrapping-from-scratch)
- [Common gotchas](#common-gotchas)
- [Future improvements](#future-improvements)
  - [Environment-scoped GitHub Actions secrets](#environment-scoped-github-actions-secrets)
- [Files](#files)

## Overview

The offline catalog is built weekly by a GitHub Actions pipeline, sliced into 16 filter variants, chunked under a 256 MiB cap, and uploaded to a public Cloudflare R2 bucket. The Flutter client downloads it from a custom domain on that bucket. OpenTofu owns the Cloudflare side of that pipeline.

```text
                    GitHub Actions
        ┌────────────────────────────────────┐
        │  tofu_apply.yml                    │
        │    plan → (approval) → apply ──────┼──► Cloudflare API
        │                                    │      • mints downstream tokens
        │                                    │      • manages R2 bucket + domain
        │                                    │      • writes cache rule
        │                                    │
        │  build_catalog.yml  (workflow_run) │
        │    └── build + upload ─────────────┼──► R2 bucket
        │                                    │      ▼
        │                                    │      catalog.opennutritracker.org
        └────────────────────────────────────┘            ▲
                                                          │
                                                Flutter client downloads here
```

A successful `tofu_apply.yml` is the gate for `build_catalog.yml`: the catalog only gets uploaded into infrastructure that has just been reconciled with the OpenTofu config.

## What OpenTofu manages

Cloudflare resources, all defined in `opentofu/cloudflare/*.tf`:

| Resource                                                    | File         | Purpose                                                                             |
| ----------------------------------------------------------- | ------------ | ----------------------------------------------------------------------------------- |
| `cloudflare_r2_bucket.catalog` (`opennutritracker-catalog`) | `r2.tf`      | Public-read bucket the catalog chunks live in.                                      |
| `cloudflare_r2_custom_domain.catalog`                       | `r2.tf`      | `catalog.opennutritracker.org`. Canonical app-facing host.                          |
| `cloudflare_ruleset.cache`                                  | `cache.tf`   | Forces 7-day edge + browser TTL on responses from the custom domain.                |
| `cloudflare_api_token.catalog_upload`                       | `tokens.tf`  | Bucket-scoped, object-write only. Used by the build workflow to upload chunks.      |
| `cloudflare_api_token.cache_purge`                          | `tokens.tf`  | Zone-scoped, purge only. Used after each upload to invalidate the new URLs.         |

Plus seven GitHub Actions secrets, defined in `github.tf`, that publish the values above into the build workflow:

- `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT`, `R2_BUCKET` for the upload step.
- `CLOUDFLARE_PURGE_TOKEN`, `CLOUDFLARE_ZONE_ID`, `CDN_HOST` for the cache-purge step.

The cache rule deserves a footnote: without it Cloudflare would mark every R2 response as `DYNAMIC` and the edge would never serve a hit, because R2 itself does not set `Cache-Control` headers on objects by default.

## What OpenTofu does not manage

A few things stay outside the config because OpenTofu cannot bootstrap the credentials it would need to manage them.

- **The bootstrap Cloudflare API token** (`CLOUDFLARE_API_TOKEN`). Created manually in the Cloudflare dashboard with enough scope to manage the entire `opennutritracker.org` zone, any R2 bucket on the account, and to mint and revoke other API tokens.
- **The state R2 bucket** (`opennutritracker-tf-state`) and its credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`). Created by hand before the first `tofu init`. The bucket is private and never gets a public-access domain.
- **The GitHub PAT** (`TF_GITHUB_TOKEN`). Needs `repo` scope so OpenTofu can write Actions secrets.
- **The state encryption passphrase** (`TF_VAR_STATE_PASSPHRASE`). Generated once with `openssl rand -base64 32`, stored in the matching GitHub Actions secret, and kept in cold storage outside the repo.

These four secrets, plus `TF_VAR_account_id` and `TF_VAR_zone_id_opennutritracker_org`, are the manual prerequisites for any apply.

## State

### Backend

State lives at `s3://opennutritracker-tf-state/cloudflare/terraform.tfstate` in Cloudflare R2, accessed via the S3-compatible API. Auth comes from `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` env vars: in CI from GitHub Actions secrets, locally from `opentofu/cloudflare/.env` (gitignored). The bucket is private and has no custom domain attached.

### Encryption

R2 encrypts at rest server-side, but that only protects against attackers with raw disk access to Cloudflare's storage. It does nothing against an attacker holding valid R2 credentials. So we add a second layer.

`encryption.tf` configures OpenTofu's native state encryption. The state is wrapped in an authenticated-encryption envelope before it leaves the local process; what lands in R2 looks like:

```json
{
  "serial": 7,
  "lineage": "...",
  "meta": { "key_provider.pbkdf2.state": "..." },
  "encrypted_data": "<base64 ciphertext>",
  "encryption_version": "v0"
}
```

No `resources` array, no plaintext token values: only the metadata needed to decrypt the payload, plus the ciphertext itself.

Parameters:

- **Cipher**: AES-256-GCM (authenticated; tampering or wrong key fails closed).
- **Key derivation**: PBKDF2-SHA512, 600 000 iterations, 32-byte salt regenerated on every write. Matches OWASP's 2024 PBKDF2-SHA512 guidance and well above OpenTofu's 200 k floor.
- **Lockdown**: `enforced = true` on the `state` block, so OpenTofu refuses any operation that would read or write unencrypted state.

### What the passphrase guards

The state file holds the raw `value` of `cloudflare_api_token.catalog_upload` and `cloudflare_api_token.cache_purge`. Cloudflare returns those values exactly once when the token is minted, and OpenTofu has to keep them in state to detect drift on subsequent applies. A leaked unencrypted state file would let an attacker read the catalog-upload token directly and from there overwrite or delete catalog data.

### Recovery if the passphrase is lost

OpenTofu cannot decrypt the state, so `tofu plan` and `tofu apply` both fail with `cipher: message authentication failed`. The recovery path:

1. Mint a fresh bootstrap Cloudflare API token in the dashboard.
2. Delete the encrypted state object from R2.
3. Delete every resource OpenTofu would re-create (catalog R2 bucket, custom domain, both downstream tokens) by hand, since OpenTofu cannot read its own state to know they exist.
4. Run `tofu init && tofu apply` from scratch. New downstream tokens get minted, the cache rule is rewritten, and the seven GitHub Actions secrets re-seal to the new token values.

All of that is recoverable, but it is disruptive enough that the passphrase deserves to be treated as load-bearing infrastructure. Keep it in a password manager that you trust to outlive your GitHub account, and make sure at least one other trustworthy person has access to it if the project might outlive your own involvement.

### Rotating the passphrase

OpenTofu's pattern for rotation is to add a new key provider alongside the old one with the same `encrypted_metadata_alias`, run one apply to migrate the ciphertext to the new key, and then remove the old key provider in a follow-up. The pattern is documented but not yet exercised on this repo, and is worth reaching for if there is ever evidence that the old passphrase has leaked.

## Secrets matrix

The split between manually-managed and Tofu-managed is part of the security model: the manual ones are the trust roots that everything else flows from, and they should rotate rarely; the Tofu-managed ones flow automatically and rotate whenever their underlying resources do.

### Manually-managed (bootstrap)

Live in repo settings, never touch OpenTofu state.

| Secret                                | What it authenticates                               |
| ------------------------------------- | --------------------------------------------------- |
| `CLOUDFLARE_API_TOKEN`                | Bootstrap CF token used by the cloudflare provider. |
| `TF_GITHUB_TOKEN`                     | PAT with `repo` scope, used by the github provider. |
| `AWS_ACCESS_KEY_ID`                   | State bucket R2 access key.                         |
| `AWS_SECRET_ACCESS_KEY`               | State bucket R2 secret key.                         |
| `TF_VAR_account_id`                   | Cloudflare account ID.                              |
| `TF_VAR_zone_id_opennutritracker_org` | Cloudflare zone ID for `opennutritracker.org`.      |
| `TF_VAR_STATE_PASSPHRASE`             | Passphrase for state-file encryption.               |

### Tofu-managed (regenerated on apply)

Minted by OpenTofu and sealed into GitHub via `seal.py`. Any apply that re-creates the underlying resource produces a fresh sealed value. The plaintext is never readable from outside the apply process.

| Secret                   | Source                                              |
| ------------------------ | --------------------------------------------------- |
| `R2_ACCESS_KEY_ID`       | `cloudflare_api_token.catalog_upload.id`            |
| `R2_SECRET_ACCESS_KEY`   | `sha256(cloudflare_api_token.catalog_upload.value)` |
| `R2_ENDPOINT`            | derived from `var.account_id`                       |
| `R2_BUCKET`              | `cloudflare_r2_bucket.catalog.name`                 |
| `CLOUDFLARE_PURGE_TOKEN` | `cloudflare_api_token.cache_purge.value`            |
| `CLOUDFLARE_ZONE_ID`     | `var.zone_id_opennutritracker_org`                  |
| `CDN_HOST`               | `cloudflare_r2_custom_domain.catalog.domain`        |

A note on `R2_SECRET_ACCESS_KEY`: Cloudflare R2's S3-compatible API accepts a token id as the access key id and the SHA-256 of the token value as the secret access key. Documented Cloudflare behaviour, not a workaround. The `github.tf` locals reflect that:

```hcl
catalog_secret_access_key = sha256(local.catalog_token_value)
```

## Sealing GitHub Actions secrets

`scripts/seal.py` is a tiny libsodium sealer invoked through an `external` data source. It reads `{public_key, plaintext}` JSON from stdin and writes `{ciphertext}` JSON to stdout. The ciphertext lands in `github_actions_secret.value_encrypted` and gets stored in OpenTofu state.

Two things follow from this design that are worth sitting with.

The first is that the plaintext never enters OpenTofu state at all. State only ever carries the sealed ciphertext, and that ciphertext is then wrapped in the AES-GCM envelope at the storage layer, which means there are three layers of defence between an attacker and the plaintext token values.

The second is that the seal itself is non-deterministic. libsodium's `crypto_box_seal` uses an ephemeral keypair on each call, so resealing the same plaintext produces different ciphertext. Left unmanaged, OpenTofu would see the difference as drift on every plan and try to re-upload all seven secrets even though nothing inside GitHub had actually changed.

We sidestep that by tracking a stable plaintext hash alongside each secret. `terraform_data.r2_secret_plaintext_hash` in `github.tf` holds `sha256(plaintext)` for each entry; the `github_actions_secret.r2` resource then sets `lifecycle.ignore_changes = [value_encrypted]` (so non-deterministic ciphertext drift is invisible) and `lifecycle.replace_triggered_by = [terraform_data.r2_secret_plaintext_hash[each.key]]` (so a real plaintext change triggers a destroy-then-create with a freshly-sealed value). The result: a steady-state plan shows zero changes when nothing has been rotated, and exactly one secret being replaced when one is. The recreate is destroy-then-create rather than update-in-place because GitHub's API has no "update sealed value" semantics; the gap is sub-second and only opens during a genuine rotation, so a workflow run colliding with it is vanishingly unlikely.

## Running an apply

### Locally

`opentofu/cloudflare/.env` (gitignored) carries every variable the apply needs. `tenv` is the OpenTofu version manager already on the dev box; it pins the binary version per-project.

```bash
cd opentofu/cloudflare
set -a && source .env && set +a
~/.tenv/OpenTofu/1.11.6/tofu init
~/.tenv/OpenTofu/1.11.6/tofu plan      # always plan first
~/.tenv/OpenTofu/1.11.6/tofu apply
```

### In CI

`.github/workflows/tofu_apply.yml` is split into a plan job and two apply jobs, with the trigger deciding which apply path runs (if any). The plan binary is uploaded as an artifact and the apply jobs consume it, so the apply runs against the exact plan a human reviewed rather than re-planning under their feet.

Trigger to behaviour, end to end:

- **Pull request** touching `opentofu/cloudflare/**` or the workflow file itself runs init and plan only. The plan output sits in the run logs alongside the PR for the reviewer to read. No state is written.
- **Push to `main`** under the same paths runs init, plan, and then a gated apply. The apply job uses the `tofu-apply` GitHub environment, which is configured in repo settings to require a reviewer's approval before the apply step runs. The apply consumes the plan artifact uploaded by the plan job.
- **Saturday 19:00 UTC cron** (when run from `main`) runs init, plan, and an unattended apply. The cron's job is to nudge the chained catalog rebuild even when the infrastructure is unchanged, so pausing every weekly run on a manual approval would defeat the point. The cron-triggered apply job is gated on `github.ref == 'refs/heads/main'` for safety so it does not silently apply a non-main branch's config during transitions.
- **Manual `workflow_dispatch`** runs init, plan, and then the same approval-gated apply as the push trigger. Useful for re-running an apply after a manual fix.

Both apply jobs share a single concurrency group (`tofu-apply-state`) so the cron and a human apply can never race for the state file. Plans run outside this group because they are read-only.

Both apply paths need `TF_VAR_state_passphrase` from the `tofu init` step onwards, because reading the existing state during init goes through the encryption layer.

A successful workflow run gates `.github/workflows/build_catalog.yml`, which fires via `workflow_run`. The chain only fires when the parent workflow completes from the default branch, so a PR's plan-only run does not trigger a catalog rebuild.

#### One-time environment setup

The gated apply needs a `tofu-apply` GitHub environment with at least one required reviewer, configured manually in repo settings (the GitHub API does not let collaborators create environments). Without a reviewer set, the gated apply job will run unattended, which defeats the approval gate. Path: Settings → Environments → New environment → "tofu-apply" → "Required reviewers" → add yourself.

## Adding things

### A new Cloudflare resource

1. Add the resource to whichever `.tf` file fits its shape, or create a new one if it deserves its own surface.
2. If the resource produces a value that downstream workflows need (an API token, a bucket name, a zone id), add it to the `secrets` map in `github.tf` so it gets sealed and published as an Actions secret.
3. Open a PR. The PR run lands a plan in the workflow logs for review. Once the PR merges to `main`, the workflow runs again, the apply job pauses on the `tofu-apply` environment for explicit approval, and the apply only runs after that approval lands.

### A new bootstrap secret

1. Add the secret to GitHub repo settings by hand.
2. Reference it in `.github/workflows/tofu_apply.yml`'s `env` block on the `init` and/or `apply` step.
3. If it needs to be visible to OpenTofu as a variable, add a `variable "..."` block in `variables.tf` with `sensitive = true` and reference it as `var.name`.
4. Document it in the secrets matrix above.

### Bootstrapping from scratch

If you ever need to rebuild the OpenTofu side over from nothing:

1. **Cloudflare**, in the dashboard:
   - Create the bootstrap API token with the scopes described in `main.tf` (zone management, R2 management, token mint and revoke).
   - Create the `opennutritracker-tf-state` R2 bucket. Mint bucket-scoped credentials. Note the account-scoped S3 endpoint URL.
2. **GitHub**, in repo settings:
   - Create a PAT with `repo` scope for the github provider.
   - Add all seven manually-managed secrets from the matrix above.
3. **Locally**:
   - Populate `opentofu/cloudflare/.env` (gitignored), or use `tofu.tfvars` if you prefer file-based variables.
   - `cd opentofu/cloudflare && tofu init && tofu apply`.

The first apply mints the downstream tokens, seals all seven Tofu-managed secrets into GitHub, and writes the encrypted state to R2. Subsequent applies see no drift unless a plaintext value has genuinely changed (a token rotation, a renamed bucket), thanks to the plaintext-hash trick described in the secrets section above.

## Common gotchas

- **The Cloudflare provider's resource shape changes between major versions.** The pinned constraint is `~> 5.0`. Read the provider release notes before bumping the pin; v5 changed several attribute names from v4.
- **Token values are write-once on Cloudflare's side.** If OpenTofu ever loses the value of an API token from state (state loss without a passphrase, an `import` without the `value` attribute, a `taint` followed by misconfigured replace), the only recovery is to delete the token in the dashboard and let OpenTofu mint a fresh one on the next apply. The seven Tofu-managed secrets re-seal automatically.
- **Cache-purge tokens are zone-scoped, not bucket-scoped.** Adding more zones requires a new permission group on the `cache_purge` token.
- **The bucket location is `WEUR`.** Changing it requires recreating the bucket. The catalog goes 404 from the moment R2 destroys the old bucket until the next weekly catalog build runs and repopulates the new one. Don't change it without a plan for the gap.
- **The cache rule references `cloudflare_r2_custom_domain.catalog.domain`** rather than a hard-coded hostname. If the custom domain ever changes the rule follows. If the domain gets deleted and recreated, the rule has to be applied through the same plan or the cache will briefly stop honouring the 7-day TTL.

## Future improvements

Hardening that has been considered and deliberately deferred. Each entry explains the win, the trade-off, and how to implement when the project is ready.

### Environment-scoped GitHub Actions secrets

Today the seven Tofu-managed secrets are repo-level, which means any workflow in the repo with `GITHUB_TOKEN` access reads them. Migrating them to a named GitHub deployment environment (something like `catalog`) means only workflows that declare `environment: catalog` can read those values, and the environment itself can carry protection rules around branch restrictions, required reviewers, and wait timers.

The reason this hasn't already happened is that the boundary it adds only really lands once a malicious or compromised PR could plausibly add a workflow file and merge it. On a single-maintainer repo with a tight contributor surface, environment scoping is mostly cosmetic. It starts to matter when one of these is true: the repo begins accepting community PRs that touch workflow files; the secrets gain real production sensitivity (today the catalog-upload token can only overwrite a public-read bucket whose contents are republished from public OFF data weekly); or the project moves to a dual-branch model where `main` is the production branch and feature branches must be locked out of deploying. The third trigger is the natural moment to flip this on, since the real value of the change comes from the branch restriction.

When the time does come, the implementation lives in a new file `opentofu/cloudflare/environments.tf`:

```hcl
resource "github_repository_environment" "catalog" {
  repository  = var.github_repo
  environment = "catalog"

  # Allow only `main` to deploy. Without this block any branch can
  # use the environment, which gives scoping but not branch
  # restriction.
  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment_deployment_policy" "catalog_main" {
  repository     = var.github_repo
  environment    = github_repository_environment.catalog.environment
  branch_pattern = "main"
}
```

`github.tf` changes from `github_actions_secret` to `github_actions_environment_secret`, threading the environment through:

```hcl
resource "github_actions_environment_secret" "catalog" {
  for_each = local.secrets

  repository      = var.github_repo
  environment     = github_repository_environment.catalog.environment
  secret_name     = each.key
  value_encrypted = data.external.sealed[each.key].result["ciphertext"]
  key_id          = data.github_actions_public_key.repo.key_id
}
```

The catalog-build workflow then has to declare the environment so it can actually read the secrets:

```yaml
jobs:
  build:
    environment: catalog
    runs-on: ubuntu-latest
    # ...
```

The migration is zero-downtime if the changes go in the right order, because GitHub Actions resolves secrets by most-specific scope: an environment-level secret with the same name as a repo-level one wins for any workflow that declares that environment. The safe sequence is to first add the new environment and the env-level secret resources alongside the existing repo-level ones and apply, so both scopes now exist; then update the workflow to add `environment: catalog` and push, so the next run reads the env-level values; verify a successful catalog build against them; and only then delete the repo-level resources and apply once more to let drift detection remove them. Splitting that across two PRs is cleaner than landing it all at once: the first does the additive steps, and the second does the removal once the env-level path has been live long enough to confirm it's healthy.

Local apply continues to work throughout. The provider authenticates via the PAT in `TF_GITHUB_TOKEN`, and GitHub's REST API treats PAT-authenticated calls the same regardless of origin. Environment protection rules constrain workflow runs, not direct API calls, so `tofu apply` from your laptop still creates and updates env-scoped secrets fine even when the protection rule says only `main` can deploy. The existing `repo` PAT scope already covers environment management, so no rotation is needed.

## Files

```text
opentofu/cloudflare/
  main.tf             ← terraform block, providers, backend
  variables.tf        ← input variables (account_id, zone_id, passphrase, ...)
  outputs.tf          ← outputs (bucket_name, cdn_url)
  r2.tf               ← R2 bucket + custom domain
  cache.tf            ← zone-level cache rule
  tokens.tf           ← downstream Cloudflare API tokens
  github.tf           ← GitHub Actions secrets, sealed
  encryption.tf       ← state-file encryption block
  scripts/seal.py     ← libsodium sealer for github_actions_secret values
  tofu.tfvars.example ← template for variable values
  .env                ← (gitignored) local env vars for tofu apply
  .terraform/         ← (gitignored) provider plugins, backend stub
```

```text
.github/workflows/
  tofu_apply.yml     ← plan → (gated) apply, with cron bypass
  build_catalog.yml  ← chained via workflow_run; rebuilds and uploads
                       the 16 catalog variants weekly
```
