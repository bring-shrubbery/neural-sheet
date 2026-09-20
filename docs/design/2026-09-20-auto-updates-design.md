# Automatic updates — design

Installed copies of NeuralSheet update themselves through Sparkle: on launch and
daily the app checks `https://neural-sheet.quassum.com/appcast.xml`; when a newer
release exists it shows Sparkle's standard dialog and, on "Install and Relaunch",
downloads the signed zip, verifies its EdDSA signature and Developer ID signature,
swaps the bundle and relaunches. The release workflow produces the feed.

## Update behaviour

- Sparkle 2 (2.10 or later, "Up to Next Major") added to the NeuralSheet target
  through Swift Package Manager by the maintainer in Xcode; the resulting
  `project.pbxproj` and `Package.resolved` changes are committed with the app
  change.
- One `SPUStandardUpdaterController(startingUpdater: true)` for the app's
  lifetime, owned by a `@MainActor @Observable final class Updates` in
  `app/NeuralSheet/App/Updates.swift`. It exposes `canCheckForUpdates` (mirrors
  the updater's KVO property) and `check()`.
- Sparkle's defaults apply: a check on launch and then every 24 hours
  (`SUScheduledCheckInterval` unset), a prompt with release notes and an
  Install button, "Automatically download and install" left to the user. The
  first-run "may I check automatically?" prompt is skipped by
  `SUEnableAutomaticChecks = YES`.
- The app is not sandboxed and keeps the hardened runtime, so no XPC services
  or extra entitlements are needed. Xcode signs the embedded `Sparkle.framework`
  with the app's identity; the release workflow's `codesign --verify --deep
  --strict` and notarization cover it.
- Info.plist keys, through a checked-in `app/Info.plist` (beside the Xcode
  project, outside the synchronized source folder so it is not copied as a
  resource) named by the `INFOPLIST_FILE` build setting and merged with the
  generated plist (`GENERATE_INFOPLIST_FILE` stays YES):
  - `SUFeedURL` = `https://neural-sheet.quassum.com/appcast.xml`
  - `SUPublicEDKey` = `xqg7Uv6Q+zw/+Is3ic5dSCOOc8Sa0WzuFVtCwpX3zWU=`
  - `SUEnableAutomaticChecks` = true

## What Sparkle replaces

The NeuralNote-inherited check (`UpdateCheck.swift`, the status-bar
`UpdateNotice`, `AppModel.updateNotice`, its expiry in the display-link tick,
the launch-time call in `MainView`) and `VersionCompare` in NeuralSheetCore are
removed. Sparkle carries its own "You're up to date" and "Update failed" dialogs.

- `AppModel` keeps the views' contract: `let updates = Updates()` and
  `func checkForUpdates()` (no `explicit:` parameter) that calls
  `updates.check()`.
- The app menu's "Check for Updates…" and Settings → General → "Check for
  updates" call `model.checkForUpdates()`; the menu item is disabled while
  `model.updates.canCheckForUpdates` is false (a check is already running).
- `AGENTS.md`'s list of deliberate departures gains: updates are Sparkle's
  dialogs, not the status-bar notice.

Copies of v1.0.0 and v1.0.1 in the wild have no Sparkle; they keep showing the
old notice with a link to the releases page. Every copy from the first Sparkle
release on updates in place.

## The feed

- Each release publishes `appcast.xml` as a release asset next to the DMG and
  the zip. `https://neural-sheet.quassum.com/appcast.xml` redirects to
  `https://github.com/bring-shrubbery/neural-sheet/releases/latest/download/appcast.xml`,
  so the feed always describes the newest release; Sparkle follows redirects.
- One `<item>` per feed: `<title>` = `NeuralSheet vX.Y.Z`, `<pubDate>` = the
  run's time in RFC 822, `<sparkle:version>` = the build number
  (`CURRENT_PROJECT_VERSION`, the run number, monotonic — this is what Sparkle
  compares), `<sparkle:shortVersionString>` = `X.Y.Z`,
  `<sparkle:minimumSystemVersion>` = `26.0`, `<sparkle:releaseNotesLink>` = the
  GitHub release page, `<enclosure>` with the versioned zip URL, its byte
  `length`, `type="application/octet-stream"` and `sparkle:edSignature`.
- `app/Scripts/release-appcast.sh` writes the file from arguments (version,
  build, tag, zip URL, length, signature, notes URL, date) and nothing else, so
  it is testable; its test checks the fields and `xmllint --noout` validity.

## Signing and secrets

- Key pair generated once with Sparkle's `generate_keys --account NeuralSheet`
  on the maintainer's Mac (done 2026-09-20). The private key lives in that login
  keychain and in the repository secret `SPARKLE_PRIVATE_KEY` (the
  `generate_keys -x` export, 44 bytes base64). Losing both means shipped copies
  can never update again; `docs/release.md` says so and how to back it up.
- The release workflow: the secrets check requires `SPARKLE_PRIVATE_KEY` like
  the other seven. After stapling the app and writing the zip, it downloads
  Sparkle's tools archive pinned by version and SHA-256
  (`Sparkle-2.10.0.tar.xz`,
  `c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c`), writes
  the key to `$RUNNER_TEMP`, runs `sign_update --ed-key-file <key> <zip>` and
  parses `sparkle:edSignature="…" length="…"`, then calls
  `release-appcast.sh` and adds `appcast.xml` to the artifact upload and the
  release assets. The key file is removed by the step's `trap`.
- The zip is the enclosure (not the DMG): it holds the stapled app, Sparkle
  extracts it natively, and it is already produced.

## Docs

- `docs/release.md`: a "Sparkle" section (what the feed is, the key, how to
  rotate it, what to do if a release ships without an appcast — re-run the
  workflow from the tag's artifacts is not possible; publish the next patch).
- `CHANGELOG.md` Unreleased: "Updates install from inside the app (Sparkle)".
- `web/README.md` already documents the redirect.

## Testing

- `release-appcast.sh` test script: fixed inputs → the exact fields present,
  `xmllint --noout` passes, an argument missing fails.
- `swift test` in NeuralSheetCore after removing `VersionCompare` and its
  tests; the app builds warning-free in Debug.
- Running the Debug app locally: Sparkle logs the feed fetch; "Check for
  Updates…" against the live feed reports "up to date" or, before the first
  Sparkle release exists, the 404 as a failed check (expected until the first
  appcast is published).
- End to end, by the maintainer: install the first Sparkle release (v1.0.2)
  from the DMG, then land any code change (v1.0.3); the installed app offers and
  installs the update.

## Out of scope

Delta updates, beta channels, serving the appcast from the website, update
statistics, Sparkle's system-profile reporting (off by default).
