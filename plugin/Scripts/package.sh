#!/bin/bash
# Archives the plugin's container app with the Developer ID, as the release does the Mac app,
# and puts it on a signed disk image (Audio Unit design §2, "Project"; docs/release.md, "Audio
# Unit"). The release workflow runs it and then notarizes the image; it runs the same on a Mac
# with the certificate, which is how the steps are tried without a release.
#
#   package.sh --version 1.1.3 --build 42 --identity "Developer ID Application: …" \
#              --team 6WCYZER5LX --out build
#
# Writes <out>/NeuralSheet-Plugin.xcarchive and <out>/NeuralSheet-Plugin-v<version>-macos-arm64.dmg
# and prints the image's path last. Needs create-dmg (brew install create-dmg).
#
# The archive takes the release's version on the command line, as the Mac app's does. The
# component's integer version cannot be a build setting, so it is stamped into the built
# extension and the extension and the app are signed again, inside out, keeping the entitlements
# Xcode signed them with (the sandbox and the App Group).
set -euo pipefail

cd "$(dirname "$0")/.."

version="" build="" identity="" team="" out=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version) version=$2; shift 2 ;;
        --build) build=$2; shift 2 ;;
        --identity) identity=$2; shift 2 ;;
        --team) team=$2; shift 2 ;;
        --out) out=$2; shift 2 ;;
        *) echo "error: unknown argument $1" >&2; exit 2 ;;
    esac
done
if [ -z "$version" ] || [ -z "$build" ] || [ -z "$identity" ] || [ -z "$team" ] || [ -z "$out" ]; then
    echo "usage: package.sh --version X.Y.Z --build N --identity ID --team TEAM --out DIR" >&2
    exit 2
fi

group="$team.com.quassum.neuralsheet"
tag="v$version"
mkdir -p "$out"
out=$(cd "$out" && pwd)
archive="$out/NeuralSheet-Plugin.xcarchive"
dmg="$out/NeuralSheet-Plugin-$tag-macos-arm64.dmg"

# The files must carry the Mac app's version (the floor); the build carries the release's.
echo "== version"
Scripts/check-version.sh
integer=$(Scripts/check-version.sh --pack "$version")

echo "== archive $version ($build)"
rm -rf "$archive"
set -o pipefail
xcodebuild -project NeuralSheet-Plugin.xcodeproj -scheme "NeuralSheet Plugin" -configuration Release \
    -destination 'platform=macOS,arch=arm64' -archivePath "$archive" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" PROVISIONING_PROFILE_SPECIFIER= \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
    archive 2>&1 | tee "$out/plugin-build.log" | tail -30

app="$archive/Products/Applications/NeuralSheet Plugin.app"
appex="$app/Contents/PlugIns/NeuralSheetAU.appex"
if [ ! -d "$appex" ]; then
    echo "error: the archive has no $appex" >&2
    exit 1
fi

echo "== stamp the component version $integer and sign again"
/usr/libexec/PlistBuddy -c "Set :NSExtension:NSExtensionAttributes:AudioComponents:0:version $integer" "$appex/Contents/Info.plist"
codesign -f -s "$identity" -o runtime --timestamp --preserve-metadata=entitlements "$appex"
codesign -f -s "$identity" -o runtime --timestamp --preserve-metadata=entitlements "$app"

echo "== check"
failed=0
fail() {
    echo "error: $*" >&2
    failed=1
}
# A signed entitlement's value, one line per element of an array (a key path cannot name a key
# with dots in it, so not plutil).
entitlement() {
    codesign -d --entitlements - --xml "$1" 2>/dev/null | python3 -c '
import plistlib, sys
value = plistlib.loads(sys.stdin.buffer.read() or b"<plist><dict/></plist>").get(sys.argv[1])
for item in value if isinstance(value, list) else ([] if value is None else [value]):
    print(item)
' "$2"
}
for bundle in "$app" "$appex"; do
    name=$(basename "$bundle")
    short=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$bundle/Contents/Info.plist")
    number=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$bundle/Contents/Info.plist")
    [ "$short" = "$version" ] || fail "$name is version $short, expected $version"
    [ "$number" = "$build" ] || fail "$name is build $number, expected $build"
    details=$(codesign -dvv "$bundle" 2>&1)
    grep -qF "Authority=${identity%% (*}" <<<"$details" || fail "$name is not signed by $identity"
    grep -q "flags=.*runtime" <<<"$details" || fail "$name lacks the hardened runtime"
    grep -q "^Timestamp=" <<<"$details" || fail "$name has no secure timestamp"
    entitlement "$bundle" com.apple.security.application-groups | grep -qxF "$group" \
        || fail "$name does not carry the App Group $group"
    echo "$name $short ($number)"
done
[ "$(entitlement "$appex" com.apple.security.app-sandbox)" = "True" ] || fail "NeuralSheetAU.appex is not sandboxed"
stamped=$(/usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionAttributes:AudioComponents:0:version" "$appex/Contents/Info.plist")
[ "$stamped" = "$integer" ] || fail "the component version is $stamped, expected $integer"
codesign --verify --deep --strict --verbose=2 "$app" || fail "the app's signature does not verify"
if [ "$failed" -ne 0 ]; then
    exit 1
fi

echo "== disk image"
rm -rf "$out/plugin-dmg-root" "$dmg"
mkdir -p "$out/plugin-dmg-root"
cp -R "$app" "$out/plugin-dmg-root/"
# As the Mac app's image: create-dmg exits 64 with no image when the Finder AppleScript that
# lays out the window fails, which happens on headless runners; retry once without the layout.
args=(
    --volname "NeuralSheet Plugin $tag"
    --window-pos 200 120 --window-size 540 380 --icon-size 128
    --icon "NeuralSheet Plugin.app" 140 180 --app-drop-link 400 180
    --no-internet-enable --hdiutil-quiet
)
if ! create-dmg "${args[@]}" "$dmg" "$out/plugin-dmg-root"; then
    echo "::warning::create-dmg could not lay out the plugin's window; retrying without the Finder layout"
    rm -f "$dmg"
    create-dmg "${args[@]}" --skip-jenkins "$dmg" "$out/plugin-dmg-root"
fi
rm -rf "$out/plugin-dmg-root"
codesign --sign "$identity" --timestamp "$dmg"
codesign --verify --verbose=2 "$dmg"
ls -l "$dmg"
echo "$dmg"
