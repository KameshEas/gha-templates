# gha-templates

Centralized, reusable GitHub Actions workflows and composite actions for the KameshEas mobile app portfolio (Flutter + React Native/Expo).

Consuming repos call these via `uses: KameshEas/gha-templates/.github/workflows/<file>@v1` and never duplicate CI/release logic locally. Pin to a tag (`@v1`) rather than `@main` so a template change doesn't silently affect every app at once.

## Reusable workflows

### `flutter-ci.yml`
Analyze + test + coverage. No secrets required.

```yaml
jobs:
  ci:
    uses: KameshEas/gha-templates/.github/workflows/flutter-ci.yml@v1
    with:
      flutter-channel: stable
```

### `rn-expo-ci.yml`
Lint (`npm run lint`, if present) + typecheck (`tsc --noEmit`, if `tsconfig.json` exists) + test (`npm test`, if a test script is defined). No secrets required.

```yaml
jobs:
  ci:
    uses: KameshEas/gha-templates/.github/workflows/rn-expo-ci.yml@v1
```

### `flutter-release.yml`
Two separate moments, two separate purposes:

- **`pull_request`** (opened/updated, targeting `dev-branch` or `prod-branch`) → `test_code_quality` → `smoke_test_release_build` → `build_firebase_apk` → `deploy_firebase_distribution`. A disposable testing build for the reviewer — whatever version is currently in `pubspec.yaml` is fine, Firebase doesn't care and this build never ships.
- **`push`** (i.e. the PR merged) → `resolve_version` (if `enable-auto-versioning`) → `build_release_android` → Play Store deploy (internal on `dev-branch`, production on `prod-branch`). **This is the only point where the version advances** — PR-time Firebase builds intentionally don't touch it.

Each release channel (`enable-shorebird`, `enable-firebase-distribution`, `enable-play-store`) is off by default — an app only pays for (and only needs secrets for) the channels it enables. `enable-shorebird` here only controls whether `build_release_android` registers the release with Shorebird (`shorebird release android`, making it OTA-patchable later) — it does not create patches. See `flutter-shorebird-patch.yml` below for that.

**Fail-fast job order (PR path):** cheapest checks run first so a doomed PR build fails sooner, not after a full multi-arch build. `test_code_quality` (analyze/test) gates `smoke_test_release_build` (a single-ABI, minified `flutter build apk`, exercises the exact signing + R8/ProGuard pass the full Firebase build uses) which gates `build_firebase_apk`. Every job also has a `timeout-minutes` ceiling (10-35 min depending on the job) — this is a safety net against a genuine hang, not a duration SLA, so it's sized generously against slow/cold runners rather than tightly against expected run time.

**`env-file-keys`** — comma-separated names of environment variables to write into `.env` (e.g. `ONESIGNAL_APP_ID,SENTRY_DSN`). Use it for values in the SOPS secrets file that the app reads through `flutter_dotenv`: `decrypt-sops-secrets` only *exports* them to the job's environment and `ensure-env-file` only copies `.env.example`, so without this the app gets the placeholder (usually empty) value from `.env.example`. Requires `ensure-env-file: true`. Pass the same value to `flutter-shorebird-patch.yml`: `.env` is an asset and Shorebird patches can't change assets. The values end up readable inside the built app, so list only client-side keys (an App ID, a Sentry DSN), never secrets.

**`ensure-env-file: true`** — set this if the app uses `flutter_dotenv` with `.env` declared as a `pubspec.yaml` asset. Without it, every `flutter build`/`flutter test`/`shorebird` step fails with `No file or variants found for asset: .env` because CI has no real `.env` (it's gitignored). This threads through to every job that actually builds/tests the app; the deploy jobs don't need it since they only download prebuilt artifacts.

```yaml
jobs:
  release:
    uses: KameshEas/gha-templates/.github/workflows/flutter-release.yml@v1
    with:
      keystore-filename: everwith-release.jks
      artifact-prefix: everwith
      enable-shorebird: false
      enable-firebase-distribution: true
      enable-play-store: false
    secrets: inherit
```

#### Required secrets (always)
| Secret | Purpose |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | `base64 android/app/<keystore>.jks` |
| `ANDROID_KEY_ALIAS` | Key alias inside the keystore |
| `ANDROID_STORE_PASSWORD` | Keystore password |
| `ANDROID_KEY_PASSWORD` | Key password (falls back to store password if unset) |

#### Required only when `enable-shorebird: true`
| Secret | Purpose |
|---|---|
| `SHOREBIRD_TOKEN` | `shorebird login:ci` token |

#### Required only when `enable-firebase-distribution: true`
| Secret | Purpose |
|---|---|
| `FIREBASE_ANDROID_APP_ID` | Firebase Android app id |
| `FIREBASE_SERVICE_ACCOUNT_CREDENTIALS` | Service account JSON with App Distribution role |
| `FIREBASE_DISTRIBUTION_GROUPS` | Optional tester group(s) |

#### Required only when `enable-play-store: true`
| Secret | Purpose |
|---|---|
| `GCLOUD_SERVICE_ACCOUNT_CREDENTIALS` | Service account JSON with Play Console API access |
| `PACKAGE_NAME` | Android applicationId, e.g. `com.aspiredesignovation.everwith` |

Non-sensitive identifiers (`android-application-id`, `keystore-filename`, `artifact-prefix`, branch names, `play-track`) are passed as workflow `with:` inputs — set them as repo/org [Variables](https://docs.github.com/actions/learn-github-actions/variables) (`${{ vars.X }}`) in the caller workflow if you don't want them literal in the YAML.

**First Play Store deploy caveat:** `fastlane supply` can only *update* an app already listed in Play Console — it cannot create one. The first release for any new app must be uploaded manually through the Play Console before `enable-play-store: true` is turned on.

#### Optional: auto-incrementing version + build number (`enable-auto-versioning: true`)
Instead of reading `--build-name`/`--build-number` from `pubspec.yaml`, resolve and auto-advance them from two repo [Variables](https://docs.github.com/actions/learn-github-actions/variables) each release:

- Build number: `+1` every release.
- Version (`MAJOR.MINOR.PATCH`): patch `+1`, rolling into minor after **10** and minor into major after **9** — e.g. `1.0.1 → … → 1.0.10 → 1.1.0 → … → 1.9.10 → 2.0.0`.

```yaml
with:
  enable-auto-versioning: true
  # version-variable / build-number-variable default to ANDROID_VERSION / ANDROID_BUILD_NUMBER
secrets: inherit
```

Requires `secrets.VARS_PAT` — a **fine-grained PAT** with **Variables: Read and write** on the repo (the automatic `GITHUB_TOKEN` is explicitly blocked from managing Actions Variables, even with `actions: write` permission). Bootstrap the two Variables to the app's current version/build number before first use, or the action will bootstrap them from `pubspec.yaml` itself on first run — either way, once enabled, `pubspec.yaml`'s `version:` line is no longer authoritative; check the `ANDROID_VERSION`/`ANDROID_BUILD_NUMBER` repo Variables for the real shipped version.

#### Optional: sourcing secrets from an encrypted file instead of GitHub Secrets (`enable-sops-secrets: true`)
Instead of setting `ANDROID_KEYSTORE_BASE64`/`SHOREBIRD_TOKEN`/`FIREBASE_*`/`GCLOUD_*`/`PACKAGE_NAME` individually through the GitHub Secrets UI, source them all from one [SOPS](https://github.com/getsops/sops)-encrypted `.env` file checked into a dedicated repo (`KameshEas/ci-secrets` by default). The file is ciphertext either way, but **`ci-secrets` is private**, so every consuming repo also needs read access to it.

```yaml
with:
  enable-sops-secrets: true
  sops-secrets-file: cashlyze.env   # sops-secrets-repo defaults to KameshEas/ci-secrets
secrets:
  SOPS_AGE_KEY: ${{ secrets.SOPS_AGE_KEY }}                     # decrypts the file
  CI_SECRETS_REPO_TOKEN: ${{ secrets.CI_SECRETS_REPO_TOKEN }}   # lets this repo's job check out the private ci-secrets repo
```

(`secrets: inherit` covers both automatically once they exist as real secrets on the calling repo — no need to name them individually as above unless you're passing secrets selectively.)

`CI_SECRETS_REPO_TOKEN` is a **fine-grained PAT** with **Contents: Read** on `ci-secrets` only — the job's own `GITHUB_TOKEN` can't check out a different repo, private or not, even under the same account. Same token value can be reused across every consuming app repo, same pattern as `VARS_PAT`.

Each job that builds/deploys decrypts the file at the start of the job (masking every value in the log) and exports it into the job's `env`; if `enable-sops-secrets` is left `false` (the default), those same jobs fall back to reading `secrets.*` exactly as before — the two sources are interchangeable per-app. See `ci-secrets`' own README for how to add/edit/rotate encrypted files.

### `flutter-shorebird-patch.yml`
Ships a Shorebird OTA patch to an already-released version — **`workflow_dispatch`-only, never automatic.** Shorebird can only patch Dart-only changes (no native code, no new plugin with native bindings, no asset changes — those need a full `flutter-release.yml` release instead), and that's a judgment call only a human can make per-change, so this is deliberately not inferred from git state or wired into any push/PR trigger.

```yaml
# e.g. an app repo's own .github/workflows/shorebird-patch.yml
on:
  workflow_dispatch:
    inputs:
      release-version:
        description: 'Exact release to patch, e.g. 1.0.6+18. Leave empty to patch the current live version.'
        required: false
        type: string
jobs:
  patch:
    uses: KameshEas/gha-templates/.github/workflows/flutter-shorebird-patch.yml@v1
    with:
      release-version: ${{ inputs.release-version }}
      enable-sops-secrets: true
      sops-secrets-file: cashlyze.env
    secrets: inherit
```

Trigger it from the Actions tab → Shorebird Patch → Run workflow. Leave `release-version` empty to target whatever's currently in the `ANDROID_VERSION`/`ANDROID_BUILD_NUMBER` repo Variables (the most recently shipped release); pass it explicitly (`1.0.6+18`) to patch an older still-live release instead. Requires `secrets.VARS_PAT` only when `release-version` is left empty (to look up the current version).

#### Per-app quirks you may need to opt into
Two `flutter-release.yml` inputs exist specifically because not every app's repo looks the same — both default `false` so they're opt-in per app, not global behavior:

- **`no-tree-shake-icons: true`** — set this if the app has non-constant `IconData` lookups (icon values computed at runtime, e.g. from an enum rather than a literal). Flutter's icon tree-shaker can't resolve those at compile time and the release build fails outright without `--no-tree-shake-icons`. DayZen needs this (see its own `CLAUDE.md` "Known Issues #1"); Cashlyze doesn't.
- **`enable-google-services-json: true`** + `secrets.GOOGLE_SERVICES_JSON` (or the SOPS-encrypted `GOOGLE_SERVICES_JSON` field) — set this if `android/app/google-services.json` is gitignored rather than committed. The Google Services Gradle plugin fails the build outright if the file isn't present at all, and CI obviously doesn't have a gitignored file. Cashlyze commits its copy to git, so doesn't need this; DayZen and EverWith (both gitignore it) do.

**`test-continue-on-error`** (default `true`, opposite polarity from the two above) — `test_code_quality`'s `flutter test` step is non-blocking by default so an incomplete/flaky suite doesn't stop the smoke build, Firebase distribution, or release. Set it to `false` per-app once that app's test suite is trustworthy enough to gate the pipeline on it.

## Composite actions

- `setup-flutter` — installs JDK 17, restores pub/gradle caches, runs `flutter pub get`. `ensure-env-file: true` opt-in for apps using `flutter_dotenv`.
- `write-env-file` — copies the environment variables named in `keys` (comma-separated) into `.env`, replacing any empty placeholder copied from `.env.example`. Only the named variables are written, so signing keys and credentials never end up in the app. Values must be single-line. The script is inline in `action.yml` (a script file beside it isn't reachable from container jobs, where `github.action_path` points at the host path), and `bash test.sh` in that folder tests exactly that code. Used internally via the `env-file-keys` input below.
- `decode-android-keystore` — decodes a base64 keystore to `android/app/<keystore-filename>` and exports `ANDROID_KEYSTORE_PATH`/`ANDROID_KEY_ALIAS`/`ANDROID_KEYSTORE_PASSWORD`/`ANDROID_KEY_PASSWORD` env vars for Gradle signing.
- `setup-node-expo` — Node + npm ci for RN/Expo repos.
- `resolve-version` — reads/advances the `ANDROID_VERSION`/`ANDROID_BUILD_NUMBER` repo Variables per the odometer rule above and persists the new values via the GitHub API (curl, not the `gh` CLI, so it works in minimal build containers). Used internally by `flutter-release.yml` when `enable-auto-versioning: true`.
- `decrypt-sops-secrets` — checks out one `.env` file from a `ci-secrets`-style repo, decrypts it with `sops`/`age`, masks every value, and exports it into `GITHUB_ENV`. Used internally by `flutter-release.yml` when `enable-sops-secrets: true`.
