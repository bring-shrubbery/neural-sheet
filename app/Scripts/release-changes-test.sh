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
