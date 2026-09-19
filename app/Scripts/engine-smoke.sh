#!/bin/bash
# Compiles and runs Scripts/engine_smoke.cpp against an installed checkpoint:
# proof that the engine archives and the C bridge link and transcribe.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

"$ROOT/Scripts/build-engine.sh"

MODEL=""
for candidate in \
    "$HOME/Library/NeuralSheet/models/muscriptor-small-f16.gguf" \
    "$HOME/Library/NeuralNote/models/muscriptor-small-f16.gguf" \
    "$HOME/Library/NeuralSheet/models/muscriptor-large-f16.gguf" \
    "$HOME/Library/NeuralNote/models/muscriptor-large-f16.gguf"; do
    if [ -f "$candidate" ]; then
        MODEL="$candidate"
        break
    fi
done

if [ -z "$MODEL" ]; then
    echo "error: no muscriptor checkpoint found under ~/Library/NeuralSheet/models or ~/Library/NeuralNote/models" >&2
    exit 1
fi

clang++ -std=c++23 \
    -I "$ROOT/ThirdParty/muscriptor.cpp/cpp/include" \
    "$ROOT/NeuralSheet/Engine/nsheet_engine.cpp" \
    "$ROOT/Scripts/engine_smoke.cpp" \
    -L "$ROOT/build/engine/lib" \
    -lmuscriptor_ggml -lggml -lggml-base -lggml-cpu -lggml-metal -lpffft \
    -framework Metal -framework MetalKit -framework Accelerate -framework Foundation \
    -o "$ROOT/build/engine/smoke"

echo "model: $MODEL"
exec "$ROOT/build/engine/smoke" "$MODEL"
