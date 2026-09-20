# Releasing NeuralSheet

Releases are automatic. Every push to `main` that passes CI and changes
something other than documentation is built, signed, notarized and published as
`NeuralSheet-vX.Y.Z-macos-arm64.dmg` (and a zip of the app) on a GitHub
release tagged `vX.Y.Z`. The in-app update check reads that release's tag.

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

Add the release's notes to `CHANGELOG.md` yourself; the GitHub release body is
generated from the commits.

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

### Sparkle (in-app updates)

Every release also publishes `appcast.xml`, the feed installed copies read through
`https://neural-sheet.quassum.com/appcast.xml` (a redirect to the latest release's
asset). The zip is signed with an EdDSA key so the app accepts only our builds.

The key pair was generated on 2026-09-20 with Sparkle's
`generate_keys --account NeuralSheet`. The private key lives in the login keychain
of the Mac that ran it (Keychain Access → search "sparkle-project.org", account
`NeuralSheet`) and in the repository secret `SPARKLE_PRIVATE_KEY`. **Losing both
means no installed copy can ever update again.** Back it up once:
`generate_keys --account NeuralSheet -x sparkle-neuralsheet.key` and keep the file
somewhere safe, off this machine. The matching public key is `SUPublicEDKey` in
`app/Info.plist`.

To rotate the key: ship one release signed with the old key whose Info.plist
carries the new public key, then switch `SPARKLE_PRIVATE_KEY`; copies that skip
that release are stranded, so avoid rotating.

An optional ninth secret is `CF_DEPLOY_HOOK_URL`, the Cloudflare Workers Builds deploy
hook for the website (see `web/README.md`). Without it the release still publishes, with a
warning, and the website keeps offering the previous version until it is rebuilt.

### 3. The first release

Push a code change to `main`, or run the Release workflow from the Actions tab
with **Run workflow** (only `main` is honoured). The `Decide the version` job
prints the version and the changed paths; `Build and publish` takes about
fifteen minutes, most of it the engine build the first time and Apple's
notarization queue. The release appears at
https://github.com/bring-shrubbery/neural-sheet/releases.

Until the seven secrets exist, every code push produces one red Release run
that stops at the secrets check; that is expected. Quick successive pushes
queue; GitHub keeps one pending run per queue, so a run marked *cancelled* is
not a failure — the next run covers its commits.

## When it fails

- **missing repository secrets** — the first step names them; add and re-run.
- **notarization ended with status Invalid** — the step prints Apple's log;
  the usual causes are a binary without the hardened runtime or a missing
  timestamp. Both are set by the project and the workflow, so look at what
  changed.
- **create-dmg could not apply the window layout** — a warning only; the
  image is valid, it just lacks the icon arrangement.
- **Sign the update and write the appcast failed** — the zip is notarized but not
  yet released. Usually `SPARKLE_PRIVATE_KEY` is missing or not the exported key
  (44 base64 characters). Fix the secret and re-run; nothing was tagged.
- **The tag exists** — a previous run tagged but failed to publish. The notarized
  DMG and zip are attached to that run as artifacts (the run page, *Artifacts*).
  Either publish them by hand as release `vX.Y.Z`, or delete the tag
  (`git push origin :refs/tags/vX.Y.Z`) and the release if one was created,
  then re-run. Re-running without deleting the tag prints "no code changes
  since vX.Y.Z" and releases nothing.
- **Rebuild the website failed** — the release is already published; only the site's
  download button is stale. Re-run the build from the Worker's *Builds* page in the
  Cloudflare dashboard (re-running the Release workflow prints "no code changes" and
  does nothing).
