#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/Build/Core"
OUT="$BUILD_DIR/vj_core"
DEFAULT_PLUGIN="$ROOT_DIR/Build/Plugins/libTranceGlow.dylib"

mkdir -p "$BUILD_DIR"

echo "[build] vj_core..."
clang++ -std=c++20 -fobjc-arc -ObjC++ \
  -I"$ROOT_DIR/SDK/include" \
  "$ROOT_DIR/Core/main.mm" \
  -framework Metal -framework MetalKit -framework Foundation -framework CoreGraphics -framework ImageIO -framework Cocoa \
  -o "$OUT"

# detect plugin arg (same rules as Tools/run_sample_host.sh)
args=("$@")
PLUGIN_ARG_SET=false
PLUGIN_PATH="$DEFAULT_PLUGIN"
for ((i=1; i<=${#args[@]}; i++)); do
  cur="${args[i]:-}"
  nxt="${args[i+1]:-}"
  if [[ "$cur" == "--plugin" && -n "$nxt" ]]; then
    PLUGIN_ARG_SET=true
    PLUGIN_PATH="$nxt"
    break
  elif [[ "$cur" != --* && $i -eq 1 ]]; then
    PLUGIN_ARG_SET=true
    PLUGIN_PATH="$cur"
    break
  fi
done

if [[ "$PLUGIN_ARG_SET" == false ]]; then
  # no plugin specified: ensure default exists (build examples if needed) and inject --plugin arg
  if [[ ! -f "$DEFAULT_PLUGIN" ]]; then
    echo "[build] default plugins (missing: $DEFAULT_PLUGIN)..."
    "$ROOT_DIR/Tools/build_examples.sh"
  fi
  if [[ ! -f "$DEFAULT_PLUGIN" ]]; then
    echo "[error] default plugin still missing: $DEFAULT_PLUGIN" >&2
    exit 1
  fi
  PASS_ARGS=(--plugin "$DEFAULT_PLUGIN" "$@")
else
  PASS_ARGS=("$@")
fi

echo "[run] $OUT ${PASS_ARGS[*]:-}"
"$OUT" "${PASS_ARGS[@]}"
