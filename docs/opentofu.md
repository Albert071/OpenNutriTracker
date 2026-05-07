# OpenTofu deployment

Long-form reference for the Cloudflare-side infrastructure that backs the offline catalog. The HCL itself lives in `opentofu/infrastructure/` with the same notes as inline comments; this file is where to come when you want the shape of the whole thing in one place.

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
        ┌────────────────────────────────────────────┐
        │  build_catalog.yml                         │
        │                                            │
        │  build_and_apply:  (single job)            │
        │    download OFF → trim → build sqlite      │
        │      → split into chunks                   │
        │    enforce 9.7 GiB upload ceiling          │
        │    tofu init  (acquires R2 lockfile)       │
        │    tofu plan -out=tfplan                   │
        │    tofu apply tfplan ─────────────┬────────┼─► Cloudflare API
        │      • PUTs only changed chunks   │        │     • mints downstream tokens
        │      • reconciles infra alongside │        │     • manages bucket, cache rule
        │                                   │        │
        │                                   └────────┼─► R2 bucket
        │                                            │     ▼
        │  unlock_on_failure:  (only on failure)     │     catalog.opennutritracker.org
        │    delete the lockfile if it belongs       │            ▲
        │    to this run (timestamp guard)           │            │
        └────────────────────────────────────────────┘  Flutter client downloads here
```

The pipeline lives in one workflow with one main job. Build, plan, and apply all run on the same runner with a shared filesystem, so there are no inter-job artefacts to upload and download — the chunks the build produces are read directly by the apply step that follows it. This was originally three jobs chained by `needs:` with a `tfplan` artefact in the middle, and before that two workflows wired via `workflow_run`; both earlier shapes have been collapsed because the simpler one-job version lets us reason about the whole pipeline as a single linear sequence.

OpenTofu manages every chunk as an `aws_s3_object` resource keyed off `filesha256()`, so a chunk whose content has not changed since the last apply produces no diff and no API call. Infra-side resources (bucket, custom domain, cache rule, tokens, GitHub secrets and variables) reconcile in the same plan, so any infra change rides along on the next build run.

State locking is handled at the OpenTofu layer via `use_lockfile = true` in the S3 backend (see [State](#state) below). The matching `unlock_on_failure` job runs only when the main job fails or is cancelled and a tofu state-touching step has actually started; it deletes the lockfile object directly via the S3 API, but only when the lockfile's `Created` timestamp is after this run's first tofu step started — earlier lockfiles belong to another process (most plausibly a developer's laptop apply that started before our run did) and must not be touched.

## What OpenTofu manages

Cloudflare resources, all defined in `opentofu/infrastructure/*.tf`:

| Resource                                                    | File         | Purpose                                                                             |
| ----------------------------------------------------------- | ------------ | ----------------------------------------------------------------------------------- |
| `cloudflare_r2_bucket.catalog` (`opennutritracker-catalog`) | `r2.tf`      | Public-read bucket the catalog chunks live in.                                      |
| `cloudflare_r2_custom_domain.catalog`                       | `r2.tf`      | `catalog.opennutritracker.org`. Canonical app-facing host.                          |
| `cloudflare_ruleset.cache`                                  | `cache.tf`   | 7-day edge TTL, 1-day browser `max-age`, on responses from the custom domain.       |
| `cloudflare_api_token.catalog_upload`                       | `tokens.tf`  | Bucket-scoped, object-write only. Used by the build workflow to upload chunks.      |
| `cloudflare_api_token.cache_purge`                          | `tokens.tf`  | Zone-scoped, purge only. Used after each upload to invalidate the new URLs.         |

Plus seven GitHub Actions secrets, defined by `local.secrets` in `locals.tf` and produced via `module.secret`, that publish the values above into the build workflow:

- `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ENDPOINT`, `R2_BUCKET` for the upload step.
- `CLOUDFLARE_PURGE_TOKEN`, `CLOUDFLARE_ZONE_ID`, `CDN_HOST` for the cache-purge step.

The cache rule deserves a longer footnote, because the free-tier cost model depends on it doing exactly what it does. [Cloudflare's default cache behaviour](https://developers.cloudflare.com/cache/concepts/default-cache-behavior/) caches a fixed list of file extensions (mostly static-asset extensions like `.gz`, `.zip`, `.png`) and explicitly does not cache HTML or JSON. The catalog ships chunks named `variant.db.gz.part-NN` and per-variant `variant.manifest.json` files; `.part-NN` is not on the default-cached extensions list, and `.json` is explicitly excluded. Without the rule, Cloudflare would mark every response from `catalog.opennutritracker.org` as `DYNAMIC` (compounded by R2 not setting `Cache-Control` headers on objects by default), the edge would never serve a hit, and every download would draw an R2 GetObject call.

The rule sidesteps the extension-based logic entirely: it matches on `http.host eq "catalog.opennutritracker.org"`, so every response served from the custom domain is cached regardless of file extension or origin headers. The TTLs are split deliberately: `edge_ttl` is 7 days (`var.edge_cache_seconds`), so a chunk that nobody requests for a couple of days still survives at the edge, while `browser_ttl` is 1 day (`var.browser_cache_seconds`), so users see fresh content within ~24 hours of a Saturday rebuild even if their HTTP client cached aggressively. The post-apply cache-purge step in `build_catalog.yml` then drops the edge cache for the host the moment a fresh apply lands, so the freshness path doesn't depend on TTL expiry — purge invalidates first, the daily browser `max-age` covers the long tail.

The chunked layout matters here too: Cloudflare's free, Pro, and Business plans cap cacheable response bodies at 512 MB, and the catalog's largest variant (`s0_n0_rany`) is around 520 MB compressed. A single-file layout would fail to cache by hitting that cap; the ≤256 MiB chunk size keeps every individual response comfortably under the free-tier limit while still reading as one contiguous stream from the client's point of view. Cloudflare also caches HTTP 206 (Range) responses by default, which is what makes the client's parallel range-resume downloads efficient on cache hits. As long as the cache hit ratio stays high — which it does after the first user from a region downloads each chunk — R2 egress (and therefore monetary cost) stays at zero.

## What OpenTofu does not manage

A few things stay outside the config because OpenTofu cannot bootstrap the credentials it would need to manage them.

- **The bootstrap Cloudflare API token** (`CLOUDFLARE_API_TOKEN`). Created manually in the Cloudflare dashboard with enough scope to manage the entire `opennutritracker.org` zone, any R2 bucket on the account, and to mint and revoke other API tokens.
- **The state R2 bucket** (`opennutritracker-tf-state`) and its credentials (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`). Created by hand before the first `tofu init`. The bucket is private and never gets a public-access domain.
- **The GitHub PAT** (`TF_GITHUB_TOKEN`). Needs `repo` scope so OpenTofu can write Actions secrets.
- **The state encryption passphrase** (`TF_VAR_STATE_PASSPHRASE`). Generated once with `openssl rand -base64 32`, stored in the matching GitHub Actions secret, and kept in cold storage outside the repo.

These four secrets, plus `TF_VAR_account_id` and `TF_VAR_zone_id_opennutritracker_org`, are the manual prerequisites for any apply.

## State

### Backend

State lives at `s3://opennutritracker-tf-state/cloudflare/terraform.tfstate` in Cloudflare R2, accessed via the S3-compatible API. Auth comes from `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` env vars: in CI from GitHub Actions secrets, locally from `opentofu/infrastructure/.env` (gitignored). The bucket is private and has no custom domain attached.

### Locking

The S3 backend has `use_lockfile = true` set in `tofu.tf`. OpenTofu 1.10+ writes a small companion object at `<state-key>.tflock` using a conditional `If-None-Match: *` PUT, then deletes it on release; if the conditional PUT fails because the lockfile already exists, the apply refuses to start with a clear "state is locked" message rather than racing the existing holder. R2 has supported the required conditional-write semantics since October 2024, so no DynamoDB stand-in is needed. Two layers of exclusion sit on top of each other: the GitHub Actions concurrency group catches concurrent CI runs cheaply, and the lockfile catches everything else (laptop applies, cron-vs-dispatch races, anything outside Actions).

If a process dies mid-apply (laptop crash, runner pre-emption, `kill -9`) the lockfile stays behind and the next apply refuses to start. The CI side has an `unlock_on_failure` job that handles that case automatically: it fires only when the main job fails or is cancelled and a tofu state-touching step has actually started, then deletes the lockfile object directly via the S3 API — but only when the lockfile's `Created` timestamp is after the run's first tofu step started. Earlier lockfiles belong to another process (most plausibly a developer's laptop apply that started before our run did) and must not be touched. For a stale lockfile from a laptop-side crash, the manual recovery is `tofu force-unlock <id>` once you're confident no other apply is in flight.

### Encryption

R2 encrypts at rest server-side, but that only protects against attackers with raw disk access to Cloudflare's storage. It does nothing against an attacker holding valid R2 credentials. So we add a second layer.

The `encryption { ... }` sub-block of `terraform { ... }` in `tofu.tf` configures OpenTofu's native state encryption. The state is wrapped in an authenticated-encryption envelope before it leaves the local process; what lands in R2 looks like:

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

Published by OpenTofu into two GitHub Actions stores: credentials go to **secrets** (sealed by `seal.py`, masked in workflow logs), configuration goes to **variables** (plaintext, legible in workflow logs). The split lines up with what is actually sensitive: an attacker reading a workflow log gains nothing from the bucket name or the CDN host, but they would gain everything from a leaked R2 access key. Keeping secrets in `secrets` and config in `vars` makes that distinction obvious to the next person reading the workflow file.

| Name                     | Store    | Source                                                 |
| ------------------------ | -------- | ------------------------------------------------------ |
| `R2_ACCESS_KEY_ID`       | secret   | `module.cloudflare.catalog_upload_token_id`            |
| `R2_SECRET_ACCESS_KEY`   | secret   | `module.cloudflare.r2_secret_access_key`               |
| `CLOUDFLARE_PURGE_TOKEN` | secret   | `module.cloudflare.cache_purge_token_value`            |
| `R2_BUCKET`              | variable | `module.cloudflare.bucket_name`                        |
| `R2_ENDPOINT`            | variable | `module.cloudflare.r2_endpoint`                        |
| `CDN_HOST`               | variable | `module.cloudflare.custom_domain`                      |
| `CLOUDFLARE_ZONE_ID`     | variable | `var.zone_id_opennutritracker_org`                     |

A note on `R2_SECRET_ACCESS_KEY`: Cloudflare R2's S3-compatible API accepts a token id as the access key id and the SHA-256 of the token value as the secret access key. Documented Cloudflare behaviour, not a workaround. The derivation lives inside the `cloudflare` module rather than at the root, since "how Cloudflare R2 maps a token to an S3 credential pair" is a Cloudflare concern, not a root-composition concern:

```hcl
output "r2_secret_access_key" {
  value     = sha256(cloudflare_api_token.catalog_upload.value)
  sensitive = true
}
```

## Sealing GitHub Actions secrets

`scripts/seal.py` is a tiny libsodium sealer invoked through an `external` data source. It reads `{public_key, plaintext}` JSON from stdin and writes `{ciphertext}` JSON to stdout. The ciphertext lands in `github_actions_secret.value_encrypted` and gets stored in OpenTofu state.

Two things follow from this design that are worth sitting with.

The first is that the plaintext never enters OpenTofu state at all. State only ever carries the sealed ciphertext, and that ciphertext is then wrapped in the AES-GCM envelope at the storage layer, which means there are three layers of defence between an attacker and the plaintext token values.

The second is that the seal itself is non-deterministic. libsodium's `crypto_box_seal` uses an ephemeral keypair on each call, so resealing the same plaintext produces different ciphertext. Left unmanaged, OpenTofu would see the difference as drift on every plan and try to re-upload all seven secrets even though nothing inside GitHub had actually changed.

We sidestep that with the `sealed_github_secret` module. Each instance carries a `terraform_data.plaintext_hash` resource holding `sha256(plaintext)`, and the matching `github_actions_secret.this` sets `lifecycle.ignore_changes = [value_encrypted]` (so non-deterministic ciphertext drift is invisible) and `lifecycle.replace_triggered_by = [terraform_data.plaintext_hash]` (so a real plaintext change triggers a destroy-then-create with a freshly-sealed value). The result: a steady-state plan shows zero changes when nothing has been rotated, and exactly one secret being replaced when one is. The recreate is destroy-then-create rather than update-in-place because GitHub's API has no "update sealed value" semantics; the gap is sub-second and only opens during a genuine rotation, so a workflow run colliding with it is vanishingly unlikely.

The `github_variable` module is the deliberately-thin counterpart for non-sensitive config. Variables are plaintext on GitHub's side, so they don't need sealing, the hash-rotation gate, or the `ignore_changes` dance — just a single `github_actions_variable` resource. The module exists for symmetry with `sealed_github_secret`: future readers see the same shape ("a workflow input is a module call") whether the input is sensitive or not.

## Running an apply

### Locally

`opentofu/infrastructure/.env` (gitignored) carries every variable the apply needs. `tenv` is the OpenTofu version manager already on the dev box; it pins the binary version per-project.

```bash
cd opentofu/infrastructure
set -a && source .env && set +a
~/.tenv/OpenTofu/1.11.6/tofu init
~/.tenv/OpenTofu/1.11.6/tofu plan      # always plan first
~/.tenv/OpenTofu/1.11.6/tofu apply
```

### In CI

OpenTofu runs as part of the catalog pipeline at `.github/workflows/build_catalog.yml`. The workflow has one main job (`build_and_apply`) that does everything in sequence on a single runner, plus a small trailing `unlock_on_failure` cleanup job that runs only when the main job didn't complete cleanly.

`build_and_apply` walks the catalog through these phases on a shared filesystem:

1. Download OFF, trim into 16 variants, build per-variant sqlite + FTS5 files, split into chunks under the 256 MiB cap, write per-variant manifests.
2. Enforce the 9.7 GiB upload ceiling against `$WORK/dbs` before any further work.
3. `tofu init` (which acquires the R2 lockfile via `use_lockfile = true`).
4. `tofu plan -out=tfplan`. The catalog module's `for_each` is `fileset(var.build_output_dir, ...)`, so the chunks the build step just produced are hashed in place and folded into the plan.
5. `tofu apply tfplan` — but only if the run's trigger is one of the apply paths described below.

The trigger map and the apply gate together decide what each run does:

| Event                                                   | Build + plan | Apply |
| ------------------------------------------------------- | :----------: | :---: |
| `push` to `main`                                        | yes          | yes   |
| `schedule` (Saturday 19:00 UTC, main only)              | yes          | yes   |
| `workflow_dispatch` on `main`                           | yes          | yes   |
| `pull_request` (catalog / opentofu / workflow paths)    | yes          | no    |

The PR path is the everyday review surface: the plan that runs on a PR is the reviewer's preview of what would happen on merge, and the merge button is the approval gate. The Saturday cron is the weekly content refresh — OFF publishes a new dump, the build pulls it down, and apply uploads only the chunks whose content has actually changed (each chunk is an `aws_s3_object`, so unchanged content produces no diff and no API call). Fork PRs skip the OpenTofu steps entirely, because `secrets.*` is not exposed to fork runs; the catalog build itself still validates schema, CSV, and build-script changes for contributors.

A workflow-level `concurrency: catalog-pipeline` group with `cancel-in-progress: false` serialises everything that runs inside Actions, so the cron and a manual dispatch can never race. PRs use a per-PR concurrency group with cancellation enabled, so a fix-up push cancels the in-flight plan for the previous SHA. The `unlock_on_failure` job joins the same `catalog-pipeline` group so it can't race a fresh push that started while this run was dying.

`tofu init`, `plan`, and `apply` all need `TF_VAR_state_passphrase` (because state encryption runs through `init`'s state-read path) and `TF_VAR_catalog_build_output_dir` (because the catalog module's `for_each` reads from there).

## Adding things

### A new Cloudflare resource

1. Add the resource to whichever `.tf` file fits its shape, or create a new one if it deserves its own surface.
2. If the resource produces a value that downstream workflows need (an API token, a bucket name, a zone id), expose it as an output on the `cloudflare` module and add it to the `secrets` map in `locals.tf` so it gets sealed and published as an Actions secret.
3. Open a PR. The PR run lands a plan in the workflow logs for review — that plan is the document you and the reviewer read. Once the PR merges to `main`, the post-merge run executes the same plan as an apply, with no separate approval click required: the merge itself is the approval gate.

### A new bootstrap secret

1. Add the secret to GitHub repo settings by hand.
2. Reference it in `.github/workflows/build_catalog.yml`'s `env` block on the relevant `init` / `plan` / `apply` step.
3. If it needs to be visible to OpenTofu as a variable, add a `variable "..."` block in `variables.tf` with `sensitive = true` and reference it as `var.name`.
4. Document it in the secrets matrix above.

### Bootstrapping from scratch

If you ever need to rebuild the OpenTofu side over from nothing:

1. **Cloudflare**, in the dashboard:
   - Create the bootstrap API token with the scopes described in `providers.tf` (zone management, R2 management, token mint and revoke).
   - Create the `opennutritracker-tf-state` R2 bucket. Mint bucket-scoped credentials. Note the account-scoped S3 endpoint URL.
2. **GitHub**, in repo settings:
   - Create a PAT with `repo` scope for the github provider.
   - Add all seven manually-managed secrets from the matrix above.
3. **Locally**:
   - Populate `opentofu/infrastructure/.env` (gitignored), or use `tofu.tfvars` if you prefer file-based variables.
   - `cd opentofu/infrastructure && tofu init && tofu apply`.

The first apply mints the downstream tokens, seals all seven Tofu-managed secrets into GitHub, and writes the encrypted state to R2. Subsequent applies see no drift unless a plaintext value has genuinely changed (a token rotation, a renamed bucket), thanks to the plaintext-hash trick described in the secrets section above.

## Common gotchas

- **The Cloudflare provider's resource shape changes between major versions.** The pinned constraint is `~> 5.0`. Read the provider release notes before bumping the pin; v5 changed several attribute names from v4.
- **Token values are write-once on Cloudflare's side.** If OpenTofu ever loses the value of an API token from state (state loss without a passphrase, an `import` without the `value` attribute, a `taint` followed by misconfigured replace), the only recovery is to delete the token in the dashboard and let OpenTofu mint a fresh one on the next apply. The seven Tofu-managed secrets re-seal automatically.
- **Cache-purge tokens are zone-scoped, not bucket-scoped.** Adding more zones requires a new permission group on the `cache_purge` token.
- **The bucket location is `WEUR`.** Changing it requires recreating the bucket. The catalog goes 404 from the moment R2 destroys the old bucket until the next weekly catalog build runs and repopulates the new one. Don't change it without a plan for the gap.
- **The cache rule references `cloudflare_r2_custom_domain.catalog.domain`** rather than a hard-coded hostname. If the custom domain ever changes the rule follows. If the domain gets deleted and recreated, the rule has to be applied through the same plan or the cache will briefly stop honouring the configured TTLs.

## Future improvements

Hardening that has been considered and deliberately deferred. Each entry explains the win, the trade-off, and how to implement when the project is ready.

### Environment-scoped GitHub Actions secrets

Today the seven Tofu-managed secrets are repo-level, which means any workflow in the repo with `GITHUB_TOKEN` access reads them. Migrating them to a named GitHub deployment environment (something like `catalog`) means only workflows that declare `environment: catalog` can read those values, and the environment itself can carry protection rules around branch restrictions, required reviewers, and wait timers.

The reason this hasn't already happened is that the boundary it adds only really lands once a malicious or compromised PR could plausibly add a workflow file and merge it. On a single-maintainer repo with a tight contributor surface, environment scoping is mostly cosmetic. It starts to matter when one of these is true: the repo begins accepting community PRs that touch workflow files; the secrets gain real production sensitivity (today the catalog-upload token can only overwrite a public-read bucket whose contents are republished from public OFF data weekly); or the project moves to a dual-branch model where `main` is the production branch and feature branches must be locked out of deploying. The third trigger is the natural moment to flip this on, since the real value of the change comes from the branch restriction.

When the time does come, the implementation lives in a new file `opentofu/infrastructure/environments.tf`:

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

The `sealed_github_secret` module would change from `github_actions_secret` to `github_actions_environment_secret`, threading the environment through:

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
opentofu/infrastructure/
  main.tf             ← composition: module.cloudflare + module.secret + module.variable
  tofu.tf             ← terraform { } block, R2 backend, state encryption
  providers.tf        ← provider "cloudflare" + provider "github"
  data.tf             ← github_actions_public_key data source
  variables.tf        ← input variables (account_id, zone_id, passphrase, ...)
  locals.tf           ← `local.secrets` and `local.config_variables` maps
  modules/
    cloudflare/       ← R2 bucket + custom domain + cache rule + tokens
      main.tf         ← required_providers
      r2.tf           ← bucket + custom domain
      cache.tf        ← zone-level cache rule
      tokens.tf       ← downstream Cloudflare API tokens
      variables.tf    ← module inputs (account_id, zone_id, cache TTLs)
      outputs.tf      ← bucket_name, custom_domain, r2_endpoint, ...
    sealed_github_secret/
      main.tf         ← per-secret seal + plaintext hash + secret resource
      variables.tf    ← module inputs (repository, secret_name, plaintext, ...)
    github_variable/
      main.tf         ← per-variable github_actions_variable resource
      variables.tf    ← module inputs (repository, variable_name, value)
  scripts/seal.py     ← libsodium sealer for github_actions_secret values
  tofu.tfvars.example ← template for variable values
  .env                ← (gitignored) local env vars for tofu apply
  .terraform/         ← (gitignored) provider plugins, backend stub
```

```text
.github/workflows/
  build_catalog.yml  ← end-to-end pipeline (build → plan → apply, single workflow)
                       the 16 catalog variants weekly
```
