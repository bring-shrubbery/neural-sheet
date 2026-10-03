#!/bin/bash
# Fails when a German or Spanish string has no translation (accessibility and localization
# design §2). Exports the de and es localizations the way a translator would receive them and
# counts the <trans-unit>s without a <target>: a key added in code but not translated in
# app/NeuralSheet/*.xcstrings shows up here as one.
#
# Extra arguments are passed to xcodebuild as build settings, e.g. to build unsigned on CI:
#   Scripts/check-localizations.sh CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LANGUAGES=(de es)

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

EXPORT_ARGS=()
for lang in "${LANGUAGES[@]}"; do
    EXPORT_ARGS+=(-exportLanguage "$lang")
done

# arm64 only: the engine's Float16 kernels do not build for Intel, and an export builds every
# architecture unless told otherwise.
if ! xcodebuild -exportLocalizations -project "$ROOT/NeuralSheet.xcodeproj" -localizationPath "$OUT" \
    "${EXPORT_ARGS[@]}" ARCHS=arm64 "$@" >"$OUT/export.log" 2>&1; then
    tail -40 "$OUT/export.log" >&2
    echo "error: the localizations could not be exported" >&2
    exit 1
fi

status=0

for lang in "${LANGUAGES[@]}"; do
    XLIFF="$OUT/$lang.xcloc/Localized Contents/$lang.xliff"

    if [ ! -f "$XLIFF" ]; then
        echo "error: no $lang.xliff was exported" >&2
        status=1
        continue
    fi

    units=$(xmllint --xpath "count(//*[local-name()='trans-unit'])" "$XLIFF")
    untranslated=$(xmllint --xpath "count(//*[local-name()='trans-unit'][not(*[local-name()='target'][normalize-space()])])" "$XLIFF")

    echo "$lang: $units units, $untranslated untranslated"

    if [ "$untranslated" != "0" ]; then
        xmllint --xpath "//*[local-name()='trans-unit'][not(*[local-name()='target'][normalize-space()])]/@id" "$XLIFF" \
            | sed -E 's/^ *id="(.*)"$/  untranslated: \1/' >&2
        status=1
    fi
done

exit $status
