#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/Build"
PLUGINS_OUT="$BUILD_DIR/Plugins"
SDK_INC="$ROOT_DIR/SDK/include"

mkdir -p "$PLUGINS_OUT"

# Common flags
CXX=clang++
CXXFLAGS=(
  -std=c++20
  -O2
  -fobjc-arc
  -ObjC++
  -I"$SDK_INC"
)

FRAMEWORKS=(
  -framework Metal
  -framework Foundation
  -framework QuartzCore
)

echo "[build] TranceGlow plugin..."
$CXX "${CXXFLAGS[@]}"   "$ROOT_DIR/Plugins/Examples/TranceGlow/TranceGlow.mm"   -dynamiclib -o "$PLUGINS_OUT/libTranceGlow.dylib"   "${FRAMEWORKS[@]}"

echo "[build] MandalaGen plugin..."
$CXX "${CXXFLAGS[@]}"   "$ROOT_DIR/Plugins/Examples/MandalaGen/MandalaGen.mm"   -dynamiclib -o "$PLUGINS_OUT/libMandalaGen.dylib"   "${FRAMEWORKS[@]}"

echo ""
echo "✅ Done."
echo "Plugins built in: $PLUGINS_OUT"
