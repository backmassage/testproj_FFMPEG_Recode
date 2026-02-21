# Muxmaster Media Library Encoder

> A resilient batch encoder/remuxer for Jellyfin-style media libraries.

Release version: **1.6.0**  
Bundled core script: **Muxmaster.sh v1.6.0**

## Highlights

- HEVC encoding with `vaapi` (default) or `cpu` (`libx265`)
- Optional HEVC remux mode (`--skip-hevc`) with browser-safety checks
- AAC audio strategy:
  - copy AAC streams as-is (no AAC-to-AAC re-encode)
  - otherwise encode non-AAC streams to AAC 48kHz (`256k` target by default)
- Smart per-file quality adaptation (default on):
  - uses separate adaptation curves for CPU CRF vs VAAPI QP using source resolution + bitrate
  - applies a v1.6 quality bias of `-1` to selected smart CRF/QP values
  - applies one tighter retry pass if output grows significantly (>105%)
  - supports fixed manual overrides with `--quality`, `--cpu-crf`, and `--vaapi-qp`
- HDR handling:
  - preserve metadata (`--hdr preserve`)
  - tonemap to SDR (`--hdr tonemap`)
- Auto deinterlace detection (`yadif`), configurable with `--no-deinterlace`
- Subtitle and attachment retention with safe MP4 behavior
- Automatic retry fallbacks for common FFmpeg failure modes
- Safer directory handling (output cannot be inside input)
- Condensed one-line per-file `[INFO]` render summary (video, audio, container, subs/attachments, estimated bitrate)
- Pink `[RENDER]` conversion summary line (`audio in -> out`, `video in -> out`, `bitrate in -> expected`)
- Source bitrate outlier detection by resolution tier with orange console highlighting
- End-of-run summary includes totals plus aggregate space savings (input vs output)
- Ignores files found under `Extras` directories
- Stronger show parsing for specials and grouped/year-tagged anime releases

## Requirements

- Bash
- `ffmpeg`
- `ffprobe`
- For VAAPI mode:
  - VAAPI-capable hardware/driver stack
  - Render node (for example `/dev/dri/renderD128`)
  - FFmpeg build with `hevc_vaapi`

## Quick Start

```bash
chmod +x Muxmaster.sh
./Muxmaster.sh -m cpu "/path/to/input" "/path/to/output"
```

Check environment support:

```bash
./Muxmaster.sh --check
```

## Command Usage

```text
Muxmaster.sh [OPTIONS] <input_dir> <output_dir>
```

### Options

| Option | Description |
|---|---|
| `-m, --mode <vaapi\|cpu>` | Encoder mode (default: `vaapi`) |
| `-q, --quality <value>` | Fixed quality for active mode (VAAPI QP or CPU CRF) |
| `--cpu-crf <value>` | Fixed CPU CRF override (takes precedence over `--quality` in CPU mode) |
| `--vaapi-qp <value>` | Fixed VAAPI QP override (takes precedence over `--quality` in VAAPI mode) |
| `-p, --preset <preset>` | CPU x265 preset (default: `slow`) |
| `--container <mkv\|mp4>` | Output container (default: `mkv`) |
| `--hdr <preserve\|tonemap>` | HDR handling mode (default: `preserve`) |
| `--no-deinterlace` | Disable automatic deinterlace detection |
| `--skip-hevc` | HEVC input: copy video, process audio (default: on) |
| `--no-skip-hevc` | Force HEVC re-encode |
| `--no-subs` | Disable subtitle processing |
| `--no-attachments` | Disable attachment copy (fonts/images) |
| `-f, --force` | Overwrite existing output files |
| `-d, --dry-run` | Preview actions without writing files |
| `--strict` | Disable auto-retry fallbacks |
| `--smart-quality` | Enable per-file quality adaptation (default: on) |
| `--no-smart-quality` | Disable per-file quality adaptation |
| `--clean-timestamps` | Enable timestamp regeneration (default: on) |
| `--no-clean-timestamps` | Disable timestamp regeneration |
| `--match-audio-layout` | Normalize encoded audio layout (default: on) |
| `--no-match-audio-layout` | Disable audio layout normalization |
| `--show-fps` | Show live FFmpeg FPS/speed (default: on) |
| `--no-fps` | Hide live FFmpeg FPS/speed |
| `--no-stats` | Hide per-file source video stats |
| `--color` | Force colored logs |
| `--no-color` | Disable colored logs |
| `-v, --verbose` | Verbose logging/FFmpeg output |
| `-l, --log <path>` | Write logs to file |
| `-c, --check` | Run system diagnostics and exit |
| `-V, --version` | Print script version and exit |
| `-h, --help` | Show help |

## Defaults and Behavior

- Output container: **MKV**
- HEVC output profile:
  - VAAPI: `main10` when available, fallback to `main` (8-bit)
  - CPU: `main10`, `yuv420p10le`
- Audio:
  - target: AAC, up to stereo, `256k`, 48kHz for non-AAC sources
  - AAC source streams are copied directly (no AAC-to-AAC re-encode)
- Smart quality:
  - auto-selects per-file mode-specific CRF/QP from resolution + bitrate
  - applies a v1.6 `-1` smart-bias to selected CRF/QP values
- Subtitles:
  - MKV: copy subtitle streams
  - MP4: convert text subtitles to `mov_text`, skip bitmap-only subtitle cases
- Attachments:
  - copied for MKV when enabled
  - skipped for MP4
- Existing outputs: skipped by default (`--force` to overwrite)
- Retry fallback logic (unless `--strict`):
  - remove attachments on attachment tag errors
  - remove subtitles on subtitle mux errors
  - increase mux queue size
  - enable timestamp regeneration when needed

Supported input extensions:

- `mkv`, `mp4`, `avi`, `m4v`, `mov`, `wmv`, `flv`, `webm`, `ts`, `m2ts`, `mpg`, `mpeg`, `vob`, `ogv`

## Output Naming

TV:

```text
<output>/<Show Name>/Season <NN>/<Show Name> - S<NN>E<NN>.<container>
```

Movie:

```text
<output>/<Movie Name (Year)>/<Movie Name (Year)>.<container>
```

TV specials (OP/ED/PV/Menu/Recap/etc.) are mapped to Season 00:

```text
<output>/<Show Name>/Season 00/<Show Name> - S00E<NN>.<container>
```

## Safety Notes

- Use an output directory outside the input tree. The script now rejects output paths that are equal to or nested under input.
- Use `--dry-run` before large batch jobs.

## Changelog

See [`CHANGELOG.md`](./CHANGELOG.md) for release history.
