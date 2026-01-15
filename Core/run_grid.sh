#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/Build/Core"
OUT="$BUILD_DIR/vj_grid"

mkdir -p "$BUILD_DIR"

echo "[prepare] media config + placeholders..."
python3 "$ROOT_DIR/Core/generate_media_config.py"

echo "[build] vj_grid..."
clang++ -std=c++20 -fobjc-arc -ObjC++ \
  -I"$ROOT_DIR/SDK/include" \
  "$ROOT_DIR/Core/grid_host.mm" \
  -framework Metal -framework Foundation -framework CoreGraphics -framework ImageIO -framework Cocoa \
  -o "$OUT"

if [ ! -f "$ROOT_DIR/Build/Plugins/libMandalaGen.dylib" ] || \
   [ ! -f "$ROOT_DIR/Build/Plugins/libTextFX.dylib" ] || \
   [ ! -f "$ROOT_DIR/Build/Plugins/libVideoSim.dylib" ] || \
   [ ! -f "$ROOT_DIR/Build/Plugins/libPointCloud.dylib" ] || \
   [ ! -f "$ROOT_DIR/Build/Plugins/libWireframe.dylib" ] || \
   [ ! -f "$ROOT_DIR/Build/Plugins/libTranceGlow.dylib" ]; then
  echo "[build] plugins manquants -> Tools/build_examples.sh"
  "$ROOT_DIR/Tools/build_examples.sh"
fi

echo "[run] $OUT"
(cd "$ROOT_DIR" && "$OUT")
