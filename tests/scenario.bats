#!/usr/bin/env bats
#
# r770-scenario.sh against a fake GNS3 controller (tests/helpers/fake_gns3.py
# behind a curl stub) and a stubbed docker. The scenarios here are fixtures
# under $BATS_TEST_TMPDIR; the real pack is linted by tests/scenarios.bats.

load helpers/fixtures
load helpers/stubs

setup() {
    kit_test_env
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-scenario.sh"
    BUNDLE="$BATS_TEST_TMPDIR/bundle-fixture"
    make_bundle "$BUNDLE"
    make_root "$ROOT"
    echo 'docker.io/nicolaka/netshoot:0.0.0-fixture' >> "$BUNDLE/gns3/docker-nodes/image-list.txt"
    export ROOT BATS_TEST_TMPDIR
    export SCENARIO_DIR="$BATS_TEST_TMPDIR/scenarios" SCENARIO_WAIT_SECS=4
    export FAKE_GNS3="$BATS_TEST_TMPDIR/gns3"
    mkdir -p "$FAKE_GNS3" "$ROOT/etc/lab/secrets"
    echo fixture-pw > "$ROOT/etc/lab/secrets/gns3-admin.pw"
    for i in 0 1 2 3; do mkdir -p "$ROOT/sys/class/net/lab-tap$i"; done
    make_demo_scenario
    stub curl "echo \"curl \$*\" >> \"\$STUB_LOG\"; exec python3 \"$BATS_TEST_DIRNAME/helpers/fake_gns3.py\" \"\$@\""
    stub sleep 'exit 0'
    stub hostname 'echo fixturehost'
    echo 'docker.io/nicolaka/netshoot:0.0.0-fixture' > "$BATS_TEST_TMPDIR/images.txt"
    # docker: image ls reads images.txt; exec -i appends stdin to stdin-<cid>;
    # exec exits per rc-exec-<cid> (no -i) or rc-execi-<cid> (-i), default 0
    stub docker 'echo "docker $*" >> "$STUB_LOG"
case "$1" in
  image) [ "$2" = ls ] && cat "$BATS_TEST_TMPDIR/images.txt" ;;
  exec)
    shift; mode=exec
    if [ "$1" = -i ]; then mode=execi; shift; fi
    cid=$1
    [ "$mode" = execi ] && cat >> "$BATS_TEST_TMPDIR/stdin-$cid"
    f="$BATS_TEST_TMPDIR/rc-$mode-$cid"
    [ -f "$f" ] && exit "$(cat "$f")" ;;
esac
exit 0'
}

scenario() { kit_run "$SCRIPT" "$@"; }

# make_demo_scenario — "demo": two netshoot nodes a and b, each on one of the
# two Cloud TAP ports; "needs-ike": the same shape, but also needs strongswan.
make_demo_scenario() {
    local s
    for s in demo needs-ike; do
        local d="$SCENARIO_DIR/$s"
        mkdir -p "$d/project" "$d/nodes"
        cat > "$d/project/$s.gns3" <<'EOF'
{
  "name": "__PROJECT_NAME__",
  "project_id": "__PROJECT_ID__",
  "revision": 9,
  "type": "topology",
  "variables": [{"name": "r770_scenario", "value": "__SCENARIO__"}],
  "topology": {
    "computes": [], "drawings": [],
    "nodes": [
      {"compute_id": "local", "node_id": "00000009-0000-4000-8000-000000000001", "name": "a", "node_type": "docker", "x": -100, "y": 0,
       "properties": {"image": "__IMG_NETSHOOT__", "adapters": 1, "start_command": "tail -f /dev/null", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000009-0000-4000-8000-000000000002", "name": "b", "node_type": "docker", "x": 100, "y": 0,
       "properties": {"image": "__IMG_NETSHOOT__", "adapters": 1, "start_command": "tail -f /dev/null", "console_type": "none"}},
      {"compute_id": "local", "node_id": "00000009-0000-4000-8000-000000000003", "name": "tap-a", "node_type": "cloud", "x": -100, "y": 100,
       "properties": {"ports_mapping": [{"interface": "__TAP_A__", "name": "__TAP_A__", "port_number": 0, "type": "tap"}]}},
      {"compute_id": "local", "node_id": "00000009-0000-4000-8000-000000000004", "name": "tap-b", "node_type": "cloud", "x": 100, "y": 100,
       "properties": {"ports_mapping": [{"interface": "__TAP_B__", "name": "__TAP_B__", "port_number": 0, "type": "tap"}]}}
    ],
    "links": [
      {"link_id": "00000009-0000-4000-9000-000000000001", "nodes": [
        {"node_id": "00000009-0000-4000-8000-000000000001", "adapter_number": 0, "port_number": 0},
        {"node_id": "00000009-0000-4000-8000-000000000003", "adapter_number": 0, "port_number": 0}]},
      {"link_id": "00000009-0000-4000-9000-000000000002", "nodes": [
        {"node_id": "00000009-0000-4000-8000-000000000004", "adapter_number": 0, "port_number": 0},
        {"node_id": "00000009-0000-4000-8000-000000000002", "adapter_number": 0, "port_number": 0}]}
    ]
  }
}
EOF
        printf 'ip addr replace 10.209.0.1/24 dev eth0\n' > "$d/nodes/a.sh"
        printf 'ip addr replace 10.209.0.2/24 dev eth0\n' > "$d/nodes/b.sh"
        printf '#!/bin/sh\nexit 0\n' > "$d/traffic.sh"
        printf 'icmp||10.209.0.0/24|10.209.0.0/24\n' > "$d/expect.txt"
        cat > "$d/scenario.conf" <<EOF
name=$s
description=two netshoot nodes across br-lab
range=10.209.0.0/16
images=netshoot
traffic_secs=5
ready=a|true
traffic_nodes=b a
EOF
    done
    sed -i 's/^images=netshoot$/images=netshoot strongswan/' "$SCENARIO_DIR/needs-ike/scenario.conf"
}

# seed_project <id> <name> <status> <marker-or-empty> [<tap>...] — put a
# project into the fake controller; each tap becomes a Cloud port of it
seed_project() {
    local id=$1 name=$2 st=$3 marker=$4; shift 4
    python3 - "$FAKE_GNS3/projects.json" "$id" "$name" "$st" "$marker" "$@" <<'PY'
import json, os, sys
f, pid, name, st, marker, *taps = sys.argv[1:]
projects = json.load(open(f)) if os.path.exists(f) else []
nodes = [{"node_id": f"n{i}", "name": f"cloud{i}", "node_type": "cloud",
          "properties": {"ports_mapping": [{"interface": t, "name": t, "port_number": 0, "type": "tap"}]}}
         for i, t in enumerate(taps)]
projects.append({"project_id": pid, "name": name, "status": st,
                 "variables": [{"name": "r770_scenario", "value": marker}] if marker else [],
                 "topology": {"nodes": nodes, "links": []}})
json.dump(projects, open(f, "w"))
PY
}

# ── list ───────────────────────────────────────────────────────────────────

@test "list without --bundle names every scenario and asks for a bundle to check images" {
    run scenario list
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"demo"*"10.209.0.0/16"* ]]
    [[ "$output" == *"needs-ike"* ]]
    [[ "$output" == *"pass --bundle to check them"* ]]
}

@test "list --bundle marks a scenario runnable, and one needing strongswan not runnable, naming it" {
    run scenario list --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"runnable with this bundle"* ]]
    [[ "$output" == *"NOT runnable: missing strongswan — strongSwan arrives with the next bundle cut"* ]]
}

# ── login and the controller ───────────────────────────────────────────────

@test "a GNS3 that does not answer is a refusal naming the service step" {
    touch "$FAKE_GNS3/down"
    run scenario down demo
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"GNS3 does not answer on 127.0.0.1:3080"* ]]
    [[ "$output" == *"r770-gns3-deploy.sh service"* ]]
}

@test "a refused login is a refusal naming config" {
    touch "$FAKE_GNS3/login-refused"
    run scenario down demo
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"GNS3 refused the admin login"* ]]
}

@test "the admin credential never reaches argv or the transcript" {
    run scenario down demo
    [ "$status" -eq 0 ]
    ! grep -q fixture-pw "$STUB_LOG"
    [[ "$output" != *"fixture-pw"* ]]
    [[ "$output" != *"fixture-token"* ]]
    grep -q 'POST /v3/access/users/login' "$FAKE_GNS3/requests.log"
}

@test "an unknown or malformed scenario name is refused" {
    run scenario down nope
    [ "$status" -eq 1 ]
    [[ "$output" == *"no scenario 'nope'"* ]]
    run scenario down 'Bad_Name'
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a scenario name"* ]]
    run scenario down
    [ "$status" -eq 1 ]
    [[ "$output" == *"down needs a scenario name"* ]]
}

# ── down ───────────────────────────────────────────────────────────────────

@test "down on a scenario that is not up PASSes and deletes nothing" {
    run scenario down demo
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  demo is not running"* ]]
    ! grep -q '^DELETE' "$FAKE_GNS3/requests.log"
}

@test "down stops and deletes our project, and only ours" {
    seed_project p1 lab-scenario-demo opened demo lab-tap0 lab-tap1
    seed_project p2 other-project opened ""
    run scenario down demo
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q '^POST /v3/projects/p1/nodes/stop$' "$FAKE_GNS3/requests.log"
    grep -q '^DELETE /v3/projects/p1$' "$FAKE_GNS3/requests.log"
    ! grep -q 'p2' "$FAKE_GNS3/requests.log"
    ! grep -q '"p1"' "$FAKE_GNS3/projects.json"
    grep -q '"p2"' "$FAKE_GNS3/projects.json"
    [[ "$output" == *"PASS  demo taken down"* ]]
}

@test "down refuses a same-named project without the kit's marker" {
    seed_project p9 lab-scenario-demo opened ""
    run scenario down demo
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"has no kit marker"* ]]
    ! grep -q '^DELETE' "$FAKE_GNS3/requests.log"
}
