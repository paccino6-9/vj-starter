#!/usr/bin/env python3
"""
Génère un fichier JSON listant les dossiers vidéo par vignette
et crée des placeholders si rien n'existe. Tous les chemins vivent dans le projet.
Le JSON inclut aussi 6 presets de texte.
"""
from pathlib import Path
import json
import base64
import contextlib

ROOT = Path(__file__).resolve().parent.parent
MEDIA = ROOT / "Media"
TILES = [MEDIA / f"Tile{i}" for i in range(1, 10)]
CONFIG_PATH = MEDIA / "config.json"

# PNG 1x1 magenta
PLACEHOLDER = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/w8AAr8B9fT8xs8AAAAASUVORK5CYII="
)


def ensure_placeholder(folder: Path):
  folder.mkdir(parents=True, exist_ok=True)
  frame = folder / "frame_0000.png"
  if frame.exists():
    return
  with contextlib.ExitStack() as stack:
    f = stack.enter_context(frame.open("wb"))
    f.write(PLACEHOLDER)


def main():
  videos = []
  for i, tile_dir in enumerate(TILES, start=1):
    ensure_placeholder(tile_dir)
    videos.append({"tile": i, "path": str(tile_dir.relative_to(ROOT))})

  config = {
    "videos": videos,
    "text_presets": ["VOYAGE", "ENERGY", "PULSE", "SPECTRE", "NEON", "ECHO"],
  }

  MEDIA.mkdir(exist_ok=True)
  with CONFIG_PATH.open("w", encoding="utf-8") as f:
    json.dump(config, f, indent=2)
    f.write("\n")

  print(f"[generate_media_config] Wrote {CONFIG_PATH}")


if __name__ == "__main__":
  main()
