#!/bin/bash
# Builds the plugin's container app (Release, into a temporary DerivedData), registers the Audio
# Unit extension it embeds with pluginkit, runs `auval -v aufx NSht Qssm`, and unregisters it
# again (Audio Unit design §2, "Validation"). Exits non-zero when the build fails, when our own
# sources warn, when the component's version disagrees with MARKETING_VERSION, or when auval
# does not pass.
#
#   NS_PLUGIN_SKIP_AUVAL=1   build and check only; no registration, no auval (for machines
#                            without a login session, where pluginkit cannot register)
#   NS_PLUGIN_SIGNING=team   sign as the project does (the default when an Apple Development
#                            identity is in the keychain)
#   NS_PLUGIN_SIGNING=adhoc  sign ad hoc (the default otherwise, as on a CI runner)
#
# Any further arguments are passed to xcodebuild.
set -euo pipefail

cd "$(dirname "$0")/.."

component=(aufx NSht Qssm)
derived=$(mktemp -d "${TMPDIR:-/tmp}/neuralsheet-plugin.XXXXXX")
appex=""

cleanup() {
    if [ -n "$appex" ]; then
        pluginkit -r "$appex" 2>/dev/null || true
    fi
    rm -rf "$derived"
    # SwiftPM leaves a lock beside the temporary DerivedData, named after its path.
    rm -f "${TMPDIR:-/tmp}"/*"$(basename "$derived")"*.lock
}
trap cleanup EXIT

# A sandboxed extension must carry a signature. Ad hoc lets a machine without the team's
# certificate (a CI runner) register and load it, but on a Mac where the extension has run
# signed by the team, its sandbox container belongs to that signature and an ad hoc build hangs
# in sandbox setup waiting for the user to allow it; so a developer's Mac signs as the project
# does.
mode=${NS_PLUGIN_SIGNING:-}
if [ -z "$mode" ]; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Development"; then
        mode=team
    else
        mode=adhoc
    fi
fi
case "$mode" in
    team) signing=() ;;
    adhoc) signing=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=) ;;
    *) echo "error: NS_PLUGIN_SIGNING is team or adhoc, not $mode" >&2; exit 2 ;;
esac
echo "signing: $mode"

# arm64 only, on the command line so it reaches the packages too (the engine's Float16 kernels
# do not exist on x86_64), as the Mac release workflow builds the app.
echo "== build (Release) into $derived"
set +e
xcodebuild -project NeuralSheet-Plugin.xcodeproj -scheme "NeuralSheet Plugin" \
    -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$derived" ARCHS=arm64 ONLY_ACTIVE_ARCH=YES ${signing[@]+"${signing[@]}"} "$@" build >"$derived/build.log" 2>&1
status=$?
set -e
tail -5 "$derived/build.log"
if [ "$status" -ne 0 ]; then
    grep -E " error:" "$derived/build.log" | sort -u || true
    echo "error: build failed" >&2
    exit 1
fi

if grep -E "/(plugin/(Container|NeuralSheetAU|PluginCore)|app/(Packages|NeuralSheet))/.*warning:" "$derived/build.log" | sort -u; then
    echo "error: warnings in NeuralSheet sources" >&2
    exit 1
fi
echo "no warnings in NeuralSheet sources"

app="$derived/Build/Products/Release/NeuralSheet Plugin.app"
appex="$app/Contents/PlugIns/NeuralSheetAU.appex"
info="$appex/Contents/Info.plist"

# The component's integer version must be MARKETING_VERSION's (major << 16 | minor << 8 | patch).
marketing=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$info")
declared=$(/usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionAttributes:AudioComponents:0:version" "$info")
IFS=. read -r major minor patch <<<"$marketing"
expected=$(((major << 16) | (minor << 8) | ${patch:-0}))
if [ "$declared" != "$expected" ]; then
    echo "error: AudioComponents version $declared is not MARKETING_VERSION $marketing ($expected); update project.yml" >&2
    exit 1
fi
echo "component version $declared matches $marketing"

if [ "${NS_PLUGIN_SKIP_AUVAL:-0}" = 1 ]; then
    echo "NS_PLUGIN_SKIP_AUVAL=1: not registering or running auval"
    appex=""
    exit 0
fi

echo "== register $appex"
pluginkit -a "$appex"

# Another copy registered with the same identifier and version (an Xcode build, an installed
# container) may be the one auval loads; say so rather than unregister the user's copy.
others=$(pluginkit -m -v -i com.quassum.neuralsheet.plugin.au 2>/dev/null | grep -vF "$(basename "$derived")" | grep "/" || true)
if [ -n "$others" ]; then
    echo "note: other registered copies, which auval may load instead:"
    echo "$others"
fi

# Registration reaches the component registry asynchronously.
for _ in $(seq 1 30); do
    # Read whole: auval aborts when the pipe it writes to closes early, as `grep -q` closes it.
    listing=$(auval -a 2>/dev/null || true)
    if grep -q "${component[*]}" <<<"$listing"; then
        break
    fi
    sleep 1
done

echo "== auval -v ${component[*]}"
set +e
auval -v "${component[@]}" >"$derived/auval.log" 2>&1
status=$?
set -e
cat "$derived/auval.log"

echo "== summary"
if [ "$status" -ne 0 ] || ! grep -q "AU VALIDATION SUCCEEDED" "$derived/auval.log"; then
    echo "error: auval failed (exit $status)" >&2
    exit 1
fi

# The system's version 3 bridge answers the old CurrentPreset property itself, and auval warns
# about that for every AUv3 whatever the unit implements (a current preset and factory presets
# were tried); it is reported but not fatal. Any other warning fails, as the design asks.
known="CurrentPreset property is deprectated"
grep -F "WARNING" "$derived/auval.log" | grep -F "$known" | sort -u | sed 's/^/known (system bridge): /' || true
if grep -F "WARNING" "$derived/auval.log" | grep -vF "$known" | sort -u | grep .; then
    echo "error: auval warnings" >&2
    exit 1
fi
echo "auval passed"
