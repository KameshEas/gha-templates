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
Version-gated Android build → optional Shorebird OTA release/patch → optional Firebase App Distribution → optional Google Play Console deploy (internal on `dev-branch`, production on `prod-branch`). Each release channel is off by default — an app only pays for (and only needs secrets for) the channels it enables.

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

## Composite actions

- `setup-flutter` — installs JDK 17, restores pub/gradle caches, runs `flutter pub get`. `ensure-env-file: true` opt-in for apps using `flutter_dotenv`.
- `decode-android-keystore` — decodes a base64 keystore to `android/app/<keystore-filename>` and exports `ANDROID_KEYSTORE_PATH`/`ANDROID_KEY_ALIAS`/`ANDROID_KEYSTORE_PASSWORD`/`ANDROID_KEY_PASSWORD` env vars for Gradle signing.
- `setup-node-expo` — Node + npm ci for RN/Expo repos.
- `resolve-version` — reads/advances the `ANDROID_VERSION`/`ANDROID_BUILD_NUMBER` repo Variables per the odometer rule above and persists the new values via the GitHub API (curl, not the `gh` CLI, so it works in minimal build containers). Used internally by `flutter-release.yml` when `enable-auto-versioning: true`.
