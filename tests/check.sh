#!/usr/bin/env sh
# check.sh - exercise the layout parser, host-key replacement, and updates.

set -eu

unalias -a 2>/dev/null || true
unset -f awk basename cmp find grep mkdir mktemp openssl rm sed sha256sum 2>/dev/null || true

export LC_ALL=C

PROGNAME=$(basename -- "$0")
readonly PROGNAME
ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
readonly ROOT
readonly MOSAIC="$ROOT/kiosk-mosaic.sh"
readonly FONT=/usr/share/fonts/TTF/DejaVuSans-Bold.ttf

TMP=''
FAILS=0

usage() {
    printf '%s\n' "Usage: $PROGNAME [OPTION]...
Check the camera layout parser, known-hosts replacement, and update bundles.

  -h, --help    display this help and exit"
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    exit 1
}

cleanup() {
    if [ -n "$TMP" ]; then
        rm -rf -- "$TMP"
    fi
}

fail() {
    FAILS=$((FAILS + 1))
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
}

# Runs kiosk-mosaic --print. Extra arguments come first, then the layout path.
show_layout() {
    "$MOSAIC" --print --test-pattern --hwdec none --interface none \
        --resolution 640x480 --font "$FONT" "$@"
}

# A bad layout must be rejected. $1 is the file, $2 a pattern in the error.
reject_layout() {
    _rl_err=$TMP/err
    if show_layout "$1" >"$TMP/out" 2>"$_rl_err"; then
        fail "$1 was accepted"
        return 0
    fi
    if ! grep -q -- "$2" "$_rl_err"; then
        fail "$1 was rejected, but not because of $2"
        cat "$_rl_err" >&2
    fi
}

check_layouts() {
    [ -f "$FONT" ] || die "font $FONT is missing"
    [ -x "$MOSAIC" ] || die "$MOSAIC is missing"
    _cl_out=$TMP/default.out
    if ! show_layout "$ROOT/layouts/default.conf" >"$_cl_out" 2>"$TMP/default.err"; then
        fail 'layouts/default.conf was rejected'
        cat "$TMP/default.err" >&2
        return 0
    fi
    grep -q '4 cameras' "$_cl_out" || fail 'default layout did not report 4 cameras'
    grep -q 'Entrance' "$_cl_out" || fail 'default layout did not name Entrance'
    grep -q '10 fps' "$_cl_out" || fail 'default layout did not use 10 fps'

    if ! show_layout --fps 15 "$ROOT/layouts/default.conf" >"$TMP/fps.out" 2>"$TMP/fps.err"; then
        fail '--fps 15 was rejected'
        return 0
    fi
    grep -q '15 fps' "$TMP/fps.out" || fail '--fps 15 did not override the layout'
    grep -q 'mpv ' "$_cl_out" || fail 'tiles mode did not play with mpv'
    grep -q 'panscan=1.0' "$_cl_out" || fail 'tiles mode did not fill by cropping in the player'
    if grep -q 'thread_queue_size 512' "$_cl_out"; then
        fail 'tiles mode still queued 512 packets'
    fi
    if ! show_layout --mode single "$ROOT/layouts/default.conf" >"$TMP/single.out" 2>"$TMP/single.err"; then
        fail '--mode single was rejected'
        cat "$TMP/single.err" >&2
        return 0
    fi
    grep -q 'thread_queue_size 8' "$TMP/single.out" || fail 'single mode did not use a short input queue'
    grep -q 'muxdelay 0' "$TMP/single.out" || fail 'single mode did not turn mux delay off'
    grep -q -- '-sync ext' "$TMP/single.out" || fail 'single mode did not sync ffplay to the wall clock'

    cat >"$TMP/open.conf" <<'EOF'
layout
A B
EOF
    reject_layout "$TMP/open.conf" 'no end line'

    cat >"$TMP/shape.conf" <<'EOF'
layout
A A
A B
end
A|1|Left|192.0.2.10
B|2|Right|192.0.2.11
EOF
    reject_layout "$TMP/shape.conf" 'not a rectangle'

    cat >"$TMP/addr.conf" <<'EOF'
layout
A
end
A|1|Door|not a host
EOF
    reject_layout "$TMP/addr.conf" 'invalid camera address'

    cat >"$TMP/missing.conf" <<'EOF'
layout
A B
end
A|1|Only|192.0.2.10
EOF
    reject_layout "$TMP/missing.conf" 'no camera line'

    cat >"$TMP/wide.conf" <<'EOF'
layout
A A
A A
end
A|9|Gate|192.0.2.20|stream=main,fit=fit
EOF
    if ! show_layout "$TMP/wide.conf" >"$TMP/wide.out" 2>"$TMP/wide.err"; then
        fail 'a rectangular tile was rejected'
        cat "$TMP/wide.err" >&2
        return 0
    fi
    grep -q '1 cameras' "$TMP/wide.out" || fail 'a merged tile was not one camera'
    grep -q 'main stream' "$TMP/wide.out" || fail 'stream=main was not kept'
}

# Same replacement the enroll command applies to ca/known_hosts.
replace_host() {
    awk -v name="$1" -v plain="$2" -v bracket="$3" '
        $1 == "@cert-authority" { print; next }
        $1 == name || $1 == plain || $1 == bracket { next }
        NF == 0 || $1 ~ /^#/ { next }
        { print }
    ' "$4"
}

check_known_hosts() {
    cat >"$TMP/known" <<'EOF'
@cert-authority * ssh-ed25519 KEYCA
10.0.0.5 ssh-ed25519 KEYOLD
10.0.0.6 ssh-ed25519 KEYOTHER
[10.0.0.5]:22 ssh-ed25519 KEYBRACKET
EOF
    printf '%s\n' '10.0.0.5 ssh-ed25519 KEYNEW' >"$TMP/scan"
    replace_host '10.0.0.5' '10.0.0.5' '[10.0.0.5]:22' "$TMP/known" >"$TMP/kept"
    cat "$TMP/scan" >>"$TMP/kept"
    grep -q 'KEYCA' "$TMP/kept" || fail 'the host CA line was dropped'
    grep -q 'KEYOTHER' "$TMP/kept" || fail 'another host was dropped'
    grep -q 'KEYNEW' "$TMP/kept" || fail 'the new host key was not added'
    if grep -q 'KEYOLD' "$TMP/kept" || grep -q 'KEYBRACKET' "$TMP/kept"; then
        fail 'an old host key was kept'
    fi
}

check_signature() {
    command -v openssl >/dev/null 2>&1 || die 'openssl is needed'
    command -v sha256sum >/dev/null 2>&1 || die 'sha256sum is needed'
    mkdir -p -- "$TMP/payload/boot"
    printf 'test-release\n' >"$TMP/payload/release.txt"
    printf 'kernel\n' >"$TMP/payload/boot/vmlinuz-lts"
    (
        cd -- "$TMP/payload" || exit 1
        find . -type f | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r _cs_file; do
            sha256sum -- "$_cs_file" || exit 1
        done
    ) >"$TMP/SHA256SUMS"
    openssl genrsa -out "$TMP/key.pem" 2048 2>/dev/null
    openssl rsa -in "$TMP/key.pem" -pubout -out "$TMP/key.pub" 2>/dev/null
    openssl dgst -sha256 -sign "$TMP/key.pem" -out "$TMP/SHA256SUMS.sig" "$TMP/SHA256SUMS"
    openssl dgst -sha256 -verify "$TMP/key.pub" -signature "$TMP/SHA256SUMS.sig" \
        "$TMP/SHA256SUMS" >/dev/null 2>&1 || fail 'a good signature did not verify'
    (cd -- "$TMP/payload" && sha256sum -c "$TMP/SHA256SUMS") >/dev/null 2>&1 ||
        fail 'checksums did not match the payload'
    printf 'x\n' >>"$TMP/payload/boot/vmlinuz-lts"
    if (cd -- "$TMP/payload" && sha256sum -c "$TMP/SHA256SUMS") >/dev/null 2>&1; then
        fail 'a changed file still matched its checksum'
    fi
}

# Runs a kiosk-apply function. $1 is the signing public key.
apply_fn() {
    _af_pub=$1
    shift
    KIOSK_APPLY_LIBRARY=1 KIOSK_BUILD_PUB="$_af_pub" \
        sh -c ". \"\$1\" && shift && \"\$@\"" _ \
        "$ROOT/image/kiosk/usr/local/bin/kiosk-apply" "$@"
}

# Runs a kiosk-admin function. $1 is the CA directory.
admin_fn() {
    _an_ca=$1
    shift
    CAKIO_CA_DIR="$_an_ca" KIOSK_ADMIN_LIBRARY=1 \
        sh -c ". \"\$1\" && trap cleanup EXIT && shift && \"\$@\"" _ \
        "$ROOT/kiosk-admin.sh" "$@"
}

fill_payload() {
    mkdir -p -- "$1/payload/boot"
    printf '%s\n' 'test-release' >"$1/payload/release.txt"
    printf '%s\n' 'kernel' >"$1/payload/boot/vmlinuz-lts"
    printf '%s\n' 'base' >"$1/payload/base.apkovl.tar.gz"
}

sign_tree() {
    (
        cd -- "$1/payload" || exit 1
        find . -type f | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r _st_file; do
            sha256sum -- "$_st_file" || exit 1
        done
    ) >"$1/SHA256SUMS"
    openssl dgst -sha256 -sign "$2" -out "$1/SHA256SUMS.sig" "$1/SHA256SUMS"
}

check_update() {
    command -v openssl >/dev/null 2>&1 || die 'openssl is needed'
    command -v sha256sum >/dev/null 2>&1 || die 'sha256sum is needed'
    _cu_key=$TMP/upd-key.pem
    _cu_pub=$TMP/upd-key.pub
    openssl genrsa -out "$_cu_key" 2048 2>/dev/null
    openssl rsa -in "$_cu_key" -pubout -out "$_cu_pub" 2>/dev/null

    if ! apply_fn "$_cu_pub" update_member_ok 'payload/boot/grub/grub.cfg'; then
        fail 'a nested payload path was rejected'
    fi
    if ! apply_fn "$_cu_pub" update_member_ok 'SHA256SUMS'; then
        fail 'SHA256SUMS was rejected'
    fi
    if apply_fn "$_cu_pub" update_member_ok '../etc/passwd'; then
        fail 'a parent path was accepted'
    fi
    if apply_fn "$_cu_pub" update_member_ok '/etc/passwd'; then
        fail 'an absolute path was accepted'
    fi
    if apply_fn "$_cu_pub" update_member_ok 'payload/../../etc/passwd'; then
        fail 'a payload path with .. was accepted'
    fi
    if apply_fn "$_cu_pub" update_member_ok 'notes.txt'; then
        fail 'an extra archive member was accepted'
    fi

    _cu_dir=$TMP/bundle
    fill_payload "$_cu_dir"
    sign_tree "$_cu_dir" "$_cu_key"
    if ! apply_fn "$_cu_pub" verify_update_tree "$_cu_dir" 2>"$TMP/verify.err"; then
        fail 'a valid bundle was rejected'
        cat "$TMP/verify.err" >&2
    fi
    printf 'x\n' >>"$_cu_dir/payload/boot/vmlinuz-lts"
    if apply_fn "$_cu_pub" verify_update_tree "$_cu_dir" 2>/dev/null; then
        fail 'a changed file still matched its checksum'
    fi
    printf '%s\n' 'kernel' >"$_cu_dir/payload/boot/vmlinuz-lts"
    sign_tree "$_cu_dir" "$_cu_key"
    printf '%s\n' 'extra' >"$_cu_dir/payload/extra"
    if apply_fn "$_cu_pub" verify_update_tree "$_cu_dir" 2>/dev/null; then
        fail 'a file missing from the signed list was accepted'
    fi
    rm -f -- "$_cu_dir/payload/extra"
    printf '%s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  ../x' \
        >"$_cu_dir/SHA256SUMS"
    openssl dgst -sha256 -sign "$_cu_key" -out "$_cu_dir/SHA256SUMS.sig" "$_cu_dir/SHA256SUMS"
    if apply_fn "$_cu_pub" verify_update_tree "$_cu_dir" 2>/dev/null; then
        fail 'a signed path outside the payload was accepted'
    fi

    _cu_old=$TMP/old
    _cu_new=$TMP/new
    mkdir -p -- "$_cu_old/etc/kiosk" "$_cu_old/etc/crontabs" "$_cu_old/etc/ssh"
    mkdir -p -- "$_cu_new/etc/kiosk" "$_cu_new/etc/crontabs" "$_cu_new/usr/local/bin" "$_cu_new/etc/apk"
    printf '%s\n' 'whid-cakio-dock' >"$_cu_old/etc/hostname"
    printf '%s\n' 'alpine' >"$_cu_new/etc/hostname"
    printf '%s\n' 'CAMERA_USER=cam' 'CAMERA_PASSWORD=secret' >"$_cu_old/etc/kiosk/camera.env"
    printf '%s\n' 'serial=unit' 'release=old-release' >"$_cu_old/etc/kiosk/unit.conf"
    printf '%s\n' 'serial=base' 'release=base-release' >"$_cu_new/etc/kiosk/unit.conf"
    printf '%s\n' '0 3 * * * /usr/local/bin/kiosk-nightly # cakio daily reboot' >"$_cu_old/etc/crontabs/root"
    printf '%s\n' '# alpine jobs' >"$_cu_new/etc/crontabs/root"
    printf '%s\n' 'SECRETKEY' >"$_cu_old/etc/ssh/ssh_host_ed25519_key"
    printf '%s\n' '# mosaic' >"$_cu_new/usr/local/bin/kiosk-mosaic"
    printf '%s\n' 'openssl' >"$_cu_new/etc/apk/world"
    if ! apply_fn "$_cu_pub" merge_unit_overlay "$_cu_old" "$_cu_new" '20261011-1753'; then
        fail 'the overlay merge failed'
        return 0
    fi
    grep -qx 'whid-cakio-dock' "$_cu_new/etc/hostname" || fail 'merge replaced the hostname'
    grep -qx 'release=20261011-1753' "$_cu_new/etc/kiosk/unit.conf" || fail 'merge did not set the release'
    grep -qx 'serial=unit' "$_cu_new/etc/kiosk/unit.conf" || fail 'merge replaced the unit serial'
    grep -q 'CAMERA_PASSWORD=secret' "$_cu_new/etc/kiosk/camera.env" || fail 'merge dropped the camera password'
    grep -q 'SECRETKEY' "$_cu_new/etc/ssh/ssh_host_ed25519_key" || fail 'merge dropped the host key'
    grep -q '# cakio daily reboot' "$_cu_new/etc/crontabs/root" || fail 'merge dropped the daily reboot'
    grep -q '# alpine jobs' "$_cu_new/etc/crontabs/root" || fail 'merge dropped the new crontab'
    grep -qx 'openssl' "$_cu_new/etc/apk/world" || fail 'merge dropped a new file'
    grep -qx '# mosaic' "$_cu_new/usr/local/bin/kiosk-mosaic" || fail 'merge dropped kiosk-mosaic'
}

check_inventory() {
    _ci_ca=$TMP/inv
    mkdir -p -- "$_ci_ca"
    cat >"$_ci_ca/inventory.csv" <<'EOF'
enrolled,hostname,address,serial,mac,fingerprint,layout,release
2026-01-01T00:00:00Z,whid-cakio-dock,10.0.0.5,serial,aa:bb,SHA256:abc,4 cameras,old-release
2026-01-01T00:00:00Z,whid-cakio-yard,10.0.0.6,serial,aa:cc,SHA256:def,2 cameras,keep-release
EOF
    _ci_got=$(CAKIO_CA_DIR="$_ci_ca" KIOSK_ADMIN_LIBRARY=1 \
        sh -c ". \"\$1\" && printf \"%s\\n\" \"\$CA_DIR\"" _ "$ROOT/kiosk-admin.sh")
    [ "$_ci_got" = "$_ci_ca" ] || die 'inventory test would write outside the temp directory'
    cp -a -- "$_ci_ca/inventory.csv" "$TMP/inventory.before"
    admin_fn "$_ci_ca" note_release 'nobody' 'new-release'
    cmp -s "$TMP/inventory.before" "$_ci_ca/inventory.csv" || fail 'an unknown hostname changed the inventory'
    admin_fn "$_ci_ca" note_release 'whid-cakio-dock' 'bad,release' 2>/dev/null
    cmp -s "$TMP/inventory.before" "$_ci_ca/inventory.csv" || fail 'a release containing a comma was written'
    admin_fn "$_ci_ca" note_release 'whid-cakio-dock' 'new-release'
    grep -q 'whid-cakio-dock,10.0.0.5,serial,aa:bb,SHA256:abc,4 cameras,new-release' \
        "$_ci_ca/inventory.csv" || fail 'the inventory release was not updated'
    grep -q 'keep-release' "$_ci_ca/inventory.csv" || fail 'another inventory row was changed'
}

check_grub() {
    _cg_menu=$ROOT/builder/build-in-vm.sh
    grep -q 'menuentry "Previous release"' "$_cg_menu" ||
        fail 'the boot menu has no previous release'
    grep -q 'modloop=/boot.prev/modloop-lts' "$_cg_menu" ||
        fail 'the previous release does not use its own kernel modules'
    grep -q 'modloop=/boot/modloop-lts' "$_cg_menu" ||
        fail 'the current release does not pin its kernel modules'
    grep -q 'cakio-slot=current' "$_cg_menu" || fail 'the new kernel is not marked current'
    grep -q 'cakio-slot=previous' "$_cg_menu" || fail 'the previous kernel is not marked previous'
    grep -q 'set timeout=10' "$_cg_menu" || fail 'a pending update does not wait'
    grep -q 'update-pending' "$_cg_menu" || fail 'the boot menu ignores the update flag'
    grep -q 'set default=1' "$_cg_menu" || fail 'a failed kernel does not default to the previous release'
    if grep -q 'set timeout=3' "$_cg_menu"; then
        fail 'the boot menu still waits on every boot'
    fi
    apply_fn "$TMP/unused.pub" write_grub_env "$TMP/grubenv" || fail 'the GRUB environment block was not written'
    _cg_size=$(wc -c <"$TMP/grubenv" | tr -d ' ')
    [ "$_cg_size" = 1024 ] || fail "the GRUB environment block is $_cg_size bytes"
    _cg_line=''
    IFS= read -r _cg_line <"$TMP/grubenv" || fail 'the GRUB environment block is empty'
    [ "$_cg_line" = '# GRUB Environment Block' ] || fail 'the GRUB environment block has a bad header'
}

main() {
    case ${1:-} in
        -h | --help)
            usage
            exit 0
            ;;
        '') ;;
        *)
            printf '%s: unrecognized option %s\n' "$PROGNAME" "'$1'" >&2
            printf "Try '%s --help' for more information.\n" "$PROGNAME" >&2
            exit 2
            ;;
    esac
    TMP=$(mktemp -d "${TMPDIR:-/tmp}/cakio-check.XXXXXX") || die 'cannot create a temporary directory'
    trap cleanup EXIT
    check_layouts
    check_known_hosts
    check_signature
    check_update
    check_inventory
    check_grub
    if [ "$FAILS" -ne 0 ]; then
        die "$FAILS check(s) failed"
    fi
    printf '%s: ok\n' "$PROGNAME"
}

main "$@"
