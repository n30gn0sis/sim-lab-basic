#!/usr/bin/env bash
#
# r770-gns3-deploy.sh — GNS3 server from the bundle's wheelhouse, offline,
# as a systemd service bound to 127.0.0.1 behind the front door.
#
#   r770-gns3-deploy.sh <subcommand> [--bundle <dir>] [options]
#
#   load         docker load the GNS3 docker-node images tarball, then
#                assert every tag
#   assert-tags  the tag check alone (docker load lies by omission)
#   venv       python venv at /opt/gns3, gns3-server from the wheelhouse
#              (pip --no-index; refuses if a pip index is configured)
#   secrets    generate the GNS3 admin password file once (never printed)
#   config     service user, /etc/gns3 rendered from the kit template and
#              OWNED BY THE SERVICE USER, data dirs under /srv/gns3
#   service    install + enable the systemd unit, assert 127.0.0.1:3080  (GATED)
#   labnet     the mirrored lab bridge: br-lab (hub mode), lab-tap0..N-1 for
#              GNS3 Cloud nodes, lab-mon0 <-> lab-mirror0 for Malcolm's
#              capture; systemd-networkd files, then proven from sysfs (GATED)
#   status     what is in place
#   full       the whole GNS3 pipeline, in order, stopping at the first step
#              that refuses: preflight gate copy apt phone-home docker files
#              load venv secrets config service labnet (see --from/--to/--only)
#
#   --bundle <dir>          the bundle (on the media for preflight/gate/copy
#                           under `full`, local after)
#   --media <mnt>           mountpoint of the transfer media, for `full`'s
#                           gate/copy steps (gate mounts, copy unmounts)
#   --device <dev>          block device to mount read-only at --media, for
#                           `full`'s gate step — a DISCOVERED name, never a
#                           guess
#   --from STEP / --to STEP restrict `full` to a slice of its steps
#   --only STEP             sugar for --from STEP --to STEP
#   GNS3_HOME /opt/gns3 · GNS3_USER gns3 · GNS3_ETC /etc/gns3 · GNS3_WAIT_SECS 60
#   GNS3_LAB_TAPS 4 · GNS3_LABNET_WAIT_SECS 10
#   --yes / --non-interactive / --dry-run / --force   as everywhere in the kit
#
#   0  done · 2  done with warnings · 1  refused or failed
#
# Rehearsal lessons this encodes (2026-09-12): python3-venv was assumed and
# absent (the venv came up with no pip); GNS3 v3 keeps its controller DB and
# JWT key BESIDE its config file, so a root-owned /etc/gns3 fails with
# 'unable to open database file'; a server started from a shell outlived its
# tmux session, hence a unit; `--no-index` is load-bearing or pip reaches for
# PyPI and hangs.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

BUNDLE=""
MEDIA=""; DEVICE=""; FROM=""; TO=""; ONLY=""
GNS3_HOME="${GNS3_HOME:-/opt/gns3}"
GNS3_USER="${GNS3_USER:-gns3}"
GNS3_ETC="${GNS3_ETC:-/etc/gns3}"
WAIT_SECS="${GNS3_WAIT_SECS:-60}"
SECRET="/etc/lab/secrets/gns3-admin.pw"
LAB_TAPS="${GNS3_LAB_TAPS:-4}"
LABNET_WAIT_SECS="${GNS3_LABNET_WAIT_SECS:-10}"
NETD="/etc/systemd/network"
LABNET_STAGE=""
STEPS=(preflight gate copy apt phone-home docker files load venv secrets config service labnet)
# test seam: lets a suite stub out every call this script makes to
# r770-import-bundle.sh under `full`, and record what was called.
IMPORT_BUNDLE_CMD="${IMPORT_BUNDLE_CMD:-$KIT_DIR/scripts/r770-import-bundle.sh}"
usage() { usage_from_header 3; exit 0; }
venv() { p "$GNS3_HOME"; }
local_bundle() {  # after copy, the bundle lives under /srv/bundles
    local l; l="$(p /srv/bundles)/$(basename "$BUNDLE")"
    if [ -d "$l" ]; then printf '%s' "$l"; else printf '%s' "$BUNDLE"; fi
}

# ── load / assert-tags (this script's own images, no longer shared) ─────────
cmd_assert_tags() {
    local b; b=$(bundle_dir "$BUNDLE") || exit 1
    assert_image_tags "$b/gns3/docker-nodes/image-list.txt" || die "image(s) missing after load — the tarball is incomplete or the load failed"
}
cmd_load() {
    command -v docker >/dev/null 2>&1 || die "docker is not installed — run 'r770-import-bundle.sh docker' first"
    local b tar; b=$(bundle_dir "$BUNDLE") || exit 1
    if [ "$FORCE" != "1" ] && assert_image_tags "$b/gns3/docker-nodes/image-list.txt" >/dev/null 2>&1; then
        echo "gns3/docker-nodes/image-list.txt: every tag already present — load skipped (--force to redo)"
        return 0
    fi
    tar="$b/gns3/docker-nodes/gns3-node-images.tar.gz"
    [ -s "$tar" ] || die "no gns3-node-images.tar.gz under $b/gns3/docker-nodes"
    echo "loading $tar ..."
    run docker load -i "$tar" || die "docker load failed"
    [ "$DRY" = "1" ] || cmd_assert_tags
}

cmd_venv() {
    banner "venv — gns3-server from the wheelhouse"
    need_root
    local b wh; b=$(bundle_dir "$BUNDLE") || exit 1
    require_pkg python3-venv
    [ -z "${PIP_INDEX_URL:-}${PIP_EXTRA_INDEX_URL:-}" ] || die "PIP_INDEX_URL/PIP_EXTRA_INDEX_URL is set — nothing on this box may point pip at an index; unset it"
    wh="$b/gns3/wheelhouse"
    [ -n "$(find "$wh" -maxdepth 1 -name '*.whl' 2>/dev/null | head -1)" ] || die "no wheels under $wh — this bundle's GNS3 category is empty"
    if [ -x "$(venv)/bin/gns3server" ] && [ "$FORCE" != "1" ]; then
        pass "venv already holds gns3server at $(venv) (--force to rebuild)"
    else
        run python3 -m venv "$(venv)" || die "python3 -m venv failed"
        [ "$DRY" = "1" ] || [ -x "$(venv)/bin/pip" ] || die "the venv has no pip — python3-venv (with python3-pip-whl) must come from the bundle's apt/"
        run "$(venv)/bin/pip" install --no-index --find-links "$wh" gns3-server \
            || die "pip install from the wheelhouse failed — the wheelhouse is incomplete; re-cut the bundle"
        pass "gns3-server installed from $wh with --no-index"
    fi
    if [ "$DRY" != "1" ] && [ -x "$(venv)/bin/gns3server" ]; then
        note "gns3server --version: $("$(venv)/bin/gns3server" --version 2>&1 | head -1)"
    fi
    footer "venv"
}

cmd_secrets() { banner "secrets"; need_root; secret_file "$(p "$SECRET")"; pass "admin credential location: $SECRET"; footer "secrets"; }

cmd_config() {
    banner "config — service user, config dir, data dirs"
    need_root
    local pw etc; etc="$(p "$GNS3_ETC")"
    pw=$(secret_read "$(p "$SECRET")") || exit 1
    if getent passwd "$GNS3_USER" >/dev/null 2>&1; then
        pass "service user $GNS3_USER exists"
    else
        run useradd --system --home-dir "$GNS3_ETC" --no-create-home --shell /usr/sbin/nologin "$GNS3_USER" || die "useradd $GNS3_USER failed"
        pass "service user $GNS3_USER created"
    fi
    local g
    for g in kvm docker; do
        if getent group "$g" >/dev/null 2>&1; then
            run usermod -aG "$g" "$GNS3_USER" && note "$GNS3_USER in group $g"
        else
            warn "group $g does not exist yet — add $GNS3_USER to it once that phase is built (usermod -aG $g $GNS3_USER)"
        fi
    done
    run mkdir -p "$etc"
    RENDER_MODE=0600 render "$KIT_CONFIG_DIR/gns3/gns3_server.conf.template" "$etc/gns3_server.conf" "ADMIN_PW=$pw" || exit 1
    # GNS3 v3 writes its controller database and JWT key beside the config.
    run chown -R "$GNS3_USER:$GNS3_USER" "$etc" && pass "$GNS3_ETC owned by $GNS3_USER (GNS3 writes its state there)"
    local d
    for d in /srv/gns3/projects /srv/gns3/images /srv/gns3/appliances /var/log/gns3; do
        run mkdir -p "$(p "$d")"
        run chown "$GNS3_USER:$GNS3_USER" "$(p "$d")"
    done
    pass "data dirs under /srv/gns3 and /var/log/gns3 owned by $GNS3_USER"
    footer "config"
}

svc_current() {
    printf '    unit: %s / %s\n' "$(systemctl is-enabled gns3 2>/dev/null || echo not-installed)" "$(systemctl is-active gns3 2>/dev/null || echo inactive)"
}
svc_proposed() {
    echo "    install /etc/systemd/system/gns3.service (from the kit's config/systemd/), daemon-reload, enable --now"
    sed 's/^/    | /' "$KIT_CONFIG_DIR/systemd/gns3.service"
}
cmd_service() {
    banner "service — systemd unit"
    need_root
    [ -x "$(venv)/bin/gns3server" ] || die "no gns3server at $(venv) — run venv first"
    [ -s "$(p "$GNS3_ETC")/gns3_server.conf" ] || die "no $GNS3_ETC/gns3_server.conf — run config first"
    gate "install and start the GNS3 systemd unit" svc_current svc_proposed \
        "systemctl disable --now gns3; rm /etc/systemd/system/gns3.service; systemctl daemon-reload"
    run install -m 0644 "$KIT_CONFIG_DIR/systemd/gns3.service" "$(p /etc/systemd/system)/gns3.service" || die "could not install the unit"
    run systemctl daemon-reload || die "daemon-reload failed"
    run systemctl enable --now gns3 || die "gns3.service did not start — journalctl -u gns3"
    [ "$DRY" = "1" ] && footer "service"
    local waited=0 ss_out step=5
    [ "$WAIT_SECS" -lt "$step" ] && step="$WAIT_SECS"
    while :; do
        ss_out=$(ss -ltn 2>/dev/null || true)
        if printf '%s\n' "$ss_out" | grep -qE '(0\.0\.0\.0|\*|\[::\]):3080 '; then
            fail "gns3server listens on all interfaces (:3080) — the config's host must stay 127.0.0.1; only nginx at gns3.lab may be reachable"
            break
        fi
        if printf '%s\n' "$ss_out" | grep -q '127\.0\.0\.1:3080 '; then
            pass "gns3server listening on 127.0.0.1:3080 after ${waited}s"
            break
        fi
        if [ "$waited" -ge "$WAIT_SECS" ]; then fail "nothing on 127.0.0.1:3080 after ${WAIT_SECS}s — journalctl -u gns3; a root-owned $GNS3_ETC is the usual cause"; break; fi
        sleep "$step"; waited=$((waited + step))
    done
    if command -v curl >/dev/null 2>&1; then
        note "API: $(curl -s --max-time 5 http://127.0.0.1:3080/v3/version 2>/dev/null || echo '(no answer yet)')"
    fi
    footer "service"
}

cmd_status() {
    banner "gns3 status"
    local owner
    local v=absent; [ -x "$(venv)/bin/gns3server" ] && v="$(venv)"
    printf '%-24s %s\n' "venv" "$v"
    owner=$(stat -c %U "$(p "$GNS3_ETC")" 2>/dev/null || echo absent)
    printf '%-24s %s (owner %s)\n' "config dir" "$GNS3_ETC" "$owner"
    printf '%-24s %s\n' "unit" "$(systemctl is-active gns3 2>/dev/null || echo not-installed)"
    printf '%-24s %s\n' "definitions" "$(find "$(p /srv/gns3/appliances)" -name '*.gns3a' 2>/dev/null | wc -l)"
    printf '%-24s %s\n' "images" "$(find "$(p /srv/gns3/images)" -maxdepth 1 -type f 2>/dev/null | wc -l)"
    printf '%-24s %s\n' "admin credential" "$([ -s "$(p "$SECRET")" ] && echo "present at $SECRET" || echo absent)"
    return 0
}

# ── labnet — the mirrored lab bridge ─────────────────────────────────────────
# br-lab runs with ageing_time 0, so it keeps no MAC table and floods every
# frame to every port -- including lab-mon0, whose veth peer lab-mirror0 is
# the interface Malcolm captures. A scenario puts a link on the bridge by
# binding a GNS3 Cloud node to a lab-tapN. Declared as systemd-networkd files
# so it survives a reboot and leaves netplan and every existing interface
# alone. The names are the kit's own: it creates them, it never picks one.
lab_names() {  # every interface name this step owns, one per line
    local i
    printf '%s\n' br-lab lab-mon0 lab-mirror0
    for ((i = 0; i < LAB_TAPS; i++)); do printf 'lab-tap%s\n' "$i"; done
}
lab_owner_file() {  # lab_owner_file <ifname> — the installed .netdev that declares it
    case "$1" in
        br-lab)               echo 05-br-lab.netdev ;;
        lab-mon0|lab-mirror0) echo 05-lab-mirror.netdev ;;
        *)                    echo "05-$1.netdev" ;;
    esac
}
labnet_stage() {  # labnet_stage <dir> — every file this step installs, rendered into <dir>
    local d=$1 src="$KIT_CONFIG_DIR/networkd" i
    cp "$src/br-lab.netdev" "$d/05-br-lab.netdev"
    cp "$src/br-lab.network" "$d/05-br-lab.network"
    cp "$src/lab-mirror.netdev" "$d/05-lab-mirror.netdev"
    cp "$src/lab-mon0.network" "$d/05-lab-mon0.network"
    cp "$src/lab-mirror0.network" "$d/05-lab-mirror0.network"
    for ((i = 0; i < LAB_TAPS; i++)); do
        DRY=0 render "$src/lab-tap.netdev.template" "$d/05-lab-tap$i.netdev" "TAP_NAME=lab-tap$i" "TAP_USER=$GNS3_USER" >/dev/null
        DRY=0 render "$src/lab-tap.network.template" "$d/05-lab-tap$i.network" "TAP_NAME=lab-tap$i" >/dev/null
    done
}
labnet_current() {
    local n sys; sys="$(p /sys/class/net)"
    for n in $(lab_names); do
        printf '    %-12s %s\n' "$n" "$([ -e "$sys/$n" ] && echo present || echo absent)"
    done
    printf '    kit files in %s: %s\n' "$NETD" "$(find "$(p "$NETD")" -maxdepth 1 -name '05-*lab*' -printf '%f ' 2>/dev/null)"
}
labnet_proposed() {
    local f
    echo "    install into $NETD, then networkctl reload:"
    for f in "$LABNET_STAGE"/*; do
        echo "    == $(basename "$f")"
        sed 's/^/    | /' "$f"
    done
}
labnet_wait() {  # the reload creates the links asynchronously; give it a moment
    local sys waited=0; sys="$(p /sys/class/net)"
    while [ ! -d "$sys/br-lab/bridge" ] || [ ! -e "$sys/lab-mirror0" ]; do
        [ "$waited" -ge "$LABNET_WAIT_SECS" ] && return 0
        sleep 1; waited=$((waited + 1))
    done
}
labnet_assert() {
    local sys b m n port at flags addrs missing="" phys=""
    sys="$(p /sys/class/net)"; b="$sys/br-lab"; m="$sys/lab-mirror0"
    if [ ! -d "$b/bridge" ]; then
        fail "br-lab did not appear after networkctl reload — networkctl status br-lab; journalctl -u systemd-networkd"
        return 0
    fi
    at=$(cat "$b/bridge/ageing_time" 2>/dev/null || echo unreadable)
    if [ "$at" = "0" ]; then pass "br-lab is in hub mode (ageing_time 0): every frame reaches lab-mon0"
    else fail "br-lab ageing_time is $at, not 0 — frames between two ports would not all reach the mirror"; fi
    for n in $(lab_names); do
        case "$n" in br-lab|lab-mirror0) continue ;; esac
        [ -e "$b/brif/$n" ] || missing="$missing $n"
    done
    if [ -z "$missing" ]; then pass "lab-mon0 and $LAB_TAPS TAP(s) are ports of br-lab"
    else fail "not ports of br-lab:$missing — networkctl status <name>"; fi
    for port in "$b"/brif/*; do
        [ -e "$port" ] || continue
        n=$(basename "$port")
        [ -e "$sys/$n/device" ] && phys="$phys $n"
    done
    if [ -z "$phys" ]; then pass "br-lab has no physical port (rule 8: capture ports never join the lab fabric)"
    else fail "physical interface(s) on br-lab:$phys — remove them; the lab fabric never touches a physical port"; fi
    flags=$(cat "$m/flags" 2>/dev/null || echo 0)
    if [ "$(cat "$m/operstate" 2>/dev/null)" = "up" ] && [ $(( flags & 0x100 )) -ne 0 ]; then pass "lab-mirror0 is up and promiscuous"
    else fail "lab-mirror0 is not up and promiscuous — networkctl status lab-mirror0"; fi
    addrs=$(ip -o addr show dev lab-mirror0 2>/dev/null | grep -c . || true)
    if [ "$addrs" -eq 0 ]; then pass "lab-mirror0 carries no address (IPv4, IPv6 or link-local)"
    else fail "lab-mirror0 has $addrs address(es) — the capture end must be silent; networkctl status lab-mirror0"; fi
}
cmd_labnet() {
    banner "labnet — the mirrored lab bridge"
    need_root
    case "$LAB_TAPS" in ''|*[!0-9]*) die "GNS3_LAB_TAPS must be a whole number (got '$LAB_TAPS')" ;; esac
    [ "$LAB_TAPS" -ge 1 ] || die "GNS3_LAB_TAPS must be at least 1"
    [ "$(systemctl is-active systemd-networkd 2>/dev/null)" = "active" ] \
        || die "systemd-networkd is not active — the lab network is declared as networkd files, which would do nothing without it"
    getent passwd "$GNS3_USER" >/dev/null 2>&1 || die "service user $GNS3_USER does not exist — run config first (the TAPs are owned by it)"
    local n sys netd f i rb changed=0
    sys="$(p /sys/class/net)"; netd="$(p "$NETD")"
    for n in $(lab_names); do
        if [ -e "$sys/$n" ] && [ ! -e "$netd/$(lab_owner_file "$n")" ]; then
            die "interface $n already exists and no kit file ($NETD/$(lab_owner_file "$n")) declares it — something else owns that name; nothing was changed"
        fi
    done
    LABNET_STAGE=$(mktemp -d)
    trap 'rm -rf "$LABNET_STAGE"' EXIT
    labnet_stage "$LABNET_STAGE"
    for f in "$LABNET_STAGE"/*; do cmp -s "$f" "$netd/$(basename "$f")" || changed=1; done
    if [ "$changed" -eq 0 ]; then
        pass "lab network files already in place in $NETD"
    else
        rb="rm $NETD/05-*lab*; networkctl reload; ip link del br-lab; ip link del lab-mon0"
        for ((i = 0; i < LAB_TAPS; i++)); do rb="$rb; ip link del lab-tap$i"; done
        gate "install the mirrored lab bridge (br-lab)" labnet_current labnet_proposed "$rb"
        run mkdir -p "$netd" || die "could not create $NETD"
        for f in "$LABNET_STAGE"/*; do
            run install -m 0644 "$f" "$netd/$(basename "$f")" || die "could not install $(basename "$f")"
        done
        run networkctl reload || die "networkctl reload failed — journalctl -u systemd-networkd"
        [ "$DRY" = "1" ] || pass "$(find "$LABNET_STAGE" -type f | wc -l) networkd files installed into $NETD"
    fi
    [ "$DRY" = "1" ] && footer "labnet"
    labnet_wait
    labnet_assert
    footer "labnet"
}

# ── full ─────────────────────────────────────────────────────────────────────
# The whole GNS3 pipeline, in order, stopping at the first step that refuses.
# Independent of r770-malcolm-deploy.sh's own `full` and of the retired
# r770-deploy.sh, whose child()/stage_index() this script's run_step/step_index
# (scripts/lib/common.sh) grew out of: this script now brings its own bundle
# in from the media rather than being handed an already-copied one by an
# outer orchestrator.
cmd_full() {
    [ -n "$BUNDLE" ] || die "--bundle <dir> is required for full (try --help)"
    local first last i step
    first=0; last=$(( ${#STEPS[@]} - 1 ))
    [ -z "$FROM" ] || first=$(step_index STEPS "$FROM") || die "unknown step: $FROM (see --help)"
    [ -z "$TO" ]   || last=$(step_index STEPS "$TO")    || die "unknown step: $TO (see --help)"
    [ "$first" -le "$last" ] || die "--from $FROM comes after --to $TO"
    # Resolve the local copy BEFORE the loop, not only inside the copy) arm
    # below: a resumed run (--from past copy) never executes that arm, so
    # BUNDLE would otherwise still point at --bundle's original media path
    # (already unmounted) for every in-process step. local_bundle() falls
    # back to the raw path when the copy hasn't landed yet, so this is safe
    # on a fresh run too.
    BUNDLE="$(local_bundle)"
    echo "bundle: $BUNDLE"; [ -n "$MEDIA" ] && echo "media: $MEDIA${DEVICE:+ ($DEVICE)}"
    echo "steps: ${STEPS[*]:$first:$((last - first + 1))}"
    WARNED_STEPS=""
    for i in $(seq "$first" "$last"); do
        step="${STEPS[$i]}"
        banner "$(( i + 1 ))/${#STEPS[@]}  $step"
        case "$step" in
            preflight) run_step "$step" "$IMPORT_BUNDLE_CMD" preflight --bundle "$BUNDLE" ;;
            gate)
                if [ -n "$DEVICE" ]; then run_step "$step" "$IMPORT_BUNDLE_CMD" gate --bundle "$BUNDLE" --media "$MEDIA" --device "$DEVICE"
                else run_step "$step" "$IMPORT_BUNDLE_CMD" gate --bundle "$BUNDLE"; fi ;;
            copy)
                if [ -n "$MEDIA" ]; then run_step "$step" "$IMPORT_BUNDLE_CMD" copy --bundle "$BUNDLE" --media "$MEDIA"
                else run_step "$step" "$IMPORT_BUNDLE_CMD" copy --bundle "$BUNDLE"; fi
                BUNDLE="$(local_bundle)" ;;   # now the copy has landed, so this always resolves
            apt|phone-home|docker|files) run_step "$step" "$IMPORT_BUNDLE_CMD" "$step" --bundle "$(local_bundle)" ;;
            load)    run_step "$step" cmd_load ;;
            venv)    run_step "$step" cmd_venv ;;
            secrets) run_step "$step" cmd_secrets ;;
            config)  run_step "$step" cmd_config ;;
            service) run_step "$step" cmd_service ;;
            labnet)  run_step "$step" cmd_labnet ;;
        esac
    done
    echo
    if [ -n "$WARNED_STEPS" ]; then
        echo "DEPLOYED WITH WARNINGS — steps:$WARNED_STEPS. Disposition each in the cycle log; evidence under ${KIT_EVIDENCE_DIR:-./r770-evidence}"
        exit 2
    fi
    echo "DEPLOYED — every step clean; evidence under ${KIT_EVIDENCE_DIR:-./r770-evidence}"
    exit 0
}

SUB="${1:-}"; [ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
    case "$1" in
        --bundle)  BUNDLE="${2:-}"; shift ;;
        --media)   MEDIA="${2:-}"; shift ;;
        --device)  DEVICE="${2:-}"; shift ;;
        --from)    FROM="${2:-}"; shift ;;
        --to)      TO="${2:-}"; shift ;;
        --only)    ONLY="${2:-}"; shift ;;
        -h|--help) usage ;;
        *)         common_flag "$1" || die "unknown option: $1 (try --help)" ;;
    esac
    shift
done
[ -n "$ONLY" ] && { FROM="$ONLY"; TO="$ONLY"; }
kit_init "r770-gns3-deploy"
case "$SUB" in
    load)        cmd_load ;;
    assert-tags) cmd_assert_tags ;;
    venv)    cmd_venv ;;
    secrets) cmd_secrets ;;
    config)  cmd_config ;;
    service) cmd_service ;;
    labnet)  cmd_labnet ;;
    status)  cmd_status ;;
    full)    cmd_full ;;
    -h|--help|help|"") usage ;;
    *)       die "unknown subcommand: $SUB (try --help)" ;;
esac
