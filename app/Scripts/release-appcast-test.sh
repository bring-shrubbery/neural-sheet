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
