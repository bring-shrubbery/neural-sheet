# Releasing NeuralSheet

Releases are automatic. Every push to `main` that passes CI and changes
something other than documentation is built, signed, notarized and published as
`NeuralSheet-vX.Y.Z-macos-arm64.dmg` (and a zip of the app) on a GitHub
release tagged `vX.Y.Z`, with the Audio Unit plugin beside it as
`NeuralSheet-Plugin-vX.Y.Z-macos-arm64.dmg` (see [Audio Unit](#audio-unit)).
Installed copies of the app update themselves from the `appcast.xml` each
release publishes (Sparkle); the plugin does not update itself.

## Versions

The workflow computes the version: the higher of `MARKETING_VERSION` in
`app/NeuralSheet.xcodeproj` and the last release tag with its patch bumped.

- A code push after `v1.0.3` releases `v1.0.4`. Nothing to do.
- To ship a minor or major, set `MARKETING_VERSION` (Xcode → target NeuralSheet →
  General → Version) to, say, `1.1.0` and push. That push releases `v1.1.0`; the
  next one `v1.1.1`. CI never edits the project file.
- The build number (`CURRENT_PROJECT_VERSION`) is the workflow run number.
- Pushes that change only `docs/`, `web/`, `*.md`, `LICENSE`, `NOTICE` or `.github/`
  (except the workflows) release nothing. The run says so in its log.

Add the release's notes to `CHANGELOG.md` yourself. The GitHub release body and
the notes the update prompt shows are the commit subjects since the previous tag
(`app/Scripts/release-notes.sh`): the `area:` prefix is dropped and `docs:`,
`web:` and `ci:` commits are left out, so write every subject as the line a user
will read. A `plugin:` subject reads "Audio Unit: …" and an `ios:` one "iOS: …",
so they are not taken for changes to the Mac app.

## One-time setup: the secrets

The workflow refuses to run without all eight of these repository secrets; an
unsigned build must never reach a release.

### 1. The Developer ID certificate

You need the `Developer ID Application: Quassum MB (6WCYZER5LX)` certificate
*with its private key* on the Mac you export from (`security find-identity -v
-p codesigning` lists it).

1. Keychain Access → My Certificates → right-click the certificate → Export.
   Choose `.p12`, set a password, save as `developer-id.p12`.
2. Encode and store it, then delete the file:

```sh
gh secret set MACOS_CERTIFICATE_P12 < <(base64 -i developer-id.p12)
gh secret set MACOS_CERTIFICATE_PASSWORD        # paste the .p12 password
gh secret set MACOS_SIGNING_IDENTITY --body "Developer ID Application: Quassum MB (6WCYZER5LX)"
gh secret set APPLE_TEAM_ID --body 6WCYZER5LX
rm developer-id.p12
```

### 2. The App Store Connect API key (for notarization)

1. https://appstoreconnect.apple.com → Users and Access → Integrations →
   App Store Connect API → Team Keys → **Generate API Key**.
   Name it `NeuralSheet CI`, access **Developer**.
2. Download the `.p8` (only offered once) and note the **Key ID** on that row
   and the **Issuer ID** above the table.
3. Store them, then delete the file:

```sh
gh secret set ASC_API_KEY_P8 < AuthKey_XXXXXXXXXX.p8
gh secret set ASC_API_KEY_ID --body XXXXXXXXXX
gh secret set ASC_API_ISSUER_ID --body 00000000-0000-0000-0000-000000000000
rm AuthKey_XXXXXXXXXX.p8
```

`gh secret list` should now show all eight names.

### 3. Sparkle (in-app updates)

Every release also publishes `appcast.xml`, the feed installed copies read through
`https://neural-sheet.quassum.com/appcast.xml` (a redirect to the latest release's
asset). The zip is signed with an EdDSA key so the app accepts only our builds.

The key pair was generated on 2026-09-20 with Sparkle's
`generate_keys --account NeuralSheet`. The private key lives in the login keychain
of the Mac that ran it (Keychain Access → search "sparkle-project.org", account
`NeuralSheet`) and in the repository secret `SPARKLE_PRIVATE_KEY`. **Losing both
means no installed copy can ever update again.** Back it up once:
`generate_keys --account NeuralSheet -x sparkle-neuralsheet.key` and keep the file
somewhere safe, off this machine. To set it in the repository:
`gh secret set SPARKLE_PRIVATE_KEY < sparkle-neuralsheet.key`, then delete the file.
The matching public key is `SUPublicEDKey` in `app/Info.plist`.

If the key is lost: generate a new pair, put the new public key in `app/Info.plist`,
set the new secret, and tell users to download the next release by hand — copies
with the old key will report an improperly signed update on every check and never
update on their own.

To rotate the key: ship one release signed with the old key whose Info.plist
carries the new public key, then switch `SPARKLE_PRIVATE_KEY`; copies that skip
that release are stranded, so avoid rotating.

An optional ninth secret is `CF_DEPLOY_HOOK_URL`, the Cloudflare Workers Builds deploy
hook for the website (see `web/README.md`). Without it the release still publishes, with a
warning, and the website keeps offering the previous version until it is rebuilt.

### 4. The first release

Push a code change to `main`, or run the Release workflow from the Actions tab
with **Run workflow** (only `main` is honoured). The `Decide the version` job
prints the version and the changed paths; `Build and publish` takes about
fifteen minutes, most of it the stem separation library's CMake build the
first time and Apple's notarization queue. The release appears at
https://github.com/bring-shrubbery/neural-sheet/releases.

Until the eight secrets exist, every code push produces one red Release run
that stops at the secrets check; that is expected. Quick successive pushes
queue; GitHub keeps one pending run per queue, so a run marked *cancelled* is
not a failure — the next run covers its commits.

### 5. The App Group (models and settings)

The app keeps its models and `global.settings` in the App Group container
`~/Library/Group Containers/6WCYZER5LX.com.quassum.neuralsheet`, which the Audio
Unit plugin's sandboxed extension reads too (Audio Unit design §2). Both
entitlements files name the group, and the Archive step signs the app with
`NeuralSheet/NeuralSheet.entitlements`, so nothing needs adding.

The group is prefixed with the team ID on purpose: macOS admits a
team-prefixed group on the Developer ID signature alone, while a `group.` group
needs a provisioning profile naming it, which this workflow does not embed.
Renaming the group to `group.…` means registering it in the developer account
and embedding a Developer ID provisioning profile in the app and the plugin;
without the profile, macOS keeps the app out of the container. A copy the
system keeps out (signed ad hoc or by another team) falls back to
`~/Library/NeuralSheet/models` and its settings there.

## When it fails

- **missing repository secrets** — the first step names them; add and re-run.
- **notarization ended with status Invalid** — the step prints Apple's log;
  the usual causes are a binary without the hardened runtime or a missing
  timestamp. Both are set by the project and the workflow, so look at what
  changed. A third cause is a Sparkle helper that lost its Developer ID
  signature; the Archive step re-signs them and stops with `is not Developer ID
  signed` if that fails.
- **create-dmg could not apply the window layout** — a warning only; the
  image is valid, it just lacks the icon arrangement.
- **Sign the update and write the appcast failed** — the zip is notarized but not
  yet released. Usually `SPARKLE_PRIVATE_KEY` is missing or not the exported key
  (44 base64 characters). Fix the secret and re-run; nothing was tagged.
- **The tag exists** — a previous run tagged but failed to publish. The notarized
  DMG and zip are attached to that run as artifacts (the run page, *Artifacts*), the
  plugin's DMG as an artifact of its own. Publish all four — the DMG, the zip, the
  plugin's DMG **and `appcast.xml`** — or installed copies will find no feed until
  the next release. Either publish them by hand as
  release `vX.Y.Z`, or delete the tag
  (`git push origin :refs/tags/vX.Y.Z`) and the release if one was created,
  then re-run. Re-running without deleting the tag prints "no code changes
  since vX.Y.Z" and releases nothing.
- **check-version.sh: plugin/project.yml MARKETING_VERSION is …** — the app's
  `MARKETING_VERSION` was raised without the plugin's. Set `MARKETING_VERSION` and the
  component's `version` in `plugin/project.yml`, run `make -C plugin project`, commit.
- **does not fit the component's version integer** — the release's minor or patch
  passed 255; raise `MARKETING_VERSION` (app and plugin) to the next minor.
- **the plugin's notarization ended with status Invalid**, or *Package the Audio Unit
  plugin* failed — the app is notarized but nothing is tagged yet; fix and re-run, as
  for the appcast step.
- **Rebuild the website failed** — the release is already published; only the site's
  download button is stale. Re-run the build from the Worker's *Builds* page in the
  Cloudflare dashboard (re-running the Release workflow prints "no code changes" and
  does nothing).

## Audio Unit

The plugin (`plugin/`, design: `docs/design/2026-10-03-audio-unit-design.md`) is
released by the same run as the app, from the same commit, with the same version.

### What ships

`NeuralSheet-Plugin-vX.Y.Z-macos-arm64.dmg` holds `NeuralSheet Plugin.app`, a small
container whose only jobs are to carry the extension and to show one window with the
version and an Open NeuralSheet button, and a link to Applications. Inside it,
`Contents/PlugIns/NeuralSheetAU.appex` is the AUv3 effect (`aufx` / `NSht` / `Qssm`,
listed by hosts as "Quassum: NeuralSheet"). There is no zip and no appcast: the plugin
does not update itself; the user installs each release's image over the last one.

### How it is built and signed

After the app's appcast is written, the job runs `plugin/Scripts/package.sh`, which:

1. runs `plugin/Scripts/check-version.sh`: `MARKETING_VERSION` in `plugin/project.yml`
   (and the generated project) must be the app's, and the component's integer
   `version` must be that packed as `major << 16 | minor << 8 | patch`. CI runs the
   same check in the plugin job (`Scripts/validate.sh`), so a drift fails before a
   release. Raise both with the app's `MARKETING_VERSION` (`make -C plugin project`).
2. archives the committed `plugin/NeuralSheet-Plugin.xcodeproj` (nothing is
   regenerated) with the app's flags: arm64, Manual signing with
   `MACOS_SIGNING_IDENTITY`, `MARKETING_VERSION` the release's, the build number the
   run number;
3. writes the release's packed version into the built extension's `AudioComponents`
   (an integer cannot be a build setting; hosts compare it to decide whether a cached
   scan is stale) and signs the extension and then the app again, hardened runtime,
   secure timestamp, keeping the entitlements Xcode signed them with;
4. checks both bundles' versions, the Developer ID authority, the runtime, the
   timestamp, the App Group on both and the sandbox on the extension, and
   `codesign --verify --deep --strict`;
5. builds the disk image with `create-dmg` (as the app's, retrying without the Finder
   layout) and signs it.

*Notarize and staple the plugin* then submits the image with the same App Store
Connect key, staples it and checks it with `spctl`. The image is kept as a run
artifact of its own (`NeuralSheet-Plugin-vX.Y.Z-macos-arm64`) and attached to the
release. No secret is added: the plugin uses the app's certificate and key.

On a Mac with the Developer ID certificate the same steps run without a release, up
to notarization:

```sh
cd plugin
Scripts/package.sh --version 1.1.1 --build 1 \
  --identity "Developer ID Application: Quassum MB (6WCYZER5LX)" --team 6WCYZER5LX \
  --out /tmp/neuralsheet-plugin
```

`spctl` rejects that image as "Unnotarized Developer ID", as it should. Xcode registers
the archive's copy of the extension with the system; unregister it afterwards
(`pluginkit -r <…>/ArchiveIntermediates/…/NeuralSheetAU.appex`) so hosts do not load a
copy with a higher version than your development build.

### The App Group

The extension is sandboxed, as every app extension must be, and reads the models and
`global.settings` from the App Group container the app keeps them in (§5 above). Both
targets' entitlements name `6WCYZER5LX.com.quassum.neuralsheet`; because the group is
team-prefixed, the Developer ID signature alone admits the extension, with no
provisioning profile, exactly as for the app. A copy signed by anyone else cannot read
the group and finds no models.

### Validation in CI

The `plugin` job in `ci.yml` builds the project warning-free, runs `PluginCoreTests`,
and runs `plugin/Scripts/validate.sh`: the version check, a Release build signed ad hoc,
`pluginkit -a`, `auval -v aufx NSht Qssm`, `pluginkit -r`. auval must pass with no
warning but the one the system's version 3 bridge prints for every AUv3 (the
deprecated CurrentPreset property). A red plugin job keeps CI red, so nothing releases.

Hosts are not driven in CI. `plugin/HOSTS.md` is the maintainer's checklist for Logic
Pro, GarageBand, Ableton Live, Reaper and MainStage; run it against a release's image
and file what fails.

### Installing and removing it (what to tell users)

1. Install NeuralSheet and download a model in NeuralSheet → Settings → Model; the
   plugin downloads nothing and uses the app's models.
2. Open `NeuralSheet-Plugin-vX.Y.Z-macos-arm64.dmg` and drag NeuralSheet Plugin into
   Applications.
3. Open NeuralSheet Plugin once. That registers the extension; the window can be
   closed. Hosts that cache their scan (Logic Pro, Live, Reaper) may need a rescan.
4. In the host, insert "Quassum: NeuralSheet" as an effect on an audio track.

To update, install the new image over the old app and open it once. To remove it, quit
the hosts, move `/Applications/NeuralSheet Plugin.app` to the Bin and empty it; the
system drops the extension with its app (hosts forget it at their next scan). The
extension's sandbox container, `~/Library/Containers/com.quassum.neuralsheet.plugin.au`,
can be deleted too. The App Group container is the app's and stays.

## iOS (TestFlight)

`.github/workflows/ios-testflight.yml` archives NeuralSheet for iPhone and iPad on
every push to `main` that changes something other than `docs/`, `web/`, `*.md`,
`LICENSE` or `NOTICE`, and on **Run workflow** from the Actions tab. It builds the
committed `ios/NeuralSheet-iOS.xcodeproj` (nothing is regenerated), checks that the
archive holds the app and its widget extension, and fails on warnings in our sources.

With all eight secrets below present, and only on `main`, it also signs the archive
for App Store distribution, exports `NeuralSheet.ipa` and uploads it to App Store
Connect with `xcrun altool --upload-app`. Without them (a fork, or before they are
added) it archives unsigned, uploads nothing and stays green; a partial set is a
warning naming the missing ones.

The upload is all the workflow does. Giving a build to testers (TestFlight → a group →
add the build), answering export compliance, and submitting a version for App Store
review are the maintainer's actions in App Store Connect.

### Versions and build numbers

- The version is `MARKETING_VERSION` in `ios/project.yml` (both targets). To ship a
  new one, change it in both targets, run `make -C ios project`, and commit the spec
  and the project together. Once a version is released on the App Store, App Store
  Connect refuses further builds of it, so raise it then.
- The build number (`CURRENT_PROJECT_VERSION`) is this workflow's run number, set on
  the command line, so builds only climb. It is independent of the Mac's build
  number (the Release workflow's run). Re-running a run whose upload succeeded fails
  with a duplicate build number; start a new run instead.

### Signing settings

The `Release` configuration (the archive) of the app and the widget extension signs
by hand: `CODE_SIGN_STYLE = Manual`, `CODE_SIGN_IDENTITY = Apple Distribution`, and
`PROVISIONING_PROFILE_SPECIFIER` read from `NS_APP_STORE_PROFILE` and
`NS_WIDGETS_APP_STORE_PROFILE`. Their defaults are `NeuralSheet iOS App Store` and
`NeuralSheet iOS Widgets App Store`; the workflow overrides both with the names in
the installed profiles. `Debug` stays automatic, so local builds need only the team.

### One-time setup

Four secrets are the Mac release's and are reused as they are: `APPLE_TEAM_ID`,
`ASC_API_KEY_P8`, `ASC_API_KEY_ID` and `ASC_API_ISSUER_ID` (above). The key needs
**Developer** access or higher to upload builds, which the Mac's `NeuralSheet CI`
key has. Four are new:

| Secret | What it is |
| --- | --- |
| `APPLE_DIST_CERT_P12_BASE64` | The Apple Distribution certificate and its private key, `.p12`, base64 |
| `APPLE_DIST_CERT_PASSWORD` | That `.p12`'s password |
| `IOS_APP_PROFILE_BASE64` | The App Store Connect profile for `com.quassum.neuralsheet.ios`, base64 |
| `IOS_WIDGET_PROFILE_BASE64` | The App Store Connect profile for `com.quassum.neuralsheet.ios.widgets`, base64 |

1. **The app record.** App Store Connect → Apps → **+** → New App: platform iOS,
   name NeuralSheet, bundle ID `com.quassum.neuralsheet.ios`. Uploads fail until it
   exists. If the bundle ID is not offered, register it first (step 3).
2. **The distribution certificate.** Xcode → Settings → Accounts → the Quassum MB
   team → Manage Certificates → **+** → Apple Distribution. Then Keychain Access →
   My Certificates → `Apple Distribution: Quassum MB (6WCYZER5LX)` → Export as
   `.p12` with a password:

   ```sh
   gh secret set APPLE_DIST_CERT_P12_BASE64 < <(base64 -i distribution.p12)
   gh secret set APPLE_DIST_CERT_PASSWORD        # paste the .p12 password
   rm distribution.p12
   ```

3. **The identifiers.** https://developer.apple.com/account → Certificates,
   Identifiers & Profiles → Identifiers: `com.quassum.neuralsheet.ios` and
   `com.quassum.neuralsheet.ios.widgets` as explicit App IDs (Xcode's automatic
   signing may already have made them). No capabilities are needed.
4. **The profiles.** Profiles → **+** → Distribution → **App Store Connect**, the
   App ID, the certificate from step 2. Name them `NeuralSheet iOS App Store` and
   `NeuralSheet iOS Widgets App Store` (any name works; the workflow reads it from
   the file). Download both:

   ```sh
   gh secret set IOS_APP_PROFILE_BASE64 < <(base64 -i NeuralSheet_iOS_App_Store.mobileprovision)
   gh secret set IOS_WIDGET_PROFILE_BASE64 < <(base64 -i NeuralSheet_iOS_Widgets_App_Store.mobileprovision)
   ```

The certificate and the profiles expire after a year. Renew them the same way and
replace the secrets; a renewed certificate needs new profiles too.

### When it fails

- **missing repository secrets** (a warning) — the run archived unsigned; add the
  named secrets and run the workflow again.
- **not an Apple Distribution identity of team …** — the `.p12` holds another
  certificate (a Developer ID or Apple Development one) or lacks the private key.
- **profile … is for …, expected …** or **lists devices** — the profile secret holds
  the other target's profile, or an Ad Hoc or Development profile.
- **No profile for team … matching …** at archive or export — the profile was not
  made with the certificate in `APPLE_DIST_CERT_P12_BASE64`; regenerate it.
- **The bundle version must be higher than the previously uploaded version** — a
  re-run of an uploaded build; start a new run.
- **No suitable application records were found** — the app record (step 1) is missing.
- The build uploads but is **Missing Compliance** in TestFlight — answer the export
  compliance question for it in App Store Connect.
