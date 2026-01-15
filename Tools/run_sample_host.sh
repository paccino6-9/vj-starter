#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/Build"
OUT="$BUILD_DIR/sample_host"
DEFAULT_PLUGIN="$BUILD_DIR/Plugins/libTranceGlow.dylib"

PLUGIN_PATH="$DEFAULT_PLUGIN"

if [[ $# -eq 0 ]]; then
  PASS_ARGS=(--plugin "$DEFAULT_PLUGIN")
else
  PASS_ARGS=("$@")
fi

# Extract plugin path from args (supports shorthand first-arg or --plugin PATH)
args=("$@")
for ((i=1; i<=${#args[@]}; i++)); do
  cur="${args[i]:-}"
  nxt="${args[i+1]:-}"
  if [[ "$cur" == "--plugin" && -n "$nxt" ]]; then
    PLUGIN_PATH="$nxt"
    break
  elif [[ "$cur" != --* && $i -eq 1 ]]; then
    PLUGIN_PATH="$cur"
    break
  fi
done

if [ ! -f "$PLUGIN_PATH" ]; then
  echo "Plugin not found at: $PLUGIN_PATH" >&2
  echo "Build them with: $ROOT_DIR/Tools/build_examples.sh" >&2
  exit 1
fi

mkdir -p "$BUILD_DIR"

echo "[build] sample_host..."
clang++ -std=c++20 -fobjc-arc -ObjC++ \
  -I"$ROOT_DIR/SDK/include" \
  "$ROOT_DIR/Tools/sample_host.mm" \
  -framework Metal -framework Foundation -framework CoreGraphics -framework ImageIO \
  -o "$OUT"

echo "[run] $OUT ${PASS_ARGS[*]}"
"$OUT" "${PASS_ARGS[@]}"
