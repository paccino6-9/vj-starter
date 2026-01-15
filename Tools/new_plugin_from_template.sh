#!/bin/zsh
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: ./new_plugin_from_template.sh <NewPluginName> <plugin_id>"
  echo "Example: ./new_plugin_from_template.sh MyCoolFX org.openvj.mycoolfx"
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NAME="$1"
ID="$2"

DST="$ROOT_DIR/Plugins/$NAME"
mkdir -p "$DST"
cp "$ROOT_DIR/SDK/templates/metal_effect/EffectPlugin.mm" "$DST/$NAME.mm"

# Replace identifiers
perl -pi -e "s/org\.openvj\.template\.effect/$ID/g" "$DST/$NAME.mm"
perl -pi -e "s/Template Effect/$NAME/g" "$DST/$NAME.mm"

cat > "$DST/README.md" <<EOF
# $NAME

Plugin created from template.

- Edit \`$NAME.mm\` (shader + params)
- Build examples via \`Tools/build_examples.sh\`
EOF

echo "✅ Created: $DST"
