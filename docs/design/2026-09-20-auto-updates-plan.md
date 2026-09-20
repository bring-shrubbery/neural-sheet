# Automatic Updates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Installed copies of NeuralSheet update themselves through Sparkle, fed by an `appcast.xml` the release workflow signs and publishes with every release.

**Architecture:** The app gains one `Updates` object (an `SPUStandardUpdaterController` wrapper) owned by `AppModel`; the menu and Settings call `model.checkForUpdates()`; the old GitHub-API check, the status-bar notice and `VersionCompare` are removed. Three Info.plist keys (`SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`) come from a checked-in `Info.plist` merged into the generated one. The release workflow signs the zip with `sign_update` (Sparkle's pinned tools) and writes the feed with a small tested script, `app/Scripts/release-appcast.sh`, then publishes `appcast.xml` as a release asset; the website already redirects `/appcast.xml` to it.

**Tech Stack:** Sparkle 2.10.0 (SPM, already added to the Xcode project by the maintainer: `project.pbxproj` and `Package.resolved` are modified/untracked in the working tree and belong to Task 2's commit), Swift 6 / `@Observable`, bash, GitHub Actions, `xmllint`.

**Spec:** `docs/design/2026-09-20-auto-updates-design.md`

## Global Constraints

- Feed URL `https://neural-sheet.quassum.com/appcast.xml`; public key `xqg7Uv6Q+zw/+Is3ic5dSCOOc8Sa0WzuFVtCwpX3zWU=`; `SUEnableAutomaticChecks` true. Sparkle defaults otherwise (launch + daily check, prompt, no automatic install).
- `<sparkle:version>` is the build number (`CURRENT_PROJECT_VERSION`, the run number); `<sparkle:shortVersionString>` is `X.Y.Z`; `<sparkle:minimumSystemVersion>` is `26.0`; the enclosure is the **zip** (`NeuralSheet-vX.Y.Z-macos-arm64.zip`), `type="application/octet-stream"`.
- Sparkle tools pinned: `Sparkle-2.10.0.tar.xz`, SHA-256 `c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c`.
- New required secret `SPARKLE_PRIVATE_KEY` (already set in the repo); the secrets check fails without it like the other seven.
- Views use `AppModel`'s contract only: `model.checkForUpdates()` and `model.updates.canCheckForUpdates`. No view imports Sparkle.
- Warnings are errors in our sources; `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Build: `cd app && xcodebuild -project NeuralSheet.xcodeproj -scheme NeuralSheet -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | tail -20` must show no `warning:` in `/app/NeuralSheet/` or `/app/Packages/`. Core: `cd app/Packages/NeuralSheetCore && swift test` must pass.
- `project.pbxproj` may be edited by hand only for build settings (`INFOPLIST_FILE`); the Sparkle package entries were made by Xcode and are committed as-is.
- Commit messages: lowercase `area: what` (`app:` for the app, `core:` for the package, `chore:` for CI/scripts, `docs:`). Every commit body ends with `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- Bash: `set -euo pipefail`, portable to macOS.

---

### Task 1: `release-appcast.sh` — the feed from arguments, with a test

**Files:**
- Create: `app/Scripts/release-appcast.sh`
- Create: `app/Scripts/release-appcast-test.sh`

**Interfaces:**
- Produces: `release-appcast.sh --version X.Y.Z --build N --tag vX.Y.Z --url <zip url> --length <bytes> --signature <base64> --notes <url> --date "<RFC 822>"` prints the appcast XML to stdout, exit 0. Any missing or empty option → message on stderr, exit 1. Output validated by `xmllint --noout`.

- [ ] **Step 1: Write the failing test**

```bash
cat > app/Scripts/release-appcast-test.sh <<'EOF'
#!/bin/bash
# Exercises release-appcast.sh: the fields land where Sparkle reads them, the XML is
# well formed, and a missing option fails. Run: app/Scripts/release-appcast-test.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/release-appcast.sh"
failures=0

ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; failures=$((failures + 1)); }

out=$("$SCRIPT" --version 1.2.3 --build 45 --tag v1.2.3 \
    --url "https://github.com/bring-shrubbery/neural-sheet/releases/download/v1.2.3/NeuralSheet-v1.2.3-macos-arm64.zip" \
    --length 4271794 --signature "AbC+dEf/gH0=" \
    --notes "https://github.com/bring-shrubbery/neural-sheet/releases/tag/v1.2.3" \
    --date "Sun, 20 Sep 2026 19:19:22 +0000")

if printf '%s' "$out" | xmllint --noout - 2>/dev/null; then ok "well-formed xml"; else fail "xml does not parse"; fi

# check <label> <literal that must appear once>
check() {
    local n
    n=$(printf '%s' "$out" | grep -cF -- "$2" || true)
    if [ "$n" -eq 1 ]; then ok "$1"; else fail "$1 (found $n of: $2)"; fi
}
check "title"          "<title>NeuralSheet v1.2.3</title>"
check "build number"   "<sparkle:version>45</sparkle:version>"
check "short version"  "<sparkle:shortVersionString>1.2.3</sparkle:shortVersionString>"
check "minimum system" "<sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>"
check "release notes"  "<sparkle:releaseNotesLink>https://github.com/bring-shrubbery/neural-sheet/releases/tag/v1.2.3</sparkle:releaseNotesLink>"
check "pubDate"        "<pubDate>Sun, 20 Sep 2026 19:19:22 +0000</pubDate>"
check "enclosure url"  'url="https://github.com/bring-shrubbery/neural-sheet/releases/download/v1.2.3/NeuralSheet-v1.2.3-macos-arm64.zip"'
check "length"         'length="4271794"'
check "type"           'type="application/octet-stream"'
check "signature"      'sparkle:edSignature="AbC+dEf/gH0="'
check "feed link"      "<link>https://neural-sheet.quassum.com/appcast.xml</link>"
check "one item"       "<item>"

# A missing option is an error, never an empty field.
if "$SCRIPT" --version 1.2.3 --build 45 --tag v1.2.3 --url u --length 1 --notes n --date d >/dev/null 2>&1; then
    fail "missing --signature should fail"
else
    ok "missing --signature fails"
fi
if "$SCRIPT" --version 1.2.3 --build "" --tag v1.2.3 --url u --length 1 --signature s --notes n --date d >/dev/null 2>&1; then
    fail "empty --build should fail"
else
    ok "empty --build fails"
fi

[ "$failures" -eq 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
EOF
chmod +x app/Scripts/release-appcast-test.sh
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `app/Scripts/release-appcast-test.sh`
Expected: fails (`release-appcast.sh: No such file or directory`), exit non-zero.

- [ ] **Step 3: Write the script**

```bash
cat > app/Scripts/release-appcast.sh <<'EOF'
#!/bin/bash
# Prints the Sparkle appcast for one release: a single <item> whose enclosure is the
# signed zip. Every field is an argument so the release workflow stays declarative and
# this file is testable. The feed URL in <link> is where installed apps read it.
#
#   release-appcast.sh --version 1.0.2 --build 17 --tag v1.0.2 \
#       --url https://github.com/.../NeuralSheet-v1.0.2-macos-arm64.zip \
#       --length 4271794 --signature <base64 EdDSA> \
#       --notes https://github.com/.../releases/tag/v1.0.2 \
#       --date "Sun, 20 Sep 2026 19:19:22 +0000" > appcast.xml
set -euo pipefail

FEED_URL="https://neural-sheet.quassum.com/appcast.xml"
MINIMUM_SYSTEM="26.0"

version="" build="" tag="" url="" length="" signature="" notes="" date=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version)   version=${2-};   shift 2 ;;
        --build)     build=${2-};     shift 2 ;;
        --tag)       tag=${2-};       shift 2 ;;
        --url)       url=${2-};       shift 2 ;;
        --length)    length=${2-};    shift 2 ;;
        --signature) signature=${2-}; shift 2 ;;
        --notes)     notes=${2-};     shift 2 ;;
        --date)      date=${2-};      shift 2 ;;
        *) echo "error: unknown option $1" >&2; exit 1 ;;
    esac
done

for name in version build tag url length signature notes date; do
    if [ -z "${!name}" ]; then
        echo "error: --$name is required" >&2
        exit 1
    fi
done

# The values are versions, URLs, numbers and base64: no XML metacharacters. Guard anyway.
for name in version build tag url length signature notes date; do
    case "${!name}" in
        *[\<\>\&\"]*) echo "error: --$name contains an XML metacharacter" >&2; exit 1 ;;
    esac
done

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>NeuralSheet</title>
    <link>$FEED_URL</link>
    <description>Releases of NeuralSheet, the audio-to-MIDI transcription app for macOS.</description>
    <language>en</language>
    <item>
      <title>NeuralSheet $tag</title>
      <pubDate>$date</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM_SYSTEM</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$notes</sparkle:releaseNotesLink>
      <enclosure url="$url" length="$length" type="application/octet-stream" sparkle:edSignature="$signature" />
    </item>
  </channel>
</rss>
XML
EOF
chmod +x app/Scripts/release-appcast.sh
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `app/Scripts/release-appcast-test.sh`
Expected: every line `ok …`, `all passed`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add app/Scripts/release-appcast.sh app/Scripts/release-appcast-test.sh
git commit -m "chore: release-appcast.sh writes the sparkle feed for one release"
```

---

### Task 2: The app — Sparkle in, the old check out

**Files:**
- Create: `app/NeuralSheet/App/Updates.swift`, `app/NeuralSheet/Info.plist`
- Modify: `app/NeuralSheet/App/AppModel.swift` (struct at the top; `updateNotice`; the `// MARK: - Update check` section; the display-link tick), `app/NeuralSheet/App/NeuralSheetApp.swift` (`appMenu`), `app/NeuralSheet/UI/MainView.swift` (the overlay and the launch check), `app/NeuralSheet/UI/Settings/GeneralSettingsView.swift`, `app/NeuralSheet.xcodeproj/project.pbxproj` (add `INFOPLIST_FILE` next to both `GENERATE_INFOPLIST_FILE = YES;` lines — lines 289 and 338 today), `AGENTS.md` (one clause)
- Delete: `app/NeuralSheet/App/UpdateCheck.swift`, `app/NeuralSheet/UI/UpdateNotice.swift`, `app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/VersionCompare.swift`, `app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/VersionCompareTests.swift`
- Commit also: `app/NeuralSheet.xcodeproj/project.pbxproj` (Xcode's package entries, already modified) and `app/NeuralSheet.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (untracked). Do **not** add `xcshareddata/swiftpm/configuration/` if it exists and is empty; do not add anything under `xcuserdata`.

**Interfaces:**
- Produces: `AppModel.updates: Updates` (`canCheckForUpdates: Bool`), `AppModel.checkForUpdates()`.

- [ ] **Step 1: Info.plist and the build setting**

```bash
cat > app/NeuralSheet/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<!-- Sparkle. The rest of the Info.plist is generated from build settings and merged with this. -->
	<key>SUFeedURL</key>
	<string>https://neural-sheet.quassum.com/appcast.xml</string>
	<key>SUPublicEDKey</key>
	<string>xqg7Uv6Q+zw/+Is3ic5dSCOOc8Sa0WzuFVtCwpX3zWU=</string>
	<key>SUEnableAutomaticChecks</key>
	<true/>
</dict>
</plist>
EOF
# Both target configurations: add INFOPLIST_FILE right after GENERATE_INFOPLIST_FILE.
sed -i '' 's#^\(\t*\)GENERATE_INFOPLIST_FILE = YES;#\1GENERATE_INFOPLIST_FILE = YES;\n\1INFOPLIST_FILE = NeuralSheet/Info.plist;#' app/NeuralSheet.xcodeproj/project.pbxproj
grep -n "INFOPLIST_FILE" app/NeuralSheet.xcodeproj/project.pbxproj
```

Expected: two `INFOPLIST_FILE = NeuralSheet/Info.plist;` lines, each directly under a `GENERATE_INFOPLIST_FILE = YES;` line, same indentation (tabs).

If the build in Step 6 fails with "Multiple commands produce …/Info.plist" or the built app's `Contents/Resources` contains an `Info.plist` copy (synchronized folder picked it up as a resource), move the file to `app/Info.plist`, change both settings to `INFOPLIST_FILE = Info.plist;`, and note it in the report.

- [ ] **Step 2: `Updates.swift`**

```bash
cat > app/NeuralSheet/App/Updates.swift <<'EOF'
import Foundation
import Sparkle

/// The in-app updater. One Sparkle controller for the app's lifetime: it reads the feed named by
/// `SUFeedURL` in Info.plist on launch and then daily, shows its own dialogs, and installs on the
/// user's say-so. Views never see Sparkle; they go through ``AppModel/checkForUpdates()`` and
/// read ``canCheckForUpdates`` for the menu item.
@MainActor @Observable final class Updates {
    /// False while a check or an install is under way; the menu item is disabled then.
    private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        canCheckForUpdates = controller.updater.canCheckForUpdates
        // Sparkle drives its updater on the main thread, so the change lands on the main actor.
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = change.newValue ?? false
            }
        }
    }

    /// Check for Updates…: Sparkle reports the outcome itself, including "You're up to date".
    func check() {
        controller.checkForUpdates(nil)
    }
}
EOF
```

If the compiler warns about the change handler's isolation (it is not `@Sendable`; under default main-actor isolation it is inferred main-actor-isolated and `assumeIsolated` may be flagged as redundant), drop the `MainActor.assumeIsolated { }` wrapper and assign directly. Whatever compiles warning-free wins; both are correct because Sparkle notifies on the main thread.

- [ ] **Step 3: `AppModel.swift`**

Three edits, each found with `grep -n`:

(a) Delete the `UpdateNotice` struct and its doc comment (the block from `/// The update-check notice, once one is showing (inventory §9).` through the closing `}` of `nonisolated struct UpdateNotice`), leaving one blank line between the imports and the next doc comment. In the class doc comment just below, change `the model panel and the update notice.` to `the model panel and the updater.`

(b) Replace
```swift
    // MARK: - Update check

    var updateNotice: UpdateNotice?
```
with
```swift
    // MARK: - Updates

    /// The Sparkle updater; the menu item follows its ``Updates/canCheckForUpdates``.
    let updates = Updates()
```

(c) Replace the `// MARK: - Update check` section near line 985 (the doc comment, `func checkForUpdates(explicit: Bool)`, and `func dismissUpdateNotice()`) with
```swift
    // MARK: - Updates

    /// Check for Updates…, from the app menu and Settings. Sparkle shows the result itself,
    /// including "You're up to date"; there is nothing to say in the status bar any more.
    func checkForUpdates() {
        updates.check()
    }
```

(d) In `displayLinkTick(dt:)`, delete
```swift

        if let notice = updateNotice, Date() >= notice.expiresAt {
            updateNotice = nil
        }
```

Run: `grep -n "updateNotice\|UpdateNotice\|explicit" app/NeuralSheet/App/AppModel.swift`
Expected: no matches.

- [ ] **Step 4: Callers**

`app/NeuralSheet/App/NeuralSheetApp.swift`, in `appMenu`:
```swift
            Button("Check for Updates…") {
                model.checkForUpdates()
            }
            .disabled(!model.updates.canCheckForUpdates)
```

`app/NeuralSheet/UI/Settings/GeneralSettingsView.swift`:
```swift
                    Button("Check for Updates…") {
                        model.checkForUpdates()
                    }
                    .disabled(!model.updates.canCheckForUpdates)
```

`app/NeuralSheet/UI/MainView.swift`: delete the `.overlay(alignment: .bottomTrailing) { if let notice = model.updateNotice { … } }` modifier (5 lines), the block
```swift

        if !Self.hasCheckedForUpdates {
            Self.hasCheckedForUpdates = true
            model.checkForUpdates(explicit: false)
        }
```
and the `private static var hasCheckedForUpdates = false` declaration (with its doc comment, if it has one).

- [ ] **Step 5: Delete the old check**

```bash
git rm -q app/NeuralSheet/App/UpdateCheck.swift app/NeuralSheet/UI/UpdateNotice.swift \
  app/Packages/NeuralSheetCore/Sources/NeuralSheetCore/VersionCompare.swift \
  app/Packages/NeuralSheetCore/Tests/NeuralSheetCoreTests/VersionCompareTests.swift
grep -rn "UpdateCheck\|UpdateNotice\|VersionCompare\|updateNotice\|checkForUpdates(explicit" app/NeuralSheet app/Packages/NeuralSheetCore/Sources app/Packages/NeuralSheetCore/Tests || echo "no references left"
```

Expected: `no references left`.

- [ ] **Step 6: Build and test**

```bash
cd app && xcodebuild -project NeuralSheet.xcodeproj -scheme NeuralSheet -configuration Debug \
  -destination 'platform=macOS,arch=arm64' build 2>&1 | tee /tmp/ns-build.log | tail -20
grep -E "/app/(NeuralSheet|Packages)/.*warning:" /tmp/ns-build.log || echo "no warnings in our sources"
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/NeuralSheet-*/Build/Products/Debug/NeuralSheet.app | head -1)
defaults read "$APP/Contents/Info.plist" SUFeedURL
defaults read "$APP/Contents/Info.plist" SUPublicEDKey
ls "$APP/Contents/Frameworks" | grep Sparkle
ls "$APP/Contents/Resources" | grep -c "^Info.plist$" || echo "no stray Info.plist copy: good"
cd Packages/NeuralSheetCore && swift test 2>&1 | tail -3; cd ../../..
```

Expected: `** BUILD SUCCEEDED **`; `no warnings in our sources`; the feed URL and key print; `Sparkle.framework` listed; `no stray Info.plist copy: good`; `swift test` passes (the count drops from 231 by the VersionCompare tests).

- [ ] **Step 7: Run it once**

```bash
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/NeuralSheet-*/Build/Products/Debug/NeuralSheet.app | head -1)
open "$APP"; sleep 6
log show --last 20s --predicate 'process == "NeuralSheet" AND (subsystem CONTAINS "sparkle" OR eventMessage CONTAINS "Sparkle" OR eventMessage CONTAINS "appcast")' 2>/dev/null | tail -8
osascript -e 'tell application "NeuralSheet" to quit'
```

Expected: the app launches without a crash; Sparkle logs a feed fetch (before the first Sparkle release exists, `/appcast.xml` redirects to a 404 and Sparkle logs the failed check — that is expected and silent to the user on an automatic check). Record what the log shows. If `log show` prints nothing, that is not a failure; say so.

- [ ] **Step 8: AGENTS.md**

In the "Deliberate departures so far" sentence, change `the session stores the transcription.` to `the session stores the transcription; updates are Sparkle's dialogs, not the status-bar notice.`

- [ ] **Step 9: Commit**

```bash
git add app/NeuralSheet/App/Updates.swift app/NeuralSheet/Info.plist app/NeuralSheet/App/AppModel.swift \
  app/NeuralSheet/App/NeuralSheetApp.swift app/NeuralSheet/UI/MainView.swift \
  app/NeuralSheet/UI/Settings/GeneralSettingsView.swift app/NeuralSheet.xcodeproj/project.pbxproj \
  app/NeuralSheet.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved AGENTS.md
git status --short   # only the deletions from Step 5 should remain staged besides these; nothing under xcuserdata
git commit -m "app: sparkle installs updates in place; the status-bar notice and its version check go

One SPUStandardUpdaterController owned by AppModel through Updates; the
menu and Settings call checkForUpdates() and follow canCheckForUpdates.
The feed and public key sit in NeuralSheet/Info.plist, merged into the
generated plist by INFOPLIST_FILE."
```

---

### Task 3: The workflow — sign the zip, publish the feed

**Files:**
- Modify: `.github/workflows/release.yml`

**Interfaces:**
- Consumes: `app/Scripts/release-appcast.sh` (Task 1), the zip written by "Sign, notarize and staple", secret `SPARKLE_PRIVATE_KEY`.
- Produces: `app/build/appcast.xml`, uploaded as an artifact and a release asset.

- [ ] **Step 1: The secrets check**

In "Check the signing secrets": add `SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}` to the step's `env:` and `SPARKLE_PRIVATE_KEY` to the `for name in …` list.

- [ ] **Step 2: The signing step**

Insert after "Sign, notarize and staple" and before "Keep the assets as run artifacts":

```yaml
      - name: Sign the update and write the appcast
        working-directory: app
        env:
          SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}
          SPARKLE_VERSION: 2.10.0
          SPARKLE_SHA256: c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
        run: |
          set -o pipefail
          ZIP="build/NeuralSheet-$TAG-macos-arm64.zip"
          KEY="$RUNNER_TEMP/sparkle-key"
          trap 'rm -f "$KEY"' EXIT
          printf '%s' "$SPARKLE_PRIVATE_KEY" > "$KEY"

          # Sparkle's command-line tools, pinned by version and checksum.
          TOOLS="$RUNNER_TEMP/sparkle"
          mkdir -p "$TOOLS"
          curl -fsSL -o "$TOOLS/Sparkle.tar.xz" \
            "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
          echo "$SPARKLE_SHA256  $TOOLS/Sparkle.tar.xz" | shasum -a 256 -c -
          tar -xJf "$TOOLS/Sparkle.tar.xz" -C "$TOOLS" bin/sign_update

          signature=$("$TOOLS/bin/sign_update" --ed-key-file "$KEY" "$ZIP")
          echo "sign_update: $signature"
          ed=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<< "$signature")
          length=$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' <<< "$signature")
          if [ -z "$ed" ] || [ -z "$length" ]; then
            echo "::error::sign_update did not produce a signature and length"; exit 1
          fi

          Scripts/release-appcast.sh \
            --version "$VERSION" --build "$GITHUB_RUN_NUMBER" --tag "$TAG" \
            --url "https://github.com/$GITHUB_REPOSITORY/releases/download/$TAG/NeuralSheet-$TAG-macos-arm64.zip" \
            --length "$length" --signature "$ed" \
            --notes "https://github.com/$GITHUB_REPOSITORY/releases/tag/$TAG" \
            --date "$(date -u '+%a, %d %b %Y %H:%M:%S +0000')" > build/appcast.xml
          xmllint --noout build/appcast.xml
          cat build/appcast.xml
```

- [ ] **Step 3: Publish it**

In "Keep the assets as run artifacts", add a third path line `app/build/appcast.xml`. In "Publish the GitHub release", add `app/build/appcast.xml` under `files:`.

- [ ] **Step 4: Lint and a local rehearsal of the shell**

```bash
actionlint .github/workflows/release.yml
# Rehearse the signing lines locally with the maintainer's keychain key and Sparkle's tools
# already in the scratchpad (or download them the same way); the run number is faked.
S=/private/tmp/claude-501/-Users-antoni-Projects-neural-sheet/8e48ba28-32d7-492f-901c-a3d12f807120/scratchpad/sparkle
[ -x "$S/bin/sign_update" ] || { mkdir -p "$S" && curl -fsSL -o "$S/Sparkle.tar.xz" https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz && tar -xJf "$S/Sparkle.tar.xz" -C "$S"; }
printf 'hello' > /tmp/ns-fake.zip
sig=$("$S/bin/sign_update" --account NeuralSheet /tmp/ns-fake.zip); echo "$sig"
ed=$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<< "$sig"); length=$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' <<< "$sig")
app/Scripts/release-appcast.sh --version 9.9.9 --build 1 --tag v9.9.9 --url https://example.invalid/x.zip --length "$length" --signature "$ed" --notes https://example.invalid/notes --date "$(date -u '+%a, %d %b %Y %H:%M:%S +0000')" | xmllint --noout - && echo "rehearsal ok"
rm -f /tmp/ns-fake.zip
```

Expected: actionlint silent; `sign_update` prints `sparkle:edSignature="…" length="5"`; `rehearsal ok`. (This uses the keychain key via `--account`; the workflow uses the exported file via `--ed-key-file` — the same key.)

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "chore: the release signs the zip for sparkle and publishes appcast.xml"
```

---

### Task 4: Docs

**Files:**
- Modify: `docs/release.md`, `CHANGELOG.md`

- [ ] **Step 1: `docs/release.md`**

After the "One-time setup: the secrets" section's `gh secret list` sentence (before "### 3. The first release"), add:

```
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
`app/NeuralSheet/Info.plist`.

To rotate the key: ship one release signed with the old key whose Info.plist
carries the new public key, then switch `SPARKLE_PRIVATE_KEY`; copies that skip
that release are stranded, so avoid rotating.
```

In "When it fails", add a bullet:

```
- **Sign the update and write the appcast failed** — the zip is notarized but not
  yet released. Usually `SPARKLE_PRIVATE_KEY` is missing or not the exported key
  (44 base64 characters). Fix the secret and re-run; nothing was tagged.
```

Also in the sentence listing the seven secrets ("The workflow refuses to run without all seven"), say eight, and add a row to the secrets table if there is one: `SPARKLE_PRIVATE_KEY | the `generate_keys -x` export of the Sparkle EdDSA private key`.

- [ ] **Step 2: `CHANGELOG.md`**

Under `[Unreleased]` → `### Added`, append:
```
- Updates install from inside the app (Sparkle): a check on launch and daily, a prompt with the release notes, install and relaunch. The status-bar notice and its link to the releases page are gone.
```

- [ ] **Step 3: Commit**

```bash
git add docs/release.md CHANGELOG.md
git commit -m "docs: sparkle updates, the signing key and how to keep it"
```

---

### Task 5: Verify and hand over

- [ ] **Step 1: Everything once more**

```bash
app/Scripts/release-appcast-test.sh | tail -1; app/Scripts/release-version-test.sh | tail -1; app/Scripts/release-changes-test.sh | tail -1
actionlint .github/workflows/*.yml && echo lint-clean
(cd app/Packages/NeuralSheetCore && swift test 2>&1 | tail -1)
(cd app && xcodebuild -project NeuralSheet.xcodeproj -scheme NeuralSheet -configuration Debug -destination 'platform=macOS,arch=arm64' build 2>&1 | grep -E "warning:.*app/(NeuralSheet|Packages)|BUILD" )
git status --short && echo clean
```

- [ ] **Step 2: Report to the maintainer**

Nothing is pushed. State: pushing `main` cuts v1.0.2, the first Sparkle-enabled build, and the run's "Sign the update and write the appcast" step is the first real exercise of the key; after it, `curl -sL https://neural-sheet.quassum.com/appcast.xml` must print the feed. The end-to-end proof is theirs: install v1.0.2 from the DMG, land any code change (v1.0.3), open the installed app → the Sparkle dialog offers v1.0.3.
