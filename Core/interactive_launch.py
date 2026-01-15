#!/usr/bin/env python3
import os
import shlex
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
RUNNER = ROOT / "Core" / "run_core.sh"
DEFAULT_PLUGIN = ROOT / "Build" / "Plugins" / "libTranceGlow.dylib"


def prompt(label: str, default: str = "") -> str:
  suffix = f" [{default}]" if default else ""
  val = input(f"{label}{suffix}: ").strip()
  return val or default


def parse_size(txt: str) -> tuple[int, int]:
  if "x" in txt.lower():
    parts = txt.lower().split("x", 1)
    try:
      w = int(parts[0])
      h = int(parts[1])
      if w > 0 and h > 0:
        return w, h
    except ValueError:
      pass
  return 1280, 720


def main():
  print("=== VJ Core interactive launcher ===")
  mode = prompt("Mode (1 = fenetre live, 2 = PNG, 3 = MP4 via ffmpeg)", "1")
  frames = prompt("Nombre de frames", "120")
  fps = prompt("FPS", "30")
  size = prompt("Taille (WxH)", "1280x720")
  width, height = parse_size(size)
  plugin = prompt("Chemin plugin", str(DEFAULT_PLUGIN))

  base_args = [
    "--plugin", plugin,
    "--frames", frames,
    "--fps", fps,
    "--size", str(width), str(height),
  ]

  if mode == "1":  # window
    args = base_args + ["--window"]
    print(f"[run] {' '.join(shlex.quote(str(a)) for a in [RUNNER, *args])}")
    subprocess.run([str(RUNNER), *args], check=True)
    print("[ok] Fin du rendu live.")
    return

  out_dir = prompt("Dossier de sortie", "/tmp/vj_frames")
  args = base_args + ["--out", out_dir]
  print(f"[run] {' '.join(shlex.quote(str(a)) for a in [RUNNER, *args])}")
  subprocess.run([str(RUNNER), *args], check=True)

  if mode == "3":
    mp4_path = Path(out_dir) / "out.mp4"
    ffmpeg_cmd = [
      "ffmpeg",
      "-y",
      "-framerate", fps,
      "-i", f"{out_dir}/frame_%04d.png",
      "-c:v", "libx264",
      "-pix_fmt", "yuv420p",
      str(mp4_path),
    ]
    print(f"[ffmpeg] {' '.join(shlex.quote(str(a)) for a in ffmpeg_cmd)}")
    subprocess.run(ffmpeg_cmd, check=True)
    print(f"[ok] Video: {mp4_path}")
  else:
    print(f"[ok] PNG/JPEGs dans {out_dir}")


if __name__ == "__main__":
  try:
    main()
  except KeyboardInterrupt:
    print("\nInterrompu.")
