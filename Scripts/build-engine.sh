#!/bin/bash
# Builds muscriptor.cpp (and the ggml it fetches) into static archives the app links.
# Idempotent: re-running after a successful build is a no-op unless the engine sources changed.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/ThirdParty/muscriptor.cpp/cpp"
OUT="$ROOT/build/engine"

# .stamp is touched once the archives are in place, so a stamp newer than the
# engine's CMakeLists means the copies in lib/ are current.
if [ -f "$OUT/lib/libmuscriptor_ggml.a" ] \
    && [ -f "$OUT/.stamp" ] \
    && [ "$OUT/.stamp" -nt "$SRC/CMakeLists.txt" ]; then
    echo "engine: up to date"
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

"$CMAKE" -S "$SRC" -B "$OUT" \
    -DCMAKE_BUILD_TYPE=Release \
    -DMUSCRIPTOR_METAL=ON \
    -DMUSCRIPTOR_BUILD_TESTS=OFF \
    -DMUSCRIPTOR_BUILD_BENCH=OFF \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DBUILD_TESTING=OFF

"$CMAKE" --build "$OUT" -j"$(sysctl -n hw.ncpu)"

mkdir -p "$OUT/lib"
for archive in libmuscriptor_ggml.a libpffft.a libggml.a libggml-base.a libggml-cpu.a libggml-metal.a; do
    found=$(find "$OUT" -name "$archive" -not -path "$OUT/lib/*" | head -1)
    if [ -z "$found" ]; then
        echo "error: $archive not found under $OUT after the build" >&2
        exit 1
    fi
    cp "$found" "$OUT/lib/$archive"
done

touch "$OUT/.stamp"
echo "engine: built $OUT/lib"
