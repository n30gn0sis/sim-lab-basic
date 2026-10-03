#!/usr/bin/env bash
#
# r770-install.sh — the offline installer. Takes an R770 with Ubuntu 24.04
# installed, plus the bundle media, to a proven lab in one gated,
# re-enterable run. A thin sequencer: every step is an existing kit entry
# point, called with arguments read from install.conf; no pipeline logic
# lives here, and each pipeline still runs on its own.
#
#   r770-install.sh <subcommand> [options]
#
#   discover   print disks, NICs, addresses, bridges, mounts; write
#              install.conf.template (every value empty: nothing is chosen for you)
#   wizard     pick each value from numbered lists of what discover found;
#              write install.conf
#   plan       check install.conf and the image store, then every gated step
#              under --dry-run: the whole current/proposed/rollback review at once
#   run        import gns3 malcolm docs portal dashboards validate e2e, in order;
#              stops at the first FAIL; re-enter with --from <step>
#   status     which of those steps this host has finished
#
#   --conf FILE              the answers file (default /etc/lab/install.conf)
#   --from STEP / --to STEP  a slice of run's steps
#   --yes / --non-interactive / --dry-run / --force   as everywhere in the kit
#                            (run --yes is unattended: it also implies --non-interactive)
#
#   INSTALL_IMPORT_CMD INSTALL_GNS3_CMD INSTALL_MALCOLM_CMD INSTALL_DOCS_CMD
#   INSTALL_PORTAL_CMD INSTALL_VALIDATE_CMD INSTALL_E2E_CMD   the children (tests stub them)
#
#   0  INSTALLED · 2  finished with warnings (never INSTALLED) · 1  refused or failed
#
# Started from the media, `run` imports the bundle (preflight, gate, copy —
# copy WITHOUT --media, so nothing unmounts the media this script is running
# from) and then execs the installer inside the local copy under
# /srv/bundles/<name>/kit, which carries on from gns3. Unmounting the media
# is the operator's last step; the summary prints the command.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

STEPS=(import gns3 malcolm docs portal dashboards validate e2e)
CONF_KEYS="BUNDLE MEDIA DEVICE CAPTURE_IFS LAB_BRIDGE MGMT_IF MGMT_CIDR VALIDATE_AREAS"
REQUIRED_KEYS="MEDIA DEVICE CAPTURE_IFS LAB_BRIDGE MGMT_IF MGMT_CIDR"
LATE_IFS="lab_mirror0"        # created by the gns3 step's labnet, so it may not exist yet
IMPORT="${INSTALL_IMPORT_CMD:-$KIT_DIR/scripts/r770-import-bundle.sh}"
GNS3="${INSTALL_GNS3_CMD:-$KIT_DIR/scripts/r770-gns3-deploy.sh}"
MALCOLM="${INSTALL_MALCOLM_CMD:-$KIT_DIR/scripts/r770-malcolm-deploy.sh}"
DOCS="${INSTALL_DOCS_CMD:-$KIT_DIR/scripts/r770-docs-deploy.sh}"
PORTAL="${INSTALL_PORTAL_CMD:-$KIT_DIR/scripts/r770-portal-deploy.sh}"
VALIDATE="${INSTALL_VALIDATE_CMD:-$KIT_DIR/scripts/r770-validate.sh}"
E2E="${INSTALL_E2E_CMD:-$KIT_DIR/scripts/r770-e2e.sh}"
SUB=""; CONF_PATH=""; FROM=""; TO=""
usage() { usage_from_header 3; exit 0; }

# ── install.conf ─────────────────────────────────────────────────────────────
conf_get() { local n="CONF_$1"; printf '%s' "${!n:-}"; }

# conf_load <file> — KEY=value lines into CONF_<KEY>. Parsed, never sourced:
# operator text is never evaluated. CR, surrounding blanks and one pair of
# double quotes are stripped, so a file edited on Windows reads the same.
conf_load() {
    local f=$1 line key val n=0
    [ -f "$f" ] || die "no answers file at $f — run 'r770-install.sh discover' (or wizard) first, then fill it in"
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line=${line%$'\r'}
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
        case "$line" in ''|'#'*) continue ;; esac
        [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]] || die "$f:$n: not KEY=value: $line"
        key=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}
        val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
        [[ "$val" == \"*\" ]] && { val=${val#\"}; val=${val%\"}; }
        case " $CONF_KEYS " in *" $key "*) ;; *) die "$f:$n: unknown key $key (known: $CONF_KEYS)" ;; esac
        printf -v "CONF_$key" '%s' "$val"
    done < "$f"
}

is_placeholder() {
    case "$1" in *'<'*|*'>'*|*CHANGEME*|*changeme*|/dev/sdX|/dev/sdX[0-9]*) return 0 ;; esac
    return 1
}
host_ifs()     { ip -br link 2>/dev/null | awk '{print $1}' | sed 's/@.*//'; }
host_devices() { lsblk -lpno NAME 2>/dev/null | awk '{print $1}'; }
has_line()     { printf '%s\n' "$2" | grep -qxF -- "$1"; }

# self_bundle — the bundle this installer sits in (kit/scripts/.. /..), or nothing.
self_bundle() {
    local cand; cand=$(cd "$KIT_DIR/.." 2>/dev/null && pwd -P) || return 0
    ( bundle_dir "$cand" ) >/dev/null 2>&1 && printf '%s' "$cand"
    return 0
}

# conf_check — every bad value is its own FAIL row; then one die, so the
# operator fixes the whole file in one pass.
conf_check() {
    local k v ifs devs i bad=0
    for k in $REQUIRED_KEYS; do
        v=$(conf_get "$k")
        if [ -z "$v" ]; then fail "install.conf: $k is empty — fill it from 'discover' output"; bad=1
        elif is_placeholder "$v"; then fail "install.conf: $k is a placeholder ($v) — never executed"; bad=1; fi
    done
    ifs=$(host_ifs); devs=$(host_devices)
    v=$CONF_DEVICE
    if [ -n "$v" ] && ! is_placeholder "$v" && ! has_line "$v" "$devs"; then
        fail "install.conf: DEVICE $v is not a block device on this host (lsblk)"; bad=1
    fi
    v=$CONF_MGMT_IF
    if [ -n "$v" ] && ! is_placeholder "$v" && ! has_line "$v" "$ifs"; then
        fail "install.conf: MGMT_IF $v does not exist on this host (ip -br link)"; bad=1
    fi
    for i in $CONF_CAPTURE_IFS; do
        if has_line "$i" "$ifs"; then continue; fi
        case " $LATE_IFS " in
            *" $i "*) note "CAPTURE_IFS: $i is not here yet — created by the gns3 step's labnet" ;;
            *) fail "install.conf: CAPTURE_IFS: $i does not exist on this host (ip -br link)"; bad=1 ;;
        esac
    done
    if [ -n "$CONF_LAB_BRIDGE" ] && ! has_line "$CONF_LAB_BRIDGE" "$ifs"; then
        note "LAB_BRIDGE: $CONF_LAB_BRIDGE is not here yet — created by the gns3 step's labnet"
    fi
    v=$CONF_MGMT_CIDR
    if [ -n "$v" ] && ! is_placeholder "$v" && ! [[ "$v" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
        fail "install.conf: MGMT_CIDR $v is not a.b.c.d/n"; bad=1
    fi
    if [ -z "$CONF_BUNDLE" ]; then
        CONF_BUNDLE=$(self_bundle)
        if [ -n "$CONF_BUNDLE" ]; then note "BUNDLE: the bundle this installer came in — $CONF_BUNDLE"
        else fail "install.conf: BUNDLE is empty and this installer is not inside a bundle — set BUNDLE=<the bundle directory on the media>"; bad=1; fi
    elif ! ( bundle_dir "$CONF_BUNDLE" ) >/dev/null 2>&1; then
        fail "install.conf: BUNDLE $CONF_BUNDLE is not a bundle (r770-bundle.sh, BUNDLE_NOTES.md, MANIFEST.sha256 at its root)"; bad=1
    else
        CONF_BUNDLE=$(cd "$CONF_BUNDLE" && pwd)
    fi
    [ "$bad" = 0 ] || die "install.conf ($CONF_PATH) refused — fix every FAIL above; nothing ran"
}

conf_ready() {
    local k; for k in $CONF_KEYS; do printf -v "CONF_$k" '%s' ""; done
    conf_load "$CONF_PATH"
    conf_check
}

# ── discover ─────────────────────────────────────────────────────────────────
cmd_discover() {
    banner "discover — what this host has (nothing is chosen for you)"
    local tpl cand
    tpl="${CONF_PATH}.template"
    echo "-- block devices (DEVICE: the transfer media's device) --"; lsblk -lpno NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null || echo "   (lsblk unavailable)"
    echo "-- mounts (MEDIA: where the media is mounted) --";            findmnt -lno TARGET,SOURCE 2>/dev/null || echo "   (findmnt unavailable)"
    echo "-- interfaces (MGMT_IF; capture ports for CAPTURE_IFS) --";   ip -br addr 2>/dev/null || echo "   (ip unavailable)"
    echo "-- bridges (LAB_BRIDGE once labnet exists) --";               ip -br link show type bridge 2>/dev/null || true
    cand=$(self_bundle)
    mkdir -p "$(dirname "$tpl")" || die "cannot create $(dirname "$tpl")"
    cat > "$tpl" <<EOF
# install.conf — template written by r770-install.sh discover on $(hostname -s 2>/dev/null || echo host), $(date -Is).
# Fill in every value from the discovery output; nothing has been chosen for you.
# Save the result as $CONF_PATH (or pass --conf), then: r770-install.sh plan
#
# BUNDLE: the bundle directory. Empty means the bundle this installer came in: ${cand:-none found}
BUNDLE=
# MEDIA: where the transfer media is mounted (see "mounts" above)
MEDIA=
# DEVICE: the media's block device, e.g. a partition of the USB disk (see "block devices" above)
DEVICE=
# CAPTURE_IFS: Malcolm's capture interfaces, space separated: lab_mirror0 (the lab mirror) plus any physical tap port
CAPTURE_IFS=
# LAB_BRIDGE: the lab bridge the gns3 step's labnet creates (r770-gns3-deploy.sh: br-lab)
LAB_BRIDGE=
# MGMT_IF: the management interface (see "interfaces" above)
MGMT_IF=
# MGMT_CIDR: the management network, a.b.c.d/n
MGMT_CIDR=
# VALIDATE_AREAS: optional, space separated; empty means every area (r770-validate.sh --list)
VALIDATE_AREAS=
EOF
    pass "template written: $tpl — fill it in and save it as $CONF_PATH"
    footer "discover"
}

# ── arguments ────────────────────────────────────────────────────────────────
[ $# -gt 0 ] || usage
SUB=$1; shift
while [ $# -gt 0 ]; do
    case "$1" in
        --conf)     CONF_PATH="${2:-}"; shift ;;
        --from)     FROM="${2:-}"; shift ;;
        --to)       TO="${2:-}"; shift ;;
        -h|--help)  usage ;;
        *)          common_flag "$1" || die "unknown option: $1 (try --help)" ;;
    esac
    shift
done
CONF_PATH="${CONF_PATH:-$(p /etc/lab/install.conf)}"

kit_init "r770-install"
case "$SUB" in
    discover) cmd_discover ;;
    run)      need_root; conf_ready; die "run: not implemented yet" ;;
    -h|--help|help) usage ;;
    *)        die "unknown subcommand: $SUB (try --help)" ;;
esac
