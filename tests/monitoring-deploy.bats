#!/usr/bin/env bats
#
# The monitoring stack's images come from the bundle's list, which is longer
# than the compose file and in no fixed order; the ports must bind loopback;
# nothing may pull. Each is asserted here.

load helpers/fixtures
load helpers/stubs

setup() {
    kit_test_env
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-monitoring-deploy.sh"
    BUNDLE="$BATS_TEST_TMPDIR/bundle-fixture"
    make_bundle "$BUNDLE"
    make_root "$ROOT"
    export ROOT MON_WAIT_SECS=1
    echo "ca" > "$ROOT/etc/nginx/ssl/ca.crt"
    stub dpkg 'exit 0'
    stub_log systemctl
    stub docker 'echo "docker $*" >> "$STUB_LOG"
case "$*" in *" ps "*) printf "prometheus running\nalertmanager running\ngrafana running\ncadvisor running\nblackbox running\n";; esac
exit 0'
    stub ss 'for p in 9090 9093 3000 8080 9115; do echo "LISTEN 0 128 127.0.0.1:$p 0.0.0.0:*"; done'
    stub curl 'echo "{\"data\":{\"activeTargets\":[{\"health\":\"up\"},{\"health\":\"up\"}]}}"'
}

mon() { kit_run "$SCRIPT" "$@"; }

@test "env maps every compose variable by repository name, not by list position" {
    run mon env --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    e="$ROOT/opt/monitoring/.env"
    grep -qx 'PROMETHEUS_IMAGE=docker.io/prom/prometheus:v0.0.0-fixture' "$e"
    grep -qx 'ALERTMANAGER_IMAGE=docker.io/prom/alertmanager:v0.0.0-fixture' "$e"
    grep -qx 'GRAFANA_IMAGE=docker.io/grafana/grafana-oss:0.0.0-fixture' "$e"
    grep -qx 'CADVISOR_IMAGE=ghcr.io/google/cadvisor:v0.0.0-fixture' "$e"
    grep -qx 'BLACKBOX_IMAGE=docker.io/prom/blackbox-exporter:v0.0.0-fixture' "$e"
    [ "$(wc -l < "$e")" -eq 5 ]
    [ "$(stat -c %a "$e")" = "640" ]
}

@test "env dies naming the variable it cannot set when an image is missing from the list" {
    grep -v blackbox "$BUNDLE/docker/monitoring-image-list.txt" > "$BATS_TEST_TMPDIR/l" && mv "$BATS_TEST_TMPDIR/l" "$BUNDLE/docker/monitoring-image-list.txt"
    run mon env --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"BLACKBOX_IMAGE"* ]]
    [ ! -e "$ROOT/opt/monitoring/.env" ]
}

@test "env renders the compose with the secrets dir and no token or staging path, and creates the Grafana secret once" {
    run mon env --bundle "$BUNDLE"
    [ "$status" -eq 0 ]
    c="$ROOT/opt/monitoring/docker-compose.yml"
    grep -q 'env_file: /etc/lab/secrets/grafana-admin.env' "$c"
    ! grep -qE '__|/home/ubuntu' "$c"
    s="$ROOT/etc/lab/secrets/grafana-admin.env"
    [ "$(stat -c %a "$s")" = "600" ]
    grep -qE '^GF_SECURITY_ADMIN_PASSWORD=.{32}$' "$s"
    pw=$(cut -d= -f2 "$s")
    [[ "$output" != *"$pw"* ]]
    run mon env --bundle "$BUNDLE"
    [ "$(cut -d= -f2 "$s")" = "$pw" ]
    [ -f "$ROOT/opt/monitoring/grafana/provisioning/datasources/prometheus.yml" ]
}

@test "up brings the stack up with --pull never and asserts loopback ports and healthy targets" {
    mon env --bundle "$BUNDLE" >/dev/null
    run mon up
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q "^docker compose --project-directory $ROOT/opt/monitoring --env-file $ROOT/opt/monitoring/.env up -d --pull never" "$STUB_LOG"
    grep -q '^systemctl enable --now prometheus-node-exporter' "$STUB_LOG"
    for p in 9090 9093 3000 8080 9115; do [[ "$output" == *"PASS  port $p on 127.0.0.1 only"* ]]; done
    [[ "$output" == *"every Prometheus target up (2)"* ]]
}

@test "up FAILs when a port is published on all interfaces" {
    mon env --bundle "$BUNDLE" >/dev/null
    stub ss 'echo "LISTEN 0 128 0.0.0.0:3000 0.0.0.0:*"; for p in 9090 9093 8080 9115; do echo "LISTEN 0 128 127.0.0.1:$p 0.0.0.0:*"; done'
    run mon up
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  port 3000 is published on all interfaces"* ]]
}

@test "up FAILs when a Prometheus target is down" {
    mon env --bundle "$BUNDLE" >/dev/null
    stub curl 'echo "{\"data\":{\"activeTargets\":[{\"health\":\"up\"},{\"health\":\"down\"}]}}"'
    run mon up
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"1 Prometheus target(s) not up"* ]]
}

@test "up refuses before env has run" {
    run mon up
    [ "$status" -eq 1 ]
    [[ "$output" == *"run env first"* ]]
}

@test "down keeps the volumes unless --purge-volumes is given AND the gate is passed" {
    mon env --bundle "$BUNDLE" >/dev/null
    run mon down
    [ "$status" -eq 0 ]
    grep -q ' down$' "$STUB_LOG"
    ! grep -q ' down -v' "$STUB_LOG"
    unset KIT_YES
    run mon down --purge-volumes --non-interactive
    [ "$status" -eq 1 ]
    ! grep -q ' down -v' "$STUB_LOG"
    run mon down --purge-volumes --yes
    [ "$status" -eq 0 ]
    grep -q ' down -v' "$STUB_LOG"
}
