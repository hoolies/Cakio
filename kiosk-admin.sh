#!/usr/bin/env sh
# kiosk-admin.sh - manage camera kiosks over SSH with certificates.
#
# Keeps a small certificate authority in a directory (default ./ca): a user
# CA that signs your SSH key for a few hours at a time, and a host CA that
# signs each kiosk's host key when it is enrolled, so later connections need
# no fingerprint prompts. Also keeps the inventory of enrolled kiosks.

set -eu

unalias -a 2>/dev/null || true
unset -f awk basename cat date grep mkdir mktemp openssl rm ssh ssh-keygen \
    ssh-keyscan stty 2>/dev/null || true

export LC_ALL=C

PROGNAME=$(basename -- "$0")
readonly PROGNAME
readonly ADMIN_USER=kioskadm
readonly PRINCIPAL=kiosk-admin
readonly DEFAULT_HOURS=12
readonly HOST_CERT_DAYS=3650

COMMAND=''
HOST=''
CA_DIR=${CAKIO_CA_DIR:-$PWD/ca}
PORT=22
KEY=$HOME/.ssh/id_ed25519
SSH_CONFIG=/dev/null
RECORDS=''
FINGERPRINT=''
NEW_HOSTNAME=''
NO_CREDS=''
HOURS=$DEFAULT_HOURS
NO_PASSPHRASE=''
TMP_FILES=''

usage() {
    printf '%s\n' "Usage: $PROGNAME [OPTION]... COMMAND [ARG]...
Manage camera kiosks over SSH with certificates.

Commands:
  init-ca                  create the kiosk certificate authority (run once)
  login                    sign your SSH key for $DEFAULT_HOURS hours of kiosk access
                             (skips signing when a certificate is still valid)
  enroll HOST [LAYOUT]     trust a newly installed kiosk, set its clock, layout,
                             and camera credentials, sign its host key, and save
  layout HOST FILE         install a new camera layout and save
  creds HOST...            set the camera credentials on one or more kiosks
  reboot-time HOST TIME    restart the kiosk every day at TIME (24-hour HH:MM,
                             local time) or never (TIME none), and save
  status HOST              show what the kiosk is doing
  shot HOST [FILE]         save what is on the kiosk screen (default HOST.png)
  ssh HOST [COMMAND...]    open a shell or run a command on the kiosk

Mandatory arguments to long options are mandatory for short options too.
  -c, --ca-dir=DIR         CA and inventory directory (default ./ca, or
                             \$CAKIO_CA_DIR)
  -p, --port=N             SSH port of the kiosk (default 22)
  -i, --key=FILE           your SSH key (default ~/.ssh/id_ed25519)
      --records=DIR        records written by the installer stick
                             (default CA_DIR/records)
      --ssh-config=FILE    ssh configuration to use (default: none; your
                             ~/.ssh/config is ignored on purpose)
      --fingerprint=SHA256:...
                           for enroll: accept a kiosk with this host key
                             fingerprint when there is no record for it
      --hostname=NAME      for enroll: set the kiosk hostname
      --no-creds           for enroll: do not ask for camera credentials
      --hours=N            for login: validity in hours (default $DEFAULT_HOURS)
      --no-passphrase      for init-ca: CA keys without passphrases (testing only)
  -h, --help               display this help and exit

HOST is the kiosk's address or name. Commands other than init-ca and login
need a valid login (run '$PROGNAME login' first)."
}

info() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
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
    for _cu_file in $TMP_FILES; do
        rm -f -- "$_cu_file"
    done
}

temp_file() {
    _tf_file=$(mktemp "${TMPDIR:-/tmp}/kiosk-admin.XXXXXX") || die 'cannot create a temporary file'
    TMP_FILES="$TMP_FILES $_tf_file"
    printf '%s\n' "$_tf_file"
}

set_option() {
    case $1 in
        ca-dir) CA_DIR=$2 ;;
        port)
            case $2 in
                '' | *[!0-9]*) die "invalid port '$2'" ;;
            esac
            PORT=$2
            ;;
        key) KEY=$2 ;;
        ssh-config)
            [ -f "$2" ] || die "ssh configuration file '$2' not found"
            SSH_CONFIG=$2
            ;;
        records) RECORDS=$2 ;;
        fingerprint)
            case $2 in
                SHA256:*) FINGERPRINT=$2 ;;
                *) die "a fingerprint looks like SHA256:..., not '$2'" ;;
            esac
            ;;
        hostname) NEW_HOSTNAME=$2 ;;
        hours)
            case $2 in
                '' | *[!0-9]* | 0) die "invalid number of hours '$2'" ;;
            esac
            HOURS=$2
            ;;
    esac
}

# Parses options, the command, and HOST. Sets SKIP to the number of
# arguments consumed, so the caller can shift to the remaining operands.
parse_args() {
    SKIP=0
    while [ $# -gt 0 ]; do
        case $1 in
            -h | --help)
                usage
                exit 0
                ;;
            --no-creds) NO_CREDS=1 ;;
            --no-passphrase) NO_PASSPHRASE=1 ;;
            --ca-dir=* | --port=* | --key=* | --ssh-config=* | --records=* | --fingerprint=* | \
                --hostname=* | --hours=*)
                _pa_name=${1%%=*}
                set_option "${_pa_name#--}" "${1#*=}"
                ;;
            --ca-dir | --port | --key | --ssh-config | --records | --fingerprint | --hostname | --hours)
                [ $# -ge 2 ] || usage_error "option '$1' requires an argument"
                set_option "${1#--}" "$2"
                shift
                SKIP=$((SKIP + 1))
                ;;
            -c | -p | -i)
                [ $# -ge 2 ] || usage_error "option requires an argument -- '${1#-}'"
                case $1 in
                    -c) set_option ca-dir "$2" ;;
                    -p) set_option port "$2" ;;
                    -i) set_option key "$2" ;;
                esac
                shift
                SKIP=$((SKIP + 1))
                ;;
            -c?*) set_option ca-dir "${1#-c}" ;;
            -p?*) set_option port "${1#-p}" ;;
            -i?*) set_option key "${1#-i}" ;;
            --)
                shift
                SKIP=$((SKIP + 1))
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
        SKIP=$((SKIP + 1))
    done

    [ $# -ge 1 ] || usage_error 'missing command'
    COMMAND=$1
    shift
    SKIP=$((SKIP + 1))
    case $COMMAND in
        init-ca | login) [ $# -eq 0 ] || usage_error "extra operand '$1'" ;;
        enroll | layout | creds | reboot-time | status | shot | ssh)
            [ $# -ge 1 ] || usage_error "$COMMAND needs the kiosk HOST"
            HOST=$1
            shift
            SKIP=$((SKIP + 1))
            case $HOST in
                '' | *[[:space:]]*) die "invalid host '$HOST'" ;;
            esac
            ;;
        *) usage_error "unknown command '$COMMAND'" ;;
    esac
    [ -z "$RECORDS" ] && RECORDS=$CA_DIR/records
    ARG1=${1:-}
    case $COMMAND in
        enroll) [ $# -le 1 ] || usage_error "extra operand '$2'" ;;
        layout) [ $# -eq 1 ] || usage_error 'layout needs exactly one FILE' ;;
        reboot-time)
            [ $# -eq 1 ] || usage_error 'reboot-time needs exactly one TIME (HH:MM or none)'
            case $ARG1 in
                none | off | [0-9]:[0-9][0-9] | [0-9][0-9]:[0-9][0-9]) ;;
                *) usage_error "invalid time '$ARG1' (use 24-hour HH:MM, or none)" ;;
            esac
            ;;
        status) [ $# -eq 0 ] || usage_error "extra operand '$1'" ;;
        shot) [ $# -le 1 ] || usage_error "extra operand '$2'" ;;
    esac
    # creds and ssh take any number of further operands.
    return 0
}

need_ca() {
    if [ ! -f "$CA_DIR/user_ca" ] || [ ! -f "$CA_DIR/host_ca" ]; then
        die "no CA in $CA_DIR; run '$PROGNAME init-ca' (or pass --ca-dir)"
    fi
}

need_login() {
    [ -f "$KEY" ] || die "SSH key $KEY not found; create one with: ssh-keygen -t ed25519"
    [ -f "$KEY-cert.pub" ] || die "no certificate for $KEY; run '$PROGNAME login' first"
}

# Runs a command on the kiosk. Standard input and output pass through.
# The user's own ssh configuration is ignored unless --ssh-config is given,
# so jump hosts and other settings meant for other systems do not interfere.
kssh() {
    ssh -F "$SSH_CONFIG" -p "$PORT" -i "$KEY" -o IdentitiesOnly=yes \
        -o "CertificateFile=$KEY-cert.pub" -o "UserKnownHostsFile=$CA_DIR/known_hosts" \
        -o StrictHostKeyChecking=yes -o ConnectTimeout=15 -o LogLevel=ERROR \
        -l "$ADMIN_USER" "$HOST" "$@"
}

# Runs a command on the kiosk as root.
kroot() {
    kssh doas "$@"
}

# Reads a line into REPLY without echoing it.
read_hidden() {
    printf '%s' "$1" >&2
    stty -echo 2>/dev/null || true
    read -r REPLY || REPLY=''
    stty echo 2>/dev/null || true
    printf '\n' >&2
}

cmd_init_ca() {
    [ ! -f "$CA_DIR/user_ca" ] || die "$CA_DIR already holds a CA; refusing to overwrite it"
    mkdir -p -- "$CA_DIR/records"
    chmod 700 "$CA_DIR"
    info "creating the kiosk CA in $CA_DIR"
    if [ -n "$NO_PASSPHRASE" ]; then
        set -- -N ''
    else
        set --
        printf 'Choose passphrases for the two CA keys. You will type the user CA passphrase\nat every login and the host CA passphrase at every enrollment.\n'
    fi
    ssh-keygen -q -t ed25519 -C 'camera kiosk user CA' -f "$CA_DIR/user_ca" "$@" || die 'creating the user CA failed'
    ssh-keygen -q -t ed25519 -C 'camera kiosk host CA' -f "$CA_DIR/host_ca" "$@" || die 'creating the host CA failed'
    printf '@cert-authority * %s\n' "$(cat "$CA_DIR/host_ca.pub")" >"$CA_DIR/known_hosts"
    (
        umask 077
        openssl genrsa -out "$CA_DIR/cakio-build.rsa" 2048 2>/dev/null
    ) || die 'creating the package signing key failed'
    openssl rsa -in "$CA_DIR/cakio-build.rsa" -pubout -out "$CA_DIR/cakio-build.rsa.pub" 2>/dev/null ||
        die 'deriving the signing public key failed'
    [ -f "$CA_DIR/inventory.csv" ] ||
        printf 'enrolled,hostname,address,serial,mac,fingerprint,layout,release\n' >"$CA_DIR/inventory.csv"
    printf '%s\n' "CA created in $CA_DIR. Keep this directory safe and backed up:
  user_ca, host_ca        private keys (never leave this machine)
  cakio-build.rsa         signs the packages on the stick
  known_hosts, inventory  trust and inventory of the kiosks

Next: kiosk-build.sh --ca-dir $CA_DIR"
}

cmd_login() {
    need_ca
    [ -f "$KEY.pub" ] || die "SSH key $KEY.pub not found; create one with: ssh-keygen -t ed25519"
    if [ -f "$KEY-cert.pub" ] && login_cert_still_valid; then
        info "certificate $KEY-cert.pub is still valid; not signing again"
        ssh-keygen -L -f "$KEY-cert.pub" | awk '/Valid:/ { $1 = ""; print "valid" $0 }'
        return 0
    fi
    ssh-keygen -q -s "$CA_DIR/user_ca" -I "$(id -un)@$(uname -n)" -n "$PRINCIPAL" \
        -V "-1h:+${HOURS}h" "$KEY.pub" || die 'signing your key failed'
    info "certificate written to $KEY-cert.pub"
    ssh-keygen -L -f "$KEY-cert.pub" | awk '/Valid:/ { $1 = ""; print "valid" $0 }'
}

# True when $KEY-cert.pub exists, names principal $PRINCIPAL, and has not expired.
login_cert_still_valid() {
    _lc_info=$(ssh-keygen -L -f "$KEY-cert.pub" 2>/dev/null) || return 1
    printf '%s\n' "$_lc_info" | grep -q "^[[:space:]]*${PRINCIPAL}\$" || return 1
    _lc_until=$(printf '%s\n' "$_lc_info" | awk '/Valid:/ {
        for (i = 1; i <= NF; i++) if ($i == "to") { print $(i + 1); exit }
    }')
    [ -n "$_lc_until" ] || return 1
    _lc_until=$(printf '%s' "$_lc_until" | tr -cd '0-9')
    _lc_now=$(date +%Y%m%d%H%M%S)
    [ "${#_lc_until}" -eq 14 ] && [ "$_lc_now" -lt "$_lc_until" ]
}

# Fetches the kiosk's host key, checks it against the records, and trusts it.
first_contact() {
    _fc_scan=$(temp_file)
    ssh-keyscan -p "$PORT" -T 10 -t ed25519 "$HOST" >"$_fc_scan" 2>/dev/null || true
    [ -s "$_fc_scan" ] || die "no SSH host key from $HOST port $PORT; is the kiosk up and reachable?"
    _fc_fp=$(ssh-keygen -lf "$_fc_scan" | awk '{ print $2; exit }')
    [ -n "$_fc_fp" ] || die "cannot read the host key of $HOST"

    RECORD=''
    if [ -d "$RECORDS" ]; then
        RECORD=$(grep -l "^fingerprint=$_fc_fp\$" "$RECORDS"/*.txt 2>/dev/null | head -n 1 || true)
    fi
    if [ -n "$RECORD" ]; then
        info "host key $_fc_fp matches record ${RECORD##*/}"
    elif [ "$FINGERPRINT" = "$_fc_fp" ]; then
        info "host key $_fc_fp accepted from --fingerprint"
    else
        die "the host key of $HOST is $_fc_fp, which is not in $RECORDS.
Copy the records folder from the installer stick there, or compare with the
fingerprint the installer showed and pass --fingerprint=$_fc_fp"
    fi

    if ! grep -qF -- "$(awk '{ print $3 }' "$_fc_scan")" "$CA_DIR/known_hosts"; then
        cat "$_fc_scan" >>"$CA_DIR/known_hosts"
    fi
    HOST_FP=$_fc_fp
}

# Asks for camera credentials and installs them on the kiosk.
install_creds() {
    _ic_current=$(kroot kiosk-apply show | awk -F': ' '/^camera user:/ { print $2 }')
    if [ -n "$_ic_current" ]; then
        printf 'Camera user [%s, Enter keeps the current credentials]: ' "$_ic_current" >&2
    else
        printf 'Camera user: ' >&2
    fi
    read -r _ic_user || _ic_user=''
    if [ -z "$_ic_user" ]; then
        [ -n "$_ic_current" ] && return 0
        info 'no camera credentials set; the screen will say so until you run creds'
        return 0
    fi
    while :; do
        read_hidden 'Camera password: '
        _ic_pass=$REPLY
        read_hidden 'Camera password (again): '
        [ "$REPLY" = "$_ic_pass" ] && [ -n "$_ic_pass" ] && break
        printf 'The passwords did not match; try again.\n' >&2
    done
    CREDS_USER=$_ic_user
    CREDS_PASS=$_ic_pass
    send_creds
}

send_creds() {
    printf 'CAMERA_USER=%s\nCAMERA_PASSWORD=%s\n' "$CREDS_USER" "$CREDS_PASS" | kroot kiosk-apply creds
}

# Signs the kiosk's host key with the host CA and installs the certificate.
install_host_cert() {
    _ih_pub=$(temp_file)
    kssh cat /etc/ssh/ssh_host_ed25519_key.pub >"$_ih_pub"
    [ -s "$_ih_pub" ] || die 'cannot read the host key from the kiosk'
    mv -f -- "$_ih_pub" "$_ih_pub.pub"
    TMP_FILES="$TMP_FILES $_ih_pub.pub $_ih_pub-cert.pub"
    ssh-keygen -q -s "$CA_DIR/host_ca" -I "$1" -h -n "$1,$HOST" -V "-1h:+${HOST_CERT_DAYS}d" "$_ih_pub.pub" ||
        die 'signing the host key failed'
    kroot kiosk-apply hostcert <"$_ih_pub-cert.pub"
}

record_field() {
    [ -n "$RECORD" ] || return 0
    sed -n "s/^$1=//p" "$RECORD" | head -n 1
}

# Writes one inventory row for hostname $1, replacing any earlier row for that name.
# Remaining arguments are address, serial, mac, fingerprint, layout, release.
upsert_inventory() {
    [ $# -eq 7 ] || die 'upsert_inventory needs hostname and six fields'
    _ui_host=$1
    _ui_tmp=$(temp_file)
    if [ -f "$CA_DIR/inventory.csv" ]; then
        awk -F, -v host="$_ui_host" 'NR == 1 || $2 != host { print }' \
            "$CA_DIR/inventory.csv" >"$_ui_tmp" || die 'cannot update the inventory'
    else
        printf 'enrolled,hostname,address,serial,mac,fingerprint,layout,release\n' >"$_ui_tmp"
    fi
    printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_ui_host" \
        "$2" "$3" "$4" "$5" "$6" "$7" >>"$_ui_tmp" || die 'cannot write the inventory'
    mv -f -- "$_ui_tmp" "$CA_DIR/inventory.csv"
}

cmd_enroll() {
    need_ca
    need_login
    _ce_layout=$ARG1
    if [ -n "$_ce_layout" ]; then
        [ -f "$_ce_layout" ] || die "layout file '$_ce_layout' not found"
    fi
    first_contact

    _ce_name=$(kssh hostname) || die "cannot log in to $HOST as $ADMIN_USER; is your login still valid?"
    info "connected to $_ce_name"
    kroot kiosk-apply clock "$(date +%s)"
    if [ -n "$NEW_HOSTNAME" ]; then
        kroot kiosk-apply hostname "$NEW_HOSTNAME"
        _ce_name=$NEW_HOSTNAME
    fi
    if [ -n "$_ce_layout" ]; then
        kroot kiosk-apply layout <"$_ce_layout"
    fi
    [ -n "$NO_CREDS" ] || install_creds
    install_host_cert "$_ce_name"
    kroot kiosk-apply commit

    _ce_layout_name=$(kroot kiosk-apply show | awk -F': ' '/^layout:/ { print $2 }')
    upsert_inventory "$_ce_name" "$HOST" \
        "$(record_field serial)" "$(record_field mac)" "$HOST_FP" "$_ce_layout_name" \
        "$(record_field release)"
    printf '\n%s: %s enrolled.\n' "$PROGNAME" "$_ce_name"
    kroot kiosk-apply show
}

cmd_layout() {
    need_ca
    need_login
    [ -f "$ARG1" ] || die "layout file '$ARG1' not found"
    kroot kiosk-apply layout <"$ARG1"
    kroot kiosk-apply commit
}

cmd_creds() {
    need_ca
    need_login
    printf 'Camera user: ' >&2
    read -r CREDS_USER || CREDS_USER=''
    [ -n "$CREDS_USER" ] || die 'no user given'
    while :; do
        read_hidden 'Camera password: '
        CREDS_PASS=$REPLY
        read_hidden 'Camera password (again): '
        [ "$REPLY" = "$CREDS_PASS" ] && [ -n "$CREDS_PASS" ] && break
        printf 'The passwords did not match; try again.\n' >&2
    done
    _cc_failed=''
    for _cc_host in "$HOST" "$@"; do
        HOST=$_cc_host
        printf '%s: ' "$HOST"
        if send_creds && kroot kiosk-apply commit; then
            :
        else
            _cc_failed="$_cc_failed $HOST"
        fi
    done
    [ -z "$_cc_failed" ] || die "failed on:$_cc_failed"
}

cmd_reboot_time() {
    need_ca
    need_login
    kroot kiosk-apply reboot-time "$ARG1"
    kroot kiosk-apply commit
}

cmd_status() {
    need_ca
    need_login
    kroot kiosk-status
}

cmd_shot() {
    need_ca
    need_login
    _cs_out=${ARG1:-$HOST.png}
    kssh 'doas kiosk-shot /tmp/kiosk-shot.png >/dev/null && cat /tmp/kiosk-shot.png' >"$_cs_out" ||
        die 'could not take the screenshot'
    [ -s "$_cs_out" ] || die 'the screenshot is empty'
    printf '%s\n' "$_cs_out"
}

cmd_ssh() {
    need_ca
    need_login
    exec ssh -F "$SSH_CONFIG" -p "$PORT" -i "$KEY" -o IdentitiesOnly=yes \
        -o "CertificateFile=$KEY-cert.pub" -o "UserKnownHostsFile=$CA_DIR/known_hosts" \
        -o StrictHostKeyChecking=yes -l "$ADMIN_USER" "$HOST" "$@"
}

main() {
    parse_args "$@"
    trap cleanup EXIT
    shift "$SKIP"
    case $COMMAND in
        init-ca) cmd_init_ca ;;
        login) cmd_login ;;
        enroll) cmd_enroll ;;
        layout) cmd_layout ;;
        creds) cmd_creds "$@" ;;
        reboot-time) cmd_reboot_time ;;
        status) cmd_status ;;
        shot) cmd_shot ;;
        ssh) cmd_ssh "$@" ;;
    esac
}

RECORD=''
HOST_FP=''
CREDS_USER=''
CREDS_PASS=''
ARG1=''
SKIP=0
main "$@"
