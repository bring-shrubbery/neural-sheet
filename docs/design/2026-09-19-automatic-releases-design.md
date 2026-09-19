# Automatic patch releases — design

Every code change that lands on `main` and passes CI becomes a signed, notarized
`NeuralSheet-vX.Y.Z-macos-arm64.dmg` on a GitHub release, without anyone
pushing a tag. This replaces the tag-triggered `release.yml`.

## Trigger

- `release.yml` runs on `workflow_run` of the **CI** workflow, `types: [completed]`,
  `branches: [main]`, and exits at once unless `conclusion == 'success'`. CI is
  the gate: core tests passed, the app built warning-free.
- `workflow_dispatch` stays for manual re-runs of the same logic.
- Concurrency group `release`, `cancel-in-progress: false`: runs queue, so two
  close pushes cannot both compute the same version.
- The job checks out `github.event.workflow_run.head_sha` (not `main`, which may
  have moved on), with submodules.
- Docs-only changes do not release. The diff between the previous release tag
  (or, when there is none, the empty tree) and the built commit is filtered
  through `.github/release-ignore` (gitignore syntax): `docs/`, `*.md`,
  `.github/` except `.github/workflows/`, `LICENSE`, `NOTICE`. When every changed
  path is ignored, the job logs "no code changes since vA.B.C" and stops green.

## Versioning

`app/Scripts/release-version.sh` prints the version to build, computed from two
inputs and nothing else:

- `MARKETING_VERSION` in `app/NeuralSheet.xcodeproj/project.pbxproj` — the floor
  a maintainer sets by hand for a minor or major release.
- The highest tag matching strictly `v<int>.<int>.<int>` (so `v1.0.0-checkpoint`
  is ignored), from `git tag`.

Result: `max(pbxproj version, highest tag with patch + 1)`, semver-compared.
With no strict tag the result is the pbxproj version itself. Examples:

| pbxproj | tags               | release |
|---------|--------------------|---------|
| 1.0.0   | none               | v1.0.0  |
| 1.0.0   | v1.0.0             | v1.0.1  |
| 1.0.0   | v1.0.0, v1.0.9     | v1.0.10 |
| 1.1.0   | v1.0.9             | v1.1.0  |
| 1.0.0   | v1.1.2 (from above)| v1.1.3  |

The version is passed to `xcodebuild` as `MARKETING_VERSION=<x.y.z>` and
`CURRENT_PROJECT_VERSION=<github.run_number>`; `project.pbxproj` is never
committed to by CI, there is no bot commit and no workflow loop. The script also
accepts `--changed-since` to print the previous tag for the path filter, and is
runnable locally with a fake tag list for testing.

The tag `vX.Y.Z` is created by the workflow (annotated, message
`NeuralSheet vX.Y.Z`) on the built commit through the GitHub API, after the
notarized DMG exists and just before the release is published. If the tag
already exists the job fails rather than overwrite.

## Build, package, sign, notarize, publish

1. Newest Xcode on the `macos-26` runner; engine build cache as in CI.
2. Import the Developer ID certificate into a throwaway keychain (as today).
3. `xcodebuild archive`, Release, arm64, `CODE_SIGN_STYLE=Manual`, the Developer
   ID identity, hardened runtime (already on in the project).
4. `brew install create-dmg`; `create-dmg` builds
   `NeuralSheet-vX.Y.Z-macos-arm64.dmg` with the app and an *Applications*
   symlink laid out in the window, volume name `NeuralSheet vX.Y.Z`, volume
   icon taken from the app's icon.
5. `codesign --sign <identity> --timestamp` the DMG.
6. `xcrun notarytool submit <dmg> --key <p8> --key-id --issuer --wait`, then
   `xcrun stapler staple` the DMG. The app inside was notarized as part of the
   DMG submission; the DMG is what users download, so it is what is stapled.
7. `ditto -c -k --keepParent` the (stapled-inside-DMG) app to
   `NeuralSheet-vX.Y.Z-macos-arm64.zip` as a second asset.
8. Create the tag, then `softprops/action-gh-release` with both assets and
   `generate_release_notes: true`. Release name `NeuralSheet vX.Y.Z`.

Signing and notarization are required. If any of the secrets is missing the
job fails in its first step with a message naming the secret; nothing unsigned
is ever published.

## Secrets

| Secret                       | Value                                                        |
|------------------------------|--------------------------------------------------------------|
| `MACOS_CERTIFICATE_P12`      | base64 of the Developer ID Application `.p12` (cert + key)   |
| `MACOS_CERTIFICATE_PASSWORD` | the `.p12` password                                          |
| `MACOS_SIGNING_IDENTITY`     | `Developer ID Application: Quassum MB (6WCYZER5LX)`          |
| `APPLE_TEAM_ID`              | `6WCYZER5LX`                                                 |
| `ASC_API_KEY_P8`             | contents of the App Store Connect API key `.p8`              |
| `ASC_API_KEY_ID`             | its Key ID                                                   |
| `ASC_API_ISSUER_ID`          | the Issuer ID shown on the Integrations page                 |

An App Store Connect API key (team key, Developer role) is used instead of an
Apple-ID app-specific password: it is not tied to a personal Apple ID or its
two-factor state. `docs/release.md` walks a maintainer through creating each of
these and the `gh secret set` commands.

## Files

- `.github/workflows/release.yml` — rewritten.
- `.github/release-ignore` — the docs-only filter.
- `app/Scripts/release-version.sh` — version computation; tested locally.
- `docs/release.md` — maintainer setup and how minor/major releases are made.
- `AGENTS.md`, `CHANGELOG.md` — the release paragraph and an Unreleased entry.

## Testing

- `release-version.sh` is exercised locally with `RELEASE_TAGS` overriding
  `git tag` for each row of the table above, plus a bad tag list (`v1.0`,
  `v1.0.0-rc1`) that must be ignored.
- The path filter is exercised locally with `git diff --name-only` against a
  chosen range.
- `actionlint` on the workflow.
- The first real push after the secrets are set is the end-to-end test; the run
  log states the computed version and the notarization status.
