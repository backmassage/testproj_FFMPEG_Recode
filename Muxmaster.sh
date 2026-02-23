#!/bin/bash
#===============================================================================
# Muxmaster Media Library Encoder v1.7.0
# Comprehensive HEVC/AAC encoding for Jellyfin optimization
#===============================================================================

set -o pipefail

#------------------------------------------------------------------------------
# Configuration defaults
#------------------------------------------------------------------------------
# Encoding defaults
ENCODER_MODE="vaapi"
VAAPI_DEVICE="/dev/dri/renderD128"
VAAPI_QP=19
VAAPI_PROFILE="main10"
VAAPI_SW_FORMAT="p010"
CPU_CRF=19
CPU_PRESET="slow"
CPU_HEVC_PROFILE="main10"
CPU_PIX_FMT="yuv420p10le"
OUTPUT_CONTAINER="mkv"
KEYFRAME_INT=48
AUDIO_CHANNELS=2
AUDIO_BITRATE="256k"
FFMPEG_PROBESIZE="100M"
FFMPEG_ANALYZEDURATION="100M"

# Logging/UX defaults
FFMPEG_LOGLEVEL="error"
declare -a FFMPEG_PROGRESS_ARGS=()

# Stream retention defaults
KEEP_SUBTITLES=true
KEEP_ATTACHMENTS=true

# Runtime behavior defaults
DRY_RUN=false
SKIP_EXISTING=true
SKIP_HEVC=true
SHOW_FILE_STATS=true
SHOW_FFMPEG_FPS=true
LOG_FILE=""
VERBOSE=false
CHECK_ONLY=false
QUALITY_OVERRIDE=""
CPU_CRF_FIXED_OVERRIDE=""
VAAPI_QP_FIXED_OVERRIDE=""
ACTIVE_QUALITY_OVERRIDE=""
COLOR_MODE="auto"
STRICT_MODE=false
CLEAN_TIMESTAMPS=true
MATCH_AUDIO_LAYOUT=true
HANDLE_HDR="preserve"
DEINTERLACE_AUTO=true
SMART_QUALITY=true

INPUT_DIR=""
OUTPUT_DIR=""
SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="1.7.0"

# Temp file tracking for cleanup
declare -a TEMP_FILES=()
declare -A TV_SHOW_YEAR_VARIANTS=()
declare -A OUTPUT_PATH_OWNERS=()
declare -A OUTPUT_PATH_COLLISION_COUNTER=()
RESOLVED_OUTPUT_PATH=""

# ANSI color palette
RED=""; GREEN=""; YELLOW=""; ORANGE=""; BLUE=""; CYAN=""; MAGENTA=""; NC=""

#------------------------------------------------------------------------------
# Cleanup trap - ensures temp files are removed on exit/interrupt
#------------------------------------------------------------------------------
cleanup_temp_files() {
    local f
    for f in "${TEMP_FILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
}
trap cleanup_temp_files EXIT INT TERM

# Create tracked temp file
make_temp_file() {
    local tmp
    tmp=$(mktemp)
    TEMP_FILES+=("$tmp")
    printf '%s\n' "$tmp"
}

#------------------------------------------------------------------------------
# Color initialization
#------------------------------------------------------------------------------
init_colors() {
    local enable_colors=false

    case "$COLOR_MODE" in
        always) enable_colors=true ;;
        never)  enable_colors=false ;;
        auto)
            if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
                enable_colors=true
            fi
            ;;
    esac

    if [[ "$enable_colors" == true ]]; then
        RED=$'\033[1;91m'
        GREEN=$'\033[1;92m'
        YELLOW=$'\033[1;93m'
        ORANGE=$'\033[1;38;5;208m'
        BLUE=$'\033[1;94m'
        CYAN=$'\033[1;96m'
        MAGENTA=$'\033[1;95m'
        NC=$'\033[0m'
    else
        RED=""; GREEN=""; YELLOW=""; ORANGE=""; BLUE=""; CYAN=""; MAGENTA=""; NC=""
    fi
}

#------------------------------------------------------------------------------
# Banner
#------------------------------------------------------------------------------
print_banner() {
    if [[ -n "$MAGENTA" ]]; then
        printf '%b' $'\033[1;95m'
    fi

    cat << 'EOF'
 __  __            __  __           _
|  \/  |_   ___  _|  \/  | __ _ ___| |_ ___ _ __
| |\/| | | | \ \/ / |\/| |/ _` / __| __/ _ \ '__|
| |  | | |_| |>  <| |  | | (_| \__ \ ||  __/ |
|_|  |_|\__,_/_/\_\_|  |_|\__,_|___/\__\___|_|
EOF

    if [[ -n "$MAGENTA" ]]; then
        printf '%b\n' "$NC"
    fi
}

#------------------------------------------------------------------------------
# Logging functions
#------------------------------------------------------------------------------
log_line() {
    local level="$1"
    local color="$2"
    local text="$3"
    local ts="[$(date '+%Y-%m-%d %H:%M:%S')]"
    local stream_fd=1

    [[ "$level" == "ERROR" ]] && stream_fd=2

    if [[ -n "$color" ]]; then
        printf '%s %b[%s]%b %s\n' "$ts" "$color" "$level" "$NC" "$text" >&"$stream_fd"
    else
        printf '%s [%s] %s\n' "$ts" "$level" "$text" >&"$stream_fd"
    fi

    if [[ -n "$LOG_FILE" ]]; then
        printf '%s [%s] %s\n' "$ts" "$level" "$text" >> "$LOG_FILE"
    fi

    return 0
}
log_info()    { log_line "INFO" "$BLUE" "$1"; }
log_success() { log_line "SUCCESS" "$GREEN" "$1"; }
log_warn()    { log_line "WARN" "$YELLOW" "$1"; }
log_error()   { log_line "ERROR" "$RED" "$1"; }
log_render()  { log_line "RENDER" "$MAGENTA" "$1"; }
log_outlier() { log_line "OUTLIER" "$ORANGE" "$1"; }
log_debug()   { [[ "$VERBOSE" == true ]] && log_line "DEBUG" "$CYAN" "$1"; return 0; }

#------------------------------------------------------------------------------
# CLI help
#------------------------------------------------------------------------------
usage() {
    local exit_code="${1:-0}"
    local usage_stream=1
    [[ "$exit_code" -ne 0 ]] && usage_stream=2

    cat >&"$usage_stream" << EOF
Muxmaster v$SCRIPT_VERSION - Jellyfin-Optimized Media Encoder

Usage: $SCRIPT_NAME [OPTIONS] <input_dir> <output_dir>

Encoding Options:
  -m, --mode <vaapi|cpu>    Encoder mode (default: vaapi hardware)
  -q, --quality <value>     Fixed quality for active mode (QP for VAAPI, CRF for CPU)
  --cpu-crf <value>         Fixed CPU CRF override (takes precedence over --quality in CPU mode)
  --vaapi-qp <value>        Fixed VAAPI QP override (takes precedence over --quality in VAAPI mode)
  -p, --preset <preset>     CPU preset (default: slow)

HDR/Color Options:
  --hdr <preserve|tonemap>  HDR handling (default: preserve)
  --no-deinterlace          Disable automatic deinterlace detection

Stream Options:
  --skip-hevc               Copy HEVC video, encode audio only (default: on)
  --no-skip-hevc            Re-encode HEVC video
  --no-subs                 Do not process subtitle streams
  --no-attachments          Do not include attachments (fonts/images)

Output Options:
  --container <mkv|mp4>     Output container (default: mkv)
  -f, --force               Overwrite existing output files

Behavior Options:
  -d, --dry-run             Preview only
  --strict                  Disable automatic ffmpeg retry fallbacks
  --smart-quality           Adapt quality per file using source resolution/bitrate (default: on)
  --no-smart-quality        Use fixed quality values only
  --clean-timestamps        Enable timestamp regeneration (default: on)
  --no-clean-timestamps     Disable timestamp regeneration
  --match-audio-layout      Normalize encoded audio layout (default: on)
  --no-match-audio-layout   Disable audio layout normalization

Display Options:
  --show-fps                Show live ffmpeg FPS/speed (default: on)
  --no-fps                  Disable live FPS progress
  --no-stats                Hide per-file source stats
  --color                   Force colored logs
  --no-color                Disable colored logs
  -v, --verbose             Verbose output

Utility:
  -l, --log <path>          Write logs to file
  -c, --check               System diagnostics
  -V, --version             Print version
  -h, --help                Help

Encoding: 10-bit HEVC, copy AAC or encode non-AAC to AAC (default 256k), MKV container, metadata preserved
EOF
    exit "$exit_code"
}

show_version() {
    printf '%s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
}

require_option_value() {
    local opt="$1"
    local value="${2-}"
    if [[ -z "$value" ]]; then
        log_error "Option '$opt' requires a value"
        usage 1
    fi
}

normalize_dir_arg() {
    local path="$1"
    if [[ "$path" == "/" ]]; then
        printf '/\n'
        return 0
    fi

    while [[ "$path" == */ ]]; do
        path="${path%/}"
    done

    printf '%s\n' "$path"
}

trim_whitespace() {
    local input="$1"
    printf '%s\n' "$input" | sed -E 's/[[:space:]]+/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//'
}

extract_parent_season_hint() {
    local parent="$1"

    if [[ "$parent" =~ (^|[^[:alnum:]])[Ss]eason[[:space:]_.-]*([0-9]{1,2})([^[:alnum:]]|$) ]]; then
        printf '%d\n' "$((10#${BASH_REMATCH[2]}))"
        return 0
    fi

    if [[ "$parent" =~ (^|[^[:alnum:]])[Ss]([0-9]{1,2})([^[:alnum:]]|$) ]]; then
        printf '%d\n' "$((10#${BASH_REMATCH[2]}))"
        return 0
    fi

    printf '\n'
}

clamp_int() {
    local value="$1"
    local min="$2"
    local max="$3"

    (( value < min )) && value="$min"
    (( value > max )) && value="$max"
    printf '%s\n' "$value"
}

#------------------------------------------------------------------------------
# Argument parsing
#------------------------------------------------------------------------------
parse_args() {
    local positional=()
    while [[ $# -gt 0 ]]; do
        case $1 in
            --)
                shift
                positional+=("$@")
                break
                ;;
            -m|--mode)
                require_option_value "$1" "${2-}"
                ENCODER_MODE="$2"
                shift 2
                ;;
            -q|--quality)
                require_option_value "$1" "${2-}"
                QUALITY_OVERRIDE="$2"
                shift 2
                ;;
            --cpu-crf)
                require_option_value "$1" "${2-}"
                CPU_CRF_FIXED_OVERRIDE="$2"
                shift 2
                ;;
            --vaapi-qp)
                require_option_value "$1" "${2-}"
                VAAPI_QP_FIXED_OVERRIDE="$2"
                shift 2
                ;;
            -p|--preset)
                require_option_value "$1" "${2-}"
                CPU_PRESET="$2"
                shift 2
                ;;
            --container)
                require_option_value "$1" "${2-}"
                OUTPUT_CONTAINER="${2,,}"
                shift 2
                ;;
            --hdr)
                require_option_value "$1" "${2-}"
                HANDLE_HDR="${2,,}"
                shift 2
                ;;
            --no-deinterlace)
                DEINTERLACE_AUTO=false
                shift
                ;;
            -d|--dry-run) DRY_RUN=true; shift ;;
            --skip-hevc) SKIP_HEVC=true; shift ;;
            --no-skip-hevc) SKIP_HEVC=false; shift ;;
            --show-fps) SHOW_FFMPEG_FPS=true; shift ;;
            --no-fps) SHOW_FFMPEG_FPS=false; shift ;;
            --no-stats) SHOW_FILE_STATS=false; shift ;;
            --no-subs) KEEP_SUBTITLES=false; shift ;;
            --no-attachments) KEEP_ATTACHMENTS=false; shift ;;
            --strict) STRICT_MODE=true; shift ;;
            --smart-quality) SMART_QUALITY=true; shift ;;
            --no-smart-quality) SMART_QUALITY=false; shift ;;
            --clean-timestamps) CLEAN_TIMESTAMPS=true; shift ;;
            --no-clean-timestamps) CLEAN_TIMESTAMPS=false; shift ;;
            --match-audio-layout) MATCH_AUDIO_LAYOUT=true; shift ;;
            --no-match-audio-layout) MATCH_AUDIO_LAYOUT=false; shift ;;
            --color) COLOR_MODE="always"; shift ;;
            --no-color) COLOR_MODE="never"; shift ;;
            -v|--verbose) VERBOSE=true; shift ;;
            -c|--check) CHECK_ONLY=true; shift ;;
            -V|--version) show_version; exit 0 ;;
            -l|--log)
                require_option_value "$1" "${2-}"
                LOG_FILE="$2"
                shift 2
                ;;
            -f|--force) SKIP_EXISTING=false; shift ;;
            -h|--help) usage 0 ;;
            -*) log_error "Unknown option: $1"; usage 1 ;;
            *) positional+=("$1"); shift ;;
        esac
    done

    if [[ "$CHECK_ONLY" != true ]]; then
        [[ ${#positional[@]} -ne 2 ]] && { log_error "Need exactly input_dir and output_dir"; usage 1; }
        INPUT_DIR="$(normalize_dir_arg "${positional[0]}")"
        OUTPUT_DIR="$(normalize_dir_arg "${positional[1]}")"
    fi

    case "$ENCODER_MODE" in
        vaapi|cpu) ;;
        *)
            log_error "Invalid mode '$ENCODER_MODE' (use 'vaapi' or 'cpu')"
            exit 1
            ;;
    esac

    case "$OUTPUT_CONTAINER" in
        mkv|mp4) ;;
        *)
            log_error "Invalid container '$OUTPUT_CONTAINER' (use 'mkv' or 'mp4')"
            exit 1
            ;;
    esac

    case "$HANDLE_HDR" in
        preserve|tonemap) ;;
        *)
            log_error "Invalid HDR mode '$HANDLE_HDR' (use 'preserve' or 'tonemap')"
            exit 1
            ;;
    esac

    if [[ -n "$QUALITY_OVERRIDE" ]] && ! [[ "$QUALITY_OVERRIDE" =~ ^[0-9]+$ ]]; then
        log_error "Quality must be a whole number (got '$QUALITY_OVERRIDE')"
        exit 1
    fi
    if [[ -n "$CPU_CRF_FIXED_OVERRIDE" ]] && ! [[ "$CPU_CRF_FIXED_OVERRIDE" =~ ^[0-9]+$ ]]; then
        log_error "CPU CRF must be a whole number (got '$CPU_CRF_FIXED_OVERRIDE')"
        exit 1
    fi
    if [[ -n "$VAAPI_QP_FIXED_OVERRIDE" ]] && ! [[ "$VAAPI_QP_FIXED_OVERRIDE" =~ ^[0-9]+$ ]]; then
        log_error "VAAPI QP must be a whole number (got '$VAAPI_QP_FIXED_OVERRIDE')"
        exit 1
    fi

    # Allow explicit per-mode fixed values while keeping -q/--quality for compatibility.
    # Mode-specific flags take precedence over --quality when both are provided.
    if [[ -n "$CPU_CRF_FIXED_OVERRIDE" ]]; then
        CPU_CRF="$CPU_CRF_FIXED_OVERRIDE"
    fi
    if [[ -n "$VAAPI_QP_FIXED_OVERRIDE" ]]; then
        VAAPI_QP="$VAAPI_QP_FIXED_OVERRIDE"
    fi

    ACTIVE_QUALITY_OVERRIDE=""
    if [[ "$ENCODER_MODE" == "vaapi" ]]; then
        if [[ -n "$VAAPI_QP_FIXED_OVERRIDE" ]]; then
            ACTIVE_QUALITY_OVERRIDE="$VAAPI_QP_FIXED_OVERRIDE"
        elif [[ -n "$QUALITY_OVERRIDE" ]]; then
            ACTIVE_QUALITY_OVERRIDE="$QUALITY_OVERRIDE"
            VAAPI_QP="$QUALITY_OVERRIDE"
        fi
    else
        if [[ -n "$CPU_CRF_FIXED_OVERRIDE" ]]; then
            ACTIVE_QUALITY_OVERRIDE="$CPU_CRF_FIXED_OVERRIDE"
        elif [[ -n "$QUALITY_OVERRIDE" ]]; then
            ACTIVE_QUALITY_OVERRIDE="$QUALITY_OVERRIDE"
            CPU_CRF="$QUALITY_OVERRIDE"
        fi
    fi

    if [[ "$VERBOSE" == true ]]; then
        FFMPEG_LOGLEVEL="info"
    else
        FFMPEG_LOGLEVEL="error"
    fi

    if [[ "$VERBOSE" == true || "$SHOW_FFMPEG_FPS" == true ]]; then
        FFMPEG_PROGRESS_ARGS=(-stats -stats_period 1)
    else
        FFMPEG_PROGRESS_ARGS=()
    fi
}

#------------------------------------------------------------------------------
# Portable file size function (Linux + macOS)
#------------------------------------------------------------------------------
get_file_size() {
    local file="$1"
    if [[ "$(uname)" == "Darwin" ]]; then
        stat -f%z "$file" 2>/dev/null || echo 0
    else
        stat -c%s "$file" 2>/dev/null || echo 0
    fi
}

# Human-readable byte formatter for final summary reporting.
format_bytes() {
    local bytes="$1"
    local sign=""
    local -a units=(B KiB MiB GiB TiB PiB)
    local unit_index=0
    local remainder=0

    [[ "$bytes" =~ ^-?[0-9]+$ ]] || { printf 'unknown\n'; return 0; }

    if (( bytes < 0 )); then
        sign="-"
        bytes=$((-bytes))
    fi

    while (( bytes >= 1024 && unit_index < ${#units[@]} - 1 )); do
        remainder=$((bytes % 1024))
        bytes=$((bytes / 1024))
        ((unit_index++))
    done

    if (( unit_index == 0 )); then
        printf '%s%d %s\n' "$sign" "$bytes" "${units[$unit_index]}"
    else
        printf '%s%d.%d %s\n' "$sign" "$bytes" "$((remainder * 10 / 1024))" "${units[$unit_index]}"
    fi
}

#------------------------------------------------------------------------------
# VAAPI device and encoder tests
#------------------------------------------------------------------------------
test_vaapi_profile() {
    local sw_format="$1"
    local profile="$2"
    local err_file="$3"

    ffmpeg -hide_banner -nostdin -loglevel error \
        -init_hw_device vaapi=va:"$VAAPI_DEVICE" -filter_hw_device va \
        -f lavfi -i color=black:s=256x256:d=0.1 \
        -vf "format=${sw_format},hwupload" \
        -c:v hevc_vaapi -profile:v "$profile" -f null - > /dev/null 2>"$err_file"
}

get_first_render_device() {
    local dev
    for dev in /dev/dri/renderD*; do
        [[ -e "$dev" ]] || continue
        printf '%s\n' "$dev"
        return 0
    done
    return 1
}

output_container_is_mp4() {
    [[ "${OUTPUT_CONTAINER,,}" == "mp4" ]]
}

#------------------------------------------------------------------------------
# Dependency and encoder validation
#------------------------------------------------------------------------------
check_deps() {
    command -v ffmpeg &>/dev/null || { log_error "ffmpeg not found"; exit 1; }
    command -v ffprobe &>/dev/null || { log_error "ffprobe not found"; exit 1; }

    if [[ "$ENCODER_MODE" == "vaapi" ]]; then
        if [[ ! -e "$VAAPI_DEVICE" ]]; then
            VAAPI_DEVICE=$(get_first_render_device || true)
        fi
        [[ -z "$VAAPI_DEVICE" || ! -e "$VAAPI_DEVICE" ]] && { log_error "No VAAPI device"; exit 1; }

        log_debug "Testing VAAPI device: $VAAPI_DEVICE"

        local vaapi_err
        vaapi_err=$(make_temp_file)
        if test_vaapi_profile "p010" "main10" "$vaapi_err"; then
            VAAPI_SW_FORMAT="p010"
            VAAPI_PROFILE="main10"
            log_success "VAAPI ready: $VAAPI_DEVICE (HEVC main10)"
        elif test_vaapi_profile "nv12" "main" "$vaapi_err"; then
            VAAPI_SW_FORMAT="nv12"
            VAAPI_PROFILE="main"
            log_warn "VAAPI main10 unavailable, falling back to HEVC main (8-bit)"
            log_success "VAAPI ready: $VAAPI_DEVICE (HEVC main)"
        else
            log_error "VAAPI test failed"
            [[ "$VERBOSE" == true ]] && sed 's/^/  /' "$vaapi_err"
            exit 1
        fi
    else
        if ! ffmpeg -hide_banner -nostdin -loglevel error \
                -f lavfi -i color=black:s=256x256:d=0.1 \
                -c:v libx265 -f null - > /dev/null 2>&1; then
            log_error "CPU mode selected but libx265 is unavailable"
            exit 1
        fi
    fi
}

#------------------------------------------------------------------------------
# Stream analysis functions
#------------------------------------------------------------------------------
get_codec() {
    ffprobe -v error -select_streams v:0 -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | head -1
}

has_audio_stream() {
    local count
    count=$(get_stream_count "a" "$1")
    [[ "$count" -gt 0 ]]
}

get_stream_count() {
    local selector="$1"
    local input="$2"
    local count

    count=$(ffprobe -v error -select_streams "$selector" -show_entries stream=index \
        -of csv=p=0 "$input" 2>/dev/null | sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]')
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    printf '%s\n' "$count"
}

# Get primary video stream index (skip cover art/attached pics)
get_primary_video_stream_index() {
    local idx codec attached
    while IFS='|' read -r idx codec attached; do
        [[ -z "$idx" ]] && continue
        [[ "$attached" != "1" ]] && { echo "$idx"; return 0; }
    done < <(ffprobe -v error -select_streams v \
        -show_entries stream=index,codec_name:stream_disposition=attached_pic \
        -of compact=p=0:nk=1 "$1" 2>/dev/null)

    # Return empty string if no valid video stream found
    echo ""
}

get_primary_video_codec() {
    local idx codec attached
    while IFS='|' read -r idx codec attached; do
        [[ -z "$idx" ]] && continue
        [[ "$attached" != "1" ]] && { echo "$codec"; return 0; }
    done < <(ffprobe -v error -select_streams v \
        -show_entries stream=index,codec_name:stream_disposition=attached_pic \
        -of compact=p=0:nk=1 "$1" 2>/dev/null)

    get_codec "$1"
}

get_primary_video_profile() {
    local idx profile attached
    while IFS='|' read -r idx profile attached; do
        [[ -z "$idx" ]] && continue
        [[ "$attached" != "1" ]] && { echo "$profile"; return 0; }
    done < <(ffprobe -v error -select_streams v \
        -show_entries stream=index,profile:stream_disposition=attached_pic \
        -of compact=p=0:nk=1 "$1" 2>/dev/null)

    echo ""
}

get_primary_video_pix_fmt() {
    local idx pix_fmt attached
    while IFS='|' read -r idx pix_fmt attached; do
        [[ -z "$idx" ]] && continue
        [[ "$attached" != "1" ]] && { echo "$pix_fmt"; return 0; }
    done < <(ffprobe -v error -select_streams v \
        -show_entries stream=index,pix_fmt:stream_disposition=attached_pic \
        -of compact=p=0:nk=1 "$1" 2>/dev/null)

    echo ""
}

get_primary_video_resolution() {
    local idx width height attached
    while IFS='|' read -r idx width height attached; do
        [[ -z "$idx" ]] && continue
        [[ "$attached" == "1" ]] && continue

        if [[ "$width" =~ ^[0-9]+$ && "$height" =~ ^[0-9]+$ && "$width" -gt 0 && "$height" -gt 0 ]]; then
            printf '%sx%s\n' "$width" "$height"
        else
            printf 'unknown\n'
        fi
        return 0
    done < <(ffprobe -v error -select_streams v \
        -show_entries stream=index,width,height:stream_disposition=attached_pic \
        -of compact=p=0:nk=1 "$1" 2>/dev/null)

    printf 'unknown\n'
}

get_primary_video_bitrate_bps() {
    local idx bit_rate attached
    while IFS='|' read -r idx bit_rate attached; do
        [[ -z "$idx" ]] && continue
        [[ "$attached" == "1" ]] && continue
        [[ "$bit_rate" =~ ^[0-9]+$ && "$bit_rate" -gt 0 ]] && { echo "$bit_rate"; return 0; }
    done < <(ffprobe -v error -select_streams v \
        -show_entries stream=index,bit_rate:stream_disposition=attached_pic \
        -of compact=p=0:nk=1 "$1" 2>/dev/null)

    local format_bitrate
    format_bitrate=$(ffprobe -v error -show_entries format=bit_rate \
        -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | head -1)
    [[ "$format_bitrate" =~ ^[0-9]+$ && "$format_bitrate" -gt 0 ]] && { echo "$format_bitrate"; return 0; }

    echo ""
}

format_bitrate_label() {
    local bitrate_bps="$1"

    if [[ "$bitrate_bps" =~ ^[0-9]+$ && "$bitrate_bps" -gt 0 ]]; then
        printf '%d kb/s\n' "$(((bitrate_bps + 500) / 1000))"
    else
        printf 'unknown\n'
    fi
}

get_primary_video_bitrate_label() {
    local bitrate_bps
    bitrate_bps=$(get_primary_video_bitrate_bps "$1")
    format_bitrate_label "$bitrate_bps"
}

#------------------------------------------------------------------------------
# Source bitrate outlier detection by resolution tier
#------------------------------------------------------------------------------
# Returns: low_kbps<TAB>high_kbps<TAB>tier_label
get_expected_bitrate_range_kbps() {
    local resolution="$1"
    local width height pixels

    if [[ "$resolution" =~ ^([0-9]+)x([0-9]+)$ ]]; then
        width="${BASH_REMATCH[1]}"
        height="${BASH_REMATCH[2]}"
        pixels=$((width * height))
    else
        printf '0\t0\tunknown\n'
        return 0
    fi

    # Conservative ranges to flag obvious bitrate outliers without over-triggering.
    if (( pixels <= 640 * 360 )); then
        printf '250\t1800\t<=360p\n'
    elif (( pixels <= 854 * 480 )); then
        printf '500\t2500\t<=480p\n'
    elif (( pixels <= 1280 * 720 )); then
        printf '1000\t5000\t<=720p\n'
    elif (( pixels <= 1920 * 1080 )); then
        printf '2500\t10000\t<=1080p\n'
    elif (( pixels <= 2560 * 1440 )); then
        printf '5000\t18000\t<=1440p\n'
    elif (( pixels <= 3840 * 2160 )); then
        printf '10000\t45000\t<=2160p\n'
    else
        printf '15000\t65000\t>2160p\n'
    fi
}

# Returns: status<TAB>source_kbps<TAB>low_kbps<TAB>high_kbps<TAB>tier_label
# status is one of: high, low, normal, unknown
assess_bitrate_outlier() {
    local resolution="$1"
    local bitrate_bps="$2"
    local bitrate_kbps low_kbps high_kbps tier_label

    if ! [[ "$bitrate_bps" =~ ^[0-9]+$ && "$bitrate_bps" -gt 0 ]]; then
        printf 'unknown\t0\t0\t0\tunknown\n'
        return 0
    fi

    bitrate_kbps=$(((bitrate_bps + 500) / 1000))
    IFS=$'\t' read -r low_kbps high_kbps tier_label <<< "$(get_expected_bitrate_range_kbps "$resolution")"

    if ! [[ "$low_kbps" =~ ^[0-9]+$ && "$high_kbps" =~ ^[0-9]+$ && "$high_kbps" -gt "$low_kbps" ]]; then
        printf 'unknown\t%s\t0\t0\t%s\n' "$bitrate_kbps" "${tier_label:-unknown}"
        return 0
    fi

    if (( bitrate_kbps < low_kbps )); then
        printf 'low\t%s\t%s\t%s\t%s\n' "$bitrate_kbps" "$low_kbps" "$high_kbps" "$tier_label"
    elif (( bitrate_kbps > high_kbps )); then
        printf 'high\t%s\t%s\t%s\t%s\n' "$bitrate_kbps" "$low_kbps" "$high_kbps" "$tier_label"
    else
        printf 'normal\t%s\t%s\t%s\t%s\n' "$bitrate_kbps" "$low_kbps" "$high_kbps" "$tier_label"
    fi
}

#------------------------------------------------------------------------------
# Rough output bitrate estimation helpers (pre-flight visibility)
#------------------------------------------------------------------------------
estimate_quality_ratio_per_mille() {
    local mode="$1"
    local quality="$2"
    local ratio=600

    if [[ "$mode" == "vaapi" ]]; then
        # hevc_vaapi QP tends to require a higher ratio than libx265 at similar perceived quality.
        if (( quality <= 14 )); then
            ratio=930
        elif (( quality == 15 )); then
            ratio=900
        elif (( quality == 16 )); then
            ratio=860
        elif (( quality == 17 )); then
            ratio=820
        elif (( quality == 18 )); then
            ratio=770
        elif (( quality == 19 )); then
            ratio=730
        elif (( quality == 20 )); then
            ratio=680
        elif (( quality == 21 )); then
            ratio=640
        elif (( quality == 22 )); then
            ratio=590
        elif (( quality == 23 )); then
            ratio=550
        elif (( quality == 24 )); then
            ratio=510
        elif (( quality == 25 )); then
            ratio=470
        elif (( quality == 26 )); then
            ratio=430
        else
            ratio=390
        fi
    else
        # libx265 CRF generally compresses more efficiently than VAAPI QP.
        if (( quality <= 16 )); then
            ratio=900
        elif (( quality == 17 )); then
            ratio=820
        elif (( quality == 18 )); then
            ratio=740
        elif (( quality == 19 )); then
            ratio=660
        elif (( quality == 20 )); then
            ratio=590
        elif (( quality == 21 )); then
            ratio=520
        elif (( quality == 22 )); then
            ratio=460
        elif (( quality == 23 )); then
            ratio=410
        elif (( quality == 24 )); then
            ratio=360
        elif (( quality == 25 )); then
            ratio=320
        elif (( quality == 26 )); then
            ratio=290
        elif (( quality == 27 )); then
            ratio=260
        else
            ratio=230
        fi
    fi

    printf '%s\n' "$ratio"
}

estimate_transcode_video_output_range() {
    local input_resolution="$1"
    local input_bitrate_bps="$2"
    local source_video_codec="$3"
    local selected_vaapi_qp="$4"
    local selected_cpu_crf="$5"
    local quality_value ratio_per_mille
    local input_kbps low_ratio high_ratio low_kbps high_kbps low_pct high_pct
    local width height pixels
    local source_codec_lower

    if ! [[ "$input_bitrate_bps" =~ ^[0-9]+$ && "$input_bitrate_bps" -gt 0 ]]; then
        printf 'unknown\tunknown\tunknown\tunknown\n'
        return 0
    fi

    input_kbps=$(((input_bitrate_bps + 500) / 1000))

    if [[ "$ENCODER_MODE" == "vaapi" ]]; then
        quality_value="$selected_vaapi_qp"
    else
        quality_value="$selected_cpu_crf"
    fi

    ratio_per_mille=$(estimate_quality_ratio_per_mille "$ENCODER_MODE" "$quality_value")

    source_codec_lower=$(printf '%s' "$source_video_codec" | tr '[:upper:]' '[:lower:]')
    # Source codec bias: re-encoding from modern codecs often yields smaller gains.
    case "$source_codec_lower" in
        h264|avc|avc1|hevc|h265|vp9|av1)
            ratio_per_mille=$((ratio_per_mille + 110))
            ;;
        mpeg2video|mpeg4|wmv3|vc1)
            ratio_per_mille=$((ratio_per_mille - 60))
            ;;
    esac

    # Resolution bias: low-res tends to keep proportionally more overhead after re-encode.
    if [[ "$input_resolution" =~ ^([0-9]+)x([0-9]+)$ ]]; then
        width="${BASH_REMATCH[1]}"
        height="${BASH_REMATCH[2]}"
        pixels=$((width * height))
        if (( pixels <= 854 * 480 )); then
            ratio_per_mille=$((ratio_per_mille + 80))
        elif (( pixels <= 1280 * 720 )); then
            ratio_per_mille=$((ratio_per_mille + 40))
        elif (( pixels >= 3840 * 2160 )); then
            ratio_per_mille=$((ratio_per_mille - 40))
        fi
    fi

    # Bitrate bias: low-bitrate sources often shrink less (or may grow), high-bitrate masters shrink more.
    if (( input_kbps < 1500 )); then
        ratio_per_mille=$((ratio_per_mille + 120))
    elif (( input_kbps < 3000 )); then
        ratio_per_mille=$((ratio_per_mille + 70))
    elif (( input_kbps > 30000 )); then
        ratio_per_mille=$((ratio_per_mille - 50))
    elif (( input_kbps > 15000 )); then
        ratio_per_mille=$((ratio_per_mille - 20))
    fi

    ratio_per_mille=$(clamp_int "$ratio_per_mille" 220 1050)
    low_ratio=$((ratio_per_mille * 75 / 100))
    high_ratio=$((ratio_per_mille * 145 / 100))
    low_kbps=$(((input_kbps * low_ratio + 500) / 1000))
    high_kbps=$(((input_kbps * high_ratio + 500) / 1000))
    low_pct=$(((low_ratio + 5) / 10))
    high_pct=$(((high_ratio + 5) / 10))

    printf '%s\t%s\t%s\t%s\n' "$low_kbps" "$high_kbps" "$low_pct" "$high_pct"
}

#------------------------------------------------------------------------------
# HDR and color space detection
#------------------------------------------------------------------------------
get_primary_video_color_fields() {
    local input="$1"
    local idx color_transfer color_primaries color_space attached

    while IFS='|' read -r idx color_transfer color_primaries color_space attached; do
        [[ -z "$idx" ]] && continue
        [[ "$attached" == "1" ]] && continue
        printf '%s:%s:%s\n' "${color_transfer:-unknown}" "${color_primaries:-unknown}" "${color_space:-unknown}"
        return 0
    done < <(ffprobe -v error -select_streams v \
        -show_entries stream=index,color_transfer,color_primaries,color_space:stream_disposition=attached_pic \
        -of compact=p=0:nk=1 "$input" 2>/dev/null)

    printf 'unknown:unknown:unknown\n'
}

detect_hdr_type() {
    local input="$1"
    local color_transfer color_primaries color_space

    IFS=':' read -r color_transfer color_primaries color_space <<< "$(get_primary_video_color_fields "$input")"

    # Check for HDR indicators
    case "$color_transfer" in
        smpte2084|arib-std-b67)
            echo "hdr10"
            return 0
            ;;
    esac

    case "$color_primaries" in
        bt2020)
            echo "hdr10"
            return 0
            ;;
    esac

    echo "sdr"
}

get_color_metadata() {
    local input="$1"
    get_primary_video_color_fields "$input"
}

#------------------------------------------------------------------------------
# Interlace detection
#------------------------------------------------------------------------------
is_interlaced() {
    local input="$1"
    local idx field_order attached

    while IFS='|' read -r idx field_order attached; do
        [[ -z "$idx" ]] && continue
        [[ "$attached" == "1" ]] && continue
        case "$field_order" in
            tt|bb|tb|bt)
                return 0
                ;;
        esac
        return 1
    done < <(ffprobe -v error -select_streams v \
        -show_entries stream=index,field_order:stream_disposition=attached_pic \
        -of compact=p=0:nk=1 "$input" 2>/dev/null)

    return 1
}

#------------------------------------------------------------------------------
# Audio channel detection
#------------------------------------------------------------------------------
get_audio_channels() {
    local input="$1"
    local stream_idx="${2:-0}"
    local channels

    channels=$(ffprobe -v error -select_streams "a:$stream_idx" \
        -show_entries stream=channels \
        -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null | head -1)

    [[ "$channels" =~ ^[0-9]+$ ]] || channels=2
    printf '%s\n' "$channels"
}

get_audio_codec() {
    local input="$1"
    local stream_idx="${2:-0}"
    local codec

    codec=$(ffprobe -v error -select_streams "a:$stream_idx" \
        -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 "$input" 2>/dev/null | head -1)

    printf '%s\n' "$codec"
}

#------------------------------------------------------------------------------
# Subtitle format detection
#------------------------------------------------------------------------------
get_subtitle_codecs() {
    local input="$1"
    ffprobe -v error -select_streams s \
        -show_entries stream=codec_name \
        -of csv=p=0 "$input" 2>/dev/null
}

has_bitmap_subtitles() {
    local input="$1"
    local codec
    while read -r codec; do
        case "$codec" in
            hdmv_pgs_subtitle|dvd_subtitle|dvb_subtitle|xsub)
                return 0
                ;;
        esac
    done < <(get_subtitle_codecs "$input")
    return 1
}

#------------------------------------------------------------------------------
# HEVC stream safety check for browser/Jellyfin compatibility
#------------------------------------------------------------------------------
is_edge_safe_hevc_stream() {
    local profile_lower pix_fmt_lower
    profile_lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    pix_fmt_lower=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')

    case "$profile_lower" in
        main|main\ 10|main10) ;;
        *) return 1 ;;
    esac

    case "$pix_fmt_lower" in
        yuv420p|yuv420p10le) return 0 ;;
        *) return 1 ;;
    esac
}

#------------------------------------------------------------------------------
# File validation
#------------------------------------------------------------------------------
validate_input_file() {
    local input="$1"

    # Check file exists and is readable
    [[ ! -f "$input" ]] && { log_error "File not found: $input"; return 1; }
    [[ ! -r "$input" ]] && { log_error "File not readable: $input"; return 1; }

    # Check file has content
    local size
    size=$(get_file_size "$input")
    [[ "$size" -lt 1000 ]] && { log_error "File too small (possibly corrupt): $input"; return 1; }

    # Check file is a valid media container
    if ! ffprobe -v error -show_entries format=duration "$input" &>/dev/null; then
        log_error "Cannot probe file (possibly corrupt): $input"
        return 1
    fi

    return 0
}

#------------------------------------------------------------------------------
# FFmpeg execution helpers
#------------------------------------------------------------------------------
run_ffmpeg_logged() {
    local err_file="$1"
    shift

    if [[ "$VERBOSE" == true || "$SHOW_FFMPEG_FPS" == true ]]; then
        "$@" 2> >(tee "$err_file" >&2)
    else
        "$@" 2>"$err_file"
    fi
}

#------------------------------------------------------------------------------
# Error pattern matchers for retry logic
#------------------------------------------------------------------------------
ffmpeg_error_has_attachment_tag_issue() {
    local err_file="$1"
    [[ -s "$err_file" ]] || return 1
    grep -Eq 'Attachment stream [0-9]+ has no (filename|mimetype) tag' "$err_file"
}

ffmpeg_error_has_subtitle_mux_issue() {
    local err_file="$1"
    [[ -s "$err_file" ]] || return 1
    grep -Eqi 'Subtitle codec .* is not supported|Could not find tag for codec .* in stream .*subtitle|Error initializing output stream .*subtitle|Error while opening encoder for output stream .*subtitle|Subtitle encoding currently only possible from text to text or bitmap to bitmap|Unknown encoder|Codec .* is not supported' "$err_file"
}

ffmpeg_error_has_mux_queue_overflow() {
    local err_file="$1"
    [[ -s "$err_file" ]] || return 1
    grep -Eq 'Too many packets buffered for output stream' "$err_file"
}

ffmpeg_error_has_timestamp_discontinuity() {
    local err_file="$1"
    [[ -s "$err_file" ]] || return 1
    grep -Eqi 'Non-monotonous DTS|non monotonically increasing dts|invalid, non monotonically increasing dts|DTS .*out of order|PTS .*out of order|pts has no value|missing PTS|Timestamps are unset' "$err_file"
}

#------------------------------------------------------------------------------
# Build video filter chain
#------------------------------------------------------------------------------
build_video_filter() {
    local input="$1"
    local encoder_mode="$2"
    local -a filters=()

    # Deinterlace if needed
    if [[ "$DEINTERLACE_AUTO" == true ]] && is_interlaced "$input"; then
        log_info "  Detected interlaced content, applying yadif deinterlacer" >&2
        filters+=("yadif=mode=send_frame:parity=auto:deint=interlaced")
    fi

    # HDR handling
    local hdr_type
    hdr_type=$(detect_hdr_type "$input")

    if [[ "$hdr_type" == "hdr10" && "$HANDLE_HDR" == "tonemap" ]]; then
        log_info "  HDR detected, applying tonemapping to SDR" >&2
        filters+=("zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p")
    fi

    if [[ "$encoder_mode" == "vaapi" ]]; then
        # VAAPI needs hwupload
        filters+=("format=${VAAPI_SW_FORMAT},hwupload")
    fi

    # Join filters with comma
    local IFS=','
    echo "${filters[*]}"
}

#------------------------------------------------------------------------------
# Build audio encoding options
#------------------------------------------------------------------------------

# Check if all audio streams are already AAC
all_audio_is_compatible_aac() {
    local input="$1"
    local stream_count codec i

    stream_count=$(get_stream_count "a" "$input")
    [[ "$stream_count" -eq 0 ]] && return 1

    for ((i=0; i<stream_count; i++)); do
        codec=$(get_audio_codec "$input" "$i")
        [[ "$codec" != "aac" ]] && return 1
    done

    return 0
}

build_audio_opts() {
    local input="$1"
    local -a opts=()

    if ! has_audio_stream "$input"; then
        opts=(-an)
    elif all_audio_is_compatible_aac "$input"; then
        # Source audio is already AAC — copy to avoid lossy AAC->AAC re-encode
        log_debug "All audio tracks are AAC, copying" >&2
        opts=(-map 0:a -c:a copy)
    else
        # Build per-stream audio strategy:
        # - copy AAC streams as-is (never AAC->AAC re-encode)
        # - encode remaining streams to AAC
        local stream_count i source_channels target_channels source_codec layout
        stream_count=$(get_stream_count "a" "$input")

        for ((i=0; i<stream_count; i++)); do
            source_codec=$(get_audio_codec "$input" "$i")
            source_channels=$(get_audio_channels "$input" "$i")

            target_channels="$source_channels"
            [[ "$target_channels" -lt 1 ]] && target_channels=1
            [[ "$target_channels" -gt "$AUDIO_CHANNELS" ]] && target_channels="$AUDIO_CHANNELS"

            opts+=(-map "0:a:$i")

            if [[ "$source_codec" == "aac" ]]; then
                log_debug "Audio stream a:$i is AAC, copying" >&2
                opts+=(-c:a:"$i" copy)
                continue
            fi

            opts+=(-c:a:"$i" aac -ac:a:"$i" "$target_channels" -ar:a:"$i" 48000 -b:a:"$i" "$AUDIO_BITRATE")

            if [[ "$MATCH_AUDIO_LAYOUT" == true ]]; then
                case "$target_channels" in
                    1) layout="mono" ;;
                    2) layout="stereo" ;;
                    *) layout="" ;;
                esac

                if [[ -n "$layout" ]]; then
                    opts+=(-filter:a:"$i" "aresample=async=1:first_pts=0:min_hard_comp=0.100,aformat=sample_rates=48000:channel_layouts=${layout}")
                else
                    opts+=(-filter:a:"$i" "aresample=async=1:first_pts=0:min_hard_comp=0.100,aformat=sample_rates=48000")
                fi
            fi
        done
    fi

    printf '%s\n' "${opts[*]}"
}

#------------------------------------------------------------------------------
# Pre-flight render plan summaries
#------------------------------------------------------------------------------
compute_smart_quality_settings() {
    local input="$1"
    local selected_vaapi_qp="$VAAPI_QP"
    local selected_cpu_crf="$CPU_CRF"
    local note="fixed defaults"
    local res width height pixels=0 bitrate_bps=0 bitrate_kbps=0 cpu_adj=0 vaapi_adj=0
    local resolution_label="unknown" bitrate_label="unknown"

    if [[ -n "$ACTIVE_QUALITY_OVERRIDE" ]]; then
        if [[ "$ENCODER_MODE" == "vaapi" ]]; then
            note="manual fixed override (VAAPI_QP=${selected_vaapi_qp})"
        else
            note="manual fixed override (CPU_CRF=${selected_cpu_crf})"
        fi
        printf '%s\t%s\t%s\n' "$selected_vaapi_qp" "$selected_cpu_crf" "$note"
        return 0
    fi

    if [[ "$SMART_QUALITY" != true ]]; then
        note="smart quality disabled"
        printf '%s\t%s\t%s\n' "$selected_vaapi_qp" "$selected_cpu_crf" "$note"
        return 0
    fi

    res=$(get_primary_video_resolution "$input")
    if [[ "$res" =~ ^([0-9]+)x([0-9]+)$ ]]; then
        width="${BASH_REMATCH[1]}"
        height="${BASH_REMATCH[2]}"
        pixels=$((width * height))
        resolution_label="${width}x${height}"
    fi

    bitrate_bps=$(get_primary_video_bitrate_bps "$input")
    if [[ "$bitrate_bps" =~ ^[0-9]+$ && "$bitrate_bps" -gt 0 ]]; then
        bitrate_kbps=$(((bitrate_bps + 500) / 1000))
        bitrate_label="${bitrate_kbps}kb/s"
    fi

    # CPU curve: finer quality control, moderately quality-biased on high-res masters.
    if (( pixels > 0 )); then
        if (( pixels <= 640 * 360 )); then
            cpu_adj=$((cpu_adj + 4))
        elif (( pixels <= 854 * 480 )); then
            cpu_adj=$((cpu_adj + 3))
        elif (( pixels <= 1280 * 720 )); then
            cpu_adj=$((cpu_adj + 2))
        elif (( pixels <= 1920 * 1080 )); then
            cpu_adj=$((cpu_adj + 1))
        elif (( pixels >= 3840 * 2160 )); then
            cpu_adj=$((cpu_adj - 2))
        elif (( pixels >= 2560 * 1440 )); then
            cpu_adj=$((cpu_adj - 1))
        fi
    fi

    # VAAPI curve: generally needs a slightly different QP ramp than CPU CRF.
    if (( pixels > 0 )); then
        if (( pixels <= 640 * 360 )); then
            vaapi_adj=$((vaapi_adj + 6))
        elif (( pixels <= 854 * 480 )); then
            vaapi_adj=$((vaapi_adj + 4))
        elif (( pixels <= 1280 * 720 )); then
            vaapi_adj=$((vaapi_adj + 3))
        elif (( pixels <= 1920 * 1080 )); then
            vaapi_adj=$((vaapi_adj + 1))
        elif (( pixels >= 3840 * 2160 )); then
            vaapi_adj=$((vaapi_adj - 1))
        fi
    fi

    # CPU bitrate adaptation.
    if (( bitrate_kbps > 0 )); then
        if (( bitrate_kbps < 1200 )); then
            cpu_adj=$((cpu_adj + 2))
        elif (( bitrate_kbps < 2500 )); then
            cpu_adj=$((cpu_adj + 1))
        elif (( bitrate_kbps > 35000 )); then
            cpu_adj=$((cpu_adj - 2))
        elif (( bitrate_kbps > 18000 )); then
            cpu_adj=$((cpu_adj - 1))
        fi
    fi

    # VAAPI bitrate adaptation.
    if (( bitrate_kbps > 0 )); then
        if (( bitrate_kbps < 1200 )); then
            vaapi_adj=$((vaapi_adj + 3))
        elif (( bitrate_kbps < 2500 )); then
            vaapi_adj=$((vaapi_adj + 2))
        elif (( bitrate_kbps > 30000 )); then
            vaapi_adj=$((vaapi_adj - 2))
        elif (( bitrate_kbps > 16000 )); then
            vaapi_adj=$((vaapi_adj - 1))
        fi
    fi

    # V1.7 tuning: lower smart-selected quality values by 1 step for both render paths.
    selected_cpu_crf=$(clamp_int "$((CPU_CRF + cpu_adj - 1))" 16 30)
    selected_vaapi_qp=$(clamp_int "$((VAAPI_QP + vaapi_adj - 1))" 14 36)
    note="smart (${resolution_label}, ${bitrate_label}, cpu_adj=${cpu_adj}, vaapi_adj=${vaapi_adj}, smart_bias=-1, cpu_crf=${selected_cpu_crf}, vaapi_qp=${selected_vaapi_qp}, mode=${ENCODER_MODE})"

    printf '%s\t%s\t%s\n' "$selected_vaapi_qp" "$selected_cpu_crf" "$note"
}

describe_audio_plan() {
    local input="$1"
    local stream_count codec i copy_count=0 transcode_count=0

    stream_count=$(get_stream_count "a" "$input")
    if [[ "$stream_count" -eq 0 ]]; then
        printf 'transcode=n/a (no audio streams)'
        return 0
    fi

    for ((i=0; i<stream_count; i++)); do
        codec=$(get_audio_codec "$input" "$i")
        if [[ "$codec" == "aac" ]]; then
            ((copy_count++))
        else
            ((transcode_count++))
        fi
    done

    if [[ "$transcode_count" -eq 0 ]]; then
        printf 'transcode=no (copy all %d AAC stream(s))' "$copy_count"
    elif [[ "$copy_count" -eq 0 ]]; then
        printf 'transcode=yes (all %d stream(s) -> AAC %s, 48kHz, up to %dch)' "$stream_count" "$AUDIO_BITRATE" "$AUDIO_CHANNELS"
    else
        printf 'transcode=yes (copy %d AAC stream(s), transcode %d stream(s) -> AAC %s, 48kHz, up to %dch)' "$copy_count" "$transcode_count" "$AUDIO_BITRATE" "$AUDIO_CHANNELS"
    fi
}

format_codec_label() {
    local codec="${1:-unknown}"
    [[ -z "$codec" ]] && codec="unknown"
    printf '%s\n' "${codec^^}"
}

describe_audio_conversion_short() {
    local input="$1"
    local stream_count codec codec_label source_codecs="" output_label
    local i copy_count=0 transcode_count=0

    stream_count=$(get_stream_count "a" "$input")
    if [[ "$stream_count" -eq 0 ]]; then
        printf 'none -> none'
        return 0
    fi

    for ((i=0; i<stream_count; i++)); do
        codec=$(get_audio_codec "$input" "$i")
        [[ -z "$codec" ]] && codec="unknown"
        codec_label=$(format_codec_label "$codec")

        if [[ ",$source_codecs," != *",$codec_label,"* ]]; then
            source_codecs="${source_codecs:+${source_codecs},}${codec_label}"
        fi

        if [[ "$codec" == "aac" ]]; then
            ((copy_count++))
        else
            ((transcode_count++))
        fi
    done

    if [[ "$transcode_count" -eq 0 ]]; then
        output_label="AAC (copy)"
    elif [[ "$copy_count" -eq 0 ]]; then
        output_label="AAC (${AUDIO_BITRATE})"
    else
        output_label="AAC (copy + transcode ${AUDIO_BITRATE})"
    fi

    printf '%s -> %s' "$source_codecs" "$output_label"
}

describe_subtitle_plan() {
    local input="$1"
    local include_subtitles="$2"
    local subtitle_count

    subtitle_count=$(get_stream_count "s" "$input")
    if [[ "$subtitle_count" -eq 0 ]]; then
        printf 'none (no subtitle streams)'
        return 0
    fi

    if [[ "$KEEP_SUBTITLES" != true || "$include_subtitles" != true ]]; then
        printf 'disabled'
        return 0
    fi

    if output_container_is_mp4; then
        if has_bitmap_subtitles "$input"; then
            printf 'skip bitmap subtitles (MP4 incompatible)'
        else
            printf 'transcode text subtitles to mov_text'
        fi
    else
        printf 'copy subtitle streams'
    fi
}

describe_attachment_plan() {
    local input="$1"
    local include_attachments="$2"
    local attachment_count

    attachment_count=$(get_stream_count "t" "$input")
    if [[ "$attachment_count" -eq 0 ]]; then
        printf 'none (no attachment streams)'
        return 0
    fi

    if [[ "$KEEP_ATTACHMENTS" != true || "$include_attachments" != true ]]; then
        printf 'disabled'
        return 0
    fi

    if output_container_is_mp4; then
        printf 'disabled for MP4'
    else
        printf 'copy %d attachment stream(s)' "$attachment_count"
    fi
}

# Compact status labels for one-line INFO summaries.
describe_audio_plan_compact() {
    local input="$1"
    local stream_count codec i transcode_count=0 copy_count=0

    stream_count=$(get_stream_count "a" "$input")
    if [[ "$stream_count" -eq 0 ]]; then
        printf 'none'
        return 0
    fi

    for ((i=0; i<stream_count; i++)); do
        codec=$(get_audio_codec "$input" "$i")
        if [[ "$codec" == "aac" ]]; then
            ((copy_count++))
        else
            ((transcode_count++))
        fi
    done

    if [[ "$transcode_count" -eq 0 ]]; then
        printf 'copy AAC'
    elif [[ "$copy_count" -eq 0 ]]; then
        printf 'AAC %s' "$AUDIO_BITRATE"
    else
        printf 'copy + AAC %s' "$AUDIO_BITRATE"
    fi
}

describe_subs_attachments_compact() {
    local input="$1" include_subtitles="$2" include_attachments="$3"
    local subtitle_count attachment_count subtitle_action attachment_action

    subtitle_count=$(get_stream_count "s" "$input")
    attachment_count=$(get_stream_count "t" "$input")

    if [[ "$KEEP_SUBTITLES" != true || "$include_subtitles" != true ]]; then
        subtitle_action="subs off"
    elif [[ "$subtitle_count" -eq 0 ]]; then
        subtitle_action="subs none"
    elif output_container_is_mp4; then
        if has_bitmap_subtitles "$input"; then
            subtitle_action="subs skip-bitmap"
        else
            subtitle_action="subs mov_text"
        fi
    else
        subtitle_action="subs copy"
    fi

    if [[ "$KEEP_ATTACHMENTS" != true || "$include_attachments" != true ]]; then
        attachment_action="att off"
    elif [[ "$attachment_count" -eq 0 ]]; then
        attachment_action="att none"
    elif output_container_is_mp4; then
        attachment_action="att off(MP4)"
    else
        attachment_action="att copy"
    fi

    if [[ "$subtitle_action" == "subs copy" && "$attachment_action" == "att copy" ]]; then
        printf 'copy'
    elif [[ "$subtitle_action" == "subs none" && "$attachment_action" == "att none" ]]; then
        printf 'none'
    else
        printf '%s, %s' "$subtitle_action" "$attachment_action"
    fi
}

log_encode_render_plan() {
    local input="$1" video_stream_idx="$2" include_subtitles="$3" include_attachments="$4" muxing_queue_size="$5" timestamp_fix="$6" selected_vaapi_qp="$7" selected_cpu_crf="$8" quality_mode_note="$9"
    local source_video_codec source_codec_label
    local container_plan
    local input_resolution input_bitrate_bps input_bitrate_label
    local est_low_kbps est_high_kbps est_low_pct est_high_pct
    local audio_conversion video_conversion bitrate_conversion
    local video_compact audio_compact subs_att_compact est_bitrate_compact

    source_video_codec=$(get_primary_video_codec "$input")
    [[ -z "$source_video_codec" ]] && source_video_codec=$(get_codec "$input")
    source_codec_label="${source_video_codec:-unknown}"
    input_resolution=$(get_primary_video_resolution "$input")
    input_bitrate_bps=$(get_primary_video_bitrate_bps "$input")
    input_bitrate_label=$(format_bitrate_label "$input_bitrate_bps")
    IFS=$'\t' read -r est_low_kbps est_high_kbps est_low_pct est_high_pct <<< "$(estimate_transcode_video_output_range "$input_resolution" "$input_bitrate_bps" "$source_codec_label" "$selected_vaapi_qp" "$selected_cpu_crf")"

    audio_compact=$(describe_audio_plan_compact "$input")
    audio_conversion=$(describe_audio_conversion_short "$input")
    subs_att_compact=$(describe_subs_attachments_compact "$input" "$include_subtitles" "$include_attachments")

    if output_container_is_mp4; then
        container_plan="MP4"
    else
        container_plan="${OUTPUT_CONTAINER^^}"
    fi

    if [[ "$ENCODER_MODE" == "vaapi" ]]; then
        video_conversion="$(format_codec_label "$source_codec_label") -> HEVC (VAAPI QP=${selected_vaapi_qp})"
        video_compact="${input_resolution} $(format_codec_label "$source_codec_label") -> HEVC QP${selected_vaapi_qp}"
    else
        video_conversion="$(format_codec_label "$source_codec_label") -> HEVC (x265 CRF=${selected_cpu_crf})"
        video_compact="${input_resolution} $(format_codec_label "$source_codec_label") -> HEVC CRF${selected_cpu_crf}"
    fi

    if [[ "$est_low_kbps" != "unknown" ]]; then
        bitrate_conversion="${input_bitrate_label} -> ~${est_low_kbps}-${est_high_kbps} kb/s"
        est_bitrate_compact="~${est_low_kbps}-${est_high_kbps} kb/s"
    else
        bitrate_conversion="${input_bitrate_label} -> unknown"
        est_bitrate_compact="unknown"
    fi

    # Keep INFO output compact: one concise summary line per file.
    log_render "Conversion: audio ${audio_conversion} | video ${video_conversion} | bitrate ${bitrate_conversion}"
    log_info "Video: ${video_compact} | Audio: ${audio_compact} | Container: ${container_plan} | Subtitles/Attachments: ${subs_att_compact} | Est. bitrate: ${est_bitrate_compact}"
    log_debug "  Quality mode: ${quality_mode_note}"
    log_debug "  Retry knobs: mux_queue=${muxing_queue_size}, timestamp_fix=${timestamp_fix}, stream=${video_stream_idx}"
    if [[ "$est_low_kbps" != "unknown" ]]; then
        log_debug "  Estimate detail: ~${est_low_kbps}-${est_high_kbps} kb/s (~${est_low_pct}-${est_high_pct}% of source bitrate, rough)"
    fi
}

log_remux_render_plan() {
    local input="$1" video_stream_idx="$2" include_subtitles="$3" include_attachments="$4" muxing_queue_size="$5" timestamp_fix="$6"
    local source_video_codec source_profile source_pix_fmt
    local container_plan
    local input_resolution input_bitrate_bps input_bitrate_label
    local audio_conversion video_conversion bitrate_conversion
    local video_compact audio_compact subs_att_compact

    source_video_codec=$(get_primary_video_codec "$input")
    [[ -z "$source_video_codec" ]] && source_video_codec=$(get_codec "$input")
    source_profile=$(get_primary_video_profile "$input")
    source_pix_fmt=$(get_primary_video_pix_fmt "$input")
    input_resolution=$(get_primary_video_resolution "$input")
    input_bitrate_bps=$(get_primary_video_bitrate_bps "$input")
    input_bitrate_label=$(format_bitrate_label "$input_bitrate_bps")

    audio_compact=$(describe_audio_plan_compact "$input")
    audio_conversion=$(describe_audio_conversion_short "$input")
    subs_att_compact=$(describe_subs_attachments_compact "$input" "$include_subtitles" "$include_attachments")

    if output_container_is_mp4; then
        container_plan="MP4"
    else
        container_plan="${OUTPUT_CONTAINER^^}"
    fi

    video_conversion="$(format_codec_label "${source_video_codec:-unknown}") -> $(format_codec_label "${source_video_codec:-unknown}") (copy)"
    bitrate_conversion="${input_bitrate_label} -> ~same (video copy)"
    video_compact="${input_resolution} $(format_codec_label "${source_video_codec:-unknown}") -> copy"

    # Keep INFO output compact: one concise summary line per file.
    log_render "Conversion: audio ${audio_conversion} | video ${video_conversion} | bitrate ${bitrate_conversion}"
    log_info "Video: ${video_compact} | Audio: ${audio_compact} | Container: ${container_plan} | Subtitles/Attachments: ${subs_att_compact} | Est. bitrate: ~same (video copy)"
    log_debug "  Video copy detail: stream=${video_stream_idx}, profile=${source_profile:-unknown}, pix_fmt=${source_pix_fmt:-unknown}"
    log_debug "  Retry knobs: mux_queue=${muxing_queue_size}, timestamp_fix=${timestamp_fix}"
}

#------------------------------------------------------------------------------
# Build subtitle options
#------------------------------------------------------------------------------
build_subtitle_opts() {
    local input="$1"
    local include_subtitles="$2"
    local -a opts=()
    local subtitle_codec="copy"
    local subtitle_count

    if [[ "$KEEP_SUBTITLES" != true || "$include_subtitles" != true ]]; then
        return
    fi

    subtitle_count=$(get_stream_count "s" "$input")
    [[ "$subtitle_count" -eq 0 ]] && return

    if output_container_is_mp4; then
        if has_bitmap_subtitles "$input"; then
            log_warn "  Bitmap subtitles cannot be included in MP4 container" >&2
            return
        fi
        subtitle_codec="mov_text"
    fi

    opts=(-map 0:s? -c:s "$subtitle_codec")
    printf '%s\n' "${opts[*]}"
}

#------------------------------------------------------------------------------
# Remux HEVC sources (copy video, encode audio)
#------------------------------------------------------------------------------
run_remux_with_audio_opts() {
    local input="$1" output="$2" video_stream_idx="$3" err_file="$4" include_subtitles="$5" include_attachments="$6" muxing_queue_size="${7:-4096}" timestamp_fix="${8:-false}"
    shift 8
    local -a audio_opts_array=() subtitle_opts_array=() attachment_opts=() pre_input_opts=() timestamp_opts=() stream_disposition_opts=() container_opts=() tag_opts=()
    local audio_stream_count=0 i mp4_output=false

    # Parse audio opts from remaining args
    read -ra audio_opts_array <<< "$*"

    if output_container_is_mp4; then
        mp4_output=true
        container_opts=(-movflags +faststart)
    else
        container_opts=()
    fi

    # hvc1 tag for compatibility (MP4 only; MKV uses codec IDs natively)
    if [[ "$mp4_output" == true ]]; then
        tag_opts=(-tag:v hvc1)
    else
        tag_opts=()
    fi

    if [[ "$timestamp_fix" == true ]]; then
        pre_input_opts=(-fflags +genpts+discardcorrupt)
        timestamp_opts=(-avoid_negative_ts make_zero)
    else
        pre_input_opts=()
        timestamp_opts=()
    fi

    # Build subtitle options
    local sub_opts_str
    sub_opts_str=$(build_subtitle_opts "$input" "$include_subtitles")
    [[ -n "$sub_opts_str" ]] && read -ra subtitle_opts_array <<< "$sub_opts_str"

    if [[ "$KEEP_ATTACHMENTS" == true && "$include_attachments" == true ]]; then
        if [[ "$mp4_output" == true ]]; then
            attachment_opts=()
        else
            attachment_opts=(-map 0:t? -c:t copy)
        fi
    else
        attachment_opts=()
    fi

    audio_stream_count=$(get_stream_count "a" "$input")
    stream_disposition_opts=(-disposition:v:0 default)
    if [[ "$audio_stream_count" -gt 0 ]]; then
        stream_disposition_opts+=(-disposition:a:0 default)
        for ((i=1; i<audio_stream_count; i++)); do
            stream_disposition_opts+=(-disposition:a:"$i" 0)
        done
    fi

    run_ffmpeg_logged "$err_file" \
        ffmpeg -hide_banner -nostdin -y -loglevel "$FFMPEG_LOGLEVEL" ${FFMPEG_PROGRESS_ARGS[@]+"${FFMPEG_PROGRESS_ARGS[@]}"} \
            -probesize "$FFMPEG_PROBESIZE" -analyzeduration "$FFMPEG_ANALYZEDURATION" -ignore_unknown \
            ${pre_input_opts[@]+"${pre_input_opts[@]}"} \
            -i "$input" \
            -map "0:${video_stream_idx}" ${audio_opts_array[@]+"${audio_opts_array[@]}"} ${subtitle_opts_array[@]+"${subtitle_opts_array[@]}"} ${attachment_opts[@]+"${attachment_opts[@]}"} \
            -dn -max_muxing_queue_size "$muxing_queue_size" -max_interleave_delta 0 \
            -c:v copy \
            ${tag_opts[@]+"${tag_opts[@]}"} \
            ${stream_disposition_opts[@]+"${stream_disposition_opts[@]}"} \
            -map_metadata 0 -map_chapters 0 \
            ${timestamp_opts[@]+"${timestamp_opts[@]}"} \
            ${container_opts[@]+"${container_opts[@]}"} \
            "$output"
}

run_remux_attempt() {
    local input="$1" output="$2" video_stream_idx="$3" err_file="$4" include_attachments="${5:-true}" include_subtitles="${6:-true}" muxing_queue_size="${7:-4096}" timestamp_fix="${8:-false}"
    local audio_opts

    audio_opts=$(build_audio_opts "$input")

    run_remux_with_audio_opts "$input" "$output" "$video_stream_idx" "$err_file" "$include_subtitles" "$include_attachments" "$muxing_queue_size" "$timestamp_fix" $audio_opts
}

#------------------------------------------------------------------------------
# Full transcode (video + audio encode)
#------------------------------------------------------------------------------
run_encode_attempt() {
    local input="$1" output="$2" video_stream_idx="$3" err_file="$4" include_attachments="${5:-true}" include_subtitles="${6:-true}" muxing_queue_size="${7:-4096}" timestamp_fix="${8:-false}" selected_vaapi_qp="${9:-$VAAPI_QP}" selected_cpu_crf="${10:-$CPU_CRF}"
    local -a audio_opts_array=() subtitle_opts_array=() attachment_opts=() pre_input_opts=() timestamp_opts=() stream_disposition_opts=() container_opts=() tag_opts=() color_opts=()
    local audio_stream_count=0 i mp4_output=false vf_chain

    if output_container_is_mp4; then
        mp4_output=true
        container_opts=(-movflags +faststart)
    else
        container_opts=()
    fi

    # Build audio options
    local audio_opts_str
    audio_opts_str=$(build_audio_opts "$input")
    [[ -n "$audio_opts_str" ]] && read -ra audio_opts_array <<< "$audio_opts_str"

    # Build subtitle options
    local sub_opts_str
    sub_opts_str=$(build_subtitle_opts "$input" "$include_subtitles")
    [[ -n "$sub_opts_str" ]] && read -ra subtitle_opts_array <<< "$sub_opts_str"

    if [[ "$KEEP_ATTACHMENTS" == true && "$include_attachments" == true ]]; then
        if [[ "$mp4_output" == true ]]; then
            attachment_opts=()
        else
            attachment_opts=(-map 0:t? -c:t copy)
        fi
    else
        attachment_opts=()
    fi

    if [[ "$timestamp_fix" == true ]]; then
        pre_input_opts=(-fflags +genpts+discardcorrupt)
        timestamp_opts=(-avoid_negative_ts make_zero)
    else
        pre_input_opts=()
        timestamp_opts=()
    fi

    # Preserve color metadata for HDR passthrough
    local hdr_type
    hdr_type=$(detect_hdr_type "$input")
    if [[ "$hdr_type" == "hdr10" && "$HANDLE_HDR" == "preserve" ]]; then
        local color_meta
        color_meta=$(get_color_metadata "$input")
        IFS=':' read -r ct cp cs <<< "$color_meta"
        [[ "$ct" != "unknown" ]] && color_opts+=(-color_trc "$ct")
        [[ "$cp" != "unknown" ]] && color_opts+=(-color_primaries "$cp")
        [[ "$cs" != "unknown" ]] && color_opts+=(-colorspace "$cs")
    fi

    # hvc1 tag for compatibility (MP4 only; MKV uses codec IDs natively)
    if [[ "$mp4_output" == true ]]; then
        tag_opts=(-tag:v hvc1)
    else
        tag_opts=()
    fi

    audio_stream_count=$(get_stream_count "a" "$input")
    stream_disposition_opts=(-disposition:v:0 default)
    if [[ "$audio_stream_count" -gt 0 ]]; then
        stream_disposition_opts+=(-disposition:a:0 default)
        for ((i=1; i<audio_stream_count; i++)); do
            stream_disposition_opts+=(-disposition:a:"$i" 0)
        done
    fi

    # Build video filter chain
    vf_chain=$(build_video_filter "$input" "$ENCODER_MODE")

    if [[ "$ENCODER_MODE" == "vaapi" ]]; then
        local -a vf_opts=()
        [[ -n "$vf_chain" ]] && vf_opts=(-vf "$vf_chain")

        run_ffmpeg_logged "$err_file" \
            ffmpeg -hide_banner -nostdin -y -loglevel "$FFMPEG_LOGLEVEL" ${FFMPEG_PROGRESS_ARGS[@]+"${FFMPEG_PROGRESS_ARGS[@]}"} \
                -probesize "$FFMPEG_PROBESIZE" -analyzeduration "$FFMPEG_ANALYZEDURATION" -ignore_unknown \
                ${pre_input_opts[@]+"${pre_input_opts[@]}"} \
                -init_hw_device vaapi=va:"$VAAPI_DEVICE" -filter_hw_device va \
                -i "$input" \
                ${vf_opts[@]+"${vf_opts[@]}"} \
                -map "0:${video_stream_idx}" ${audio_opts_array[@]+"${audio_opts_array[@]}"} ${subtitle_opts_array[@]+"${subtitle_opts_array[@]}"} ${attachment_opts[@]+"${attachment_opts[@]}"} \
                -dn -max_muxing_queue_size "$muxing_queue_size" -max_interleave_delta 0 \
                -c:v hevc_vaapi -qp "$selected_vaapi_qp" -profile:v "$VAAPI_PROFILE" -g "$KEYFRAME_INT" \
                ${tag_opts[@]+"${tag_opts[@]}"} \
                ${color_opts[@]+"${color_opts[@]}"} \
                ${stream_disposition_opts[@]+"${stream_disposition_opts[@]}"} \
                -map_metadata 0 -map_chapters 0 \
                ${timestamp_opts[@]+"${timestamp_opts[@]}"} \
                ${container_opts[@]+"${container_opts[@]}"} \
                "$output"
    else
        local -a vf_opts=()
        if [[ -n "$vf_chain" ]]; then
            vf_opts=(-vf "$vf_chain")
        fi

        run_ffmpeg_logged "$err_file" \
            ffmpeg -hide_banner -nostdin -y -loglevel "$FFMPEG_LOGLEVEL" ${FFMPEG_PROGRESS_ARGS[@]+"${FFMPEG_PROGRESS_ARGS[@]}"} \
                -probesize "$FFMPEG_PROBESIZE" -analyzeduration "$FFMPEG_ANALYZEDURATION" -ignore_unknown \
                ${pre_input_opts[@]+"${pre_input_opts[@]}"} \
                -i "$input" \
                ${vf_opts[@]+"${vf_opts[@]}"} \
                -map "0:${video_stream_idx}" ${audio_opts_array[@]+"${audio_opts_array[@]}"} ${subtitle_opts_array[@]+"${subtitle_opts_array[@]}"} ${attachment_opts[@]+"${attachment_opts[@]}"} \
                -dn -max_muxing_queue_size "$muxing_queue_size" -max_interleave_delta 0 \
                -c:v libx265 -crf "$selected_cpu_crf" -preset "$CPU_PRESET" \
                -profile:v "$CPU_HEVC_PROFILE" -pix_fmt "$CPU_PIX_FMT" -g "$KEYFRAME_INT" \
                -x265-params "log-level=error:open-gop=0" \
                ${tag_opts[@]+"${tag_opts[@]}"} \
                ${color_opts[@]+"${color_opts[@]}"} \
                ${stream_disposition_opts[@]+"${stream_disposition_opts[@]}"} \
                -map_metadata 0 -map_chapters 0 \
                ${timestamp_opts[@]+"${timestamp_opts[@]}"} \
                ${container_opts[@]+"${container_opts[@]}"} \
                "$output"
    fi
}

#------------------------------------------------------------------------------
# Filename parsing for TV/Movie classification
#------------------------------------------------------------------------------
extract_show_base_and_year_tag() {
    local show_name="$1"
    local base_show="$show_name"
    local year_tag=""

    if [[ "$show_name" =~ ^(.+)[[:space:]]+\((19[0-9]{2}|20[0-9]{2})(-[0-9]{4})?\)$ ]]; then
        base_show=$(trim_whitespace "${BASH_REMATCH[1]}")
        year_tag="${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
    fi

    printf '%s\t%s\n' "$base_show" "$year_tag"
}

register_tv_show_year_variant() {
    local show_name="$1"
    local base_show year_tag variant_bucket existing_variant
    local -a existing_variants=()

    IFS=$'\t' read -r base_show year_tag <<< "$(extract_show_base_and_year_tag "$show_name")"
    [[ -z "$year_tag" || -z "$base_show" ]] && return 0

    variant_bucket="${TV_SHOW_YEAR_VARIANTS[$base_show]:-}"
    if [[ -n "$variant_bucket" ]]; then
        variant_bucket="${variant_bucket#|}"
        variant_bucket="${variant_bucket%|}"
        IFS='|' read -r -a existing_variants <<< "$variant_bucket"
        for existing_variant in "${existing_variants[@]}"; do
            [[ "$existing_variant" == "$show_name" ]] && return 0
        done
    fi

    TV_SHOW_YEAR_VARIANTS["$base_show"]="${TV_SHOW_YEAR_VARIANTS[$base_show]:-}|$show_name|"
}

build_tv_year_variant_index() {
    local f
    TV_SHOW_YEAR_VARIANTS=()

    for f in "$@"; do
        parse_filename "$(basename "$f")" "$(dirname "$f")" true
        if [[ "$MEDIA_TYPE" == "tv" && -n "$SHOW_NAME" ]]; then
            register_tv_show_year_variant "$SHOW_NAME"
        fi
    done
}

harmonize_tv_show_name() {
    local show_name="$1"
    local base_show year_tag variant_bucket first_variant="" variant variant_count=0
    local -a variants=()

    IFS=$'\t' read -r base_show year_tag <<< "$(extract_show_base_and_year_tag "$show_name")"
    if [[ -n "$year_tag" || -z "$base_show" ]]; then
        printf '%s\n' "$show_name"
        return 0
    fi

    variant_bucket="${TV_SHOW_YEAR_VARIANTS[$base_show]:-}"
    if [[ -z "$variant_bucket" ]]; then
        printf '%s\n' "$show_name"
        return 0
    fi

    variant_bucket="${variant_bucket#|}"
    variant_bucket="${variant_bucket%|}"
    IFS='|' read -r -a variants <<< "$variant_bucket"
    for variant in "${variants[@]}"; do
        [[ -z "$variant" ]] && continue
        ((variant_count++))
        [[ -z "$first_variant" ]] && first_variant="$variant"
    done

    if (( variant_count == 1 )) && [[ -n "$first_variant" ]]; then
        printf '%s\n' "$first_variant"
    else
        printf '%s\n' "$show_name"
    fi
}

parse_filename() {
    local filename="$1"
    local parent_input="$2"
    local suppress_debug="${3:-false}"
    local parent="$parent_input"
    local parent_lower
    local base="${filename%.*}"

    # If parse context is a full path and we're inside a "specials-like" subfolder,
    # prefer the grandparent folder as naming context (helps NC/Extras layouts).
    if [[ "$parent_input" == */* ]]; then
        parent=$(basename "$parent_input")
        parent_lower="${parent,,}"
        case "$parent_lower" in
            extras|extra|specials|bonus|featurettes|nc|ncop*|nced*)
                local grandparent
                grandparent=$(basename "$(dirname "$parent_input")")
                if [[ -n "$grandparent" && "$grandparent" != "." && "$grandparent" != "/" ]]; then
                    parent="$grandparent"
                fi
                ;;
        esac
    fi

    MEDIA_TYPE="" SHOW_NAME="" SEASON="" EPISODE="" MOVIE_NAME="" YEAR=""

    # SxxExx pattern (supports optional v2 suffix like S01E01v2)
    if [[ "$base" =~ (^|[^[:alnum:]])[Ss]([0-9]{1,2})[Ee]([0-9]{1,3})([Vv][0-9]+)?([^[:alnum:]]|$) ]]; then
        MEDIA_TYPE="tv"
        SEASON="${BASH_REMATCH[2]}"
        EPISODE="${BASH_REMATCH[3]}"
        SHOW_NAME=$(trim_whitespace "$(echo "$base" | sed -E 's/[[:space:]._-]*[Ss][0-9]{1,2}[Ee][0-9]{1,3}([Vv][0-9]+)?[^[:space:]]*.*//' | tr '._' ' ' | sed 's/[[:space:]-]*$//')")
        [[ -z "$SHOW_NAME" ]] && SHOW_NAME=$(trim_whitespace "$(echo "$parent" | tr '._' ' ' | sed -E 's/[[:space:]._-]*([Ss]eason[[:space:]_.-]*[0-9]{1,2}|[Ss][0-9]{1,2}|[Ss][0-9]{1,2}[Ee][0-9]{1,3}([Vv][0-9]+)?)([[:space:]].*)?$//' | sed 's/[[:space:]-]*$//')")
    # 1x01 pattern (supports optional v2 suffix like 1x01v2)
    elif [[ "$base" =~ (^|[^0-9])([0-9]{1,2})[xX]([0-9]{1,3})([Vv][0-9]+)?([^0-9]|$) ]]; then
        MEDIA_TYPE="tv"
        SEASON="${BASH_REMATCH[2]}"
        EPISODE="${BASH_REMATCH[3]}"
        SHOW_NAME=$(trim_whitespace "$(echo "$base" | sed -E 's/[[:space:]._-]*[0-9]{1,2}[xX][0-9]{1,3}([Vv][0-9]+)?[^[:space:]]*.*//' | tr '._' ' ' | sed 's/[[:space:]-]*$//')")
        [[ -z "$SHOW_NAME" ]] && SHOW_NAME=$(trim_whitespace "$(echo "$parent" | tr '._' ' ' | sed -E 's/[[:space:]._-]*([Ss]eason[[:space:]_.-]*[0-9]{1,2}|[Ss][0-9]{1,2})([[:space:]].*)?$//' | sed 's/[[:space:]-]*$//')")
    # OP/ED special patterns: Show.S01.NCED1 / S01ED-Title
    elif [[ "$base" =~ ^(.*)[[:space:]_.-]*[Ss]([0-9]{1,2})[[:space:]_.-]*(NC)?(OP|ED)([0-9]{0,2})([^[:alnum:]]|$) ]]; then
        local special_num oped_kind show_from_name show_from_parent
        MEDIA_TYPE="tv"
        SEASON="${BASH_REMATCH[2]}"
        special_num="${BASH_REMATCH[5]}"
        [[ -z "$special_num" ]] && special_num=1
        special_num=$((10#$special_num))
        oped_kind=$(printf '%s' "${BASH_REMATCH[4]}" | tr '[:lower:]' '[:upper:]')
        if [[ "$oped_kind" == "OP" ]]; then
            EPISODE=$((100 + special_num))
        else
            EPISODE=$((200 + special_num))
        fi

        show_from_name=$(trim_whitespace "$(echo "${BASH_REMATCH[1]}" | tr '._' ' ' | sed 's/[[:space:]-]*$//')")
        if [[ -n "$show_from_name" ]]; then
            SHOW_NAME="$show_from_name"
        else
            show_from_parent=$(trim_whitespace "$(echo "$parent" | tr '._' ' ' | sed -E 's/[[:space:]]+[Ss][0-9]{1,2}([[:space:]].*)?$//' | sed 's/[[:space:]-]*$//')")
            [[ -z "$show_from_parent" ]] && show_from_parent=$(trim_whitespace "$(echo "$parent" | tr '._' ' ')")
            SHOW_NAME="$show_from_parent"
        fi
    # Creditless OP/ED often use numeric index syntax (e.g. "Show - 001 - ... [Creditless Opening]").
    # Map these to TV specials to avoid collisions with normal episodes.
    elif [[ "$base" =~ ^(\[.+\][[:space:]]*)?(.+)[[:space:]_.-]+([0-9]{1,3})[[:space:]]*-[[:space:]]+.*\[(Creditless[[:space:]]+Opening|Creditless[[:space:]]+Ending)\] ]]; then
        local special_num creditless_kind
        MEDIA_TYPE="tv"
        SHOW_NAME=$(trim_whitespace "$(echo "${BASH_REMATCH[2]}" | tr '._' ' ' | sed 's/[[:space:]-]*$//')")
        SEASON="0"
        special_num="${BASH_REMATCH[3]}"
        special_num=$((10#$special_num))
        creditless_kind=$(printf '%s' "${BASH_REMATCH[4]}" | tr '[:upper:]' '[:lower:]')
        if [[ "$creditless_kind" == *"opening"* ]]; then
            EPISODE=$((100 + special_num))
        else
            EPISODE=$((200 + special_num))
        fi
    # Episodic keyword pattern: Show - Episode 16.5 - Title
    elif [[ "$base" =~ ^(\[.+\][[:space:]]*)?(.+)[[:space:]_.-]+[Ee]pisode[[:space:]_.-]+([0-9]{1,3})([._]([0-9]{1,2}))?([[:space:]][^-]*)?[[:space:]]*-[[:space:]]+(.+)$ ]]; then
        local ep_major ep_minor
        MEDIA_TYPE="tv"
        SHOW_NAME=$(trim_whitespace "$(echo "${BASH_REMATCH[2]}" | tr '._' ' ' | sed 's/[[:space:]-]*$//')")
        ep_major="${BASH_REMATCH[3]}"
        ep_minor="${BASH_REMATCH[5]}"

        if [[ -n "$ep_minor" ]]; then
            SEASON="0"
            EPISODE="${ep_major}${ep_minor}"
        else
            SEASON="1"
            EPISODE="$ep_major"
        fi
    # Named TV specials with numeric index: Show OP/ED/PV/Special/Menu - 01
    elif [[ "$base" =~ ^(.+)[[:space:]_.-]+(OP|ED|PV|Special|Menu)[[:space:]_.-]*-[[:space:]]*([0-9]{1,3})([^[:alnum:]]|$) ]]; then
        local special_kind special_num special_offset
        MEDIA_TYPE="tv"
        SEASON="0"
        SHOW_NAME=$(trim_whitespace "$(echo "${BASH_REMATCH[1]}" | tr '._' ' ' | sed -E 's/[[:space:]]*-[[:space:]]*/ /g' | sed 's/[[:space:]-]*$//')")
        special_kind=$(printf '%s' "${BASH_REMATCH[2]}" | tr '[:lower:]' '[:upper:]')
        special_num="${BASH_REMATCH[3]}"
        special_num=$((10#$special_num))

        case "$special_kind" in
            OP)      special_offset=100 ;;
            ED)      special_offset=200 ;;
            PV)      special_offset=300 ;;
            SPECIAL) special_offset=400 ;;
            MENU)    special_offset=500 ;;
            *)       special_offset=900 ;;
        esac
        EPISODE=$((special_offset + special_num))
    # Named TV specials without explicit index: Show - Recap / Day Breakers / documentary extras
    elif [[ "$base" =~ ^(.+)[[:space:]]*-[[:space:]]*(Recap|Day[[:space:]]+Breakers|BTS[[:space:]]+Documentary|Convention[[:space:]]+Panel)$ ]]; then
        local special_kind special_offset
        MEDIA_TYPE="tv"
        SEASON="0"
        SHOW_NAME=$(trim_whitespace "$(echo "${BASH_REMATCH[1]}" | tr '._' ' ' | sed -E 's/[[:space:]]*-[[:space:]]*/ /g' | sed 's/[[:space:]-]*$//')")
        special_kind=$(printf '%s' "${BASH_REMATCH[2]}" | tr '[:upper:]' '[:lower:]')

        case "$special_kind" in
            recap)             special_offset=601 ;;
            day\ breakers)     special_offset=602 ;;
            bts\ documentary)  special_offset=603 ;;
            convention\ panel) special_offset=604 ;;
            *)                 special_offset=699 ;;
        esac
        EPISODE="$special_offset"
    # Numbered movie-part naming: "Title The Movie 1 - Part Name"
    elif [[ "$base" =~ ^(.+[[:space:]]The[[:space:]]Movie)[[:space:]]([0-9]{1,2})[[:space:]]*-[[:space:]]*(.+)$ ]]; then
        MEDIA_TYPE="movie"
        MOVIE_NAME=$(trim_whitespace "$(echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} - ${BASH_REMATCH[3]}" | tr '._' ' ' | sed -E 's/\[[^]]*\]//g')")
    # Anime: [Group] Name - 05
    elif [[ "$base" =~ ^(\[.+\])?[[:space:]]*(.+)[[:space:]]+-[[:space:]]*([0-9]{1,3})([[:space:]]|\[|v[0-9]|$) ]]; then
        local parsed_show
        MEDIA_TYPE="tv"
        SEASON="1"
        EPISODE="${BASH_REMATCH[3]}"
        parsed_show=$(trim_whitespace "${BASH_REMATCH[2]}")

        # If greedy matching consumed a prior episode token (e.g. "Show - 027 - 800 Years..."),
        # recover the intended earlier episode number and trim it back out of the show title.
        if [[ "$parsed_show" =~ ^(.+)[[:space:]]-[[:space:]]([0-9]{1,3})$ ]]; then
            SHOW_NAME=$(trim_whitespace "${BASH_REMATCH[1]}")
            EPISODE="${BASH_REMATCH[2]}"
        else
            SHOW_NAME="$parsed_show"
        fi
    # Episodic: [Group] Show 05 - Title (supports 21' style episode tokens)
    elif [[ "$base" =~ ^(\[.+\][[:space:]]*)?(.+)[[:space:]_.-]+([0-9]{1,3})\'?[[:space:]]+-[[:space:]]+(.+)$ ]]; then
        MEDIA_TYPE="tv"
        SEASON="1"
        EPISODE="${BASH_REMATCH[3]}"
        SHOW_NAME=$(trim_whitespace "$(echo "${BASH_REMATCH[2]}" | tr '._' ' ')")
    # Episodic fallback: 05 - Title (derive show name from parent directory)
    elif [[ "$base" =~ ^([0-9]{1,3})\'?[[:space:]]*-[[:space:]]*(.+)$ ]]; then
        MEDIA_TYPE="tv"
        SEASON="1"
        EPISODE="${BASH_REMATCH[1]}"
        SHOW_NAME=$(trim_whitespace "$(echo "$parent" | tr '._' ' ')")
    # Group releases: [Group] Show 05 [Tags] / [Group] Show - 05 (Tags)
    elif [[ "$base" =~ ^(\[[^]]+\][[:space:]]+)(.+)[[:space:]_.-]+([0-9]{1,3})\'?([Vv][0-9]+)?([[:space:]].*)?$ ]]; then
        local show_no_year parent_year_label
        MEDIA_TYPE="tv"
        SEASON="1"
        EPISODE="${BASH_REMATCH[3]}"
        SHOW_NAME=$(trim_whitespace "$(echo "${BASH_REMATCH[2]}" | tr '._' ' ' | sed 's/[[:space:]-]*$//')")
        if [[ "$SHOW_NAME" =~ ^(.+)[[:space:]]+(19[0-9]{2}|20[0-9]{2})$ ]]; then
            show_no_year=$(trim_whitespace "${BASH_REMATCH[1]}")
            if [[ "$parent" =~ \(([0-9]{4}(-[0-9]{4})?)\) ]]; then
                parent_year_label="${BASH_REMATCH[1]}"
                SHOW_NAME="${show_no_year} (${parent_year_label})"
            else
                SHOW_NAME="$show_no_year"
            fi
        fi
    # Anime: [Group]Name_Name_01_BD or Name_01
    elif [[ "$base" =~ ^(\[.+\])?(.+)_([0-9]{2,3})(_[^.]*)?$ ]]; then
        MEDIA_TYPE="tv"
        SEASON="1"
        EPISODE="${BASH_REMATCH[3]}"
        SHOW_NAME=$(trim_whitespace "$(echo "${BASH_REMATCH[2]}" | tr '_' ' ')")
    # Movie with year
    elif [[ "$base" =~ (.+)[._[:space:]]\(?((19[0-9]{2}|20[0-9]{2}))\)? ]]; then
        MEDIA_TYPE="movie"
        MOVIE_NAME=$(trim_whitespace "$(echo "${BASH_REMATCH[1]}" | tr '._' ' ')")
        YEAR="${BASH_REMATCH[2]}"
    else
        MEDIA_TYPE="movie"
        MOVIE_NAME=$(trim_whitespace "$(echo "$base" | tr '._' ' ')")
    fi

    # Clean tags
    local tags='720p|1080p|2160p|4K|UHD|WEB-DL|WEBRip|BluRay|BDRip|BD|DVDRip|HDTV|x264|x265|HEVC|H\.?264|H\.?265|AAC|AC3|DTS|DTS-HD|TrueHD|FLAC|EAC3|DD\+?|Atmos|10bit|HDR|HDR10|HDR10\+|DV|DoVi|Dual\.?Audio|MULTI|REMUX|PROPER|REPACK|EMBER|NF|AMZN|DSNP|HMAX|ATVP'
    SHOW_NAME=$(trim_whitespace "$(echo "$SHOW_NAME" | sed -E "s/(^|[[:space:]._-])(${tags})([[:space:]._-]|$).*$//I" | sed -E 's/\[[^]]*\]//g')")
    MOVIE_NAME=$(trim_whitespace "$(echo "$MOVIE_NAME" | sed -E "s/(^|[[:space:]._-])(${tags})([[:space:]._-]|$).*$//I" | sed -E 's/\[[^]]*\]//g')")

    # Title case
    SHOW_NAME=$(echo "$SHOW_NAME" | sed 's/\b\(.\)/\u\1/g')
    MOVIE_NAME=$(echo "$MOVIE_NAME" | sed 's/\b\(.\)/\u\1/g')

    # Fallbacks
    # If a parent folder clearly indicates a higher season (e.g. "S2"/"Season 2"),
    # prefer that hint for season-less episodic naming that defaulted to Season 01.
    if [[ "$MEDIA_TYPE" == "tv" && "$SEASON" =~ ^[0-9]+$ ]]; then
        local parent_season_hint
        parent_season_hint=$(extract_parent_season_hint "$parent")
        if [[ "$parent_season_hint" =~ ^[0-9]+$ ]]; then
            if (( 10#$SEASON == 1 && parent_season_hint > 1 )); then
                SEASON="$parent_season_hint"
            fi
        fi
    fi

    [[ "$MEDIA_TYPE" == "tv" && -z "$SHOW_NAME" ]] && SHOW_NAME="Unknown"
    [[ "$MEDIA_TYPE" == "movie" && -z "$MOVIE_NAME" ]] && MOVIE_NAME="Unknown"

    if [[ "$suppress_debug" != true ]]; then
        log_debug "Parsed: $MEDIA_TYPE | show='$SHOW_NAME' S${SEASON:-?}E${EPISODE:-?} | movie='$MOVIE_NAME' (${YEAR:-no year})"
    fi
}

get_output_path() {
    if [[ "$MEDIA_TYPE" == "tv" ]]; then
        local s=$(printf "%02d" "$((10#${SEASON:-1}))")
        local e=$(printf "%02d" "$((10#${EPISODE:-1}))")
        echo "$OUTPUT_DIR/$SHOW_NAME/Season $s/${SHOW_NAME} - S${s}E${e}.${OUTPUT_CONTAINER}"
    else
        local name="$MOVIE_NAME"
        [[ -n "$YEAR" ]] && name="$MOVIE_NAME ($YEAR)"
        echo "$OUTPUT_DIR/$name/${name}.${OUTPUT_CONTAINER}"
    fi
}

resolve_output_path_for_input() {
    local input="$1"
    local requested_output="$2"
    local owner dir filename stem ext candidate counter

    RESOLVED_OUTPUT_PATH="$requested_output"
    owner="${OUTPUT_PATH_OWNERS[$requested_output]:-}"
    if [[ -z "$owner" || "$owner" == "$input" ]]; then
        OUTPUT_PATH_OWNERS["$requested_output"]="$input"
        return 0
    fi

    dir=$(dirname "$requested_output")
    filename=$(basename "$requested_output")
    stem="${filename%.*}"
    ext="${filename##*.}"
    counter="${OUTPUT_PATH_COLLISION_COUNTER[$requested_output]:-1}"

    while true; do
        candidate="${dir}/${stem} - dup${counter}.${ext}"
        owner="${OUTPUT_PATH_OWNERS[$candidate]:-}"
        if [[ -z "$owner" || "$owner" == "$input" ]]; then
            OUTPUT_PATH_COLLISION_COUNTER["$requested_output"]=$((counter + 1))
            OUTPUT_PATH_OWNERS["$candidate"]="$input"
            log_warn "Output collision: $(basename "$filename") already claimed; remapping $(basename "$input") -> $(basename "$candidate")"
            RESOLVED_OUTPUT_PATH="$candidate"
            return 0
        fi
        ((counter++))
    done
}

#------------------------------------------------------------------------------
# Encode a single file with retry logic
#------------------------------------------------------------------------------
encode_file() {
    local input="$1" output="$2" video_stream_idx="${3:-0}"

    mkdir -p "$(dirname "$output")" || { log_error "Can't create dir"; return 1; }

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY] $input"
        log_info "   -> $output"
        return 0
    fi

    log_info "Encoding: $(basename "$input")"
    log_info "  -> $(basename "$output")"

    local start encode_result=1
    start=$(date +%s)
    local ffmpeg_err
    ffmpeg_err=$(make_temp_file)
    local encode_include_attachments=true
    local encode_include_subtitles=true
    local encode_muxing_queue_size=4096
    local encode_timestamp_fix="$CLEAN_TIMESTAMPS"
    local retry_count=0
    local max_retries=4
    local encode_vaapi_qp encode_cpu_crf encode_quality_note
    IFS=$'\t' read -r encode_vaapi_qp encode_cpu_crf encode_quality_note <<< "$(compute_smart_quality_settings "$input")"

    local quality_pass=0
    local max_quality_passes=2

    while (( quality_pass < max_quality_passes )); do
        retry_count=0
        encode_result=1

        log_encode_render_plan "$input" "$video_stream_idx" "$encode_include_subtitles" "$encode_include_attachments" "$encode_muxing_queue_size" "$encode_timestamp_fix" "$encode_vaapi_qp" "$encode_cpu_crf" "$encode_quality_note"

        # Try encoding with progressive fallbacks
        while [[ $retry_count -lt $max_retries ]]; do
            if run_encode_attempt "$input" "$output" "$video_stream_idx" "$ffmpeg_err" "$encode_include_attachments" "$encode_include_subtitles" "$encode_muxing_queue_size" "$encode_timestamp_fix" "$encode_vaapi_qp" "$encode_cpu_crf"; then
                encode_result=0
                break
            fi

            [[ "$STRICT_MODE" == true ]] && break

            ((retry_count++))

            if [[ "$encode_include_attachments" == true ]] && ffmpeg_error_has_attachment_tag_issue "$ffmpeg_err"; then
                log_warn "Retry $retry_count: removing attachments"
                encode_include_attachments=false
                rm -f "$output"
                continue
            fi

            if [[ "$encode_include_subtitles" == true ]] && ffmpeg_error_has_subtitle_mux_issue "$ffmpeg_err"; then
                log_warn "Retry $retry_count: removing subtitles"
                encode_include_subtitles=false
                rm -f "$output"
                continue
            fi

            if [[ "$encode_muxing_queue_size" -lt 16384 ]] && ffmpeg_error_has_mux_queue_overflow "$ffmpeg_err"; then
                log_warn "Retry $retry_count: increasing mux queue to 16384"
                encode_muxing_queue_size=16384
                rm -f "$output"
                continue
            fi

            if [[ "$encode_timestamp_fix" != true ]] && ffmpeg_error_has_timestamp_discontinuity "$ffmpeg_err"; then
                log_warn "Retry $retry_count: enabling timestamp fix"
                encode_timestamp_fix=true
                rm -f "$output"
                continue
            fi

            # No matching fix found, stop retrying
            break
        done

        if [[ $encode_result -eq 0 && -f "$output" ]]; then
            local in_sz out_sz ratio
            in_sz=$(get_file_size "$input")
            out_sz=$(get_file_size "$output")
            [[ $in_sz -gt 0 ]] && ratio=$((out_sz * 100 / in_sz)) || ratio=0

            if [[ "$SMART_QUALITY" == true && -z "$ACTIVE_QUALITY_OVERRIDE" && "$ratio" -gt 105 && $((quality_pass + 1)) -lt "$max_quality_passes" ]]; then
                log_warn "Output is larger than source (${ratio}%), retrying with tighter quality settings"
                encode_cpu_crf=$(clamp_int "$((encode_cpu_crf + 2))" 16 30)
                encode_vaapi_qp=$(clamp_int "$((encode_vaapi_qp + 2))" 14 36)
                encode_quality_note="smart retry (tighter): CPU_CRF=${encode_cpu_crf}, VAAPI_QP=${encode_vaapi_qp}"
                rm -f "$output"
                ((quality_pass++))
                continue
            fi

            local elapsed=$(( $(date +%s) - start ))
            log_success "Done in ${elapsed}s (${ratio}%)"
            return 0
        fi

        break
    done

    log_error "Failed!"
    if [[ -s "$ffmpeg_err" ]]; then
        log_error "Last ffmpeg output:"
        tail -n 20 "$ffmpeg_err" | sed 's/^/  /'
    fi
    rm -f "$output"
    return 1
}

#------------------------------------------------------------------------------
# Process all files in input directory
#------------------------------------------------------------------------------
process_files() {
    local -a files=()
    local exts="mkv|mp4|avi|m4v|mov|wmv|flv|webm|ts|m2ts|mpg|mpeg|vob|ogv"

    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$INPUT_DIR" \
        -type d -iname "extras" -prune -o \
        -type f -regextype posix-extended -iregex ".*\.($exts)$" -print0 | sort -z)

    build_tv_year_variant_index "${files[@]}"
    OUTPUT_PATH_OWNERS=()
    OUTPUT_PATH_COLLISION_COUNTER=()

    local total=${#files[@]} current=0 encoded=0 skipped=0 failed=0
    local total_input_bytes=0 total_output_bytes=0

    log_info "Found $total files"
    local profile_label="$CPU_HEVC_PROFILE"
    [[ "$ENCODER_MODE" == "vaapi" ]] && profile_label="$VAAPI_PROFILE"
    log_info "Mode: $ENCODER_MODE (HEVC ${profile_label}), QP/CRF: $([[ $ENCODER_MODE == vaapi ]] && echo $VAAPI_QP || echo $CPU_CRF)"
    if [[ -n "$ACTIVE_QUALITY_OVERRIDE" ]]; then
        if [[ "$ENCODER_MODE" == "vaapi" ]]; then
            log_info "Quality mode: manual fixed override (VAAPI_QP=${ACTIVE_QUALITY_OVERRIDE})"
        else
            log_info "Quality mode: manual fixed override (CPU_CRF=${ACTIVE_QUALITY_OVERRIDE})"
        fi
    elif [[ "$SMART_QUALITY" == true ]]; then
        log_info "Quality mode: smart per-file adaptation (mode-specific CPU/VAAPI curves)"
    else
        log_info "Quality mode: fixed defaults"
    fi
    log_info "Container: ${OUTPUT_CONTAINER^^}"
    log_info "Audio: AAC passthrough (no AAC->AAC), otherwise encode to AAC ${AUDIO_BITRATE}"
    if output_container_is_mp4; then
        log_info "Compatibility: hvc1 tag for Apple/browser support"
    fi
    [[ "$HANDLE_HDR" == "preserve" ]] && log_info "HDR: Preserve metadata when present"
    [[ "$HANDLE_HDR" == "tonemap" ]] && log_info "HDR: Tonemap to SDR"
    [[ "$DEINTERLACE_AUTO" == true ]] && log_info "Deinterlace: Auto-detect and apply yadif"
    if [[ "$KEEP_SUBTITLES" == true ]]; then
        if output_container_is_mp4; then
            log_info "Subtitles: Text subs only (mov_text for MP4)"
        else
            log_info "Subtitles: Copy all streams"
        fi
    fi
    if [[ "$KEEP_ATTACHMENTS" == true ]] && ! output_container_is_mp4; then
        log_info "Attachments: Copy fonts/images"
    fi
    [[ "$SKIP_HEVC" == true ]] && log_info "HEVC sources: Remux (copy video, encode audio)"
    [[ "$STRICT_MODE" == true ]] && log_info "Retry policy: Strict mode (no auto-retry)"
    echo

    for f in "${files[@]}"; do
        ((current++))

        log_info "[$current/$total] $(basename "$f")"

        # Validate file before processing
        if ! validate_input_file "$f"; then
            log_error "Skipping invalid file"
            ((failed++))
            echo
            continue
        fi

        # Check for video stream
        local video_idx
        video_idx=$(get_primary_video_stream_index "$f")
        if [[ -z "$video_idx" ]]; then
            log_warn "No video stream found, skipping"
            ((skipped++))
            echo
            continue
        fi

        parse_filename "$(basename "$f")" "$(dirname "$f")"
        if [[ "$MEDIA_TYPE" == "tv" ]]; then
            local parsed_show_name="$SHOW_NAME"
            SHOW_NAME=$(harmonize_tv_show_name "$SHOW_NAME")
            if [[ "$SHOW_NAME" != "$parsed_show_name" ]]; then
                log_debug "Harmonized show name: '$parsed_show_name' -> '$SHOW_NAME'"
            fi
        fi
        local out
        out=$(get_output_path)
        resolve_output_path_for_input "$f" "$out"
        out="$RESOLVED_OUTPUT_PATH"
        local video_codec video_resolution video_bitrate_bps video_bitrate_label
        local bitrate_outlier_status source_bitrate_kbps outlier_low_kbps outlier_high_kbps outlier_tier
        video_codec=$(get_primary_video_codec "$f")
        [[ -z "$video_codec" ]] && video_codec=$(get_codec "$f")
        video_resolution=$(get_primary_video_resolution "$f")
        video_bitrate_bps=$(get_primary_video_bitrate_bps "$f")
        video_bitrate_label=$(format_bitrate_label "$video_bitrate_bps")
        IFS=$'\t' read -r bitrate_outlier_status source_bitrate_kbps outlier_low_kbps outlier_high_kbps outlier_tier <<< "$(assess_bitrate_outlier "$video_resolution" "$video_bitrate_bps")"

        log_debug "Primary video stream: index=${video_idx}, codec=${video_codec:-unknown}"

        if [[ "$SHOW_FILE_STATS" == true ]]; then
            local hdr_type
            hdr_type=$(detect_hdr_type "$f")
            local hdr_label=""
            [[ "$hdr_type" != "sdr" ]] && hdr_label=" [HDR]"
            local interlace_label=""
            is_interlaced "$f" && interlace_label=" [Interlaced]"
            log_info "  Video: ${video_resolution} | ${video_bitrate_label} | ${video_codec:-unknown}${hdr_label}${interlace_label}"
        fi

        # Flag unusual bitrate-vs-resolution combinations to aid source triage.
        if [[ "$bitrate_outlier_status" == "high" || "$bitrate_outlier_status" == "low" ]]; then
            log_outlier "  Bitrate outlier (${bitrate_outlier_status}): ${source_bitrate_kbps} kb/s for ${video_resolution}; expected ${outlier_low_kbps}-${outlier_high_kbps} kb/s (${outlier_tier})"
        fi

        # Check if already HEVC - copy video, encode audio only
        if [[ "$SKIP_HEVC" == true && "$video_codec" == "hevc" ]]; then
            local allow_hevc_remux=true
            local source_profile source_pix_fmt
            source_profile=$(get_primary_video_profile "$f")
            source_pix_fmt=$(get_primary_video_pix_fmt "$f")

            if ! is_edge_safe_hevc_stream "$source_profile" "$source_pix_fmt"; then
                allow_hevc_remux=false
                log_warn "  HEVC profile '${source_profile:-unknown}' not browser-safe; will re-encode"
            fi

            if [[ "$allow_hevc_remux" == true ]]; then
                if [[ "$SKIP_EXISTING" == true && -f "$out" ]]; then
                    log_warn "Skip (exists): $(basename "$out")"
                    ((skipped++))
                    echo
                    continue
                fi

                log_info "Remuxing (copy HEVC, encode AAC): $(basename "$f")"
                log_info "  -> $(basename "$out")"
                mkdir -p "$(dirname "$out")"

                if [[ "$DRY_RUN" == true ]]; then
                    log_success "[DRY] Would remux"
                    ((encoded++))
                    echo
                    continue
                fi

                local start_rm=$(date +%s)
                local remux_err remux_ok=false
                remux_err=$(make_temp_file)
                local remux_include_subtitles=true
                local remux_include_attachments=true
                local remux_muxing_queue_size=4096
                local remux_timestamp_fix="$CLEAN_TIMESTAMPS"
                local remux_retry_count=0
                local remux_max_retries=4

                log_remux_render_plan "$f" "$video_idx" "$remux_include_subtitles" "$remux_include_attachments" "$remux_muxing_queue_size" "$remux_timestamp_fix"

                while [[ $remux_retry_count -lt $remux_max_retries ]]; do
                    if run_remux_attempt "$f" "$out" "$video_idx" "$remux_err" "$remux_include_attachments" "$remux_include_subtitles" "$remux_muxing_queue_size" "$remux_timestamp_fix"; then
                        remux_ok=true
                        break
                    fi

                    [[ "$STRICT_MODE" == true ]] && break

                    ((remux_retry_count++))
                    rm -f "$out"

                    if [[ "$remux_include_attachments" == true ]] && ffmpeg_error_has_attachment_tag_issue "$remux_err"; then
                        log_warn "Remux retry $remux_retry_count: skip attachments"
                        remux_include_attachments=false
                        continue
                    fi

                    if [[ "$remux_include_subtitles" == true ]] && ffmpeg_error_has_subtitle_mux_issue "$remux_err"; then
                        log_warn "Remux retry $remux_retry_count: skip subtitles"
                        remux_include_subtitles=false
                        continue
                    fi

                    if [[ "$remux_muxing_queue_size" -lt 16384 ]] && ffmpeg_error_has_mux_queue_overflow "$remux_err"; then
                        log_warn "Remux retry $remux_retry_count: increase queue"
                        remux_muxing_queue_size=16384
                        continue
                    fi

                    if [[ "$remux_timestamp_fix" != true ]] && ffmpeg_error_has_timestamp_discontinuity "$remux_err"; then
                        log_warn "Remux retry $remux_retry_count: fix timestamps"
                        remux_timestamp_fix=true
                        continue
                    fi

                    break
                done

                if [[ "$remux_ok" != true ]]; then
                    log_error "Remux failed"
                    if [[ -s "$remux_err" ]]; then
                        log_error "Last ffmpeg output:"
                        tail -n 20 "$remux_err" | sed 's/^/  /'
                    fi
                    rm -f "$out"
                    ((failed++))
                    echo
                    continue
                fi

                local elapsed_rm=$(( $(date +%s) - start_rm ))
                local in_sz out_sz ratio
                in_sz=$(get_file_size "$f")
                out_sz=$(get_file_size "$out")
                [[ $in_sz -gt 0 ]] && ratio=$((out_sz * 100 / in_sz)) || ratio=100
                total_input_bytes=$((total_input_bytes + in_sz))
                total_output_bytes=$((total_output_bytes + out_sz))
                log_success "Remuxed in ${elapsed_rm}s (${ratio}% of original)"
                ((encoded++))
                echo
                continue
            fi
        fi

        if [[ "$SKIP_EXISTING" == true && -f "$out" ]]; then
            log_warn "Skip (exists)"
            ((skipped++))
            echo
            continue
        fi

        if encode_file "$f" "$out" "$video_idx"; then
            ((encoded++))
            if [[ "$DRY_RUN" != true && -f "$out" ]]; then
                local enc_in_sz enc_out_sz
                enc_in_sz=$(get_file_size "$f")
                enc_out_sz=$(get_file_size "$out")
                total_input_bytes=$((total_input_bytes + enc_in_sz))
                total_output_bytes=$((total_output_bytes + enc_out_sz))
            fi
        else
            ((failed++))
        fi
        echo
    done

    # End-of-run summary includes processed count and aggregate space savings.
    local total_space_saved_bytes=$((total_input_bytes - total_output_bytes))

    log_info "=============================="
    log_info "Done: $encoded encoded, $skipped skipped, $failed failed"
    log_info "Summary report:"
    log_info "  Total files processed: $current"
    if [[ "$DRY_RUN" == true ]]; then
        log_info "  Total space saved: n/a (dry run)"
    elif (( total_space_saved_bytes >= 0 )); then
        log_success "  Total space saved: $(format_bytes "$total_space_saved_bytes") (input $(format_bytes "$total_input_bytes") -> output $(format_bytes "$total_output_bytes"))"
    else
        log_warn "  Total space saved: -$(format_bytes "$((-total_space_saved_bytes))") (overall output is larger)"
    fi

    return 0
}

#------------------------------------------------------------------------------
# System diagnostics
#------------------------------------------------------------------------------
run_check() {
    log_info "=== System Check ==="

    if command -v ffmpeg &>/dev/null; then
        local ffmpeg_version
        ffmpeg_version=$(ffmpeg -version 2>/dev/null | head -1)
        log_success "ffmpeg: ${ffmpeg_version:-unknown}"
    else
        log_error "ffmpeg not found"
    fi

    log_info "HEVC encoders:"
    local hevc_encoders
    hevc_encoders=$(ffmpeg -hide_banner -encoders 2>/dev/null | grep -E "hevc|265" || true)
    if [[ -n "$hevc_encoders" ]]; then
        printf '%s\n' "$hevc_encoders"
    else
        log_warn "No HEVC-related encoders reported by ffmpeg"
    fi

    local dev
    dev=$(get_first_render_device || true)
    if [[ -n "$dev" ]]; then
        log_info "Testing VAAPI on $dev..."
        if ffmpeg -hide_banner -nostdin -init_hw_device vaapi=va:"$dev" \
                -f lavfi -i color=black:s=256x256:d=0.1 \
                -vf 'format=p010,hwupload' -c:v hevc_vaapi -profile:v main10 -f null - 2>/dev/null; then
            log_success "VAAPI works (main10)"
        elif ffmpeg -hide_banner -nostdin -init_hw_device vaapi=va:"$dev" \
                -f lavfi -i color=black:s=256x256:d=0.1 \
                -vf 'format=nv12,hwupload' -c:v hevc_vaapi -profile:v main -f null - 2>/dev/null; then
            log_success "VAAPI works (main/8-bit only)"
        else
            log_error "VAAPI failed"
        fi
    else
        log_warn "No VAAPI device found"
    fi

    log_info "Testing CPU x265..."
    if ffmpeg -hide_banner -nostdin -f lavfi -i color=black:s=256x256:d=0.1 -c:v libx265 -f null - 2>/dev/null; then
        log_success "CPU x265 works"
    else
        log_error "CPU x265 failed"
    fi

    log_info "Testing AAC encoder..."
    if ffmpeg -hide_banner -nostdin -f lavfi -i sine=frequency=1000:duration=0.1 -c:a aac -f null - 2>/dev/null; then
        log_success "AAC encoder works"
    else
        log_error "AAC encoder failed"
    fi
}

#------------------------------------------------------------------------------
# Entrypoint
#------------------------------------------------------------------------------
main() {
    init_colors
    parse_args "$@"
    init_colors  # Re-init after --color/--no-color parsed
    print_banner

    if [[ "$CHECK_ONLY" == true ]]; then
        run_check
        exit 0
    fi

    [[ ! -d "$INPUT_DIR" ]] && { log_error "Input not found: $INPUT_DIR"; exit 1; }
    mkdir -p "$OUTPUT_DIR"

    local input_abs output_abs
    input_abs=$(cd "$INPUT_DIR" && pwd -P) || { log_error "Cannot resolve input path: $INPUT_DIR"; exit 1; }
    output_abs=$(cd "$OUTPUT_DIR" && pwd -P) || { log_error "Cannot resolve output path: $OUTPUT_DIR"; exit 1; }
    if [[ "$output_abs" == "$input_abs" || "$output_abs" == "$input_abs/"* ]]; then
        log_error "Output directory must not be inside input directory"
        log_error "Choose an output path outside: $INPUT_DIR"
        exit 1
    fi

    log_info "=== Muxmaster v${SCRIPT_VERSION} ==="
    log_info "In:  $INPUT_DIR"
    log_info "Out: $OUTPUT_DIR"
    [[ "$DRY_RUN" == true ]] && log_warn "DRY RUN"
    echo

    check_deps
    process_files
}

main "$@"
