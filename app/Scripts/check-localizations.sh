#!/bin/bash
# Fails when a German or Spanish string has no translation (accessibility and localization
# design §2). Exports the de and es localizations the way a translator would receive them and
# counts the <trans-unit>s without a <target>: a key added in code but not translated in the
# catalogs shows up here as one. The export syncs the catalogs with the code first, as Xcode does,
# so a run can rewrite them into Xcode's own form: commit what it writes.
#
# Both apps by default: the Mac's (app/NeuralSheet/*.xcstrings) and the iPhone and iPad app's
# (ios/NeuralSheet/*.xcstrings, ios/NeuralSheetWidgets/*.xcstrings, and the Mac's Core.xcstrings it
# shares). `--mac` or `--ios` first checks one. For the iOS app it also fails when a key the Mac's
# Localizable.xcstrings holds too is translated differently: the two catalogs cannot be one file
# (a target holds one Localizable table, and the iOS export would rewrite the Mac's), so the
# shared wording is kept the same here (sub-issue J).
#
# Further arguments are passed to xcodebuild as build settings, e.g. to build unsigned on CI:
#   Scripts/check-localizations.sh --mac CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(cd "$ROOT/.." && pwd)
LANGUAGES=(de es)

PROJECTS=(mac ios)
case "${1:-}" in
    --mac) PROJECTS=(mac); shift ;;
    --ios) PROJECTS=(ios); shift ;;
esac

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

EXPORT_ARGS=()
for lang in "${LANGUAGES[@]}"; do
    EXPORT_ARGS+=(-exportLanguage "$lang")
done

status=0

# Counts the units without a translation in each exported language of one project.
check_export() {
    local name=$1 dir=$2

    for lang in "${LANGUAGES[@]}"; do
        local xliff="$dir/$lang.xcloc/Localized Contents/$lang.xliff"

        if [ ! -f "$xliff" ]; then
            echo "error: no $lang.xliff was exported for $name" >&2
            status=1
            continue
        fi

        local units untranslated
        units=$(xmllint --xpath "count(//*[local-name()='trans-unit'])" "$xliff")
        untranslated=$(xmllint --xpath "count(//*[local-name()='trans-unit'][not(*[local-name()='target'][normalize-space()])])" "$xliff")

        echo "$name $lang: $units units, $untranslated untranslated"

        if [ "$untranslated" != "0" ]; then
            xmllint --xpath "//*[local-name()='trans-unit'][not(*[local-name()='target'][normalize-space()])]/@id" "$xliff" \
                | sed -E 's/^ *id="(.*)"$/  untranslated: \1/' >&2
            status=1
        fi
    done
}

for project in "${PROJECTS[@]}"; do
    case $project in
        mac)
            # arm64 only: the engine's Float16 kernels do not build for Intel, and an export builds
            # every architecture unless told otherwise.
            if ! xcodebuild -exportLocalizations -project "$ROOT/NeuralSheet.xcodeproj" -localizationPath "$OUT/mac" \
                "${EXPORT_ARGS[@]}" ARCHS=arm64 "$@" >"$OUT/mac.log" 2>&1; then
                tail -40 "$OUT/mac.log" >&2
                echo "error: the Mac localizations could not be exported" >&2
                exit 1
            fi

            check_export mac "$OUT/mac"
            ;;
        ios)
            # For the simulator, whose engine build CI caches.
            if ! xcodebuild -exportLocalizations -project "$REPO/ios/NeuralSheet-iOS.xcodeproj" -localizationPath "$OUT/ios" \
                "${EXPORT_ARGS[@]}" -sdk iphonesimulator ARCHS=arm64 "$@" >"$OUT/ios.log" 2>&1; then
                tail -40 "$OUT/ios.log" >&2
                echo "error: the iOS localizations could not be exported" >&2
                exit 1
            fi

            check_export ios "$OUT/ios"

            # The wording both apps show, translated alike.
            if ! python3 - "$ROOT/NeuralSheet/Localizable.xcstrings" "$REPO/ios/NeuralSheet/Localizable.xcstrings" "${LANGUAGES[@]}" <<'EOF'
import json, sys

mac_path, ios_path, *languages = sys.argv[1:]
mac = json.load(open(mac_path, encoding="utf-8"))["strings"]
ios = json.load(open(ios_path, encoding="utf-8"))["strings"]

def text(entry, lang):
    loc = entry.get("localizations", {}).get(lang)
    return json.dumps(loc, sort_keys=True) if loc else None

shared = sorted(set(mac) & set(ios))
drift = [(key, lang) for key in shared for lang in languages
         if text(mac[key], lang) and text(ios[key], lang) and text(mac[key], lang) != text(ios[key], lang)]

print(f"ios: {len(shared)} keys shared with the Mac, {len(drift)} translated differently")
for key, lang in drift:
    print(f"  differs from the Mac ({lang}): {key}", file=sys.stderr)
sys.exit(1 if drift else 0)
EOF
            then
                status=1
            fi
            ;;
    esac
done

exit $status
