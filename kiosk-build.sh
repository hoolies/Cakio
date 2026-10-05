#!/usr/bin/env sh
# kiosk-build.sh - build the camera kiosk installer stick, and write or test it.
#
# Downloads and verifies the official Alpine ISO, then boots it in a QEMU
# virtual machine that assembles the stick image (see builder/build-in-vm.sh).
# Nothing is installed on this machine beyond qemu and the usual tools.
#
# Needs: qemu-system-x86_64 with OVMF, curl, sha256sum, tar, truncate,
# openssl. gpg is used to check the ISO signature when available.

set -eu

unalias -a 2>/dev/null || true
unset -f awk basename blockdev cat cp curl dd findmnt gpg mkdir mktemp mount openssl \
    qemu-system-x86_64 rm sha256sum sort stty tail tar truncate udisksctl umount 2>/dev/null || true

export LC_ALL=C

PROGNAME=$(basename -- "$0")
readonly PROGNAME
KIOSK_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
readonly KIOSK_DIR
readonly DEFAULT_BRANCH=v3.24
readonly DEFAULT_MIRROR=https://dl-cdn.alpinelinux.org/alpine
readonly DEFAULT_TIMEZONE=America/Toronto
readonly DEFAULT_SIZE_GB=2
readonly DEFAULT_MEMORY_MB=2048
readonly DEFAULT_TEST_DISK_GB=16
readonly ALPINE_KEY_URL=https://alpinelinux.org/keys/ncopa.asc
readonly BUILD_TIMEOUT=5400
readonly OVMF_CANDIDATES='/usr/share/ovmf/OVMF.fd
/usr/share/qemu/OVMF.fd
/usr/share/OVMF/OVMF.fd
/usr/share/edk2/ovmf/OVMF.fd
/usr/share/edk2-ovmf/x64/OVMF.fd'

COMMAND=''
OUTPUT=''
DISK=''
STICK_USER=''
STICK_PASS=''
STICK_LAYOUT=''
BRANCH=$DEFAULT_BRANCH
MIRROR=$DEFAULT_MIRROR
CACHE_DIR=${XDG_CACHE_HOME:-$HOME/.cache}/cakio
CA_DIR=${CAKIO_CA_DIR:-$PWD/ca}
TIMEZONE=$DEFAULT_TIMEZONE
SIZE_GB=$DEFAULT_SIZE_GB
MEMORY_MB=$DEFAULT_MEMORY_MB
KEEP_INPUTS=''
ISO_UPDATE=ask
STICK_IMAGE=''
TEST_DISK=''
SSH_PORT=2222
HEADLESS=''

OVMF=''
ISO_FILE=''
INPUTS=''
TMP_FILES=''
QEMU_PID=''

usage() {
    printf '%s\n' "Usage: $PROGNAME [OPTION]... COMMAND [ARG]
Build the camera kiosk installer stick, write it to a USB device, or test it.

Commands:
  image               build the stick image (default)
  write [DEVICE]      write the image to a USB stick; without DEVICE it finds
                        the stick (plug it in when asked) and shows what is on
                        it before erasing anything
  boot                boot the image in a virtual machine to try the installer
                        and the installed kiosk

Mandatory arguments to long options are mandatory for short options too.
  -o, --output=FILE     stick image file (default cakio-RELEASE.img)
      --branch=NAME     Alpine branch (default $DEFAULT_BRANCH)
      --mirror=URL      Alpine mirror (default $DEFAULT_MIRROR)
      --cache=DIR       where downloads are kept (default ~/.cache/cakio)
      --update          download a newer Alpine release without asking
      --no-update       keep the cached Alpine release without asking
  -c, --ca-dir=DIR      kiosk CA directory from kiosk-admin init-ca
                          (default ./ca, or \$CAKIO_CA_DIR)
      --timezone=ZONE   kiosk time zone (default $DEFAULT_TIMEZONE)
      --size=GB         image size in gigabytes (default $DEFAULT_SIZE_GB)
      --memory=MB       memory for the build VM (default $DEFAULT_MEMORY_MB)
      --keep-inputs     keep the temporary build inputs for inspection
      --image=FILE      for boot: the stick image (default: the newest cakio-*.img)
      --disk=FILE       for boot: the virtual internal disk
                          (default cakio-test-disk.img, created if missing)
      --disk-only       for boot: start from the internal disk, without the stick
      --ssh-port=N      for boot: local port forwarded to the kiosk's SSH
                          (default 2222)
      --headless        for boot: no window; serial console on this terminal
  -h, --help            display this help and exit

Typical use:
  kiosk-admin.sh init-ca          once, creates ./ca
  $PROGNAME                 builds cakio-RELEASE.img (takes a few minutes)
  $PROGNAME write           writes it to a USB stick
  $PROGNAME boot            tries it in a virtual machine"
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

cleanup() {
    if [ -n "$QEMU_PID" ]; then
        kill "$QEMU_PID" 2>/dev/null || true
    fi
    if [ -n "$INPUTS" ] && [ -z "$KEEP_INPUTS" ]; then
        rm -rf -- "$INPUTS"
    fi
    for _cu_file in $TMP_FILES; do
        rm -f -- "$_cu_file"
    done
}

in_range() {
    case $1 in
        '' | *[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

set_option() {
    case $1 in
        output) OUTPUT=$2 ;;
        branch)
            case $2 in
                v[0-9]*.[0-9]* | edge) BRANCH=$2 ;;
                *) die "invalid branch '$2'; use something like v3.24" ;;
            esac
            ;;
        mirror) MIRROR=${2%/} ;;
        cache) CACHE_DIR=$2 ;;
        ca-dir) CA_DIR=$2 ;;
        timezone) TIMEZONE=$2 ;;
        size)
            in_range "$2" 1 64 || die "invalid size '$2'; use 1 to 64 gigabytes"
            SIZE_GB=$2
            ;;
        memory)
            in_range "$2" 1024 65536 || die "invalid memory '$2'; use 1024 to 65536 MB"
            MEMORY_MB=$2
            ;;
        image) STICK_IMAGE=$2 ;;
        disk) TEST_DISK=$2 ;;
        ssh-port)
            in_range "$2" 1024 65535 || die "invalid port '$2'"
            SSH_PORT=$2
            ;;
    esac
}

parse_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            -h | --help)
                usage
                exit 0
                ;;
            --keep-inputs) KEEP_INPUTS=1 ;;
            --update) ISO_UPDATE=yes ;;
            --no-update) ISO_UPDATE=no ;;
            --disk-only) STICK_IMAGE=none ;;
            --headless) HEADLESS=1 ;;
            --output=* | --branch=* | --mirror=* | --cache=* | --ca-dir=* | \
                --timezone=* | --size=* | --memory=* | --image=* | --disk=* | \
                --ssh-port=*)
                _pa_name=${1%%=*}
                set_option "${_pa_name#--}" "${1#*=}"
                ;;
            --output | --branch | --mirror | --cache | --ca-dir | --timezone | \
                --size | --memory | --image | --disk | --ssh-port)
                [ $# -ge 2 ] || usage_error "option '$1' requires an argument"
                set_option "${1#--}" "$2"
                shift
                ;;
            -o | -c)
                [ $# -ge 2 ] || usage_error "option requires an argument -- '${1#-}'"
                if [ "$1" = -o ]; then OUTPUT=$2; else CA_DIR=$2; fi
                shift
                ;;
            -o?*) OUTPUT=${1#-o} ;;
            -c?*) CA_DIR=${1#-c} ;;
            --)
                shift
                break
                ;;
            --*) usage_error "unrecognized option '$1'" ;;
            -?*)
                _pa_char=${1#-}
                usage_error "invalid option -- '${_pa_char%"${_pa_char#?}"}'"
                ;;
            *) break ;;
        esac
        shift
    done

    COMMAND=${1:-image}
    [ $# -eq 0 ] || shift
    case $COMMAND in
        image | boot) [ $# -eq 0 ] || usage_error "extra operand '$1'" ;;
        write)
            [ $# -le 1 ] || usage_error "extra operand '$2'"
            WRITE_DEVICE=${1:-}
            ;;
        *) usage_error "unknown command '$COMMAND'" ;;
    esac
}

need_tool() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is needed; install it ($2)"
}

find_ovmf() {
    while IFS= read -r _fo_path; do
        if [ -f "$_fo_path" ]; then
            OVMF=$_fo_path
            return 0
        fi
    done <<EOF
$OVMF_CANDIDATES
EOF
    die 'OVMF firmware not found; install it (sudo apt install ovmf)'
}

check_tools() {
    need_tool qemu-system-x86_64 'sudo apt install qemu-system-x86'
    need_tool curl 'sudo apt install curl'
    need_tool sha256sum coreutils
    need_tool truncate coreutils
    need_tool tar tar
    need_tool openssl openssl
    find_ovmf
}

check_ca() {
    [ -f "$CA_DIR/user_ca.pub" ] ||
        die "no kiosk CA in $CA_DIR; run kiosk-admin.sh init-ca first (or pass --ca-dir)"
    if [ ! -f "$CA_DIR/cakio-build.rsa" ]; then
        info "creating the package signing key in $CA_DIR"
        (
            umask 077
            openssl genrsa -out "$CA_DIR/cakio-build.rsa" 2048 2>/dev/null
        ) || die 'cannot create the signing key'
        openssl rsa -in "$CA_DIR/cakio-build.rsa" -pubout -out "$CA_DIR/cakio-build.rsa.pub" 2>/dev/null ||
            die 'cannot derive the signing public key'
    fi
    [ -f "$CA_DIR/cakio-build.rsa.pub" ] || die "$CA_DIR/cakio-build.rsa.pub is missing"
}

# Downloads $1 to $2 unless $2 exists; fails on any HTTP error.
fetch() {
    [ ! -s "$2" ] || return 0
    info "downloading ${1##*/}"
    curl -fsSL --retry 3 -o "$2.part" "$1" || die "download failed: $1"
    mv -f -- "$2.part" "$2"
}

# Downloads $1 to $2, replacing $2; returns 1 quietly when offline.
refetch() {
    curl -fsSL --retry 1 --max-time 60 -o "$2.part" "$1" 2>/dev/null || {
        rm -f -- "$2.part"
        return 1
    }
    mv -f -- "$2.part" "$2"
}

# The version number inside an ISO name such as alpine-standard-3.24.2-x86_64.iso.
iso_version() {
    _iv=${1#alpine-standard-}
    printf '%s\n' "${_iv%-x86_64.iso}"
}

# Prints "name sha256" of the newest standard ISO listed in $1.
latest_iso_in() {
    awk '
        $1 == "flavor:" { flavor = $2 }
        $1 == "iso:" && flavor == "alpine-standard" { iso = $2 }
        $1 == "sha256:" && flavor == "alpine-standard" { sum = $2 }
        END { if (iso != "" && sum != "") print iso, sum }' "$1"
}

# Downloads ISO $1 with published checksum $2, verifies it, and records it as
# the ISO to use for this branch.
download_iso() {
    ISO_FILE=$CACHE_DIR/$1
    if [ -s "$ISO_FILE" ] && [ "$(sha256sum "$ISO_FILE" | cut -d' ' -f1)" = "$2" ]; then
        info "$1 is already in the cache"
    else
        info "downloading Alpine $(iso_version "$1") (about 370 MB, kept in $CACHE_DIR)"
        rm -f -- "$ISO_FILE" "$ISO_FILE.asc"
        fetch "$MIRROR/$BRANCH/releases/x86_64/$1" "$ISO_FILE"
        [ "$(sha256sum "$ISO_FILE" | cut -d' ' -f1)" = "$2" ] ||
            die "$1 does not match the published SHA-256; download corrupted or tampered"
        info 'SHA-256 verified'
    fi
    verify_iso_signature
    printf '%s %s\n' "$1" "$2" >"$CACHE_DIR/current-$BRANCH"
}

# Sets ISO_FILE to a verified Alpine standard ISO for BRANCH.
#
# The first build downloads the newest release. Later builds reuse that
# download and only check whether Alpine has published a newer one; if so,
# you are asked (or --update / --no-update decides).
get_iso() {
    mkdir -p -- "$CACHE_DIR"
    _gi_pointer=$CACHE_DIR/current-$BRANCH
    _gi_have=''
    _gi_have_sum=''
    if [ -f "$_gi_pointer" ]; then
        read -r _gi_have _gi_have_sum <"$_gi_pointer" || true
        [ -s "$CACHE_DIR/$_gi_have" ] || _gi_have=''
    fi

    _gi_yaml=$CACHE_DIR/latest-releases-$BRANCH.yaml
    _gi_latest=''
    _gi_latest_sum=''
    if refetch "$MIRROR/$BRANCH/releases/x86_64/latest-releases.yaml" "$_gi_yaml"; then
        _gi_info=$(latest_iso_in "$_gi_yaml")
        _gi_latest=${_gi_info% *}
        _gi_latest_sum=${_gi_info#* }
    elif [ -z "$_gi_have" ]; then
        die "cannot reach $MIRROR and no Alpine ISO is cached yet; connect to the internet for the first build"
    else
        warn "cannot reach $MIRROR; using the cached $_gi_have without checking for a newer release"
    fi

    if [ -z "$_gi_have" ]; then
        [ -n "$_gi_latest" ] || die "no alpine-standard release listed for $BRANCH"
        download_iso "$_gi_latest" "$_gi_latest_sum"
        return 0
    fi

    if [ -n "$_gi_latest" ] && [ "$_gi_latest" != "$_gi_have" ]; then
        if want_newer_iso "$(iso_version "$_gi_have")" "$(iso_version "$_gi_latest")"; then
            download_iso "$_gi_latest" "$_gi_latest_sum"
            return 0
        fi
        info "keeping Alpine $(iso_version "$_gi_have")"
    fi

    ISO_FILE=$CACHE_DIR/$_gi_have
    [ "$(sha256sum "$ISO_FILE" | cut -d' ' -f1)" = "$_gi_have_sum" ] ||
        die "the cached $_gi_have is damaged; delete $_gi_pointer and build again to download it afresh"
    verify_iso_signature
    info "using Alpine $(iso_version "$_gi_have") from the cache"
}

# Decides whether to download version $2 when version $1 is cached.
want_newer_iso() {
    case $ISO_UPDATE in
        yes)
            info "Alpine $2 is available (you have $1); downloading it as requested"
            return 0
            ;;
        no)
            info "Alpine $2 is available (you have $1); keeping yours as requested"
            return 1
            ;;
    esac
    if [ ! -t 0 ]; then
        info "Alpine $2 is available (you have $1); keeping yours (no terminal to ask; use --update to take it)"
        return 1
    fi
    printf '%s: Alpine %s is available; you have %s. Download the newer one (about 370 MB)? [y/N] ' \
        "$PROGNAME" "$2" "$1" >&2
    read -r _wn_answer || _wn_answer=''
    case $_wn_answer in
        [Yy] | [Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}

# Checks ISO_FILE against Alpine's release signature when gpg is available.
# The signature and key are kept next to the ISO, so this also works offline.
verify_iso_signature() {
    if ! command -v gpg >/dev/null 2>&1; then
        warn 'gpg is not installed; the ISO signature was not checked (SHA-256 was)'
        return 0
    fi
    _vs_sig=$ISO_FILE.asc
    _vs_key=$CACHE_DIR/alpine-release-key.asc
    if [ ! -s "$_vs_sig" ] || [ ! -s "$_vs_key" ]; then
        fetch "$MIRROR/$BRANCH/releases/x86_64/${ISO_FILE##*/}.asc" "$_vs_sig"
        fetch "$ALPINE_KEY_URL" "$_vs_key"
    fi
    _vs_ring=$(mktemp "${TMPDIR:-/tmp}/cakio-ring.XXXXXX")
    TMP_FILES="$TMP_FILES $_vs_ring $_vs_ring~"
    gpg --quiet --batch --no-default-keyring --keyring "$_vs_ring" \
        --import "$_vs_key" 2>/dev/null ||
        die 'cannot import the Alpine release key'
    gpg --quiet --batch --no-default-keyring --keyring "$_vs_ring" \
        --trust-model always --verify "$_vs_sig" "$ISO_FILE" 2>/dev/null ||
        die 'the ISO signature does not verify against the Alpine release key'
    info 'release signature verified'
}

release_name() {
    date +%Y%m%d-%H%M
}

# Prepares the read-only inputs disk for the build VM.
prepare_inputs() {
    INPUTS=$(mktemp -d "${TMPDIR:-/tmp}/cakio-inputs.XXXXXX") || die 'cannot create a temporary directory'
    mkdir -p "$INPUTS/builder" "$INPUTS/image" "$INPUTS/layouts" "$INPUTS/keys" "$INPUTS/ca"
    cp -R "$KIOSK_DIR/image/kiosk" "$KIOSK_DIR/image/installer" "$INPUTS/image/"
    cp "$KIOSK_DIR/builder/build-in-vm.sh" "$INPUTS/builder/"
    cp "$KIOSK_DIR/kiosk-mosaic.sh" "$INPUTS/kiosk-mosaic"
    cp "$KIOSK_DIR"/layouts/*.conf "$INPUTS/layouts/" 2>/dev/null || warn 'no layouts in layouts/'
    cp "$CA_DIR/cakio-build.rsa" "$CA_DIR/cakio-build.rsa.pub" "$INPUTS/keys/"
    cp "$CA_DIR/user_ca.pub" "$INPUTS/ca/"
    : >"$INPUTS/cakio-inputs"
    cat >"$INPUTS/build.conf" <<EOF
RELEASE=$RELEASE
TIMEZONE=$TIMEZONE
MIRROR=$MIRROR
BRANCH=$BRANCH
EOF

    # The configuration the live ISO loads: run the builder at boot.
    _pi_ovl=$(mktemp -d "${TMPDIR:-/tmp}/cakio-ovl.XXXXXX")
    mkdir -p "$_pi_ovl/etc/local.d" "$_pi_ovl/etc/runlevels/default" "$_pi_ovl/etc/apk"
    cat >"$_pi_ovl/etc/local.d/cakio-build.start" <<'EOF'
#!/bin/sh
# Started by the local service in the build VM.
mkdir -p /mnt/in
mount -t vfat -o ro /dev/vda1 /mnt/in || { echo 'BUILD FAILED: no inputs disk' >/dev/ttyS0; poweroff -f; }
exec sh /mnt/in/builder/build-in-vm.sh
EOF
    chmod 755 "$_pi_ovl/etc/local.d/cakio-build.start"
    ln -s /etc/init.d/local "$_pi_ovl/etc/runlevels/default/local"
    printf 'alpine-base\n' >"$_pi_ovl/etc/apk/world"
    : >"$_pi_ovl/etc/.default_boot_services"
    tar -C "$_pi_ovl" --owner=0 --group=0 --numeric-owner -czf "$INPUTS/localhost.apkovl.tar.gz" etc ||
        die 'cannot create the build VM configuration'
    rm -rf -- "$_pi_ovl"
}

run_build_vm() {
    _rb_log=$OUTPUT.build.log
    touch -- "$_rb_log" 2>/dev/null || die "cannot write to ${OUTPUT%/*}; choose another --output"
    : >"$_rb_log"
    info "building $OUTPUT in a virtual machine (log: $_rb_log)"
    # Start from an empty file: leftovers from an earlier build would boot.
    rm -f -- "$OUTPUT"
    truncate -s "${SIZE_GB}G" "$OUTPUT" || die "cannot create $OUTPUT"

    qemu-system-x86_64 -name cakio-build -machine q35 -accel kvm -accel tcg -cpu max \
        -smp 2 -m "$MEMORY_MB" -bios "$OVMF" -display none -monitor none \
        -serial "file:$_rb_log" -cdrom "$ISO_FILE" -boot d \
        -drive "file=fat:ro:$INPUTS,format=raw,if=virtio,read-only=on" \
        -drive "file=$OUTPUT,format=raw,if=virtio" \
        -nic user,model=virtio-net-pci &
    QEMU_PID=$!
    tail -n +1 -f --pid="$QEMU_PID" "$_rb_log" 2>/dev/null &
    _rb_tail=$!

    _rb_waited=0
    while kill -0 "$QEMU_PID" 2>/dev/null; do
        if [ "$_rb_waited" -ge "$BUILD_TIMEOUT" ]; then
            kill "$QEMU_PID" 2>/dev/null || true
            die 'the build VM did not finish in time'
        fi
        sleep 2
        _rb_waited=$((_rb_waited + 2))
    done
    wait "$QEMU_PID" || true
    QEMU_PID=''
    kill "$_rb_tail" 2>/dev/null || true

    grep -q '^BUILD OK' "$_rb_log" || die "the build failed; see $_rb_log"
}

cmd_image() {
    check_tools
    check_ca
    RELEASE=$(release_name)
    [ -n "$OUTPUT" ] || OUTPUT=$PWD/cakio-$RELEASE.img
    case $OUTPUT in
        /*) ;;
        *) OUTPUT=$PWD/$OUTPUT ;;
    esac
    get_iso
    prepare_inputs
    run_build_vm
    printf '\n%s: stick image ready: %s (release %s)\n' "$PROGNAME" "$OUTPUT" "$RELEASE"
    printf 'Next: %s write   (plug in a USB stick)   or   %s boot\n' "$PROGNAME" "$PROGNAME"
}

newest_image() {
    for _ni_file in "$PWD"/cakio-*.img; do
        [ -f "$_ni_file" ] || continue
        printf '%s\n' "$_ni_file"
    done | sort | tail -n 1
}

# Prints the names (sda, sdb, ...) of disks that are USB devices or removable.
# Internal NVMe and SATA disks are neither, so they are never listed.
usb_disks() {
    for _ud_dir in /sys/block/*; do
        _ud_name=${_ud_dir##*/}
        case $_ud_name in
            loop* | ram* | sr* | zram* | dm-* | md* | nbd*) continue ;;
        esac
        _ud_size=$(cat "$_ud_dir/size" 2>/dev/null || printf 0)
        [ "$_ud_size" -gt 0 ] || continue
        case $(readlink -f "$_ud_dir") in
            *usb*) ;;
            *) [ "$(cat "$_ud_dir/removable" 2>/dev/null)" = 1 ] || continue ;;
        esac
        printf '%s\n' "$_ud_name"
    done
}

# Prints "14.6 GB SanDisk Ultra" for disk $1.
disk_summary() {
    _ds_gb=$(awk -v s="$(cat "/sys/block/$1/size" 2>/dev/null || printf 0)" 'BEGIN { printf "%.1f", s * 512 / 1000000000 }')
    _ds_vendor=$(tr -d '\n' <"/sys/block/$1/device/vendor" 2>/dev/null | sed 's/[[:space:]]*$//')
    _ds_model=$(tr -d '\n' <"/sys/block/$1/device/model" 2>/dev/null | sed 's/[[:space:]]*$//')
    printf '%s GB %s %s\n' "$_ds_gb" "${_ds_vendor:-}" "${_ds_model:-unknown model}" | sed 's/  */ /g'
}

# Prints one line per filesystem found on disk $1, or nothing if it is blank.
disk_contents() {
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -n -P -o NAME,FSTYPE,LABEL,SIZE,MOUNTPOINTS "/dev/$1" 2>/dev/null |
            sed 's/NAME="\([^"]*\)" FSTYPE="\([^"]*\)" LABEL="\([^"]*\)" SIZE="\([^"]*\)" MOUNTPOINTS="\([^"]*\)"/\1|\2|\3|\4|\5/' |
            awk -F'|' '$2 != "" || $5 != "" {
                line = "  " $1 ": " $4 " " ($2 != "" ? $2 : "unknown filesystem")
                if ($3 != "") line = line ", label \"" $3 "\""
                if ($3 == "CAKIOUSB") line = line " (an earlier Cakio stick)"
                if ($5 != "") line = line ", open at " $5
                print line
            }'
    else
        for _dc_part in /sys/block/"$1"/"$1"*; do
            [ -d "$_dc_part" ] && printf '  %s: a partition\n' "${_dc_part##*/}"
        done
    fi
}

# Waits up to $1 seconds for a USB disk that is not in list $2; prints its name.
wait_for_new_disk() {
    _wd_waited=0
    while [ "$_wd_waited" -lt "$1" ]; do
        for _wd_name in $(usb_disks); do
            case " $2 " in
                *" $_wd_name "*) ;;
                *)
                    # Give the system a moment to read the partition table.
                    sleep 2
                    printf '%s\n' "$_wd_name"
                    return 0
                    ;;
            esac
        done
        sleep 1
        _wd_waited=$((_wd_waited + 1))
    done
    return 1
}

# Sets DISK to the stick to write: the one named in $1, or found interactively.
choose_disk() {
    if [ -n "$1" ]; then
        _ch_name=${1##*/}
        if [ ! -e "/dev/$_ch_name" ]; then
            die "/dev/$_ch_name does not exist. If you clicked Eject in the file manager, the stick is
powered off: unplug it, plug it back in, and run '$PROGNAME write' without a device name"
        fi
        if [ ! -e "/sys/block/$_ch_name" ]; then
            # A partition was given; use its disk.
            _ch_parent=$(readlink -f "/sys/class/block/$_ch_name/.." 2>/dev/null)
            _ch_parent=${_ch_parent##*/}
            [ -e "/sys/block/$_ch_parent" ] || die "/dev/$_ch_name is not a disk or a partition"
            info "/dev/$_ch_name is a partition; using the whole stick /dev/$_ch_parent"
            _ch_name=$_ch_parent
        fi
        case " $(usb_disks | tr '\n' ' ') " in
            *" $_ch_name "*) ;;
            *) die "/dev/$_ch_name is not a USB or removable disk; refusing to write to it" ;;
        esac
        DISK=$_ch_name
        return 0
    fi

    _ch_present=$(usb_disks | tr '\n' ' ')
    _ch_present=${_ch_present% }
    if [ -n "$_ch_present" ]; then
        printf 'USB sticks connected now:\n' >&2
        _ch_n=0
        for _ch_name in $_ch_present; do
            _ch_n=$((_ch_n + 1))
            printf '  %d) /dev/%s  %s\n' "$_ch_n" "$_ch_name" "$(disk_summary "$_ch_name")" >&2
        done
        if [ "$_ch_n" -eq 1 ]; then
            printf 'Use this one? [Y/n] (n = wait for another stick to be plugged in) ' >&2
        else
            printf 'Type the number to use, or n to wait for another stick to be plugged in: ' >&2
        fi
        read -r _ch_answer || _ch_answer=''
        case $_ch_answer in
            '' | [Yy] | [Yy][Ee][Ss])
                [ "$_ch_n" -eq 1 ] || die 'please type the number of the stick'
                DISK=$_ch_present
                return 0
                ;;
            [Nn] | [Nn][Oo]) ;;
            *)
                _ch_i=0
                for _ch_name in $_ch_present; do
                    _ch_i=$((_ch_i + 1))
                    if [ "$_ch_answer" = "$_ch_i" ]; then
                        DISK=$_ch_name
                        return 0
                    fi
                done
                die "no stick numbered '$_ch_answer'"
                ;;
        esac
    fi

    printf 'Plug in the USB stick now. Waiting up to 60 seconds...\n' >&2
    DISK=$(wait_for_new_disk 60 "$_ch_present") || die 'no USB stick appeared. If you clicked Eject in the file manager earlier, the stick is
powered off: unplug it and plug it back in, then try again'
    info "found /dev/$DISK  $(disk_summary "$DISK")"
}

# Unmounts everything on disk $1, without root when the desktop mounted it.
unmount_disk() {
    awk -v d="/dev/$1" 'index($1, d) == 1 { print $1 }' /proc/mounts | while read -r _um_dev; do
        info "unmounting $_um_dev"
        if command -v udisksctl >/dev/null 2>&1 && udisksctl unmount -b "$_um_dev" >/dev/null 2>&1; then
            continue
        fi
        if [ "$(id -u)" -eq 0 ]; then
            umount "$_um_dev" || die "cannot unmount $_um_dev"
        else
            sudo umount "$_um_dev" || die "cannot unmount $_um_dev"
        fi
    done
    if grep -q "^/dev/$1" /proc/mounts; then
        die "/dev/$1 is still mounted; close whatever is using it and try again"
    fi
}

# Reads a line into REPLY without echoing it.
read_hidden() {
    printf '%s' "$1"
    stty -echo 2>/dev/null || true
    read -r REPLY || REPLY=''
    stty echo 2>/dev/null || true
    printf '\n'
}

# Asks for the camera credentials to store on the stick. Sets STICK_USER and
# STICK_PASS; both empty means the installer asks on every unit.
ask_stick_credentials() {
    printf '\nCamera credentials for the units imaged from this stick.\n'
    printf 'They are stored on the stick, so the installer only asks you to confirm them.\n'
    printf 'Camera user (leave empty to type the credentials on each unit instead): '
    read -r STICK_USER || STICK_USER=''
    [ -n "$STICK_USER" ] || return 0
    while :; do
        read_hidden 'Camera password: '
        STICK_PASS=$REPLY
        read_hidden 'Camera password (again): '
        [ "$REPLY" = "$STICK_PASS" ] && [ -n "$STICK_PASS" ] && return 0
        printf 'The passwords did not match; try again.\n'
    done
}

# Lists the layouts and their cameras and asks which one the installer should
# offer first. Sets STICK_LAYOUT (a file name, or empty for the installer's
# own guess from the hostname).
ask_stick_layout() {
    _al_n=0
    printf '\nCameras this stick knows about (from %s):\n' "$KIOSK_DIR/layouts"
    for _al_file in "$KIOSK_DIR"/layouts/*.conf; do
        [ -f "$_al_file" ] || continue
        _al_n=$((_al_n + 1))
        printf '  %d) %s\n' "$_al_n" "${_al_file##*/}"
        awk -F'|' '/^[[:space:]]*[A-Za-z0-9_]+[[:space:]]*\|/ {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $4)
            printf "       %-6s %-32s %s\n", $2, $3, $4 }' "$_al_file"
    done
    [ "$_al_n" -gt 0 ] || die "no layouts in $KIOSK_DIR/layouts; the stick would have nothing to show"
    printf 'Layout the installer should offer first: number, or Enter to let it pick from the hostname: '
    read -r _al_answer || _al_answer=''
    STICK_LAYOUT=''
    [ -n "$_al_answer" ] || return 0
    _al_i=0
    for _al_file in "$KIOSK_DIR"/layouts/*.conf; do
        [ -f "$_al_file" ] || continue
        _al_i=$((_al_i + 1))
        if [ "$_al_answer" = "$_al_i" ]; then
            STICK_LAYOUT=${_al_file##*/}
            return 0
        fi
    done
    die "no layout numbered '$_al_answer'"
}

# Prints where partition $1 is mounted, if it is.
mount_point_of() {
    if command -v findmnt >/dev/null 2>&1; then
        findmnt -n -o TARGET --source "$1" 2>/dev/null | head -n 1
    else
        awk -v d="$1" '$1 == d { print $2; exit }' /proc/mounts
    fi
}

# Mounts partition $1 and prints the mount point; uses the desktop's mounter
# when available so no password is needed. The desktop may well mount a
# freshly written stick by itself; in that case its mount point is used.
mount_partition() {
    _mp_dir=$(mount_point_of "$1")
    if [ -n "$_mp_dir" ]; then
        printf '%s\n' "$_mp_dir"
        return 0
    fi
    if command -v udisksctl >/dev/null 2>&1; then
        if _mp_out=$(udisksctl mount -b "$1" 2>/dev/null); then
            # "Mounted /dev/sdb1 at /media/user/CAKIOUSB" (older versions end with a dot)
            printf '%s\n' "${_mp_out##* at }" | sed 's/\.$//'
            return 0
        fi
        sleep 1
        _mp_dir=$(mount_point_of "$1")
        [ -n "$_mp_dir" ] || return 1
        printf '%s\n' "$_mp_dir"
        return 0
    fi
    _mp_dir=$(mktemp -d "${TMPDIR:-/tmp}/cakio-stick.XXXXXX") || return 1
    if [ "$(id -u)" -eq 0 ]; then
        mount "$1" "$_mp_dir" || return 1
    else
        sudo mount -o "uid=$(id -u)" "$1" "$_mp_dir" || return 1
    fi
    printf '%s\n' "$_mp_dir"
}

unmount_partition() {
    if command -v udisksctl >/dev/null 2>&1 && udisksctl unmount -b "$1" >/dev/null 2>&1; then
        return 0
    fi
    if [ "$(id -u)" -eq 0 ]; then
        umount "$1"
    else
        sudo umount "$1"
    fi
}

# Writes the defaults the installer will offer onto the freshly written stick.
write_stick_defaults() {
    _wsd_part=/dev/${DISK}1
    case $DISK in
        *[0-9]) _wsd_part=/dev/${DISK}p1 ;;
    esac
    _wsd_waited=0
    while [ ! -b "$_wsd_part" ] && [ "$_wsd_waited" -lt 10 ]; do
        sleep 1
        _wsd_waited=$((_wsd_waited + 1))
        # The kernel normally notices the new partition table by itself;
        # ask it to look again if it has not after a few seconds.
        if [ "$_wsd_waited" -eq 3 ]; then
            if [ "$(id -u)" -eq 0 ]; then
                blockdev --rereadpt "/dev/$DISK" 2>/dev/null || true
            else
                sudo blockdev --rereadpt "/dev/$DISK" 2>/dev/null || true
            fi
        fi
    done
    [ -b "$_wsd_part" ] || die "the stick was written, but its partition $_wsd_part did not appear; unplug and replug it, then run write again"
    _wsd_mnt=$(mount_partition "$_wsd_part") || die 'the stick was written, but it could not be opened to store the defaults'
    [ -d "$_wsd_mnt/kiosk" ] || die "the stick was written, but $_wsd_mnt does not look like a Cakio stick"
    if [ -n "$STICK_LAYOUT" ] && [ ! -f "$_wsd_mnt/layouts/$STICK_LAYOUT" ]; then
        warn "$STICK_LAYOUT is not on the stick (the image was built before it was added); the installer will pick from the hostname"
        STICK_LAYOUT=''
    fi
    {
        printf '# Defaults offered by the installer. Written by kiosk-build.sh write.\n'
        printf 'CAMERA_USER=%s\n' "$STICK_USER"
        printf 'CAMERA_PASSWORD=%s\n' "$STICK_PASS"
        printf 'DEFAULT_LAYOUT=%s\n' "$STICK_LAYOUT"
    } >"$_wsd_mnt/kiosk/defaults.conf" || die 'cannot write the defaults to the stick'
    sync
    unmount_partition "$_wsd_part" || warn 'could not unmount the stick cleanly; wait a few seconds before unplugging it'
}

cmd_write() {
    need_tool dd coreutils
    [ -n "$OUTPUT" ] || OUTPUT=$(newest_image)
    if [ -z "$OUTPUT" ] || [ ! -f "$OUTPUT" ]; then
        die 'no stick image found; build one first or pass --output'
    fi
    [ -t 0 ] || die 'write needs a terminal to ask questions'

    choose_disk "$WRITE_DEVICE"
    _cw_dev=/dev/$DISK
    _cw_contents=$(disk_contents "$DISK")

    ask_stick_credentials
    ask_stick_layout

    printf '\nStick:   %s  %s\nImage:   %s\n' "$_cw_dev" "$(disk_summary "$DISK")" "$OUTPUT"
    if [ -n "$STICK_USER" ]; then
        printf 'Cameras: user %s (password stored on the stick)\n' "$STICK_USER"
    else
        printf 'Cameras: credentials typed on each unit\n'
    fi
    printf 'Layout:  %s\n' "${STICK_LAYOUT:-chosen from the hostname on each unit}"
    if [ -n "$_cw_contents" ]; then
        printf '\nThis stick has data on it:\n%s\n' "$_cw_contents"
        printf '\nAll of it will be erased. Type YES to erase the stick and write the image: '
    else
        printf '\nThe stick looks empty. Type YES to write the image: '
    fi
    read -r _cw_answer || _cw_answer=''
    [ "$_cw_answer" = YES ] || die 'cancelled; nothing was written'

    unmount_disk "$DISK"
    info "writing (a few minutes; you may be asked for your password)"
    if [ "$(id -u)" -eq 0 ]; then
        dd if="$OUTPUT" of="$_cw_dev" bs=4M conv=fsync status=progress || die 'writing failed'
    else
        sudo dd if="$OUTPUT" of="$_cw_dev" bs=4M conv=fsync status=progress || die 'writing failed'
    fi
    sync
    sleep 2
    unmount_disk "$DISK" 2>/dev/null || true
    write_stick_defaults
    sleep 1
    if command -v udisksctl >/dev/null 2>&1 && udisksctl power-off -b "$_cw_dev" >/dev/null 2>&1; then
        printf '%s: done. The stick is powered off; unplug it.\n' "$PROGNAME"
    else
        printf '%s: done. Unplug the stick.\n' "$PROGNAME"
    fi
}

cmd_boot() {
    check_tools
    [ -n "$TEST_DISK" ] || TEST_DISK=$PWD/cakio-test-disk.img
    if [ ! -f "$TEST_DISK" ]; then
        info "creating the virtual internal disk $TEST_DISK (${DEFAULT_TEST_DISK_GB} GB, grows as used)"
        truncate -s "${DEFAULT_TEST_DISK_GB}G" "$TEST_DISK" || die "cannot create $TEST_DISK"
    fi
    if [ "$STICK_IMAGE" != none ]; then
        [ -n "$STICK_IMAGE" ] || STICK_IMAGE=${OUTPUT:-$(newest_image)}
        if [ -z "$STICK_IMAGE" ] || [ ! -f "$STICK_IMAGE" ]; then
            die 'no stick image found; build one first or pass --image'
        fi
    fi

    set -- -name cakio-test -machine q35 -accel kvm -accel tcg -cpu max -smp 2 -m 4096 \
        -bios "$OVMF" -device VGA,xres=1920,yres=1080 \
        -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22"
    if [ "$STICK_IMAGE" != none ]; then
        set -- "$@" -drive "file=$STICK_IMAGE,format=raw,if=none,id=stick" \
            -device virtio-blk-pci,drive=stick,bootindex=0
    fi
    set -- "$@" -drive "file=$TEST_DISK,format=raw,if=none,id=disk" \
        -device virtio-blk-pci,drive=disk,bootindex=1
    if [ -n "$HEADLESS" ]; then
        set -- "$@" -display none -serial mon:stdio
    fi

    info "SSH to the kiosk with: kiosk-admin.sh --port $SSH_PORT enroll 127.0.0.1"
    exec qemu-system-x86_64 "$@"
}

main() {
    parse_args "$@"
    trap cleanup EXIT
    trap 'cleanup; exit 130' INT
    trap 'cleanup; exit 143' TERM
    case $COMMAND in
        image) cmd_image ;;
        write) cmd_write ;;
        boot) cmd_boot ;;
    esac
}

WRITE_DEVICE=''
RELEASE=''
main "$@"
