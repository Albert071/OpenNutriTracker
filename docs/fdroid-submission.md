# F-Droid submission

Tracking GitHub issue: [#126](https://github.com/simonoppowa/OpenNutriTracker/issues/126).

This document walks through getting OpenNutriTracker listed on
[F-Droid](https://f-droid.org/). The work is split between this repository (the
build recipe, the stub `.env`, the README badge) and the upstream
`fdroiddata` repository, which is where the metadata actually has to land.

## What lives where

- `metadata/net.simonoppowa.OpenNutriTracker.yml` — the F-Droid build recipe in
  the format `fdroiddata` expects. Kept in our repo so it travels with the
  source; copied into `fdroiddata` at submission time.
- `.env.fdroid` — a stub set of env vars so the `envied` code generator can run
  in a clean container without access to the maintainer's secrets.
- `fastlane/metadata/android/<locale>/` — title, descriptions, screenshots,
  changelogs. F-Droid reads these from the source tree at build time, so the
  files we already keep for Play Store metadata double up here.

## Submitting to fdroiddata

The upstream repository is `https://gitlab.com/fdroid/fdroiddata`. Submissions
are merge requests against `master`.

1. Fork `https://gitlab.com/fdroid/fdroiddata` to your GitLab account.
2. Clone the fork and create a branch:

   ```sh
   git clone git@gitlab.com:<your-user>/fdroiddata.git
   cd fdroiddata
   git checkout -b add-opennutritracker
   ```

3. Copy the recipe across from this repo:

   ```sh
   cp <opennutritracker>/metadata/net.simonoppowa.OpenNutriTracker.yml \
      metadata/net.simonoppowa.OpenNutriTracker.yml
   ```

4. Validate locally with the `fdroidserver` tools (install via `pipx install
   fdroidserver` or your package manager):

   ```sh
   fdroid readmeta
   fdroid lint net.simonoppowa.OpenNutriTracker
   ```

   `readmeta` parses every YAML file in `metadata/` and surfaces structural
   problems. `lint` checks our package specifically: required fields, license
   identifier, anti-feature wording, URL reachability.

5. Optionally do a dry-run build inside F-Droid's build container:

   ```sh
   fdroid build -v -l net.simonoppowa.OpenNutriTracker
   ```

   This is slow (it provisions a clean VM and runs the full Flutter toolchain)
   but it catches missing system packages and `prebuild` failures before the MR
   reviewers see them.

6. Open a merge request against `fdroiddata`. The reviewers will look at the
   recipe, run their own build, and either merge or leave feedback.

## Build infrastructure constraints

F-Droid builds run in a clean container with no access to the maintainer's
machine. The recipe has to handle the parts our normal local flow takes for
granted.

- **Network during compile.** Gradle dependencies fetched through F-Droid's
  Maven mirrors are fine. Anything else — `pub get` reaching out to `pub.dev`,
  generated code that hits a remote API at build time — is permitted only in
  the `prebuild` step, which runs before the build sandbox locks down network
  access. Our `prebuild` does `flutter pub get` and `dart run build_runner
  build`, both of which fit that model.
- **No secrets.** The maintainer's `.env` is not available. We commit
  `.env.fdroid` with empty placeholder values and the recipe's `prebuild`
  copies it into place before `build_runner` runs. The `envied` package then
  generates an `env.g.dart` whose obfuscated constants are all empty strings,
  which is harmless for the F-Droid build because none of those keys are
  required for the core app to function.
- **JDK version.** F-Droid's default builder uses an older JDK than the one
  Flutter 3.x expects. The `sudo` block installs `openjdk-17-jdk-headless`
  before the build starts.
- **Reproducibility.** F-Droid prefers reproducible builds, which Flutter does
  not currently guarantee out of the box. This is acceptable for an initial
  listing — F-Droid will fall back to signing with its own key — but reviewers
  may comment on it.

## Anti-features

OpenNutriTracker does not need any anti-feature tags as of this submission.

- **`NonFreeNet`** — does not apply. Open Food Facts is open-licensed and
  served from `world.openfoodfacts.org`. The Supabase FDC mirror serves USDA
  Food Data Central data, which is U.S. public domain.
- **`NonFreeAssets`** — does not apply. All bundled assets are GPL-3.0-or-later
  alongside the source.
- **`Tracking`** — does not apply by default. Sentry crash reporting is
  off-by-default and only initialises in release builds when the user opts in
  during onboarding. The F-Droid build ships with an empty `SENTRY_DNS`, which
  disables Sentry entirely.

If a reviewer disagrees about Sentry, the cleanest path is probably to add a
build flavour that excludes the `sentry_flutter` package on F-Droid builds.
Worth waiting for the conversation before pre-emptively gutting it.

## Metadata gaps to address before submission

The audit at the time of this PR turned up:

- **No localized metadata.** `fastlane/metadata/android/` only contains
  `en-US/`. Adding `de/`, `cs/`, `it/`, `pl/`, `tr/`, `uk/`, `zh/` to mirror
  the ARB translations would let F-Droid serve a translated listing.
- **Feature graphic is the wrong size.** F-Droid (and Google Play) expect
  1024×500 PNG; the current `images/featureGraphic.png` is 512×250. F-Droid
  may scale it up acceptably, but a fresh export at the target size would be
  better.
- **Only one changelog file.** `fastlane/metadata/android/en-US/changelogs/`
  contains `12.txt` from an early release. F-Droid will list whichever
  changelog file matches the `versionCode` it's building. Adding a changelog
  per recent release would give users something to read in the F-Droid client.
- **Screenshots are English only.** `phoneScreenshots/` only contains
  `*_en-US.png`. Localized screenshots are a nice-to-have rather than a
  blocker.

None of these block the initial listing. They are quality-of-life items the
maintainer can add over time.

## After the MR merges

- Update `README.md` to swap the F-Droid badge from the `TODO` placeholder to
  the live link.
- Tag releases as `v<version>` (we already do this on the GitHub side). F-Droid
  is configured with `UpdateCheckMode: Tags`, so new releases will be picked
  up automatically.
- Each new release needs a `fastlane/metadata/android/en-US/changelogs/<versionCode>.txt`
  file. Adding it to the develop-to-main release checklist would keep things
  tidy.
