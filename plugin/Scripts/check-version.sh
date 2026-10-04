#!/bin/bash
# The plugin carries the Mac app's version (Audio Unit design §2, "Project"). Checks that
# MARKETING_VERSION in plugin/project.yml and in the generated project is the Mac app's
# (app/NeuralSheet.xcodeproj), and that the component's integer version in project.yml and in
# NeuralSheetAU/Info.plist is that version packed as major << 16 | minor << 8 | patch. Exits
# non-zero, naming what disagrees, otherwise.
#
#   check-version.sh               the check; prints the version on success
#   check-version.sh --pack 1.1.3  prints 1.1.3 packed (65795); fails when minor or patch
#                                  passes 255, which the integer cannot hold
#
# The release builds with the release's version (MARKETING_VERSION=X.Y.Z, as the Mac app) and
# stamps the packed integer into the built extension, so the files here only need to agree
# with the Mac app's floor.
set -euo pipefail

PLUGIN=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$(cd "$PLUGIN/.." && pwd)

pack() {
    local version=$1 major minor patch
    if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "error: $version is not major.minor.patch" >&2
        return 1
    fi
    IFS=. read -r major minor patch <<<"$version"
    major=$((10#$major)) minor=$((10#$minor)) patch=$((10#$patch))
    if [ "$major" -gt 65535 ] || [ "$minor" -gt 255 ] || [ "$patch" -gt 255 ]; then
        echo "error: $version does not fit the component's version integer (minor and patch up to 255); raise MARKETING_VERSION" >&2
        return 1
    fi
    echo $(((major << 16) | (minor << 8) | patch))
}

if [ "${1:-}" = "--pack" ]; then
    pack "${2:?usage: check-version.sh --pack X.Y.Z}"
    exit
fi

# MARKETING_VERSION from a project file; every configuration must agree.
project_version() {
    local versions
    versions=$(sed -n 's/^[[:space:]]*MARKETING_VERSION = \([^;]*\);.*/\1/p' "$1" | sort -u)
    if [ "$(printf '%s\n' "$versions" | grep -c .)" -ne 1 ]; then
        echo "error: expected exactly one MARKETING_VERSION in $1, found: ${versions:-none}" >&2
        exit 1
    fi
    echo "$versions"
}

mac=$(project_version "$ROOT/app/NeuralSheet.xcodeproj/project.pbxproj")
spec=$(sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([0-9.]*\)"\{0,1\}[[:space:]]*$/\1/p' "$PLUGIN/project.yml" | sort -u)
generated=$(project_version "$PLUGIN/NeuralSheet-Plugin.xcodeproj/project.pbxproj")
spec_integer=$(sed -n 's/^[[:space:]]*version:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$PLUGIN/project.yml" | sort -u)
plist_integer=$(/usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionAttributes:AudioComponents:0:version" "$PLUGIN/NeuralSheetAU/Info.plist")
expected=$(pack "$mac")

failed=0
fail() {
    echo "error: $*" >&2
    failed=1
}
[ "$spec" = "$mac" ] || fail "plugin/project.yml MARKETING_VERSION is ${spec:-missing}, the Mac app's is $mac"
[ "$generated" = "$mac" ] || fail "NeuralSheet-Plugin.xcodeproj MARKETING_VERSION is $generated, the Mac app's is $mac; run make project"
[ "$spec_integer" = "$expected" ] || fail "plugin/project.yml component version is ${spec_integer:-missing}, $mac packs to $expected"
[ "$plist_integer" = "$expected" ] || fail "NeuralSheetAU/Info.plist component version is $plist_integer, $mac packs to $expected; run make project"
if [ "$failed" -ne 0 ]; then
    exit 1
fi
echo "$mac"
