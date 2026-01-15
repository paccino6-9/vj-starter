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
  -framework CoreGraphics
  -framework CoreText
)

echo "[build] TranceGlow plugin..."
$CXX "${CXXFLAGS[@]}"   "$ROOT_DIR/Plugins/Examples/TranceGlow/TranceGlow.mm"   -dynamiclib -o "$PLUGINS_OUT/libTranceGlow.dylib"   "${FRAMEWORKS[@]}"

echo "[build] MandalaGen plugin..."
$CXX "${CXXFLAGS[@]}"   "$ROOT_DIR/Plugins/Examples/MandalaGen/MandalaGen.mm"   -dynamiclib -o "$PLUGINS_OUT/libMandalaGen.dylib"   "${FRAMEWORKS[@]}"

echo "[build] TextFX plugin..."
$CXX "${CXXFLAGS[@]}"   "$ROOT_DIR/Plugins/Examples/TextFX/TextFX.mm"   -dynamiclib -o "$PLUGINS_OUT/libTextFX.dylib"   "${FRAMEWORKS[@]}"

echo "[build] VideoSim plugin..."
$CXX "${CXXFLAGS[@]}"   "$ROOT_DIR/Plugins/Examples/VideoSim/VideoSim.mm"   -dynamiclib -o "$PLUGINS_OUT/libVideoSim.dylib"   "${FRAMEWORKS[@]}"

echo "[build] PointCloud plugin..."
$CXX "${CXXFLAGS[@]}"   "$ROOT_DIR/Plugins/Examples/PointCloud/PointCloud.mm"   -dynamiclib -o "$PLUGINS_OUT/libPointCloud.dylib"   "${FRAMEWORKS[@]}"

echo "[build] Wireframe plugin..."
$CXX "${CXXFLAGS[@]}"   "$ROOT_DIR/Plugins/Examples/Wireframe/Wireframe.mm"   -dynamiclib -o "$PLUGINS_OUT/libWireframe.dylib"   "${FRAMEWORKS[@]}"

echo ""
echo "✅ Done."
echo "Plugins built in: $PLUGINS_OUT"
