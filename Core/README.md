# Core

Minimal host that loads plugins, drives a Metal render loop, and can either display frames in a window or export them to files. Still CLI-only but now with a live Metal window option.

## Features

- `dlopen` + `dlsym` plugin loading using the SDK API (C ABI)
- Metal render loop (single-threaded) with checksum logging
- Live Metal window output via `--window`
- Optional PNG export of each frame
- Optional param injection from a JSON file
- Optional input images for effects/transitions (falls back to generated gradients)
- Sample params auto-applied for the example plugins (unless `--no-example-params`)

## Build & run

From repo root:

```bash
./Tools/build_examples.sh             # build plugins once (if not already)
./Core/run_core.sh --frames 1 --out /tmp/vj_frames
# live window (stops after N frames)
./Core/run_core.sh --window --frames 240 --fps 30
```

Common flags:

- `--plugin PATH` (or positional arg): dylib path (default: `Build/Plugins/libTranceGlow.dylib`)
- `--frames N` (default 60), `--fps N` (default 30)
- `--size W H` (default 1280 720)
- `--window` to open a Metal window instead of headless export
- `--out DIR` to emit PNG frames (otherwise only logs checksums)
- `--inputA PATH` / `--inputB PATH` for effect/transition inputs (PNG/JPEG/etc.)
- `--params FILE` JSON to override params
- `--no-example-params` to skip the baked-in example presets

## Interactive launcher (prompts)

Use the helper script to choose live window vs PNG vs MP4 output:

```bash
./Core/interactive_launch.py
```

## Params JSON format

A flat object keyed by `param_id`:

```json
{
  "amount": 0.85,
  "symmetry": 12,
  "posterize": true,
  "tint": [1.0, 0.8, 1.1, 1.0]
}
```

- float/int/bool map to the corresponding types
- enums accept index (`0`) or label (`"OptionName"`)
- colors expect `[r, g, b]` or `[r, g, b, a]` in 0..1

## Notes

- Requires macOS + Metal.
- Outputs are in `Build/Core/vj_core` (built by `Core/run_core.sh`).
- MP4 export uses `ffmpeg` (installed via Homebrew in this environment).
