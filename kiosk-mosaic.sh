#!/usr/bin/env sh
# kiosk-mosaic.sh - show the cameras in a layout file as one labelled mosaic
# that fills the screen.
#
# tiles mode (default): every camera gets its own borderless ffplay window,
# fed by its own ffmpeg. A camera that fails only affects its own tile, which
# shows "No signal" until the camera is back. While the network cable is
# unplugged, the screen shows a message instead of the cameras.
#
# single mode: one ffmpeg builds the whole mosaic and pipes raw frames to one
# full-screen ffplay. Any camera failing restarts the whole mosaic.
#
# Layout files live in layouts/; start from layouts/default.conf.
#
# Needs ffmpeg, ffplay, and a bold sans font. On Alpine:
#   apk add ffmpeg ffplay font-dejavu mesa-va-gallium
#
# Testing hook: KIOSK_NET_ROOT=DIR makes the cable check read
# DIR/sys/class/net and DIR/proc/net/route instead of the real ones.

set -eu

unalias -a 2>/dev/null || true
unset -f awk basename cat command date ffmpeg ffplay find kill mkfifo mktemp mv \
    rm sed sleep uname xrandr 2>/dev/null || true

export LC_ALL=C

PROGNAME=$(basename -- "$0")
readonly PROGNAME
readonly DEFAULT_CREDS=/etc/kiosk/camera.env
readonly DEFAULT_TIMEOUT=5
readonly DEFAULT_RESTART_DELAY=5
readonly FALLBACK_RESOLUTION=1920x1080
# Seconds to wait after TERM before sending KILL to a child process.
readonly STOP_TIMEOUT=3
# A camera that keeps streaming for this many seconds counts as working.
readonly LIVE_AFTER=20
readonly SYS_NET="${KIOSK_NET_ROOT:-}/sys/class/net"
readonly PROC_ROUTE="${KIOSK_NET_ROOT:-}/proc/net/route"
# Stands in for the temporary directory in --print output.
readonly PRINT_TMP=/tmp/kiosk-mosaic.XXXXXX
# Checked in order; the first existing file is used for all text.
readonly FONT_CANDIDATES='/usr/share/fonts/truetype/msttcorefonts/Arial_Bold.ttf
/usr/share/fonts/truetype/msttcorefonts/Arial.ttf
/usr/share/fonts/liberation/LiberationSans-Bold.ttf
/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf
/usr/share/fonts/truetype/liberation2/LiberationSans-Bold.ttf
/usr/share/fonts/TTF/LiberationSans-Bold.ttf
/usr/share/fonts/liberation-sans/LiberationSans-Bold.ttf
/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf
/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf
/usr/share/fonts/TTF/DejaVuSans-Bold.ttf
/usr/share/fonts/dejavu-sans-fonts/DejaVuSans-Bold.ttf'

LAYOUT=''
OPT_RESOLUTION=''
OPT_FPS=''
OPT_FIT=''
OPT_STREAM=''
OPT_SUB_MAX_HEIGHT=''
OPT_LABELS=''
OPT_LABEL_SIZE=''
CONNECTOR=''
MODE=tiles
INTERFACE=''
HWDEC=auto
TRANSPORT=tcp
TIMEOUT=$DEFAULT_TIMEOUT
TIMESTAMPS=arrival
CREDS_FILE=$DEFAULT_CREDS
FONT_FILE=''
RESTART=''
RESTART_DELAY=$DEFAULT_RESTART_DELAY
LOGLEVEL=warning
TEST_PATTERN=''
SNAPSHOT=''
PRINT=''

FFMPEG_BIN=''
FFPLAY_BIN=''
TIMEOUT_OPTION=-timeout
RENDER_NODE=''
DECODE=software
DETECTED=''
DETECTED_SRC=''
FONT_PATH=''
IFACE=''
CRED_USER=''
CRED_PASS=''
ENC_USER=''
ENC_PASS=''
SPEC=''
GRAPH=''
CANVAS=''
TMP_DIR=''
ERR_FIFO=''
LOG_OPEN=''
MASK_PID=''
MESSAGE_PID=''
SUP_PIDS=''
# Set per tile by tile_info, and per supervisor process below.
TILE_TOK=''
TILE_LABEL=''
TX=0
TY=0
TW=0
TH=0
FIFO=''
FFMPEG_PID=''
FFPLAY_PID=''
SLATE_PID=''

usage() {
    printf '%s\n' "Usage: $PROGNAME [OPTION]... LAYOUT
Show the cameras listed in LAYOUT as one labelled mosaic that fills the screen.

Mandatory arguments to long options are mandatory for short options too.
  -r, --resolution=WxH     mosaic size; auto matches the screen (default auto)
      --connector=NAME     screen to measure in auto mode, such as DP-1
                             (default: first connected screen)
      --mode=MODE          tiles gives every camera its own window, so a failing
                             camera only affects its tile; single renders the
                             whole mosaic in one ffmpeg (default tiles)
      --interface=NAME     network port to watch; while its cable is unplugged
                             the screen asks for the cable instead of showing
                             cameras (default: the first wired port; none skips
                             the check)
  -f, --fps=N              frames per second (default 10)
      --fit=MODE           how video fills a tile: fill (crop), fit (letterbox),
                             or stretch (default fill)
      --stream=MODE        camera stream: auto, main, or sub (default auto)
      --sub-max-height=N   in auto mode, use the substream for tiles up to N
                             pixels tall (default 400)
      --hwdec=MODE         video decoding: auto, vaapi, or none (default auto)
      --transport=PROTO    RTSP transport: tcp or udp (default tcp)
      --timeout=SECONDS    give up on a camera that sends nothing for SECONDS
                             (default $DEFAULT_TIMEOUT)
      --timestamps=MODE    arrival paces video by when frames arrive; camera
                             uses the camera clocks (default arrival)
      --creds=FILE         camera credentials file
                             (default $DEFAULT_CREDS)
      --font=FILE          text font (default: first bold sans font found)
      --label-size=N       label font size in pixels (default: scaled per tile)
      --no-labels          do not draw camera labels on live video
      --restart            in single mode, start the mosaic again whenever it
                             stops (tiles mode always retries)
      --restart-delay=N    seconds to wait before retrying a camera or restarting
                             the mosaic (default $DEFAULT_RESTART_DELAY)
      --loglevel=LEVEL     ffmpeg and ffplay log level (default warning)
      --test-pattern       show test patterns instead of cameras
      --snapshot=FILE      save one frame of the mosaic to FILE, such as a.png
  -p, --print              print the commands with the password masked, then exit
  -h, --help               display this help and exit

LAYOUT is a text file with optional settings, one layout block, and one line
per camera. Each name in the layout block is a tile; repeat a name across
cells to make a bigger tile, and use . for an empty cell:

  fps 10
  layout
  A A B
  A A C
  end
  A|1002|Main Entrance|10.0.136.13
  B|1003|Main Entrance Parking|10.0.136.14
  C|1008|Yard|10.0.136.19|stream=main,fit=fit

Camera lines are tile|id|name|address, optionally followed by |options.
Settings: resolution, fps, fit, stream, sub_max_height, main_path, sub_path,
port, labels, label_size. Camera options: stream, fit, main_path, sub_path,
port. Defaults: main_path /rtsp_tunnel, sub_path /rtsp_tunnel?inst=2, port 554.
Options given on the command line override the file.

Credentials come from CAMERA_USER and CAMERA_PASSWORD in the environment, or
from the credentials file, one KEY=value per line without quotes. Give the
password as-is; it is URL-encoded for you."
}

info() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
}

warn() {
    printf '%s: warning: %s\n' "$PROGNAME" "$1" >&2
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    exit 1
}

usage_error() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
    exit 2
}

# $1 = value, $2 = option as typed, $3 = what is allowed.
bad_value() {
    printf "%s: invalid argument '%s' for '%s'\n" "$PROGNAME" "$1" "$2" >&2
    printf 'Valid arguments are: %s\n' "$3" >&2
    printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
    exit 2
}

# Succeeds when $1 is a whole number from $2 to $3.
in_range() {
    case $1 in
        '' | *[!0-9]*) return 1 ;;
    esac
    [ "${#1}" -le 6 ] || return 1
    [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

# $1 = option name without dashes, $2 = value, $3 = option as typed.
set_option() {
    case $1 in
        resolution)
            case $2 in
                auto) ;;
                *x*)
                    if ! in_range "${2%%x*}" 64 16384 || ! in_range "${2#*x}" 64 16384; then
                        bad_value "$2" "$3" 'auto, or WIDTHxHEIGHT such as 1920x1080'
                    fi
                    ;;
                *) bad_value "$2" "$3" 'auto, or WIDTHxHEIGHT such as 1920x1080' ;;
            esac
            OPT_RESOLUTION=$2
            ;;
        connector)
            [ -n "$2" ] || bad_value "$2" "$3" 'a screen name such as DP-1'
            CONNECTOR=$2
            ;;
        mode)
            case $2 in
                tiles | single) MODE=$2 ;;
                *) bad_value "$2" "$3" 'tiles, single' ;;
            esac
            ;;
        interface)
            [ -n "$2" ] || bad_value "$2" "$3" 'a network port name such as eth0, or none'
            INTERFACE=$2
            ;;
        fps)
            in_range "$2" 1 60 || bad_value "$2" "$3" 'a number from 1 to 60'
            OPT_FPS=$2
            ;;
        fit)
            case $2 in
                fill | fit | stretch) OPT_FIT=$2 ;;
                *) bad_value "$2" "$3" 'fill, fit, stretch' ;;
            esac
            ;;
        stream)
            case $2 in
                auto | main | sub) OPT_STREAM=$2 ;;
                *) bad_value "$2" "$3" 'auto, main, sub' ;;
            esac
            ;;
        sub-max-height)
            in_range "$2" 1 16384 || bad_value "$2" "$3" 'a number from 1 to 16384'
            OPT_SUB_MAX_HEIGHT=$2
            ;;
        hwdec)
            case $2 in
                auto | vaapi | none) HWDEC=$2 ;;
                *) bad_value "$2" "$3" 'auto, vaapi, none' ;;
            esac
            ;;
        transport)
            case $2 in
                tcp | udp) TRANSPORT=$2 ;;
                *) bad_value "$2" "$3" 'tcp, udp' ;;
            esac
            ;;
        timeout)
            in_range "$2" 1 3600 || bad_value "$2" "$3" 'a number of seconds from 1 to 3600'
            TIMEOUT=$2
            ;;
        timestamps)
            case $2 in
                arrival | camera) TIMESTAMPS=$2 ;;
                *) bad_value "$2" "$3" 'arrival, camera' ;;
            esac
            ;;
        creds)
            [ -n "$2" ] || bad_value "$2" "$3" 'a file name'
            CREDS_FILE=$2
            ;;
        font)
            [ -n "$2" ] || bad_value "$2" "$3" 'a font file name'
            FONT_FILE=$2
            ;;
        label-size)
            in_range "$2" 6 300 || bad_value "$2" "$3" 'a number from 6 to 300'
            OPT_LABEL_SIZE=$2
            ;;
        restart-delay)
            in_range "$2" 0 3600 || bad_value "$2" "$3" 'a number of seconds from 0 to 3600'
            RESTART_DELAY=$2
            ;;
        loglevel)
            case $2 in
                quiet | panic | fatal | error | warning | info | verbose | debug | trace) LOGLEVEL=$2 ;;
                *) bad_value "$2" "$3" 'quiet, panic, fatal, error, warning, info, verbose, debug, trace' ;;
            esac
            ;;
        snapshot)
            [ -n "$2" ] || bad_value "$2" "$3" 'a file name such as mosaic.png'
            SNAPSHOT=$2
            ;;
    esac
}

set_operand() {
    [ -z "$LAYOUT" ] || usage_error "extra operand '$1'"
    LAYOUT=$1
}

parse_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            -h | --help)
                usage
                exit 0
                ;;
            -p | --print) PRINT=1 ;;
            --no-labels) OPT_LABELS=off ;;
            --restart) RESTART=1 ;;
            --test-pattern) TEST_PATTERN=1 ;;
            --resolution=* | --connector=* | --mode=* | --interface=* | --fps=* | \
                --fit=* | --stream=* | --sub-max-height=* | --hwdec=* | \
                --transport=* | --timeout=* | --timestamps=* | --creds=* | \
                --font=* | --label-size=* | --restart-delay=* | --loglevel=* | \
                --snapshot=*)
                _pa_name=${1%%=*}
                set_option "${_pa_name#--}" "${1#*=}" "$_pa_name"
                ;;
            --resolution | --connector | --mode | --interface | --fps | --fit | \
                --stream | --sub-max-height | --hwdec | --transport | --timeout | \
                --timestamps | --creds | --font | --label-size | --restart-delay | \
                --loglevel | --snapshot)
                [ $# -ge 2 ] || usage_error "option '$1' requires an argument"
                set_option "${1#--}" "$2" "$1"
                shift
                ;;
            -r)
                [ $# -ge 2 ] || usage_error "option requires an argument -- 'r'"
                set_option resolution "$2" -r
                shift
                ;;
            -f)
                [ $# -ge 2 ] || usage_error "option requires an argument -- 'f'"
                set_option fps "$2" -f
                shift
                ;;
            -r?*) set_option resolution "${1#-r}" -r ;;
            -f?*) set_option fps "${1#-f}" -f ;;
            --)
                shift
                break
                ;;
            --*) usage_error "unrecognized option '$1'" ;;
            -?*)
                _pa_char=${1#-}
                _pa_char=${_pa_char%"${_pa_char#?}"}
                usage_error "invalid option -- '$_pa_char'"
                ;;
            *) set_operand "$1" ;;
        esac
        shift
    done

    while [ $# -gt 0 ]; do
        set_operand "$1"
        shift
    done

    [ -n "$LAYOUT" ] || usage_error 'missing operand'
    return 0
}

find_ffmpeg() {
    FFMPEG_BIN=$(command -v ffmpeg) ||
        die 'ffmpeg was not found; install ffmpeg or add it to PATH'

    _fm_major=$("$FFMPEG_BIN" -version 2>/dev/null | awk '
        NR == 1 {
            v = $3
            sub(/^[^0-9]*/, "", v)
            split(v, part, ".")
            print part[1] + 0
            exit
        }') || _fm_major=''

    # FFmpeg 5 renamed the RTSP socket timeout from -stimeout to -timeout.
    case $_fm_major in
        '' | *[!0-9]*) TIMEOUT_OPTION=-timeout ;;
        *)
            if [ "$_fm_major" -lt 5 ]; then
                TIMEOUT_OPTION=-stimeout
            else
                TIMEOUT_OPTION=-timeout
            fi
            ;;
    esac
}

find_ffplay() {
    if FFPLAY_BIN=$(command -v ffplay); then
        return 0
    fi

    _fp_candidate=${FFMPEG_BIN%/*}/ffplay
    if [ -x "$_fp_candidate" ]; then
        FFPLAY_BIN=$_fp_candidate
        return 0
    fi

    die 'ffplay was not found; install ffplay (Alpine: apk add ffplay) or add it to PATH'
}

# Sets DETECTED to the screen's preferred mode, such as 1920x1080.
detect_screen() {
    DETECTED=$FALLBACK_RESOLUTION
    DETECTED_SRC=default

    for _ds_status in /sys/class/drm/card*-*/status; do
        [ -r "$_ds_status" ] || continue
        _ds_dir=${_ds_status%/status}
        _ds_name=${_ds_dir##*/}
        _ds_name=${_ds_name#card*-}
        if [ -n "$CONNECTOR" ] && [ "$_ds_name" != "$CONNECTOR" ]; then
            continue
        fi

        _ds_state=''
        read -r _ds_state <"$_ds_status" || true
        [ "$_ds_state" = connected ] || continue

        _ds_mode=''
        if [ -r "$_ds_dir/modes" ]; then
            read -r _ds_mode <"$_ds_dir/modes" || true
        fi
        _ds_mode=${_ds_mode%%[!0-9x]*}
        case $_ds_mode in
            [1-9]*x[1-9]*)
                DETECTED=$_ds_mode
                DETECTED_SRC="screen $_ds_name"
                return 0
                ;;
        esac
    done

    # Some drivers do not list modes in sysfs; ask the X server instead.
    if [ -n "${DISPLAY:-}" ] && command -v xrandr >/dev/null 2>&1; then
        _ds_mode=$(xrandr --current 2>/dev/null | KM_WANT=$CONNECTOR awk '
            BEGIN { want = ENVIRON["KM_WANT"] }
            want == "" && /^Screen [0-9]+:/ {
                for (i = 1; i < NF - 2; i++) {
                    if ($i == "current") {
                        h = $(i + 3)
                        sub(/,.*/, "", h)
                        print $(i + 1) "x" h
                        exit
                    }
                }
            }
            want != "" && $1 == want && $2 == "connected" {
                for (i = 3; i <= NF; i++) {
                    if ($i ~ /^[0-9]+x[0-9]+\+/) {
                        split($i, part, "+")
                        print part[1]
                        exit
                    }
                }
            }') || _ds_mode=''
        case $_ds_mode in
            [1-9]*x[1-9]*)
                DETECTED=$_ds_mode
                DETECTED_SRC='xrandr'
                return 0
                ;;
        esac
    fi

    return 0
}

find_font() {
    FONT_PATH=''

    if [ -n "$FONT_FILE" ]; then
        if [ ! -f "$FONT_FILE" ] || [ ! -r "$FONT_FILE" ]; then
            die "cannot read font file '$FONT_FILE'"
        fi
        FONT_PATH=$FONT_FILE
        return 0
    fi

    while IFS= read -r _ff_candidate; do
        if [ -f "$_ff_candidate" ]; then
            FONT_PATH=$_ff_candidate
            break
        fi
    done <<EOF
$FONT_CANDIDATES
EOF
    return 0
}

# Sets IFACE to the network port whose cable is checked, or empty for none.
find_interface() {
    IFACE=''
    case $INTERFACE in
        none) return 0 ;;
        '') ;;
        *)
            [ -d "$SYS_NET/$INTERFACE" ] || die "network port '$INTERFACE' does not exist"
            IFACE=$INTERFACE
            return 0
            ;;
    esac

    for _fi_dir in "$SYS_NET"/*; do
        _fi_name=${_fi_dir##*/}
        [ "$_fi_name" != lo ] || continue
        # Real hardware has a device link; Wi-Fi has a wireless directory.
        [ -e "$_fi_dir/device" ] || continue
        [ ! -d "$_fi_dir/wireless" ] || continue
        [ ! -e "$_fi_dir/phy80211" ] || continue
        IFACE=$_fi_name
        return 0
    done

    warn 'no wired network port found; skipping the cable check'
    return 0
}

# Turns the layout file into SPEC lines:
#   T|n|tile|id|name|address|port|path|stream|fit|x|y|w|h   one per camera
#   F|n|filters        per-tile video filters (tiles mode)
#   S|n|graph          the "no signal" screen under a tile (tiles mode)
#   M|0|graph          the full-screen network cable message
#   C|w|h|cols|rows|cameras|fps|labels|source
#   G|graph            the whole-mosaic filter graph (single mode, snapshots)
# Graphs contain @STATUS@ where the text file path goes; the message graph
# reads two files, the path and the path with 2 appended.
build_spec() {
    SPEC=$(
        KM_PROG=$PROGNAME KM_LAYOUT=$LAYOUT KM_FONT=$FONT_PATH \
            KM_HOST=$(uname -n) KM_DETECTED=$DETECTED KM_DETECTED_SRC=$DETECTED_SRC \
            KM_OPT_RESOLUTION=$OPT_RESOLUTION KM_OPT_FPS=$OPT_FPS \
            KM_OPT_FIT=$OPT_FIT KM_OPT_STREAM=$OPT_STREAM \
            KM_OPT_SUB_MAX_HEIGHT=$OPT_SUB_MAX_HEIGHT \
            KM_OPT_LABELS=$OPT_LABELS KM_OPT_LABEL_SIZE=$OPT_LABEL_SIZE \
            awk '
function trim(s) {
    sub(/^[ \t\r]+/, "", s)
    sub(/[ \t\r]+$/, "", s)
    return s
}
function q(s) {
    return "\047" s "\047"
}
function fail(msg) {
    printf "%s: %s\n", prog, msg | "cat 1>&2"
    close("cat 1>&2")
    failed = 1
    exit 1
}
function warn(msg) {
    printf "%s: warning: %s\n", prog, msg | "cat 1>&2"
    close("cat 1>&2")
}
function at() {
    return layout_name ":" FNR ": "
}
function uint(s) {
    return s ~ /^[0-9]+$/ && length(s) <= 6
}
function round(x) {
    return int(x + 0.5)
}
function even(x) {
    return 2 * int(x / 2 + 0.5)
}
function esc(s, chars,    out, i, n, c) {
    out = ""
    n = length(s)
    for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (index(chars, c) > 0)
            out = out "\\" c
        else
            out = out c
    }
    return out
}
# Escapes a filter option value twice: for the option parser, then for the
# filter graph parser.
function fval(s) {
    return esc(esc(s, "\\\047:"), "\\\047[],;")
}
function check(key, val, where,    n) {
    n = val + 0
    if (key == "resolution") {
        if (val != "auto" && val !~ /^[0-9]+x[0-9]+$/)
            fail(where "resolution must be auto or WIDTHxHEIGHT, not " q(val))
    } else if (key == "fps") {
        if (!uint(val) || n < 1 || n > 60)
            fail(where "fps must be 1 to 60, not " q(val))
    } else if (key == "fit") {
        if (val != "fill" && val != "fit" && val != "stretch")
            fail(where "fit must be fill, fit, or stretch, not " q(val))
    } else if (key == "stream") {
        if (val != "auto" && val != "main" && val != "sub")
            fail(where "stream must be auto, main, or sub, not " q(val))
    } else if (key == "sub_max_height") {
        if (!uint(val) || n < 1)
            fail(where "sub_max_height must be a positive number, not " q(val))
    } else if (key == "main_path" || key == "sub_path") {
        if (substr(val, 1, 1) != "/" || val ~ /[ \t]/)
            fail(where key " must start with / and have no spaces, not " q(val))
    } else if (key == "port") {
        if (!uint(val) || n < 1 || n > 65535)
            fail(where "port must be 1 to 65535, not " q(val))
    } else if (key == "labels") {
        if (val != "on" && val != "off")
            fail(where "labels must be on or off, not " q(val))
    } else if (key == "label_size") {
        if (val != "auto" && (!uint(val) || n < 6 || n > 300))
            fail(where "label_size must be auto or 6 to 300, not " q(val))
    } else {
        fail(where "unknown setting " q(key))
    }
}
# Command-line option, then layout file, then built-in default.
function setting(key,    v) {
    if (key in has_flag) {
        v = ENVIRON["KM_OPT_" toupper(key)]
        if (v != "")
            return v
    }
    if (key in file_setting)
        return file_setting[key]
    return def[key]
}
# Command-line option, then camera option, then setting().
function camera_setting(tile, key,    v) {
    if (key in has_flag) {
        v = ENVIRON["KM_OPT_" toupper(key)]
        if (v != "")
            return v
    }
    if ((tile, key) in camera_option)
        return camera_option[tile, key]
    return setting(key)
}
function label_of(tok) {
    if (camera_id[tok] != "" && camera_name[tok] != "")
        return camera_id[tok] " - " camera_name[tok]
    return camera_id[tok] camera_name[tok]
}
# The camera label in the bottom-left corner of a w by h tile.
function drawtext(label, w, h, size,    fs, border, offset, n, room, s) {
    if (size == "auto") {
        fs = int(10 + h / 30)
        if (fs > 72)
            fs = 72
    } else {
        fs = size + 0
    }
    border = round(fs * 0.28)
    if (border < 2)
        border = 2
    offset = border + round(fs * 0.15)
    if (offset < border + 2)
        offset = border + 2
    if (size == "auto") {
        # Shrink long labels to fit the tile, at about 0.65 em per character.
        n = length(label)
        room = w - 2 * offset
        if (n > 0 && 0.65 * fs * n > room)
            fs = int(room / (0.65 * n))
        if (fs < 10)
            fs = 10
    }
    s = "drawtext=fontfile=" fval(font) ":expansion=none:text=" fval(label)
    s = s ":x=" offset ":y=h-th-" offset ":fontsize=" fs
    s = s ":fontcolor=white:box=1:boxcolor=black@0.65:boxborderw=" border
    return s
}
# One centered line of text read from a file, redrawn whenever the file
# changes. The file name gets suffix (such as "" or "2") after @STATUS@, and
# the line is drawn shift pixels below the middle.
function status_text(size, color, suffix, shift) {
    return "drawtext=fontfile=" fval(font) ":textfile=@STATUS@" suffix ":reload=1" \
        ":expansion=none:fontsize=" size ":fontcolor=" color \
        ":x=(w-text_w)/2:y=(h-text_h)/2" (shift >= 0 ? "+" : "") shift
}
# The screen shown under a tile while its camera is down.
function slate_graph(tok, w, h,    fs, cap, s) {
    fs = int(14 + h / 16)
    cap = int(w / 13)
    if (fs > cap)
        fs = cap
    if (fs > 60)
        fs = 60
    if (fs < 12)
        fs = 12
    s = "color=c=0x202428:s=" w "x" h ":r=1"
    s = s "," status_text(fs, "0xd8dce0", "", 0)
    s = s "," drawtext(label_of(tok), w, h, label_size)
    return s ",format=yuv420p"
}
# The full-screen message shown while the network cable is unplugged.
function message_graph(W, H,    fs, hs, s) {
    fs = int(H / 22)
    hs = int(H / 45)
    s = "color=c=0x101820:s=" W "x" H ":r=1"
    # Two lines, each centered on its own: message.txt and message.txt2.
    s = s "," status_text(fs, "white", "", -int(fs * 0.7))
    s = s "," status_text(fs, "white", "2", int(fs * 0.7))
    if (host != "") {
        s = s ",drawtext=fontfile=" fval(font) ":expansion=none:text=" fval(host)
        s = s ":fontsize=" hs ":fontcolor=0x8a9099:x=(w-text_w)/2:y=h-text_h-" int(H / 24)
    }
    return s ",format=yuv420p"
}
BEGIN {
    prog = ENVIRON["KM_PROG"]
    layout_name = ENVIRON["KM_LAYOUT"]
    host = ENVIRON["KM_HOST"]
    def["resolution"] = "auto"
    def["fps"] = 10
    def["fit"] = "fill"
    def["stream"] = "auto"
    def["sub_max_height"] = 400
    def["main_path"] = "/rtsp_tunnel"
    def["sub_path"] = "/rtsp_tunnel?inst=2"
    def["port"] = 554
    def["labels"] = "on"
    def["label_size"] = "auto"
    split("resolution fps fit stream sub_max_height labels label_size", flagged, " ")
    for (i in flagged)
        has_flag[flagged[i]] = 1
    in_layout = 0
    seen_layout = 0
    rows = 0
    cols = 0
    ntiles = 0
    ncameras = 0
}
{
    line = trim($0)
    if (line == "" || substr(line, 1, 1) == "#")
        next

    if (in_layout) {
        if (line == "end") {
            in_layout = 0
            next
        }
        if (index(line, "|") > 0)
            fail(at() "the layout block needs an end line before the camera lines")
        n = split(line, cell, /[ \t]+/)
        if (rows == 0)
            cols = n
        else if (n != cols)
            fail(at() "layout row has " n " cells but the first row has " cols)
        for (c = 1; c <= n; c++) {
            tok = cell[c]
            if (tok == ".")
                continue
            if (tok !~ /^[A-Za-z0-9_]+$/)
                fail(at() "tile names use letters, digits, and _, not " q(tok))
            if (!(tok in cells_of)) {
                cells_of[tok] = 0
                top[tok] = rows
                bottom[tok] = rows
                left[tok] = c - 1
                right[tok] = c - 1
                tiles[++ntiles] = tok
            }
            cells_of[tok]++
            if (rows > bottom[tok])
                bottom[tok] = rows
            if (c - 1 < left[tok])
                left[tok] = c - 1
            if (c - 1 > right[tok])
                right[tok] = c - 1
        }
        rows++
        next
    }

    if (line == "layout") {
        if (seen_layout)
            fail(at() "only one layout block is allowed")
        seen_layout = 1
        in_layout = 1
        next
    }

    if (index(line, "|") > 0) {
        n = split(line, field, "|")
        if (n < 4 || n > 5)
            fail(at() "camera lines look like tile|id|name|address[|options]")
        tile = trim(field[1])
        if (tile !~ /^[A-Za-z0-9_]+$/)
            fail(at() "invalid tile name " q(tile))
        if (tile in camera_line)
            fail(at() "tile " q(tile) " already has a camera on line " camera_line[tile])
        camera_line[tile] = FNR
        camera_id[tile] = trim(field[2])
        camera_name[tile] = trim(field[3])
        camera_address[tile] = trim(field[4])
        if (camera_id[tile] == "" && camera_name[tile] == "")
            fail(at() "camera needs an id or a name")
        if (camera_address[tile] !~ /^[A-Za-z0-9._-]+$/ && camera_address[tile] !~ /^\[[0-9A-Fa-f:.]+\]$/)
            fail(at() "invalid camera address " q(camera_address[tile]))
        cameras[++ncameras] = tile
        if (n == 5 && trim(field[5]) != "") {
            m = split(field[5], option, ",")
            for (k = 1; k <= m; k++) {
                kv = trim(option[k])
                eq = index(kv, "=")
                if (eq < 2)
                    fail(at() "camera options look like key=value, not " q(kv))
                key = substr(kv, 1, eq - 1)
                val = substr(kv, eq + 1)
                if (key !~ /^(stream|fit|main_path|sub_path|port)$/)
                    fail(at() "unknown camera option " q(key))
                check(key, val, at())
                camera_option[tile, key] = val
            }
        }
        next
    }

    key = line
    sub(/[ \t].*$/, "", key)
    val = line
    sub(/^[^ \t]+[ \t]*/, "", val)
    if (val == "")
        fail(at() "setting " q(key) " needs a value")
    check(key, val, at())
    file_setting[key] = val
}
END {
    if (failed)
        exit 1
    if (in_layout)
        fail(layout_name ": the layout block has no end line")
    if (rows == 0)
        fail(layout_name ": no layout block found")
    if (ncameras == 0)
        fail(layout_name ": no camera lines found")

    res = setting("resolution")
    source = (ENVIRON["KM_OPT_RESOLUTION"] != "") ? "--resolution" : "layout file"
    if (res == "auto") {
        res = ENVIRON["KM_DETECTED"]
        source = ENVIRON["KM_DETECTED_SRC"]
        if (source == "default")
            warn("could not detect the screen size; using " res " (set --resolution)")
    }
    split(res, dims, "x")
    W = dims[1] - dims[1] % 2
    H = dims[2] - dims[2] % 2
    if (W < 64 || H < 64)
        fail("invalid mosaic size " q(res))

    fps = setting("fps") + 0
    labels = setting("labels")
    label_size = setting("label_size")
    sub_max = setting("sub_max_height") + 0
    font = ENVIRON["KM_FONT"]
    if (font == "")
        fail("no text font found; install font-dejavu (Alpine) or fonts-dejavu-core (Ubuntu), or use --font")

    for (t = 1; t <= ntiles; t++) {
        tok = tiles[t]
        if (!(tok in camera_line))
            fail(layout_name ": tile " q(tok) " is in the layout but has no camera line")
        if (cells_of[tok] != (bottom[tok] - top[tok] + 1) * (right[tok] - left[tok] + 1))
            fail(layout_name ": tile " q(tok) " is not a rectangle in the layout")
    }

    # Cell edges, rounded to even pixels so every tile works with yuv420p.
    for (i = 0; i <= cols; i++)
        xs[i] = even(i * W / cols)
    for (i = 0; i <= rows; i++)
        ys[i] = even(i * H / rows)

    n = 0
    graph = ""
    stack = ""
    positions = ""
    for (k = 1; k <= ncameras; k++) {
        tok = cameras[k]
        if (!(tok in cells_of)) {
            warn(layout_name ":" camera_line[tok] ": tile " q(tok) " is not in the layout; skipping it")
            continue
        }
        x = xs[left[tok]]
        y = ys[top[tok]]
        w = xs[right[tok] + 1] - x
        h = ys[bottom[tok] + 1] - y
        if (w < 32 || h < 32)
            fail(layout_name ": tile " q(tok) " would be only " w "x" h " pixels")

        fit = camera_setting(tok, "fit")
        stream = camera_setting(tok, "stream")
        if (stream == "auto")
            stream = (h <= sub_max) ? "sub" : "main"
        path = camera_setting(tok, stream "_path")
        port = camera_setting(tok, "port")

        chain = "fps=" fps ","
        if (fit == "fill")
            chain = chain "scale=" w ":" h ":force_original_aspect_ratio=increase:force_divisible_by=2:flags=bilinear,crop=" w ":" h
        else if (fit == "fit")
            chain = chain "scale=" w ":" h ":force_original_aspect_ratio=decrease:force_divisible_by=2:flags=bilinear,pad=" w ":" h ":(ow-iw)/2:(oh-ih)/2:color=black"
        else
            chain = chain "scale=" w ":" h ":flags=bilinear"
        chain = chain ",format=yuv420p,setsar=1"
        if (labels == "on")
            chain = chain "," drawtext(label_of(tok), w, h, label_size)
        graph = graph "[" n ":v]" chain "[v" n "];"
        stack = stack "[v" n "]"
        positions = positions (n > 0 ? "|" : "") x "_" y
        if (n == 0) {
            first_x = x
            first_y = y
        }
        print "T|" n "|" tok "|" camera_id[tok] "|" camera_name[tok] "|" camera_address[tok] "|" port "|" path "|" stream "|" fit "|" x "|" y "|" w "|" h
        print "F|" n "|" chain
        print "S|" n "|" slate_graph(tok, w, h)
        n++
    }
    if (n == 0)
        fail(layout_name ": none of the cameras are in the layout")
    if (n == 1)
        graph = graph "[v0]pad=" W ":" H ":" first_x ":" first_y ":color=black,format=yuv420p[out]"
    else
        graph = graph stack "xstack=inputs=" n ":layout=" positions ":fill=black:shortest=1,format=yuv420p[out]"
    print "C|" W "|" H "|" cols "|" rows "|" n "|" fps "|" labels "|" source
    print "G|" graph
    print "M|0|" message_graph(W, H)
}' <"$LAYOUT"
    ) || exit 1

    GRAPH=''
    CANVAS=''
    while IFS= read -r _bs_line; do
        case $_bs_line in
            G\|*) GRAPH=${_bs_line#G|} ;;
            C\|*) CANVAS=$_bs_line ;;
        esac
    done <<EOF
$SPEC
EOF
    [ -n "$GRAPH" ] || die 'internal error: no filter graph was generated'
    return 0
}

# Prints the payload of the SPEC line "KIND|INDEX|payload".
spec_line() {
    _sl_prefix="$1|$2|"
    while IFS= read -r _sl_line; do
        case $_sl_line in
            "$_sl_prefix"*)
                printf '%s\n' "${_sl_line#"$_sl_prefix"}"
                return 0
                ;;
        esac
    done <<EOF
$SPEC
EOF
    return 1
}

# Sets TILE_TOK, TILE_LABEL, TX, TY, TW, and TH from the T line of tile $1.
tile_info() {
    while IFS='|' read -r _ti_kind _ti_n _ti_tok _ti_id _ti_name _ _ _ _ _ \
        _ti_x _ti_y _ti_w _ti_h; do
        [ "$_ti_kind" = T ] || continue
        [ "$_ti_n" = "$1" ] || continue
        TILE_TOK=$_ti_tok
        if [ -n "$_ti_id" ] && [ -n "$_ti_name" ]; then
            TILE_LABEL="$_ti_id - $_ti_name"
        else
            TILE_LABEL="$_ti_id$_ti_name"
        fi
        TX=$_ti_x
        TY=$_ti_y
        TW=$_ti_w
        TH=$_ti_h
        return 0
    done <<EOF
$SPEC
EOF
    die "internal error: no tile $1"
}

find_render_node() {
    for _fr_node in /dev/dri/renderD*; do
        if [ -c "$_fr_node" ] && [ -r "$_fr_node" ] && [ -w "$_fr_node" ]; then
            RENDER_NODE=$_fr_node
            return 0
        fi
    done
    return 1
}

# Succeeds when FFmpeg can open a VA-API device on RENDER_NODE.
probe_vaapi() {
    "$FFMPEG_BIN" -hide_banner -nostdin -loglevel quiet \
        -init_hw_device "vaapi=probe:$RENDER_NODE" \
        -f lavfi -i nullsrc=size=64x64:duration=0.1 -frames:v 1 -f null - \
        >/dev/null 2>&1
}

choose_decoder() {
    DECODE=software
    [ -z "$TEST_PATTERN" ] || return 0

    case $HWDEC in
        none) ;;
        vaapi)
            find_render_node ||
                die 'no usable GPU render node (/dev/dri/renderD*) for --hwdec=vaapi'
            probe_vaapi ||
                die "VA-API does not work on $RENDER_NODE; install the VA driver (Alpine: mesa-va-gallium)"
            DECODE=vaapi
            ;;
        auto)
            if find_render_node && probe_vaapi; then
                DECODE=vaapi
            fi
            ;;
    esac
    return 0
}

# Prints $1 percent-encoded for use in a URL.
urlencode() {
    KM_RAW=$1 awk 'BEGIN {
        for (i = 1; i < 256; i++)
            ord[sprintf("%c", i)] = i
        s = ENVIRON["KM_RAW"]
        n = length(s)
        out = ""
        for (i = 1; i <= n; i++) {
            c = substr(s, i, 1)
            if (c ~ /[A-Za-z0-9._~-]/)
                out = out c
            else
                out = out sprintf("%%%02X", ord[c])
        }
        printf "%s", out
    }'
}

read_creds_file() {
    _rc_cr=$(printf '\r')
    while IFS= read -r _rc_line || [ -n "$_rc_line" ]; do
        _rc_line=${_rc_line%"$_rc_cr"}
        case $_rc_line in
            CAMERA_USER=*) CRED_USER=${_rc_line#CAMERA_USER=} ;;
            CAMERA_PASSWORD=*) CRED_PASS=${_rc_line#CAMERA_PASSWORD=} ;;
        esac
    done <"$CREDS_FILE"

    case $CREDS_FILE in
        /*) _rc_path=$CREDS_FILE ;;
        *) _rc_path=./$CREDS_FILE ;;
    esac
    if [ -n "$(find "$_rc_path" -prune -perm -004 2>/dev/null)" ]; then
        warn "$CREDS_FILE is readable by everyone; run: chmod 600 $CREDS_FILE"
    fi
    return 0
}

# Sets ENC_USER and ENC_PASS; fails when no credentials are available.
load_credentials() {
    CRED_USER=''
    CRED_PASS=''

    if [ -n "${CAMERA_USER:-}" ] && [ -n "${CAMERA_PASSWORD:-}" ]; then
        CRED_USER=$CAMERA_USER
        CRED_PASS=$CAMERA_PASSWORD
    elif [ -f "$CREDS_FILE" ] && [ -r "$CREDS_FILE" ]; then
        read_creds_file
    fi

    if [ -z "$CRED_USER" ] || [ -z "$CRED_PASS" ]; then
        return 1
    fi

    ENC_USER=$(urlencode "$CRED_USER")
    ENC_PASS=$(urlencode "$CRED_PASS")
    CRED_PASS=''
    return 0
}

# Copies stdin to stdout with every URL password replaced by ****, so
# ffmpeg error messages never put the camera password in a log. Also drops
# the errors ffmpeg prints when it is stopped on purpose or ffplay goes away.
mask_credentials() {
    awk '
    /Immediate exit requested|Broken pipe|Error muxing a packet|Error writing trailer|Error closing file/ { next }
    {
        out = ""
        s = $0
        while (match(s, "://[^:/@ ]*:[^@/ ]*@")) {
            m = substr(s, RSTART, RLENGTH)
            cut = index(substr(m, 4), ":") + 3
            out = out substr(s, 1, RSTART - 1) substr(m, 1, cut) "****@"
            s = substr(s, RSTART + RLENGTH)
        }
        print out s
        fflush()
    }'
}

# Prints $1 quoted for a POSIX shell when it needs quoting.
quote() {
    case $1 in
        '') printf "''" ;;
        *[!A-Za-z0-9_./:=@%+,^-]*)
            printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
            ;;
        *) printf '%s' "$1" ;;
    esac
}

# Prints a command, starting a new line before each input and the filters.
print_command() {
    _pc_first=1
    for _pc_arg in "$@"; do
        if [ -n "$_pc_first" ]; then
            _pc_first=''
        else
            case $_pc_arg in
                -thread_queue_size | -filter_complex | -vf | -map) printf ' \\\n    ' ;;
                *) printf ' ' ;;
            esac
        fi
        quote "$_pc_arg"
    done
}

# Replaces every @STATUS@ in graph $1 with the text file path $2.
with_status_file() {
    _ws_graph=$1
    while :; do
        case $_ws_graph in
            *@STATUS@*) _ws_graph="${_ws_graph%%@STATUS@*}$2${_ws_graph#*@STATUS@}" ;;
            *) break ;;
        esac
    done
    printf '%s\n' "$_ws_graph"
}

# Writes $2 to text file $1 in one step, so drawtext never reads a half-written file.
write_text() {
    printf '%s' "$2" >"$1.tmp" && mv -f -- "$1.tmp" "$1"
}

# Sleeps $1 seconds one at a time, so a stop signal is handled within a second.
pause() {
    _pz_left=$1
    while [ "$_pz_left" -gt 0 ]; do
        sleep 1
        _pz_left=$((_pz_left - 1))
    done
}

# $1 = run-display, run-snapshot, print-display, or print-snapshot.
# $2 = output: the FIFO, the snapshot file, or - for stdout.
# $3 = tile index for a single tile, or empty for the whole mosaic.
# run-display starts ffmpeg in the background and sets FFMPEG_PID.
ffmpeg_command() {
    _fc_action=$1
    _fc_output=$2
    _fc_tile=${3:-}
    if [ "${_fc_action%%-*}" = print ]; then
        _fc_userinfo="${ENC_USER:-USER}:****"
    else
        _fc_userinfo="$ENC_USER:$ENC_PASS"
    fi

    set -- -hide_banner -nostdin -loglevel "$LOGLEVEL"
    if [ -z "$_fc_tile" ] && [ "$TIMESTAMPS" = arrival ]; then
        # Keep the arrival clock so every camera shares one timeline.
        set -- "$@" -copyts
    fi

    while IFS='|' read -r _fc_kind _fc_n _ _ _ _fc_addr _fc_port _fc_path _fc_stream _; do
        [ "$_fc_kind" = T ] || continue
        if [ -n "$_fc_tile" ] && [ "$_fc_n" != "$_fc_tile" ]; then
            continue
        fi
        set -- "$@" -thread_queue_size 512
        if [ -n "$TEST_PATTERN" ]; then
            if [ "$_fc_stream" = sub ]; then
                _fc_size=640x360
            else
                _fc_size=1920x1080
            fi
            # The realtime filter paces test frames like a live camera.
            if [ "$TIMESTAMPS" = arrival ]; then
                set -- "$@" -use_wallclock_as_timestamps 1
            fi
            set -- "$@" -f lavfi -i "testsrc2=size=$_fc_size:rate=30,realtime"
            continue
        fi

        set -- "$@" -rtsp_transport "$TRANSPORT" -allowed_media_types video \
            "$TIMEOUT_OPTION" "$((TIMEOUT * 1000000))" -fflags +nobuffer
        if [ "$TIMESTAMPS" = arrival ]; then
            set -- "$@" -use_wallclock_as_timestamps 1
        fi
        if [ "$DECODE" = vaapi ]; then
            set -- "$@" -hwaccel vaapi -hwaccel_device "$RENDER_NODE"
        fi
        set -- "$@" -i "rtsp://$_fc_userinfo@$_fc_addr:$_fc_port$_fc_path"
    done <<EOF
$SPEC
EOF

    if [ -n "$_fc_tile" ]; then
        _fc_chain=$(spec_line F "$_fc_tile") || die "internal error: no filters for tile $_fc_tile"
        set -- "$@" -vf "$_fc_chain"
    else
        set -- "$@" -filter_complex "$GRAPH" -map '[out]'
    fi
    set -- "$@" -an
    case $_fc_action in
        *-display)
            set -- "$@" -c:v rawvideo -f nut
            if [ "$_fc_output" = - ]; then
                set -- "$@" -
            else
                set -- "$@" -y "$_fc_output"
            fi
            ;;
        *-snapshot) set -- "$@" -frames:v 1 -update 1 -y "$_fc_output" ;;
    esac

    # Messages go through the credential masker on file descriptor 3.
    case $_fc_action in
        run-display)
            "$FFMPEG_BIN" "$@" 2>&3 &
            FFMPEG_PID=$!
            ;;
        run-snapshot) "$FFMPEG_BIN" "$@" 2>&3 ;;
        print-*) print_command ffmpeg "$@" ;;
    esac
}

# $1 = run or print, $2 = input: the FIFO or - for stdin, $3 = tile index or
# empty for full screen. run starts ffplay in the background and sets FFPLAY_PID.
ffplay_command() {
    _pl_action=$1
    _pl_input=$2
    _pl_tile=${3:-}
    set -- -hide_banner -loglevel "$LOGLEVEL" -fflags nobuffer -flags low_delay \
        -framedrop -autoexit -an -sn
    if [ -n "$_pl_tile" ]; then
        tile_info "$_pl_tile"
        set -- "$@" -noborder -left "$TX" -top "$TY" -x "$TW" -y "$TH" \
            -window_title "$PROGNAME tile $TILE_TOK"
    else
        set -- "$@" -fs -window_title "$PROGNAME"
    fi
    set -- "$@" -f nut "$_pl_input"

    case $_pl_action in
        run)
            "$FFPLAY_BIN" "$@" </dev/null 3>&- &
            FFPLAY_PID=$!
            ;;
        print) print_command ffplay "$@" ;;
    esac
}

# $1 = run or print, $2 = tile index. The slate sits under the live window of
# its tile and shows the status text file. run sets SLATE_PID.
slate_command() {
    _sc_action=$1
    _sc_graph=$(spec_line S "$2") || die "internal error: no slate for tile $2"
    _sc_graph=$(with_status_file "$_sc_graph" "${TMP_DIR:-$PRINT_TMP}/t$2.txt")
    tile_info "$2"
    set -- -hide_banner -loglevel error -noborder -left "$TX" -top "$TY" -x "$TW" -y "$TH" \
        -an -sn -window_title "$PROGNAME slate $TILE_TOK" -f lavfi -i "$_sc_graph"

    case $_sc_action in
        run)
            "$FFPLAY_BIN" "$@" </dev/null 3>&- &
            SLATE_PID=$!
            ;;
        print) print_command ffplay "$@" ;;
    esac
}

# $1 = run or print. The full-screen message shown while the network is down.
# run sets MESSAGE_PID.
message_command() {
    _mc_action=$1
    _mc_graph=$(spec_line M 0) || die 'internal error: no message screen'
    _mc_graph=$(with_status_file "$_mc_graph" "${TMP_DIR:-$PRINT_TMP}/message.txt")
    set -- -hide_banner -loglevel error -fs -noborder -an -sn \
        -window_title "$PROGNAME message" -f lavfi -i "$_mc_graph"

    case $_mc_action in
        run)
            "$FFPLAY_BIN" "$@" </dev/null 3>&- &
            MESSAGE_PID=$!
            ;;
        print) print_command ffplay "$@" ;;
    esac
}

print_commands() {
    IFS='|' read -r _ _pr_w _pr_h _pr_cols _pr_rows _pr_n _pr_fps _pr_labels _pr_src <<EOF
$CANVAS
EOF
    if [ -n "$TEST_PATTERN" ]; then
        _pr_decode='test pattern'
    elif [ "$DECODE" = vaapi ]; then
        _pr_decode="vaapi on $RENDER_NODE"
    else
        _pr_decode=software
    fi

    printf '# mosaic %sx%s (%s), grid %sx%s, %s cameras, %s fps, labels %s, %s mode\n' \
        "$_pr_w" "$_pr_h" "$_pr_src" "$_pr_cols" "$_pr_rows" "$_pr_n" \
        "$_pr_fps" "$_pr_labels" "$MODE"
    printf '# decoding: %s, timestamps: %s, cable check: %s\n' \
        "$_pr_decode" "$TIMESTAMPS" "${IFACE:-none}"
    while IFS='|' read -r _pr_kind _ _pr_tile _pr_id _pr_name _pr_addr _ _ \
        _pr_stream _pr_fit _pr_x _pr_y _pr_tw _pr_th; do
        [ "$_pr_kind" = T ] || continue
        printf '# %-3s %-6s %-36s %-15s %9s at %-9s %s stream, %s\n' \
            "$_pr_tile" "$_pr_id" "$_pr_name" "$_pr_addr" \
            "${_pr_tw}x$_pr_th" "$_pr_x,$_pr_y" "$_pr_stream" "$_pr_fit"
    done <<EOF
$SPEC
EOF

    if [ -n "$SNAPSHOT" ]; then
        ffmpeg_command print-snapshot "$SNAPSHOT"
        printf '\n'
        return 0
    fi

    if [ "$MODE" = single ]; then
        ffmpeg_command print-display -
        printf ' \\\n    | '
        ffplay_command print -
        printf '\n'
    else
        while IFS='|' read -r _pr_kind _pr_n _pr_tile _; do
            [ "$_pr_kind" = T ] || continue
            printf '\n# tile %s\n' "$_pr_tile"
            ffmpeg_command print-display - "$_pr_n"
            printf ' \\\n    | '
            ffplay_command print - "$_pr_n"
            printf '\n'
        done <<EOF
$SPEC
EOF
        tile_info 0
        printf '\n# shown under a tile while its camera is down (tile %s)\n' "$TILE_TOK"
        slate_command print 0
        printf '\n'
    fi

    if [ -n "$IFACE" ]; then
        printf '\n# shown while the network cable is unplugged\n'
        message_command print
        printf '\n'
    fi
}

# Sends TERM to child $1, waits up to $2 seconds (default STOP_TIMEOUT), then
# KILLs it if still running.
stop_process() {
    _sp_pid=$1
    _sp_limit=${2:-$STOP_TIMEOUT}
    [ -n "$_sp_pid" ] || return 0

    if kill -0 "$_sp_pid" 2>/dev/null; then
        kill -s TERM "$_sp_pid" 2>/dev/null || true
        _sp_waited=0
        while kill -0 "$_sp_pid" 2>/dev/null; do
            if [ "$_sp_waited" -ge "$_sp_limit" ]; then
                kill -s KILL "$_sp_pid" 2>/dev/null || true
                break
            fi
            sleep 1
            _sp_waited=$((_sp_waited + 1))
        done
    fi

    wait "$_sp_pid" 2>/dev/null || true
    return 0
}

# Stops the ffmpeg and ffplay pair of this process.
stop_children() {
    for _st_pid in $FFMPEG_PID $FFPLAY_PID; do
        kill -s TERM "$_st_pid" 2>/dev/null || true
    done
    stop_process "$FFMPEG_PID"
    stop_process "$FFPLAY_PID"
    FFMPEG_PID=''
    FFPLAY_PID=''
}

stop_message() {
    stop_process "$MESSAGE_PID"
    MESSAGE_PID=''
}

# Starts the credential masker reading ERR_FIFO and opens the FIFO for
# writing on file descriptor 3, which every ffmpeg uses as its stderr.
open_log_masker() {
    mask_credentials <"$ERR_FIFO" >&2 &
    MASK_PID=$!
    exec 3>"$ERR_FIFO"
    LOG_OPEN=1
}

# Closes descriptor 3 and lets the masker print what is left.
close_log_masker() {
    [ -n "$LOG_OPEN" ] || return 0
    exec 3>&-
    LOG_OPEN=''
    _cl_waited=0
    while kill -0 "$MASK_PID" 2>/dev/null && [ "$_cl_waited" -lt 20 ]; do
        sleep 0.1 2>/dev/null || sleep 1
        _cl_waited=$((_cl_waited + 1))
    done
    stop_process "$MASK_PID"
    MASK_PID=''
}

cleanup() {
    stop_tiles
    stop_message
    stop_children
    close_log_masker
    if [ -n "$TMP_DIR" ]; then
        rm -rf -- "$TMP_DIR"
        TMP_DIR=''
    fi
}

on_signal() {
    trap - HUP INT TERM
    info 'stopping the mosaic'
    cleanup
    exit "$1"
}

check_display() {
    if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}${SDL_VIDEODRIVER:-}" ]; then
        die 'no display found; run this inside an X or Wayland session'
    fi
}

# Installs the traps, creates the temporary directory, and starts the masker.
setup_tmp() {
    trap cleanup EXIT
    trap 'on_signal 129' HUP
    trap 'on_signal 130' INT
    trap 'on_signal 143' TERM

    TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/kiosk-mosaic.XXXXXX") ||
        die 'cannot create a temporary directory'
    # The path is spliced into filter graphs, where these characters are special.
    case $TMP_DIR in
        *[\'\\\[\],\;:]*)
            die "temporary directory '$TMP_DIR' has characters FFmpeg cannot take; set TMPDIR=/tmp"
            ;;
    esac
    FIFO=$TMP_DIR/mosaic.nut
    ERR_FIFO=$TMP_DIR/ffmpeg.err
    mkfifo -m 600 -- "$FIFO" "$ERR_FIFO" || die "cannot create FIFOs in $TMP_DIR"
    open_log_masker
}

# Succeeds when the network cable is plugged in.
link_up() {
    _lu_state=''
    read -r _lu_state 2>/dev/null <"$SYS_NET/$IFACE/carrier" || return 1
    [ "$_lu_state" = 1 ]
}

# Succeeds when the port has an address, which gives it a route.
has_route() {
    [ -r "$PROC_ROUTE" ] || return 1
    while read -r _hr_name _; do
        [ "$_hr_name" != "$IFACE" ] || return 0
    done <"$PROC_ROUTE"
    return 1
}

network_ready() {
    [ -z "$IFACE" ] || { link_up && has_route; }
}

# Returns once the network is usable, showing the message screen meanwhile.
wait_for_network() {
    [ -n "$IFACE" ] || return 0
    _wn_shown=''
    while :; do
        if link_up; then
            if has_route; then
                if [ -n "$MESSAGE_PID" ]; then
                    stop_message
                    info "network is up on $IFACE"
                fi
                return 0
            fi
            _wn_text='Network cable connected|Waiting for a network address'
        else
            _wn_text='Connect the ethernet cable|to view the cameras'
        fi

        if [ "$_wn_text" != "$_wn_shown" ]; then
            write_text "$TMP_DIR/message.txt" "${_wn_text%%|*}"
            write_text "$TMP_DIR/message.txt2" "${_wn_text#*|}"
            if [ -z "$MESSAGE_PID" ]; then
                message_command run
            fi
            if [ -z "$_wn_shown" ]; then
                warn "waiting for the network on $IFACE"
            fi
            _wn_shown=$_wn_text
        fi
        sleep 1
    done
}

# Runs ffplay and ffmpeg once, connected by the FIFO, until either stops.
run_pipeline() {
    ffplay_command run "$FIFO"
    ffmpeg_command run-display "$FIFO"

    while kill -0 "$FFPLAY_PID" 2>/dev/null && kill -0 "$FFMPEG_PID" 2>/dev/null; do
        sleep 1
    done

    _rp_status=0
    if kill -0 "$FFMPEG_PID" 2>/dev/null; then
        info 'ffplay stopped; stopping ffmpeg'
    else
        wait "$FFMPEG_PID" || _rp_status=$?
        FFMPEG_PID=''
        info "ffmpeg stopped with status $_rp_status"
    fi
    stop_children
    return "$_rp_status"
}

run_single() {
    find_ffplay
    check_display
    setup_tmp
    if [ "$RESTART_DELAY" -eq 1 ]; then
        _rs_unit=second
    else
        _rs_unit=seconds
    fi

    _rs_waiting=''
    while :; do
        wait_for_network
        _rs_status=0
        if [ -n "$TEST_PATTERN" ] || load_credentials; then
            _rs_waiting=''
            run_pipeline || _rs_status=$?
        else
            [ -n "$RESTART" ] ||
                die "no camera credentials; set CAMERA_USER and CAMERA_PASSWORD or create $CREDS_FILE"
            if [ -z "$_rs_waiting" ]; then
                warn "no camera credentials in $CREDS_FILE yet; waiting for them"
                _rs_waiting=1
            fi
            _rs_status=1
        fi

        [ -n "$RESTART" ] || return "$_rs_status"
        if [ -z "$_rs_waiting" ]; then
            info "restarting in $RESTART_DELAY $_rs_unit"
        fi
        pause "$RESTART_DELAY"
    done
}

tile_shutdown() {
    trap - EXIT TERM HUP
    stop_children
    stop_process "$SLATE_PID"
    exit 143
}

# Keeps one tile alive: a slate underneath, and a live ffmpeg/ffplay pair on
# top that is restarted whenever it stops. Runs as a background process.
tile_supervisor() {
    _ts_n=$1
    trap tile_shutdown EXIT TERM HUP
    tile_info "$_ts_n"
    _ts_status=$TMP_DIR/t$_ts_n.txt
    FIFO=$TMP_DIR/t$_ts_n.nut
    if [ ! -p "$FIFO" ]; then
        mkfifo -m 600 -- "$FIFO" || die "cannot create $FIFO"
    fi

    write_text "$_ts_status" 'Connecting to camera'
    slate_command run "$_ts_n"
    # Let the slate map first so the live window lands on top of it. New X
    # windows go on top, and nothing here ever restacks them.
    pause 2

    _ts_down=''
    while :; do
        if ! kill -0 "$SLATE_PID" 2>/dev/null; then
            wait "$SLATE_PID" 2>/dev/null || true
            warn "tile $TILE_TOK: its background screen stopped; starting it again"
            slate_command run "$_ts_n"
            pause 1
        fi

        if [ -z "$TEST_PATTERN" ] && ! load_credentials; then
            if [ -z "$_ts_down" ]; then
                warn "tile $TILE_TOK: no camera credentials in $CREDS_FILE; waiting for them"
                write_text "$_ts_status" 'No camera credentials'
                _ts_down=1
            fi
            pause "$RESTART_DELAY"
            continue
        fi

        _ts_started=$(date +%s)
        _ts_live=''
        ffplay_command run "$FIFO" "$_ts_n"
        ffmpeg_command run-display "$FIFO" "$_ts_n"
        while kill -0 "$FFPLAY_PID" 2>/dev/null && kill -0 "$FFMPEG_PID" 2>/dev/null; do
            sleep 1
            if [ -z "$_ts_live" ] && [ $(($(date +%s) - _ts_started)) -ge "$LIVE_AFTER" ]; then
                _ts_live=1
                if [ -n "$_ts_down" ]; then
                    info "tile $TILE_TOK ($TILE_LABEL): camera is back"
                    _ts_down=''
                fi
            fi
        done
        stop_children

        if [ -n "$_ts_live" ]; then
            info "tile $TILE_TOK ($TILE_LABEL): camera stopped; retrying every $RESTART_DELAY seconds"
            write_text "$_ts_status" "No signal since $(date +%H:%M)"
            _ts_down=1
        elif [ -z "$_ts_down" ]; then
            warn "tile $TILE_TOK ($TILE_LABEL): no signal; retrying every $RESTART_DELAY seconds"
            write_text "$_ts_status" "No signal since $(date +%H:%M)"
            _ts_down=1
        fi
        pause "$RESTART_DELAY"
    done
}

start_tiles() {
    SUP_PIDS=''
    _sa_count=0
    while IFS='|' read -r _sa_kind _sa_n _; do
        [ "$_sa_kind" = T ] || continue
        tile_supervisor "$_sa_n" </dev/null &
        SUP_PIDS="$SUP_PIDS $_sa_n=$!"
        _sa_count=$((_sa_count + 1))
    done <<EOF
$SPEC
EOF
    info "started $_sa_count camera tiles"
}

# Restarts any tile supervisor that has stopped.
check_tiles() {
    _ck_new=''
    for _ck_entry in $SUP_PIDS; do
        _ck_n=${_ck_entry%%=*}
        _ck_pid=${_ck_entry#*=}
        if ! kill -0 "$_ck_pid" 2>/dev/null; then
            wait "$_ck_pid" 2>/dev/null || true
            warn "tile $_ck_n stopped unexpectedly; starting it again"
            tile_supervisor "$_ck_n" </dev/null &
            _ck_pid=$!
        fi
        _ck_new="$_ck_new $_ck_n=$_ck_pid"
    done
    SUP_PIDS=$_ck_new
}

stop_tiles() {
    [ -n "$SUP_PIDS" ] || return 0
    for _sx_entry in $SUP_PIDS; do
        kill -s TERM "${_sx_entry#*=}" 2>/dev/null || true
    done
    # Each supervisor stops its own children first, so give it longer.
    for _sx_entry in $SUP_PIDS; do
        stop_process "${_sx_entry#*=}" 10
    done
    SUP_PIDS=''
}

run_tiles() {
    find_ffplay
    check_display
    setup_tmp

    while :; do
        wait_for_network
        start_tiles
        while network_ready; do
            pause 2
            check_tiles
        done
        warn "network on $IFACE is down; stopping the cameras"
        stop_tiles
    done
}

run_snapshot() {
    if [ -z "$TEST_PATTERN" ] && ! load_credentials; then
        die "no camera credentials; set CAMERA_USER and CAMERA_PASSWORD or create $CREDS_FILE"
    fi
    setup_tmp
    _rn_status=0
    ffmpeg_command run-snapshot "$SNAPSHOT" || _rn_status=$?
    close_log_masker
    [ "$_rn_status" -eq 0 ] || die "ffmpeg could not write $SNAPSHOT"
    info "wrote $SNAPSHOT"
}

main() {
    parse_args "$@"
    if [ ! -f "$LAYOUT" ] || [ ! -r "$LAYOUT" ]; then
        die "cannot read layout file '$LAYOUT'"
    fi

    find_ffmpeg
    case $OPT_RESOLUTION in
        '' | auto) detect_screen ;;
    esac
    find_font
    [ -n "$SNAPSHOT" ] || find_interface
    build_spec
    choose_decoder

    if [ -n "$PRINT" ]; then
        # The password is masked, so missing credentials only hide the user.
        load_credentials || true
        print_commands
        exit 0
    fi

    if [ -n "$SNAPSHOT" ]; then
        run_snapshot
        exit 0
    fi

    if [ "$MODE" = single ]; then
        run_single
    else
        run_tiles
    fi
}

main "$@"
