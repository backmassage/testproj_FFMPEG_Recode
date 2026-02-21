# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Changed

- No unreleased changes yet.

## [1.6.0] - 2026-02-20

### Changed

- Bumped bundled script version to `Muxmaster.sh v1.6.0`.
- Updated README release metadata and defaults for `1.6.0`.
- Increased default non-AAC encode bitrate to `AAC 256k` (48kHz, up to stereo).
- Added source bitrate outlier analysis (resolution-aware thresholds) and orange-highlighted outlier logging.
- Updated smart quality behavior to apply a v1.6 `-1` bias to selected CPU CRF and VAAPI QP values.
- Condensed per-file pre-flight `[INFO]` output into a single readable status line (video/audio/container/subtitles-attachments/estimated bitrate).
- Kept `[RENDER]` conversion summaries while moving deep render internals to debug-level output.
- Added end-of-run reporting for total files processed and aggregate space savings (input bytes vs output bytes).

### Fixed

- Corrected smart-quality reporting details so debug notes explicitly reflect the v1.6 `-1` smart-bias and selected CRF/QP values.
- Refined compact audio status text to correctly distinguish copy-only, transcode-only, and mixed copy+transcode audio cases.

## [1.5.0] - 2026-02-19

### Changed

- Bumped bundled script version to `Muxmaster.sh v1.5.0`.
- Updated README release metadata for `1.5.0`.
- Removed end-of-run per-file CSV reporting output; the script now keeps standard totals summary (`encoded`, `skipped`, `failed`).
- Added `_docs/show-parsing-design.md` to document parser and output-mapping architecture.
- Updated file discovery to ignore media files inside any `Extras` directory (case-insensitive).
- Improved pre-flight render plan reporting to correctly indicate when subtitle/attachment streams are absent.

### Fixed

- Prevented filename parsing collisions between grouped era releases (for example `Berserk` 1997 vs `Berserk` 2016/2017) by using parent-year disambiguation when available.
- Fixed special-content parsing so OP/ED/PV/Menu/Special/Recap-style entries map as TV specials under `Season 00` instead of splitting into pseudo-shows or movies.
- Added episodic keyword parsing for names like `Show - Episode 16.5 - Title` and mapped decimal episodes to `Season 00` special numbering.
- Fixed greedy episodic extraction for names like `Show - 027 - 800 Years...` so episode indexing remains correct.
- Fixed false TV classification from codec tags in movie names (for example `H.265`).
- Added movie-part parsing for `... The Movie 1 - Part Name` style files so they are treated as movies instead of TV episodes.
- Improved fallback show-name cleanup to avoid inconsistent names caused by trailing season tokens in parent directories.

## [1.4.0] - 2026-02-18

### Changed

- Set default quality to `19` for both VAAPI QP and CPU CRF.
- Set default AAC audio bitrate to `224k`.
- Bumped bundled script version to `Muxmaster.sh v1.4.0`.
- Updated README defaults and release metadata for `1.4.0`.
- Polished CLI help wording for audio layout and release summary text.
- Added pre-flight render parameter logging before FFmpeg execution, including whether video/audio are transcoded or copied.
- Added a per-file CSV summary section at the end of each run with one-line status/action output for every processed file.
- Removed bundled `JellyfinLibraryAudit.py` from the final 1.4 release package to keep distribution focused on the core `Muxmaster.sh` workflow.
- Added smart per-file quality adaptation (resolution/bitrate-aware CRF/QP) with a one-pass tighter retry when output size grows significantly.
- Updated smart quality math to use separate CPU (`libx265` CRF) and VAAPI (`hevc_vaapi` QP) adaptation curves instead of a mirrored adjustment.
- Added explicit fixed-quality overrides `--cpu-crf` and `--vaapi-qp` (with `--quality` kept for active-mode compatibility).
- Added pre-flight input/output estimate logging that shows source resolution/bitrate and a rough encoded output bitrate range.
- Added a pink pre-flight conversion summary line showing `audio in -> out`, `video in -> out`, and `bitrate in -> expected bitrate`.

### Fixed

- Improved filename classification for episodic releases named like `Show 01 - Episode Title` (including `21'` episode notation) so they are treated as TV episodes instead of separate movies/folders.
- Improved episodic detection for fansub/group release names like `[Group] Show 01 [Tags]` and `[Group] Show - 01 (Tags)` so they map to TV folders correctly.
- Added support for `1x01` season/episode naming so releases like `1x01 - Episode Title` map to TV folders instead of movie folders.
- Hardened episode-token matching to avoid false positives from resolution tags (for example `1920x1080`) and added support for `01v2`-style episode suffixes.
- Replaced `xargs`-based title trimming in filename parsing to avoid quote-related parse errors on titles containing apostrophes.
- Improved FFmpeg stream analysis for HDR/color/interlace detection by targeting the primary non-attachment video stream, preventing false analysis on files with attached cover-art video streams.
- Hardened HDR metadata passthrough so ffmpeg only receives valid color flags when metadata is present, reducing encode failures caused by unknown color values.
- Fixed command-substitution logging contamination in option-builder helpers (`build_audio_opts`, `build_subtitle_opts`, `build_video_filter`) that could corrupt generated FFmpeg argument lists in verbose/warning scenarios.
- Updated per-stream audio handling so AAC tracks are always copied as-is (no AAC-to-AAC re-encode), while non-AAC tracks are encoded to AAC.
- Fixed filename tag cleanup to only trim known release tags at token boundaries, preventing accidental title truncation for names containing substrings like `NonAAC`.

## [1.2.3] - 2026-02-17

### Added

- Argument validation for:
  - `--container` values (`mkv`, `mp4`)
  - `--hdr` values (`preserve`, `tonemap`)
- Runtime safety guard that rejects output directories that are the same as, or nested inside, the input directory.

### Changed

- Updated README for release `1.2.3` and aligned documented behavior/options with `Muxmaster.sh v2.1.0`.
- Clarified CLI help text for `--no-match-audio-layout`.

### Fixed

- Fixed audio channel-selection logic during re-encode so mixed multi-audio inputs no longer get forced to mono when the first track is mono.

## [1.1] - 2026-02-16

### Added

- `--strict` mode to disable automatic per-file FFmpeg fallback retries.
- Helper scripts folder organization with `scripts/helpers/` and `scripts/helpers/extra/`.
- Dedicated release changelog (`CHANGELOG.md`).

### Changed

- Project version finalized to `1.1`.
- Moved `harleybox_auto.sh` to `scripts/helpers/harleybox_auto.sh`.
- Updated HarleyBox helper mount/fstab defaults to remove `umask=000` and include `nofail`.
- Preserved audio/subtitle stream metadata (title/language tags) during remux and encode flows.

### Fixed

- Mitigated common FFmpeg remux/encode failures with targeted retry fallbacks:
  - attachment tag issues (missing filename/mimetype),
  - subtitle mux/copy failures,
  - mux queue overflow (`Too many packets buffered for output stream`),
  - timestamp discontinuity / non-monotonic DTS issues.
- Added keep-metadata to clean-metadata fallback for per-file robustness.
- Preserved distinct audio/subtitle track titles per stream index (fixes dual-audio name loss).
