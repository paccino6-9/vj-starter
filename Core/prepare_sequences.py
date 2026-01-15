#!/usr/bin/env python3
"""
Prépare 9 dossiers de séquences par vignette avec des PNG placeholder
si aucun média n'est présent. Les chemins par défaut sont Media/Tile1..Tile9.
Remplace les PNG par tes propres frames (frame_0000.png, frame_0001.png, etc.).
"""
from pathlib import Path
import base64
import contextlib

ROOT = Path(__file__).resolve().parent.parent
MEDIA_ROOT = ROOT / "Media"
TILES = [MEDIA_ROOT / f"Tile{i}" for i in range(1, 10)]

# 1x1 magenta PNG
PLACEHOLDER_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/w8AAr8B9fT8xs8AAAAASUVORK5CYII="
)


def ensure_placeholder(folder: Path):
  folder.mkdir(parents=True, exist_ok=True)
  target = folder / "frame_0000.png"
  if target.exists():
    return
  with contextlib.ExitStack() as stack:
    f = stack.enter_context(target.open("wb"))
    f.write(PLACEHOLDER_PNG)


def main():
  for tile_dir in TILES:
    ensure_placeholder(tile_dir)
  print(f"[prepare_sequences] Ready placeholders under {MEDIA_ROOT}")


if __name__ == "__main__":
  main()
