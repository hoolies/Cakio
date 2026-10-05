#!/usr/bin/env sh
# build-in-vm.sh - assemble the camera kiosk USB stick.
#
# Runs as root inside a throwaway Alpine virtual machine started by
# kiosk-build.sh from the official Alpine ISO. The inputs prepared by
# kiosk-build.sh are on a read-only FAT disk; the stick image is the second
# disk. Everything is fetched with Alpine's own apk, which checks package
# signatures. Progress goes to the serial port, which kiosk-build.sh shows.
#
# The stick ends up with:
#   boot/, efi/                 kernel, initramfs, modules, grub (from the ISO)
#   apks/x86_64/                every package the kiosk and installer need,
#                               with an index signed by the build key
#   boot/cakio-installer.cpio.gz  the installer configuration, loaded as a
#                               second initramfs (see copy_boot_files)
#   kiosk/modloop-lts           the kernel modules image, kept out of boot/
#                               so the installer can tell its own apart from
#                               the one on an already installed unit
#   kiosk/cakio.apkovl.tar.gz   the base kiosk configuration
#   kiosk/grub.cfg              grub configuration for the internal disk
#   layouts/, records/, release.txt

set -eu

export LC_ALL=C

readonly IN=/mnt/in
readonly OUT=/mnt/out
readonly IN_DEV=/dev/vda1
readonly OUT_DISK=/dev/vdb
readonly OUT_PART=/dev/vdb1
readonly ESP_TYPE=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
readonly KIOSK_UID=1000
readonly ADMIN_UID=1001
readonly SHADOW_GID=42

ISO_MNT=''
RELEASE=''
TIMEZONE=''
MIRROR=''
BRANCH=''

log() {
    printf '%s %s\n' "$(date +%H:%M:%S)" "$1"
}

fail() {
    log "ERROR: $1"
    printf 'BUILD FAILED\n'
    sync
    sleep 2
    poweroff -f
    exit 1
}

mount_inputs() {
    mkdir -p "$IN"
    if ! grep -q " $IN " /proc/mounts; then
        mount -t vfat -o ro "$IN_DEV" "$IN" || fail "cannot mount the inputs disk $IN_DEV"
    fi
    [ -f "$IN/cakio-inputs" ] || fail 'the inputs disk has no cakio-inputs marker'
    # shellcheck source=/dev/null
    . "$IN/build.conf"
    : "${RELEASE:?}" "${TIMEZONE:?}" "${MIRROR:?}" "${BRANCH:?}"
    log "building release $RELEASE from Alpine $BRANCH"
}

find_iso_mount() {
    for _fm_dir in /media/*; do
        if [ -f "$_fm_dir/boot/modloop-lts" ] && [ -d "$_fm_dir/efi" ]; then
            ISO_MNT=$_fm_dir
            return 0
        fi
    done
    fail 'cannot find the mounted Alpine ISO'
}

setup_network() {
    log 'bringing up the network'
    ip link set eth0 up
    udhcpc -i eth0 -n -q -t 15 >/dev/null 2>&1 || fail 'no DHCP lease in the build VM'
    printf '%s/%s/main\n%s/%s/community\n' "$MIRROR" "$BRANCH" "$MIRROR" "$BRANCH" >/etc/apk/repositories
    apk update >/dev/null || fail 'apk update failed; is the mirror reachable?'
}

# Keeps the account files of the plain live system before extra packages add users.
snapshot_accounts() {
    cp /etc/passwd /tmp/base-passwd
    cp /etc/group /tmp/base-group
    cp /etc/shadow /tmp/base-shadow
}

install_build_tools() {
    log 'installing build tools'
    apk add --quiet --no-progress abuild sfdisk dosfstools tzdata cpio >/dev/null || fail 'cannot install build tools'
}

prepare_output_disk() {
    log "partitioning the stick image $OUT_DISK"
    # The initramfs mounts anything that looks like Alpine media, including
    # an old stick image; let go of it first. (No pipeline here: a fail
    # inside "| while read" would only leave a subshell.)
    _po_mounts=$(awk -v d="$OUT_DISK" 'index($1, d) == 1 { print $2 }' /proc/mounts)
    for _po_mnt in $_po_mounts; do
        umount "$_po_mnt" || fail "cannot unmount $_po_mnt from $OUT_DISK"
    done
    sfdisk --quiet --force --wipe always --wipe-partitions always "$OUT_DISK" <<EOF || fail 'partitioning failed'
label: gpt
type=$ESP_TYPE, name=CAKIOUSB
EOF
    _po_waited=0
    while [ ! -b "$OUT_PART" ]; do
        [ "$_po_waited" -lt 20 ] || fail "$OUT_PART did not appear"
        sleep 0.5
        _po_waited=$((_po_waited + 1))
    done
    mkfs.vfat -F 32 -n CAKIOUSB "$OUT_PART" >/dev/null || fail 'formatting failed'
    mkdir -p "$OUT"
    mount -t vfat "$OUT_PART" "$OUT" || fail "cannot mount $OUT_PART"
}

copy_boot_files() {
    log 'copying kernel, initramfs, modules, and grub from the ISO'
    cp -r "$ISO_MNT/boot" "$OUT/" || fail 'copying boot files failed'
    cp -r "$ISO_MNT/efi" "$OUT/" || fail 'copying EFI files failed'
    rm -rf "$OUT/boot/syslinux"
    [ -f "$OUT/boot/vmlinuz-lts" ] || fail 'the ISO has no vmlinuz-lts'
    [ -f "$OUT/boot/modloop-lts" ] || fail 'the ISO has no modloop-lts'
    [ -f "$OUT/efi/boot/bootx64.efi" ] || fail 'the ISO has no efi/boot/bootx64.efi'

    # A unit that already holds a kiosk has its own copy of everything in
    # boot/, and Alpine takes the first copy it finds, which is the internal
    # disk's. The kernel modules image therefore lives in kiosk/, a folder
    # only the stick has, and the installer is told to use it from there
    # (modloop= below). The installer puts it back into boot/ on the unit.
    mkdir -p "$OUT/kiosk"
    mv "$OUT/boot/modloop-lts" "$OUT/kiosk/modloop-lts" || fail 'cannot move modloop-lts'

    cat >"$OUT/boot/grub/grub.cfg" <<'EOF'
set timeout=1
set default=0
search --no-floppy --set=root --label CAKIOUSB

menuentry "Install the camera kiosk (erases the internal disk after you confirm)" {
    # The installer's configuration rides inside the initramfs (the second
    # initrd file) and apkovl= points at it there. Left to itself, Alpine
    # loads the first configuration it finds on any disk, and on a unit
    # that already holds a kiosk the internal disk is found first, so the
    # kiosk would come up instead of the installer. Pointing apkovl= at a
    # disk does not work either: Alpine has that disk mounted read-only by
    # then and refuses to mount it again. modloop= picks the stick's kernel
    # modules for the same reason; using the internal disk's would keep that
    # disk busy and the installer could not erase it.
    linux /boot/vmlinuz-lts modules=loop,squashfs,sd-mod,usb-storage quiet apkovl=/cakio-installer.apkovl.tar.gz modloop=/kiosk/modloop-lts
    initrd /boot/initramfs-lts /boot/cakio-installer.cpio.gz
}
EOF

    cat >"$OUT/kiosk/grub.cfg" <<'EOF'
set timeout=0
set default=0
search --no-floppy --set=root --label CAKIO

menuentry "Camera kiosk" {
    linux /boot/vmlinuz-lts modules=loop,squashfs,sd-mod,mmc_block,nvme quiet vt.global_cursor_default=0 autodetect_serial=no
    initrd /boot/initramfs-lts
}
EOF
}

fetch_packages() {
    log 'fetching packages'
    mkdir -p "$OUT/apks/x86_64"
    _fp_world=$(cat "$IN/image/kiosk/etc/apk/world" "$IN/image/installer/etc/apk/world" | sort -u | tr '\n' ' ')
    # shellcheck disable=SC2086 # the package list is meant to split
    apk fetch --quiet --no-progress --recursive --output "$OUT/apks/x86_64" $_fp_world ||
        fail 'apk fetch failed; check the package names in etc/apk/world'
    log "$(find "$OUT/apks/x86_64" -name '*.apk' | wc -l) packages, $(du -sm "$OUT/apks" | cut -f1) MB"

    log 'indexing and signing the package repository'
    (
        cd "$OUT/apks/x86_64" || exit 1
        apk index --quiet --rewrite-arch x86_64 -o APKINDEX.tar.gz ./*.apk
    ) || fail 'apk index failed'
    cp "$IN/keys/cakio-build.rsa" /tmp/cakio-build.rsa
    cp "$IN/keys/cakio-build.rsa.pub" /tmp/cakio-build.rsa.pub
    chmod 600 /tmp/cakio-build.rsa
    abuild-sign -q -k /tmp/cakio-build.rsa "$OUT/apks/x86_64/APKINDEX.tar.gz" || fail 'signing the index failed'
    touch "$OUT/apks/.boot_repository"
}

# Copies an overlay tree from the inputs to $2 with sane modes.
stage_tree() {
    mkdir -p "$2"
    cp -r "$1/." "$2/"
    find "$2" -type d -exec chmod 755 {} +
    find "$2" -type f -exec chmod 644 {} +
    for _st_file in "$2"/usr/local/bin/* "$2"/etc/local.d/*; do
        [ -f "$_st_file" ] && chmod 755 "$_st_file"
    done
    # Alpine's apk needs its key readable; everything else root-owned is fine.
    chown -R 0:0 "$2"
}

add_runlevel() {
    _ar_level=$1
    shift
    mkdir -p "$STAGE/etc/runlevels/$_ar_level"
    for _ar_svc in "$@"; do
        ln -sf "/etc/init.d/$_ar_svc" "$STAGE/etc/runlevels/$_ar_level/$_ar_svc"
    done
}

build_kiosk_overlay() {
    log 'building the kiosk configuration'
    STAGE=/tmp/stage-kiosk
    rm -rf "$STAGE"
    stage_tree "$IN/image/kiosk" "$STAGE"

    install -m 755 "$IN/kiosk-mosaic" "$STAGE/usr/local/bin/kiosk-mosaic"

    # Accounts: the live system's plus the kiosk user and the administrator.
    cp /tmp/base-passwd "$STAGE/etc/passwd"
    cp /tmp/base-group "$STAGE/etc/group"
    cp /tmp/base-shadow "$STAGE/etc/shadow"
    printf 'cakio:x:%s:%s:Camera kiosk:/home/cakio:/usr/local/bin/kiosk-session\n' "$KIOSK_UID" "$KIOSK_UID" >>"$STAGE/etc/passwd"
    printf 'kioskadm:x:%s:%s:Kiosk administrator:/home/kioskadm:/bin/sh\n' "$ADMIN_UID" "$ADMIN_UID" >>"$STAGE/etc/passwd"
    printf 'cakio:x:%s:\nkioskadm:x:%s:\n' "$KIOSK_UID" "$ADMIN_UID" >>"$STAGE/etc/group"
    for _bk_group in video audio input tty; do
        awk -F: -v g="$_bk_group" -v u=cakio 'BEGIN { OFS = ":" }
            $1 == g { $4 = ($4 == "") ? u : $4 "," u } { print }' "$STAGE/etc/group" >"$STAGE/etc/group.new"
        mv "$STAGE/etc/group.new" "$STAGE/etc/group"
    done
    # No passwords anywhere: the console logs the kiosk user in by itself and
    # the administrator uses SSH certificates. "*" means no password without
    # marking the account locked, which sshd would refuse.
    sed -i 's/^root:[^:]*:/root:!:/' "$STAGE/etc/shadow"
    printf 'cakio:*::0:::::\nkioskadm:*::0:::::\n' >>"$STAGE/etc/shadow"
    chmod 644 "$STAGE/etc/passwd" "$STAGE/etc/group"
    chown "0:$SHADOW_GID" "$STAGE/etc/shadow"
    chmod 640 "$STAGE/etc/shadow"

    mkdir -p "$STAGE/home/cakio" "$STAGE/home/kioskadm"
    chown "$KIOSK_UID:$KIOSK_UID" "$STAGE/home/cakio"
    chown "$ADMIN_UID:$ADMIN_UID" "$STAGE/home/kioskadm"
    chmod 700 "$STAGE/home/cakio" "$STAGE/home/kioskadm"

    add_runlevel sysinit devfs dmesg udev udev-trigger udev-settle modloop
    add_runlevel boot modules sysctl hostname bootmisc syslog networking
    add_runlevel default local sshd chronyd acpid udev-postmount crond
    chmod 600 "$STAGE/etc/crontabs/root"
    add_runlevel shutdown mount-ro killprocs savecache

    mkdir -p "$STAGE/etc/apk/keys" "$STAGE/etc/ssh/sshd_config.d" "$STAGE/etc/kiosk"
    install -m 644 /tmp/cakio-build.rsa.pub "$STAGE/etc/apk/keys/cakio-build.rsa.pub"
    install -m 644 "$IN/ca/user_ca.pub" "$STAGE/etc/ssh/kiosk_user_ca.pub"
    chmod 600 "$STAGE/etc/ssh/sshd_config"
    chmod 644 "$STAGE/etc/ssh/principals/kioskadm"

    [ -f "/usr/share/zoneinfo/$TIMEZONE" ] || fail "unknown timezone $TIMEZONE"
    cp "/usr/share/zoneinfo/$TIMEZONE" "$STAGE/etc/localtime"
    printf '%s\n' "$TIMEZONE" >"$STAGE/etc/timezone"
    printf 'cakio-new\n' >"$STAGE/etc/hostname"
    : >"$STAGE/etc/motd"
    printf 'release=%s\n' "$RELEASE" >"$STAGE/etc/kiosk/release"

    (cd "$STAGE" && tar -czf "$OUT/kiosk/cakio.apkovl.tar.gz" etc usr home) ||
        fail 'cannot write the kiosk configuration'
}

build_installer_overlay() {
    log 'building the installer configuration'
    STAGE=/tmp/stage-installer
    rm -rf "$STAGE"
    stage_tree "$IN/image/installer" "$STAGE"
    cp /tmp/base-passwd "$STAGE/etc/passwd"
    cp /tmp/base-group "$STAGE/etc/group"
    cp /tmp/base-shadow "$STAGE/etc/shadow"
    chown "0:$SHADOW_GID" "$STAGE/etc/shadow"
    chmod 640 "$STAGE/etc/shadow"
    mkdir -p "$STAGE/etc/apk/keys"
    install -m 644 /tmp/cakio-build.rsa.pub "$STAGE/etc/apk/keys/cakio-build.rsa.pub"
    # The installer runs with Alpine's default boot services.
    : >"$STAGE/etc/.default_boot_services"
    printf 'cakio-installer\n' >"$STAGE/etc/hostname"
    # Packed into a small initramfs rather than left on the stick, so the
    # installer always starts with its own configuration (see the grub
    # entry in copy_boot_files). Nothing on the stick's root matches
    # *.apkovl.tar.gz, so a kiosk booted with the stick still inserted
    # cannot pick the installer's configuration by mistake either.
    rm -rf /tmp/installer-initfs
    mkdir -p /tmp/installer-initfs
    (cd "$STAGE" && tar -czf /tmp/installer-initfs/cakio-installer.apkovl.tar.gz etc usr) ||
        fail 'cannot write the installer configuration'
    (cd /tmp/installer-initfs && printf 'cakio-installer.apkovl.tar.gz\n' | cpio -o -H newc 2>/dev/null | gzip -9) \
        >"$OUT/boot/cakio-installer.cpio.gz" || fail 'cannot pack the installer configuration'
    [ -s "$OUT/boot/cakio-installer.cpio.gz" ] || fail 'the packed installer configuration is empty'
}

copy_extras() {
    log 'copying layouts'
    mkdir -p "$OUT/layouts" "$OUT/records"
    cp "$IN"/layouts/*.conf "$OUT/layouts/" 2>/dev/null || log 'no layouts found'
    printf '%s\n' "$RELEASE" >"$OUT/release.txt"
    printf 'This stick installs the camera kiosk. Boot a thin client from it.\n' >"$OUT/README.txt"
}

main() {
    exec >/dev/ttyS0 2>&1
    log 'builder started'
    mount_inputs
    find_iso_mount
    snapshot_accounts
    setup_network
    install_build_tools
    prepare_output_disk
    copy_boot_files
    fetch_packages
    build_kiosk_overlay
    build_installer_overlay
    copy_extras
    log "stick uses $(du -sm "$OUT" | cut -f1) MB"
    umount "$OUT" || fail 'cannot unmount the stick image'
    sync
    printf 'BUILD OK\n'
    sleep 1
    poweroff -f
}

STAGE=''
main
