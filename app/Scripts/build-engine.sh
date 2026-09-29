#!/bin/bash
# Builds demucs.cpp into the static archive the app links for stem separation. Transcription
# itself is pure Swift (Packages/NeuralSheetEngine) and needs nothing from here.
# Idempotent: re-running after a successful build is a no-op unless the submodule moved.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
STEMS_SRC="$ROOT/Scripts/stems"
OUT="$ROOT/build/engine"

if [ ! -f "$ROOT/ThirdParty/demucs.cpp/vendor/eigen/Eigen/Dense" ]; then
    echo "error: $ROOT/ThirdParty/demucs.cpp (with its vendor/eigen) is missing; run git submodule update --init --recursive" >&2
    exit 1
fi

# .stamp records the submodule commit the archive in lib/ was built from, so
# a submodule bump (even one that touches no CMakeLists) rebuilds it.
ENGINE_REV="$(git -C "$ROOT/ThirdParty/demucs.cpp" rev-parse HEAD 2>/dev/null || echo unknown)"
if [ -f "$OUT/lib/libdemucs.a" ] \
    && [ -f "$OUT/.stamp" ] \
    && [ "$(cat "$OUT/.stamp")" = "$ENGINE_REV" ]; then
    echo "engine: up to date ($ENGINE_REV)"
    exit 0
fi

# Xcode's run-script PATH does not include Homebrew.
CMAKE=$(command -v cmake || true)
if [ -z "$CMAKE" ] && [ -x /opt/homebrew/bin/cmake ]; then
    CMAKE=/opt/homebrew/bin/cmake
fi
if [ -z "$CMAKE" ]; then
    echo "error: cmake not found; brew install cmake" >&2
    exit 1
fi

# The stem separation library (stem separation design §2), its own CMake project.
"$CMAKE" -S "$STEMS_SRC" -B "$OUT/stems" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DCMAKE_OSX_ARCHITECTURES=arm64

"$CMAKE" --build "$OUT/stems" -j"$(sysctl -n hw.ncpu)"

mkdir -p "$OUT/lib"
found=$(find "$OUT/stems" -name "libdemucs.a" -print -quit)
if [ -z "$found" ]; then
    echo "error: libdemucs.a not found under $OUT/stems after the build" >&2
    exit 1
fi
cp "$found" "$OUT/lib/libdemucs.a"

echo "$ENGINE_REV" > "$OUT/.stamp"
echo "engine: built $OUT/lib"
