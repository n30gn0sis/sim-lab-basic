#!/usr/bin/env bash
#
# r770-gns3-deploy.sh — GNS3 server from the bundle's wheelhouse, offline,
# as a systemd service bound to 127.0.0.1 behind the portal.
#
#   r770-gns3-deploy.sh <subcommand> [--bundle <dir>] [options]
#
#   venv       python venv at /opt/gns3, gns3-server from the wheelhouse
#              (pip --no-index; refuses if a pip index is configured)
#   secrets    generate the GNS3 admin password file once (never printed)
#   config     service user, /etc/gns3 rendered from the kit template and
#              OWNED BY THE SERVICE USER, data dirs under /srv/gns3
#   service    install + enable the systemd unit, assert 127.0.0.1:3080  (GATED)
#   status     what is in place
#
#   GNS3_HOME /opt/gns3 · GNS3_USER gns3 · GNS3_ETC /etc/gns3 · GNS3_WAIT_SECS 60
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
GNS3_HOME="${GNS3_HOME:-/opt/gns3}"
GNS3_USER="${GNS3_USER:-gns3}"
GNS3_ETC="${GNS3_ETC:-/etc/gns3}"
WAIT_SECS="${GNS3_WAIT_SECS:-60}"
SECRET="/etc/lab/secrets/gns3-admin.pw"
usage() { usage_from_header 3 25; exit 0; }
venv() { p "$GNS3_HOME"; }

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

SUB="${1:-}"; [ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
    case "$1" in
        --bundle)  BUNDLE="${2:-}"; shift ;;
        -h|--help) usage ;;
        *)         common_flag "$1" || die "unknown option: $1 (try --help)" ;;
    esac
    shift
done
kit_init "r770-gns3-deploy"
case "$SUB" in
    venv)    cmd_venv ;;
    secrets) cmd_secrets ;;
    config)  cmd_config ;;
    service) cmd_service ;;
    status)  cmd_status ;;
    -h|--help|help|"") usage ;;
    *)       die "unknown subcommand: $SUB (try --help)" ;;
esac
