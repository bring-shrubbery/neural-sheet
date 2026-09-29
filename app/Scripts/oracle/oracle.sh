#!/bin/bash
# Regenerates the oracle fixtures the Swift engine's tests compare against:
# compiles Scripts/oracle/oracle.cpp against the muscriptor.cpp archives and
# runs it for `small` and `medium` on the CPU and on Metal. See README.md.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd) # the app/ directory that owns this script

# Where the engine's headers and archives live. They sit under ROOT in a normal
# checkout; the override exists for a worktree without the submodule, and for
# regenerating the dumps once the submodule has been removed from the tree.
ENGINE_ROOT=${NEURALSHEET_ENGINE_ROOT:-$ROOT}

SRC="$ENGINE_ROOT/ThirdParty/muscriptor.cpp"
LIB="$ENGINE_ROOT/build/engine/lib"
OUT_BASE="$ROOT/Packages/NeuralSheetEngine/Tests/NeuralSheetEngineTests/Fixtures/oracle"

if [ ! -d "$SRC/cpp/include" ]; then
    echo "error: $SRC is missing; run git submodule update --init --recursive, or set NEURALSHEET_ENGINE_ROOT" >&2
    exit 1
fi

# The archives are normally already there; only build them when they are not, so
# a regeneration run never rebuilds the engine behind the caller's back.
if [ ! -f "$LIB/libmuscriptor_ggml.a" ]; then
    "$ENGINE_ROOT/Scripts/build-engine.sh"
fi

# The commit the dumps came from, recorded in every hparams.json. The override is
# for a checkout where git cannot answer (a worktree without the submodule).
COMMIT=${NEURALSHEET_MUSCRIPTOR_COMMIT:-$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)}

# The package's own copy of the fixture once Task 1 has landed, the submodule's
# testdata otherwise; they are the same file.
FIXTURE="$ROOT/Packages/NeuralSheetEngine/Tests/NeuralSheetEngineTests/Fixtures/audio/fixture_3chunks_16k.wav"
if [ ! -f "$FIXTURE" ]; then
    FIXTURE="$SRC/testdata/audio/fixture_3chunks_16k.wav"
fi

if [ ! -f "$FIXTURE" ]; then
    echo "error: no fixture_3chunks_16k.wav under the package or $SRC/testdata/audio" >&2
    exit 1
fi

BIN_DIR="$ROOT/build/oracle"
mkdir -p "$BIN_DIR"

clang++ -std=c++23 -O2 \
    -I "$SRC/cpp/include" \
    -I "$SRC/cpp/src" \
    "$ROOT/Scripts/oracle/oracle.cpp" \
    -L "$LIB" \
    -lmuscriptor_ggml -lggml -lggml-base -lggml-cpu -lggml-metal -lpffft \
    -framework Metal -framework MetalKit -framework Accelerate -framework Foundation \
    -o "$BIN_DIR/oracle"

# Checkpoints, in the order the engine's Swift package resolves them.
MODEL_DIRS=()
if [ -n "${NEURALSHEET_MODELS:-}" ]; then
    MODEL_DIRS+=("$NEURALSHEET_MODELS")
fi
MODEL_DIRS+=("$HOME/Library/NeuralSheet/models" "$HOME/Library/NeuralNote/models")

find_checkpoint() {
    local size=$1
    local dir
    for dir in "${MODEL_DIRS[@]}"; do
        if [ -f "$dir/muscriptor-$size-f16.gguf" ]; then
            echo "$dir/muscriptor-$size-f16.gguf"
            return 0
        fi
    done
    return 1
}

echo "muscriptor.cpp: $COMMIT"
echo "fixture: $FIXTURE"

for size in small medium large; do
    if ! checkpoint=$(find_checkpoint "$size"); then
        echo "error: no muscriptor-$size-f16.gguf under \$NEURALSHEET_MODELS, ~/Library/NeuralSheet/models or ~/Library/NeuralNote/models" >&2
        exit 1
    fi

    for device in cpu gpu; do
        # The directory is named after the backend, not the request: `gpu` is Metal.
        backend=cpu
        if [ "$device" = gpu ]; then
            backend=metal
        fi

        out="$OUT_BASE/$size-$backend"
        echo "== $size-$backend"
        "$BIN_DIR/oracle" "$checkpoint" "$device" "$FIXTURE" "$out" "$COMMIT"
    done
done

echo "oracle: wrote $OUT_BASE"
