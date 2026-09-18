#!/usr/bin/env bash
#
# r770-monitoring-deploy.sh — Prometheus, Alertmanager, Grafana, cAdvisor and
# blackbox from the bundle's images, every port on 127.0.0.1 behind the portal.
#
#   r770-monitoring-deploy.sh <subcommand> [--bundle <dir>] [options]
#
#   env      derive /opt/monitoring/.env from the bundle's image list (by
#            repository name, never by position), render the compose file,
#            create the Grafana admin secret once
#   up       node exporter enabled; docker compose up -d --pull never;
#            ports asserted on 127.0.0.1; every Prometheus target up
#   down     docker compose down (volumes kept unless --purge-volumes, GATED)
#   status   what is running
#
#   MON_DIR /opt/monitoring · SECRETS_DIR /etc/lab/secrets · MON_WAIT_SECS 120
#   --yes / --non-interactive / --dry-run / --force   as everywhere in the kit
#
#   0  done · 2  done with warnings · 1  refused or failed
#
# The image list carries more images than this stack uses and in no fixed
# order, so the .env maps each compose variable to a repository name.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

BUNDLE=""; PURGE=0
MON_DIR="${MON_DIR:-/opt/monitoring}"
SECRETS_DIR="${SECRETS_DIR:-/etc/lab/secrets}"
WAIT_SECS="${MON_WAIT_SECS:-120}"
PORTS="9090 9093 3000 8080 9115"
IMAGE_VARS=(PROMETHEUS_IMAGE=prometheus ALERTMANAGER_IMAGE=alertmanager GRAFANA_IMAGE=grafana-oss
            CADVISOR_IMAGE=cadvisor BLACKBOX_IMAGE=blackbox-exporter)
usage() { usage_from_header 3; exit 0; }
mon() { p "$MON_DIR"; }

grafana_secret() {  # GF_SECURITY_ADMIN_PASSWORD=<value>, generated once, 0600, never printed
    local f pw; f="$(p "$SECRETS_DIR")/grafana-admin.env"
    if [ -s "$f" ] && [ "$FORCE" != "1" ]; then echo "secret present: $f (use --force to regenerate)"; return 0; fi
    [ "$DRY" = "1" ] && { echo "DRY-RUN: generate $f"; return 0; }
    mkdir -p "$(p "$SECRETS_DIR")"; chmod 0700 "$(p "$SECRETS_DIR")"
    pw=$(head -c 48 /dev/urandom | base64 | tr -d '/+=\n' | head -c 32)
    ( umask 077; printf 'GF_SECURITY_ADMIN_PASSWORD=%s\n' "$pw" > "$f" )
    chmod 0600 "$f"
    echo "generated secret: $f (0600) — the value is never printed or logged"
}

cmd_env() {
    banner "env — image variables from the bundle, compose rendered"
    need_root
    local b list kv var name ref envf; b=$(bundle_dir "$BUNDLE") || exit 1
    list="$b/docker/monitoring-image-list.txt"
    [ -s "$list" ] || die "$list missing — this bundle carries no monitoring images"
    run mkdir -p "$(mon)"
    envf="$(mon)/.env"
    local content=""
    for kv in "${IMAGE_VARS[@]}"; do
        var=${kv%%=*}; name=${kv#*=}
        ref=$(image_ref_from_list "$list" "$name") || die "cannot set $var: no image named '$name' in $list"
        content="${content}${var}=${ref}"$'\n'
        note "$var=$ref"
    done
    if [ "$DRY" = "1" ]; then echo "DRY-RUN: write $envf"; else printf '%s' "$content" > "$envf"; chmod 0640 "$envf"; fi
    pass ".env written from the bundle's list (${#IMAGE_VARS[@]} images)"
    grafana_secret
    render "$KIT_CONFIG_DIR/monitoring/docker-compose.yml" "$(mon)/docker-compose.yml" "SECRETS_DIR=$SECRETS_DIR" || exit 1
    local f
    for f in prometheus.yml alertmanager.yml blackbox.yml; do
        run install -m 0644 "$KIT_CONFIG_DIR/monitoring/$f" "$(mon)/$f" || die "could not install $f"
    done
    run rm -rf "$(mon)/grafana"
    run cp -a "$KIT_CONFIG_DIR/monitoring/grafana" "$(mon)/grafana"
    pass "compose, prometheus, alertmanager, blackbox and grafana provisioning in $MON_DIR"
    [ -s "$(p /etc/nginx/ssl)/ca.crt" ] || warn "no /etc/nginx/ssl/ca.crt yet — blackbox mounts it; run 'r770-portal-deploy.sh ca' before up"
    footer "env"
}

compose() { docker compose --project-directory "$(mon)" --env-file "$(mon)/.env" "$@"; }

cmd_up() {
    banner "up — the stack, from loaded images only"
    need_root
    { [ -s "$(mon)/.env" ] && [ -s "$(mon)/docker-compose.yml" ]; } || die "no $MON_DIR/.env or compose file — run env first"
    [ -s "$(p "$SECRETS_DIR")/grafana-admin.env" ] || die "no $SECRETS_DIR/grafana-admin.env — run env first"
    require_pkg prometheus-node-exporter
    run systemctl enable --now prometheus-node-exporter || warn "prometheus-node-exporter did not start — the node job will be down"
    run docker compose --project-directory "$(mon)" --env-file "$(mon)/.env" up -d --pull never || die "compose up failed — are the monitoring images loaded (images stage)?"
    [ "$DRY" = "1" ] && footer "up"
    local waited=0 out notready step=5
    [ "$WAIT_SECS" -lt "$step" ] && step="$WAIT_SECS"
    while :; do
        out=$(compose ps --format '{{.Service}} {{.State}}' 2>/dev/null || true)
        notready=$(printf '%s\n' "$out" | grep -v ' running$' | grep -c . || true)
        [ -n "$out" ] && [ "$notready" -eq 0 ] && { pass "all services running after ${waited}s"; break; }
        if [ "$waited" -ge "$WAIT_SECS" ]; then printf '%s\n' "$out" | sed 's/^/      /'; fail "$notready service(s) not running after ${WAIT_SECS}s"; break; fi
        sleep "$step"; waited=$((waited + step))
    done
    local ss_out port; ss_out=$(ss -ltn 2>/dev/null || true)
    for port in $PORTS; do
        if printf '%s\n' "$ss_out" | grep -qE "(0\.0\.0\.0|\*|\[::\]):$port "; then
            fail "port $port is published on all interfaces — every monitoring port must bind 127.0.0.1 (nginx at monitoring.lab is the way in)"
        elif printf '%s\n' "$ss_out" | grep -q "127\.0\.0\.1:$port "; then
            pass "port $port on 127.0.0.1 only"
        else
            warn "port $port not listening (yet)"
        fi
    done
    local targets up down
    targets=$(curl -s --max-time 10 http://127.0.0.1:9090/prometheus/api/v1/targets 2>/dev/null || true)
    up=$(printf '%s' "$targets" | grep -o '"health":"up"' | wc -l)
    down=$(printf '%s' "$targets" | grep -o '"health":"[a-z]*"' | grep -vc '"up"' || true)
    if [ -z "$targets" ]; then
        warn "Prometheus targets not readable yet at 127.0.0.1:9090/prometheus/ — check again in a minute (validate monitoring)"
    elif [ "$down" -gt 0 ]; then
        fail "$down Prometheus target(s) not up ($up up) — see /prometheus/targets via the portal"
    else
        pass "every Prometheus target up ($up)"
    fi
    footer "up"
}

down_current() { compose ps --format '{{.Service}} {{.State}}' 2>/dev/null | sed 's/^/    /' || true; }
down_proposed() { echo "    docker compose down -v — REMOVES the Prometheus and Grafana data volumes (metrics history, dashboards)"; }
cmd_down() {
    banner "down"
    need_root
    [ -s "$(mon)/docker-compose.yml" ] || die "no compose file at $MON_DIR"
    if [ "$PURGE" = "1" ]; then
        gate "purge the monitoring data volumes" down_current down_proposed "none — the volumes are gone; the stack comes back empty with 'up'"
        run docker compose --project-directory "$(mon)" --env-file "$(mon)/.env" down -v || die "compose down -v failed"
        pass "stack down, volumes removed"
    else
        run docker compose --project-directory "$(mon)" --env-file "$(mon)/.env" down || die "compose down failed"
        pass "stack down, data volumes kept (--purge-volumes removes them)"
    fi
    footer "down"
}

cmd_status() {
    banner "monitoring status"
    printf '%-20s %s\n' ".env" "$([ -s "$(mon)/.env" ] && echo present || echo absent)"
    printf '%-20s %s\n' "grafana secret" "$([ -s "$(p "$SECRETS_DIR")/grafana-admin.env" ] && echo "present at $SECRETS_DIR/grafana-admin.env" || echo absent)"
    [ -s "$(mon)/docker-compose.yml" ] && command -v docker >/dev/null 2>&1 && compose ps --format '{{.Service}} {{.State}}' 2>/dev/null | sed 's/^/    /'
    return 0
}

SUB="${1:-}"; [ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
    case "$1" in
        --bundle)        BUNDLE="${2:-}"; shift ;;
        --purge-volumes) PURGE=1 ;;
        -h|--help)       usage ;;
        *)               common_flag "$1" || die "unknown option: $1 (try --help)" ;;
    esac
    shift
done
kit_init "r770-monitoring-deploy"
case "$SUB" in
    env)    cmd_env ;;
    up)     cmd_up ;;
    down)   cmd_down ;;
    status) cmd_status ;;
    -h|--help|help|"") usage ;;
    *)      die "unknown subcommand: $SUB (try --help)" ;;
esac
