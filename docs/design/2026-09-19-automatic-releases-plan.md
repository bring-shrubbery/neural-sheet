# Automatic Patch Releases Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every code change that lands on `main` and passes CI becomes a signed, notarized `NeuralSheet-vX.Y.Z-macos-arm64.dmg` (plus a zip) on a GitHub release, tagged `vX.Y.Z`, with no manual tag push.

**Architecture:** Two small bash scripts under `app/Scripts/` decide *whether* to release (`release-changes.sh`: code paths changed since the last release tag) and *what version* (`release-version.sh`: `max(pbxproj MARKETING_VERSION, highest vX.Y.Z tag + 1 patch)`); both are testable locally. `.github/workflows/release.yml` runs on `workflow_run` of CI on `main`, calls the scripts in a cheap Linux `version` job, and a `release` job on `macos-26` archives, packages with `create-dmg`, signs, notarizes with an App Store Connect API key, tags, and publishes. `docs/release.md` tells a maintainer how to set up the secrets.

**Tech Stack:** GitHub Actions (`macos-26`, `ubuntu-latest`), bash, `xcodebuild`, `create-dmg` (Homebrew), `codesign`, `notarytool`, `stapler`, `softprops/action-gh-release@v2`, `actionlint`.

**Spec:** `docs/design/2026-09-19-automatic-releases-design.md`

## Global Constraints

- Only tags matching strictly `v<int>.<int>.<int>` count as releases; `v1.0.0-checkpoint` is ignored.
- CI never edits `project.pbxproj`; the version goes in as `MARKETING_VERSION=<x.y.z> CURRENT_PROJECT_VERSION=<github.run_number>` build settings.
- Signing and notarization are required: a missing secret fails the run before any build; nothing unsigned is published.
- Secrets, exactly these names: `MACOS_CERTIFICATE_P12`, `MACOS_CERTIFICATE_PASSWORD`, `MACOS_SIGNING_IDENTITY`, `APPLE_TEAM_ID`, `ASC_API_KEY_P8`, `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`.
- Asset names: `NeuralSheet-vX.Y.Z-macos-arm64.dmg`, `NeuralSheet-vX.Y.Z-macos-arm64.zip`. Release name `NeuralSheet vX.Y.Z`. Tag message `NeuralSheet vX.Y.Z`.
- Docs-only changes (`docs/`, `*.md`, `LICENSE`, `NOTICE`, `.github/` except `.github/workflows/`) do not release.
- Commit messages: lowercase `area: what` (`chore:` for CI and scripts, `docs:` for docs).
- Bash scripts: `set -euo pipefail`, portable to macOS (BSD) tools — no `sort -V`, no `grep -P`.
- Deviation from the spec, agreed here: the docs-only patterns live in a `case` statement in `release-changes.sh`, not in a `.github/release-ignore` file (gitignore syntax cannot be applied to an arbitrary path list without a fight). The spec's Files section is updated in Task 5.

---

### Task 1: `release-version.sh` — the version to build

**Files:**
- Create: `app/Scripts/release-version.sh`
- Create: `app/Scripts/release-version-test.sh`

**Interfaces:**
- Consumes: `app/NeuralSheet.xcodeproj/project.pbxproj` (`MARKETING_VERSION = 1.0.0;` lines), `git tag`.
- Produces: `app/Scripts/release-version.sh` prints `x.y.z` (no `v`) on stdout, exit 0. `app/Scripts/release-version.sh --previous` prints the highest strict release tag *with* its `v` (e.g. `v1.0.3`), or nothing when there is none, exit 0. Env overrides for tests and the workflow: `RELEASE_TAGS` (newline-separated tag list replacing `git tag`), `RELEASE_PBXPROJ` (path replacing the real pbxproj).

- [ ] **Step 1: Write the failing test**

```bash
cat > app/Scripts/release-version-test.sh <<'EOF'
#!/bin/bash
# Exercises release-version.sh against the table in
# docs/design/2026-09-19-automatic-releases-design.md. Run: app/Scripts/release-version-test.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/release-version.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
failures=0
nl=$'\n'

# check <pbxproj version> <tags, space separated> <expected version> <expected previous>
check() {
    local floor=$1 tags=$2 want=$3 want_prev=$4
    printf '\t\t\t\tMARKETING_VERSION = %s;\n\t\t\t\tMARKETING_VERSION = %s;\n' "$floor" "$floor" > "$TMP/project.pbxproj"
    local got got_prev
    got=$(RELEASE_PBXPROJ="$TMP/project.pbxproj" RELEASE_TAGS="${tags// /$nl}" "$SCRIPT")
    got_prev=$(RELEASE_PBXPROJ="$TMP/project.pbxproj" RELEASE_TAGS="${tags// /$nl}" "$SCRIPT" --previous)
    if [ "$got" = "$want" ] && [ "$got_prev" = "$want_prev" ]; then
        echo "ok   pbxproj=$floor tags=[$tags] -> $got (previous ${got_prev:-none})"
    else
        echo "FAIL pbxproj=$floor tags=[$tags] -> got $got / ${got_prev:-none}, want $want / ${want_prev:-none}"
        failures=$((failures + 1))
    fi
}

check 1.0.0 ""                              1.0.0  ""
check 1.0.0 "v1.0.0-checkpoint"             1.0.0  ""
check 1.0.0 "v1.0.0"                        1.0.1  v1.0.0
check 1.0.0 "v1.0.0 v1.0.9"                 1.0.10 v1.0.9
check 1.0.0 "v1.0.9 v1.0.10"                1.0.11 v1.0.10
check 1.1.0 "v1.0.9"                        1.1.0  v1.0.9
check 1.0.0 "v1.1.2 v1.0.9"                 1.1.3  v1.1.2
check 1.0.0 "v1.0 v1.0.0-rc1 1.2.3 v2"      1.0.0  ""
check 2.0.0 "v1.9.9"                        2.0.0  v1.9.9

# A pbxproj without a strict x.y.z MARKETING_VERSION is an error.
printf 'MARKETING_VERSION = 1.0;\n' > "$TMP/project.pbxproj"
if RELEASE_PBXPROJ="$TMP/project.pbxproj" RELEASE_TAGS="" "$SCRIPT" 2>/dev/null; then
    echo "FAIL a malformed MARKETING_VERSION should fail"; failures=$((failures + 1))
else
    echo "ok   malformed MARKETING_VERSION fails"
fi

# Two different MARKETING_VERSIONs in the pbxproj is an error.
printf 'MARKETING_VERSION = 1.0.0;\nMARKETING_VERSION = 1.1.0;\n' > "$TMP/project.pbxproj"
if RELEASE_PBXPROJ="$TMP/project.pbxproj" RELEASE_TAGS="" "$SCRIPT" 2>/dev/null; then
    echo "FAIL disagreeing MARKETING_VERSIONs should fail"; failures=$((failures + 1))
else
    echo "ok   disagreeing MARKETING_VERSIONs fail"
fi

# Against the real repo: whatever it prints must be x.y.z.
real=$("$SCRIPT")
if [[ "$real" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ok   real repo -> $real"
else
    echo "FAIL real repo -> '$real'"; failures=$((failures + 1))
fi

[ "$failures" -eq 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
EOF
chmod +x app/Scripts/release-version-test.sh
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `app/Scripts/release-version-test.sh`
Expected: fails immediately (`release-version.sh: No such file or directory`), exit non-zero.

- [ ] **Step 3: Write the script**

```bash
cat > app/Scripts/release-version.sh <<'EOF'
#!/bin/bash
# Prints the version the next release gets: the higher of MARKETING_VERSION in
# project.pbxproj (the floor a maintainer raises for a minor or major release)
# and the highest v<major>.<minor>.<patch> tag with its patch + 1. With no such
# tag the pbxproj version is it. Pre-release tags (v1.0.0-checkpoint) are ignored.
#
#   release-version.sh             1.0.3
#   release-version.sh --previous  v1.0.2   (the highest release tag; empty when none)
#
# RELEASE_TAGS (one tag per line) replaces `git tag`, RELEASE_PBXPROJ replaces the
# project file; release-version-test.sh uses both.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PBXPROJ=${RELEASE_PBXPROJ:-"$ROOT/NeuralSheet.xcodeproj/project.pbxproj"}

tags() {
    if [ -n "${RELEASE_TAGS+x}" ]; then printf '%s\n' "$RELEASE_TAGS"; else git -C "$ROOT" tag; fi
}

# Sorts x.y.z lines numerically, lowest first.
sort_versions() {
    sort -t. -k1,1n -k2,2n -k3,3n
}

# The highest strict release tag, without its v; empty when there is none.
highest_release() {
    tags | sed -n 's/^v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' | sort_versions | tail -1
}

# MARKETING_VERSION from the pbxproj; every configuration must agree.
pbxproj_version() {
    local versions
    versions=$(sed -n 's/^[[:space:]]*MARKETING_VERSION = \([^;]*\);.*/\1/p' "$PBXPROJ" | sort -u)
    if [ "$(printf '%s\n' "$versions" | grep -c .)" -ne 1 ]; then
        echo "error: expected exactly one MARKETING_VERSION in $PBXPROJ, found: ${versions:-none}" >&2
        exit 1
    fi
    if ! [[ "$versions" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "error: MARKETING_VERSION must be major.minor.patch, found: $versions" >&2
        exit 1
    fi
    echo "$versions"
}

previous=$(highest_release)

if [ "${1:-}" = "--previous" ]; then
    [ -n "$previous" ] && echo "v$previous"
    exit 0
fi

floor=$(pbxproj_version)
if [ -z "$previous" ]; then
    echo "$floor"
    exit 0
fi

IFS=. read -r major minor patch <<< "$previous"
next="$major.$minor.$((patch + 1))"
printf '%s\n%s\n' "$floor" "$next" | sort_versions | tail -1
EOF
chmod +x app/Scripts/release-version.sh
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `app/Scripts/release-version-test.sh`
Expected: every line `ok …`, last line `all passed`, exit 0. The "real repo" line prints `1.0.0` today (no strict tag exists, pbxproj says 1.0.0).

- [ ] **Step 5: Commit**

```bash
git add app/Scripts/release-version.sh app/Scripts/release-version-test.sh
git commit -m "chore: release-version.sh computes the next patch version from the tags and the pbxproj"
```

---

### Task 2: `release-changes.sh` — the code paths changed since the last release

**Files:**
- Create: `app/Scripts/release-changes.sh`
- Create: `app/Scripts/release-changes-test.sh`

**Interfaces:**
- Consumes: `git`, a tag name or empty string.
- Produces: `app/Scripts/release-changes.sh <previous-tag-or-empty>` prints, one per line, the paths changed since that tag (all tracked paths when the argument is empty) that are *not* docs-only; empty output means nothing to release. Exit 0 either way. Env override for tests: `RELEASE_PATHS` (newline-separated path list replacing the git query).

- [ ] **Step 1: Write the failing test**

```bash
cat > app/Scripts/release-changes-test.sh <<'EOF'
#!/bin/bash
# Exercises the docs-only filter in release-changes.sh. Run: app/Scripts/release-changes-test.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/release-changes.sh"
failures=0
nl=$'\n'

# check <label> <paths, space separated> <expected output, space separated>
check() {
    local label=$1 paths=$2 want=$3 got
    got=$(RELEASE_PATHS="${paths// /$nl}" "$SCRIPT" v0.0.0 | tr '\n' ' ' | sed 's/ $//')
    if [ "$got" = "$want" ]; then
        echo "ok   $label -> [${got}]"
    else
        echo "FAIL $label -> got [${got}], want [${want}]"
        failures=$((failures + 1))
    fi
}

check "docs only"        "docs/design/x.md README.md LICENSE NOTICE .github/MAINTAINERS .github/ISSUE_TEMPLATE/bug.yml" ""
check "app source"       "app/NeuralSheet/App/AppModel.swift README.md" "app/NeuralSheet/App/AppModel.swift"
check "workflow"         ".github/workflows/ci.yml .github/CODEOWNERS" ".github/workflows/ci.yml"
check "submodule bump"   "app/ThirdParty/muscriptor.cpp .gitmodules" "app/ThirdParty/muscriptor.cpp .gitmodules"
check "script"           "app/Scripts/build-engine.sh docs/icon.png" "app/Scripts/build-engine.sh"
check "md under app"     "app/Packages/NeuralSheetCore/README.md app/Packages/NeuralSheetCore/Package.swift" "app/Packages/NeuralSheetCore/Package.swift"
check "nothing"          "" ""

# With no previous tag every tracked path counts; the real repo has code, so output is non-empty.
if [ -n "$("$SCRIPT" "")" ]; then
    echo "ok   no previous tag -> whole tree"
else
    echo "FAIL no previous tag should list the tree"; failures=$((failures + 1))
fi

[ "$failures" -eq 0 ] && echo "all passed" || { echo "$failures failed"; exit 1; }
EOF
chmod +x app/Scripts/release-changes-test.sh
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `app/Scripts/release-changes-test.sh`
Expected: fails (`release-changes.sh: No such file or directory`), exit non-zero.

- [ ] **Step 3: Write the script**

```bash
cat > app/Scripts/release-changes.sh <<'EOF'
#!/bin/bash
# Prints the paths changed since the previous release tag that are worth a
# release, one per line; prints nothing when only documentation changed.
#
#   release-changes.sh v1.0.2   paths changed between v1.0.2 and HEAD
#   release-changes.sh ""       every tracked path (no release exists yet)
#
# Documentation is docs/, any *.md, LICENSE, NOTICE and .github/ except the
# workflows. RELEASE_PATHS (one path per line) replaces the git query; the test
# uses it.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
previous=${1-}

changed_paths() {
    if [ -n "${RELEASE_PATHS+x}" ]; then
        printf '%s\n' "$RELEASE_PATHS"
    elif [ -n "$previous" ]; then
        git -C "$ROOT" diff --name-only "$previous" HEAD
    else
        git -C "$ROOT" ls-tree -r --name-only HEAD
    fi
}

is_documentation() {
    case "$1" in
        docs/*|*.md|LICENSE|NOTICE) return 0 ;;
        .github/workflows/*) return 1 ;;
        .github/*) return 0 ;;
    esac
    return 1
}

changed_paths | while IFS= read -r path; do
    [ -n "$path" ] || continue
    is_documentation "$path" || echo "$path"
done
EOF
chmod +x app/Scripts/release-changes.sh
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `app/Scripts/release-changes-test.sh`
Expected: every line `ok …`, `all passed`, exit 0.

- [ ] **Step 5: Check it against real history**

Run: `app/Scripts/release-changes.sh v1.0.0-checkpoint | head`
Expected: a list of `app/…` paths (the MIDI editor work since the checkpoint), no `docs/` or `*.md` lines.

- [ ] **Step 6: Commit**

```bash
git add app/Scripts/release-changes.sh app/Scripts/release-changes-test.sh
git commit -m "chore: release-changes.sh lists the code paths changed since the last release"
```

---

### Task 3: `release.yml` — build, package, sign, notarize, publish

**Files:**
- Modify: `.github/workflows/release.yml` (full rewrite)

**Interfaces:**
- Consumes: `app/Scripts/release-version.sh` (`x.y.z`; `--previous` → `vX.Y.Z` or empty), `app/Scripts/release-changes.sh <previous>` (empty output = nothing to release), the seven secrets, the CI workflow named `CI`.
- Produces: tag `vX.Y.Z`, GitHub release `NeuralSheet vX.Y.Z` with `NeuralSheet-vX.Y.Z-macos-arm64.dmg` and `.zip`.

- [ ] **Step 1: Install actionlint (the test tool for this task)**

Run: `brew install actionlint`
Expected: installed; `actionlint --version` prints a version.

- [ ] **Step 2: Write the workflow**

```bash
cat > .github/workflows/release.yml <<'EOF'
name: Release

# Every code change that lands on main and passes CI becomes a patch release:
# a signed, notarized NeuralSheet-vX.Y.Z-macos-arm64.dmg (and zip) on a GitHub
# release, tagged vX.Y.Z. The version is the higher of MARKETING_VERSION in the
# Xcode project and the last release tag's patch + 1; raise MARKETING_VERSION in
# Xcode to ship a minor or major. Changes to docs/, *.md, LICENSE, NOTICE and
# .github/ (except the workflows) do not release. docs/release.md explains the
# secrets and the flow.

on:
  workflow_run:
    workflows: [CI]
    types: [completed]
    branches: [main]
  workflow_dispatch:

permissions:
  contents: write

# Releases queue rather than race: two runs computing the same version would
# fight over the tag.
concurrency:
  group: release
  cancel-in-progress: false

jobs:
  version:
    name: Decide the version
    # Only a green CI run of a push to main (not a pull request build whose head
    # branch happens to be main) or a manual dispatch releases.
    if: >-
      github.event_name == 'workflow_dispatch' ||
      (github.event.workflow_run.conclusion == 'success' && github.event.workflow_run.event == 'push')
    runs-on: ubuntu-latest
    outputs:
      release: ${{ steps.decide.outputs.release }}
      version: ${{ steps.decide.outputs.version }}
      tag: ${{ steps.decide.outputs.tag }}
      sha: ${{ steps.decide.outputs.sha }}
    steps:
      - uses: actions/checkout@v4
        with:
          # The commit CI built, not main's tip, which may have moved on.
          ref: ${{ github.event.workflow_run.head_sha || github.sha }}
          fetch-depth: 0
      - name: Compare with the last release
        id: decide
        run: |
          previous=$(app/Scripts/release-version.sh --previous)
          changed=$(app/Scripts/release-changes.sh "$previous")
          sha=$(git rev-parse HEAD)
          echo "sha=$sha" >> "$GITHUB_OUTPUT"
          if [ -z "$changed" ]; then
            echo "no code changes since ${previous:-the first commit}; nothing to release"
            echo "release=false" >> "$GITHUB_OUTPUT"
            exit 0
          fi
          version=$(app/Scripts/release-version.sh)
          echo "releasing v$version from $sha (previous release: ${previous:-none}); changed:"
          echo "$changed"
          {
            echo "release=true"
            echo "version=$version"
            echo "tag=v$version"
          } >> "$GITHUB_OUTPUT"

  release:
    name: Build and publish
    needs: version
    if: needs.version.outputs.release == 'true'
    runs-on: macos-26
    env:
      VERSION: ${{ needs.version.outputs.version }}
      TAG: ${{ needs.version.outputs.tag }}
      SHA: ${{ needs.version.outputs.sha }}
    steps:
      - name: Check the signing secrets
        env:
          MACOS_CERTIFICATE_P12: ${{ secrets.MACOS_CERTIFICATE_P12 }}
          MACOS_CERTIFICATE_PASSWORD: ${{ secrets.MACOS_CERTIFICATE_PASSWORD }}
          MACOS_SIGNING_IDENTITY: ${{ secrets.MACOS_SIGNING_IDENTITY }}
          APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
          ASC_API_KEY_P8: ${{ secrets.ASC_API_KEY_P8 }}
          ASC_API_KEY_ID: ${{ secrets.ASC_API_KEY_ID }}
          ASC_API_ISSUER_ID: ${{ secrets.ASC_API_ISSUER_ID }}
        run: |
          missing=()
          for name in MACOS_CERTIFICATE_P12 MACOS_CERTIFICATE_PASSWORD MACOS_SIGNING_IDENTITY \
                      APPLE_TEAM_ID ASC_API_KEY_P8 ASC_API_KEY_ID ASC_API_ISSUER_ID; do
            [ -n "${!name}" ] || missing+=("$name")
          done
          if [ "${#missing[@]}" -gt 0 ]; then
            echo "::error::missing repository secrets: ${missing[*]}; see docs/release.md"
            exit 1
          fi
          echo "all signing secrets present"

      - uses: actions/checkout@v4
        with:
          ref: ${{ env.SHA }}
          submodules: recursive
      - name: Select the newest installed Xcode
        run: |
          XCODE=$(ls -d /Applications/Xcode_*.app | sort -V | tail -1)
          echo "using $XCODE"
          sudo xcode-select -s "$XCODE"
          xcodebuild -version
      - name: Cache the engine build
        uses: actions/cache@v4
        with:
          path: app/build/engine
          key: engine-${{ runner.os }}-${{ hashFiles('.gitmodules') }}-${{ hashFiles('app/Scripts/build-engine.sh') }}

      - name: Import the signing certificate
        env:
          P12: ${{ secrets.MACOS_CERTIFICATE_P12 }}
          P12_PASSWORD: ${{ secrets.MACOS_CERTIFICATE_PASSWORD }}
        run: |
          echo "$P12" | base64 --decode > "$RUNNER_TEMP/cert.p12"
          security create-keychain -p ci build.keychain
          security default-keychain -s build.keychain
          security unlock-keychain -p ci build.keychain
          security set-keychain-settings -lut 3600 build.keychain
          security import "$RUNNER_TEMP/cert.p12" -k build.keychain -P "$P12_PASSWORD" -T /usr/bin/codesign
          security set-key-partition-list -S apple-tool:,apple: -s -k ci build.keychain
          rm "$RUNNER_TEMP/cert.p12"
          security find-identity -v -p codesigning build.keychain

      - name: Archive
        working-directory: app
        env:
          IDENTITY: ${{ secrets.MACOS_SIGNING_IDENTITY }}
          TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
        run: |
          set -o pipefail
          xcodebuild -project NeuralSheet.xcodeproj -scheme NeuralSheet -configuration Release \
            -destination 'platform=macOS,arch=arm64' -archivePath build/NeuralSheet.xcarchive \
            CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM_ID" \
            MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$GITHUB_RUN_NUMBER" \
            archive 2>&1 | tee build.log | tail -30
          APP=build/NeuralSheet.xcarchive/Products/Applications/NeuralSheet.app
          codesign --verify --deep --strict --verbose=2 "$APP"
          echo "built $(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleShortVersionString)" \
               "($(defaults read "$PWD/$APP/Contents/Info.plist" CFBundleVersion))"

      - name: Build the disk image
        working-directory: app
        run: |
          brew install create-dmg
          APP=build/NeuralSheet.xcarchive/Products/Applications/NeuralSheet.app
          DMG="build/NeuralSheet-$TAG-macos-arm64.dmg"
          rm -rf build/dmg-root && mkdir -p build/dmg-root
          cp -R "$APP" build/dmg-root/
          volicon=()
          if [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then
            volicon=(--volicon "$APP/Contents/Resources/AppIcon.icns")
          fi
          # create-dmg exits 2 when the image is fine but Finder could not lay
          # out the window (headless runners sometimes refuse); that is a
          # cosmetic loss, not a failed release.
          set +e
          create-dmg \
            --volname "NeuralSheet $TAG" "${volicon[@]}" \
            --window-pos 200 120 --window-size 540 380 --icon-size 128 \
            --icon NeuralSheet.app 140 180 --app-drop-link 400 180 \
            --no-internet-enable --hdiutil-quiet \
            "$DMG" build/dmg-root
          status=$?
          set -e
          if [ "$status" -eq 2 ]; then
            echo "::warning::create-dmg could not apply the window layout; the image is still valid"
          elif [ "$status" -ne 0 ]; then
            exit "$status"
          fi
          ls -l "$DMG"

      - name: Sign, notarize and staple
        working-directory: app
        env:
          IDENTITY: ${{ secrets.MACOS_SIGNING_IDENTITY }}
          ASC_API_KEY_P8: ${{ secrets.ASC_API_KEY_P8 }}
          ASC_API_KEY_ID: ${{ secrets.ASC_API_KEY_ID }}
          ASC_API_ISSUER_ID: ${{ secrets.ASC_API_ISSUER_ID }}
        run: |
          APP=build/NeuralSheet.xcarchive/Products/Applications/NeuralSheet.app
          DMG="build/NeuralSheet-$TAG-macos-arm64.dmg"
          KEY="$RUNNER_TEMP/AuthKey.p8"
          printf '%s\n' "$ASC_API_KEY_P8" > "$KEY"

          codesign --sign "$IDENTITY" --timestamp "$DMG"
          codesign --verify --verbose=2 "$DMG"

          xcrun notarytool submit "$DMG" --key "$KEY" --key-id "$ASC_API_KEY_ID" \
            --issuer "$ASC_API_ISSUER_ID" --wait --timeout 45m --output-format json \
            | tee build/notarize.json
          status=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", ""))' < build/notarize.json)
          if [ "$status" != "Accepted" ]; then
            id=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("id", ""))' < build/notarize.json)
            [ -n "$id" ] && xcrun notarytool log "$id" --key "$KEY" --key-id "$ASC_API_KEY_ID" --issuer "$ASC_API_ISSUER_ID"
            echo "::error::notarization ended with status '${status:-unknown}'"
            exit 1
          fi
          rm "$KEY"

          # The ticket covers the app inside the image too; staple both so the
          # DMG and the zipped app each work offline.
          xcrun stapler staple "$DMG"
          xcrun stapler staple "$APP"
          spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
          ditto -c -k --keepParent "$APP" "build/NeuralSheet-$TAG-macos-arm64.zip"

      - name: Remove the signing keychain
        if: always()
        run: security delete-keychain build.keychain || true

      - name: Tag the commit
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git tag -a "$TAG" -m "NeuralSheet $TAG" "$SHA"
          git push origin "refs/tags/$TAG"

      - name: Publish the GitHub release
        uses: softprops/action-gh-release@v2
        with:
          tag_name: ${{ env.TAG }}
          target_commitish: ${{ env.SHA }}
          name: NeuralSheet ${{ env.TAG }}
          generate_release_notes: true
          fail_on_unmatched_files: true
          files: |
            app/build/NeuralSheet-${{ env.TAG }}-macos-arm64.dmg
            app/build/NeuralSheet-${{ env.TAG }}-macos-arm64.zip

      - name: Summary
        run: |
          {
            echo "## NeuralSheet $TAG"
            echo
            echo "- commit \`$SHA\`"
            echo "- build $GITHUB_RUN_NUMBER"
            echo "- https://github.com/$GITHUB_REPOSITORY/releases/tag/$TAG"
          } >> "$GITHUB_STEP_SUMMARY"
EOF
```

- [ ] **Step 3: Lint the workflow**

Run: `actionlint .github/workflows/release.yml`
Expected: no output, exit 0. If `shellcheck` findings appear (actionlint runs it when installed), fix them in place; `${!name}` indirect expansion in the secrets check is intentional — if shellcheck flags SC3053 there, the step is `bash` (the default shell on macOS runners is bash) and the warning can be silenced with `# shellcheck disable=SC3053` on the line above the loop.

- [ ] **Step 4: Dry-run the version job's script locally**

Run:
```bash
previous=$(app/Scripts/release-version.sh --previous); echo "previous=[$previous]"
app/Scripts/release-changes.sh "$previous" | wc -l
app/Scripts/release-version.sh
```
Expected: `previous=[]`, a non-zero path count, `1.0.0`.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "chore: release on every code change to main as a notarized dmg

The workflow runs after a green CI on main instead of on a tag push, computes
the version from the tags and the pbxproj, and publishes a signed, notarized
disk image plus a zip. Signing is required; a missing secret fails the run."
```

---

### Task 4: `docs/release.md` — the maintainer setup guide

**Files:**
- Create: `docs/release.md`

**Interfaces:**
- Consumes: the secret names and flow from Task 3.
- Produces: the document `AGENTS.md` and `README.md` may link to.

- [ ] **Step 1: Write the guide**

```bash
cat > docs/release.md <<'EOF'
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
- Pushes that change only `docs/`, `*.md`, `LICENSE`, `NOTICE` or `.github/`
  (except the workflows) release nothing. The run says so in its log.

Add the release's notes to `CHANGELOG.md` yourself; the GitHub release body is
generated from the commits.

## One-time setup: the secrets

The workflow refuses to run without all seven of these repository secrets; an
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

`gh secret list` should now show all seven names.

### 3. The first release

Push a code change to `main` (or run the Release workflow from the Actions
tab with **Run workflow**). The `Decide the version` job prints the version and
the changed paths; `Build and publish` takes about fifteen minutes, most of it
the engine build the first time and Apple's notarization queue. The release
appears at https://github.com/bring-shrubbery/neural-sheet/releases.

## When it fails

- **missing repository secrets** — the first step names them; add and re-run.
- **notarization ended with status Invalid** — the step prints Apple's log;
  the usual causes are a binary without the hardened runtime or a missing
  timestamp. Both are set by the project and the workflow, so look at what
  changed.
- **create-dmg could not apply the window layout** — a warning only; the
  image is valid, it just lacks the icon arrangement.
- **The tag exists** — a previous run tagged but failed to publish. Delete the
  tag (`git push origin :refs/tags/vX.Y.Z`) and re-run, or publish the release
  by hand from the run's artifacts.
EOF
```

- [ ] **Step 2: Check the links and names against the workflow**

Run: `grep -o 'secrets\.[A-Z_0-9]*' .github/workflows/release.yml | sort -u; grep -o 'gh secret set [A-Z_0-9]*' docs/release.md | sort -u`
Expected: the same seven names in both lists.

- [ ] **Step 3: Commit**

```bash
git add docs/release.md
git commit -m "docs: how releases happen and how a maintainer sets up the signing secrets"
```

---

### Task 5: Repo docs — AGENTS.md, README, CHANGELOG, spec

**Files:**
- Modify: `AGENTS.md` (the "Maintainer workflow" paragraph, last section)
- Modify: `CHANGELOG.md` (the `[Unreleased]` → `### Added` list)
- Modify: `README.md` (only if it has an Install or Download section mentioning releases; otherwise leave it)
- Modify: `docs/design/2026-09-19-automatic-releases-design.md` (Files section: the filter lives in the script)

- [ ] **Step 1: Update AGENTS.md**

Replace the last sentence of the "Maintainer workflow" section (`…and tagged `vX.Y.Z` for release. The release workflow signs and notarizes only when the Developer ID secrets are configured.`) with:

```
…implemented on `main` or a short-lived branch, and reviewed (spec compliance and code quality) before landing. Every code change that lands on `main` and passes CI is released automatically as a signed, notarized disk image tagged `vX.Y.Z` (patch + 1; raise `MARKETING_VERSION` in Xcode for a minor or major). Never push a `v*` tag by hand. See `docs/release.md`.
```

Run: `grep -n "release" AGENTS.md`
Expected: the new sentence; no mention of "signs and notarizes only when".

- [ ] **Step 2: Update CHANGELOG.md**

Under `## [Unreleased]` → `### Added`, append:

```
- Automatic releases: every code change on `main` that passes CI is published as a signed, notarized `.dmg` (and zip) on a GitHub release, tagged with the next patch version (`docs/release.md`).
```

- [ ] **Step 3: Update the spec's Files section**

In `docs/design/2026-09-19-automatic-releases-design.md`, replace the line
`- `.github/release-ignore` — the docs-only filter.` with
`- `app/Scripts/release-changes.sh` — the docs-only filter; tested locally.`
and, in the Trigger section, replace `filtered through `.github/release-ignore` (gitignore syntax):` with `filtered by `app/Scripts/release-changes.sh`, which ignores`.

- [ ] **Step 4: Check the README**

Run: `grep -n -i "release\|download\|install" README.md`
If a line points readers at a zip or at "Releases" in a way now wrong (e.g. "download the zip"), change it to say the `.dmg`; if nothing references the asset format, leave the README alone.

- [ ] **Step 5: Commit**

```bash
git add AGENTS.md CHANGELOG.md README.md docs/design/2026-09-19-automatic-releases-design.md
git commit -m "docs: releases are automatic; the change filter lives in release-changes.sh"
```

---

### Task 6: Verify and hand over

**Files:** none.

- [ ] **Step 1: Run every local check once more**

Run:
```bash
app/Scripts/release-version-test.sh && app/Scripts/release-changes-test.sh && actionlint .github/workflows/release.yml && git status --short
```
Expected: `all passed` twice, actionlint silent, a clean tree.

- [ ] **Step 2: Confirm nothing else references the old tag-triggered flow**

Run: `grep -rn "tags: \['v\*'\]\|v\* tag\|push a tag" --exclude-dir=.git --exclude-dir=build . | grep -v "docs/design/2026-09-19-automatic-releases"`
Expected: no matches (the spec and plan may mention it historically).

- [ ] **Step 3: Report to the maintainer**

Tell them, in this order: what was committed (nothing is pushed by this plan); that the workflow will fail on the secrets check until the seven secrets exist; the exact steps in `docs/release.md` §1–2; and that the first real push after that produces `v1.0.0` (since no strict tag exists yet and the pbxproj says 1.0.0).
