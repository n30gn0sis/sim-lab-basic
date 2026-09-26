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
# project into the fake controller; each tap becomes a Cloud port of it, of
# type $SEED_PORT_TYPE (default tap)
seed_project() {
    local id=$1 name=$2 st=$3 marker=$4; shift 4
    python3 - "$FAKE_GNS3/projects.json" "$id" "$name" "$st" "$marker" "${SEED_PORT_TYPE:-tap}" "$@" <<'PY'
import json, os, sys
f, pid, name, st, marker, ptype, *taps = sys.argv[1:]
projects = json.load(open(f)) if os.path.exists(f) else []
nodes = [{"node_id": f"n{i}", "name": f"cloud{i}", "node_type": "cloud",
          "properties": {"ports_mapping": [{"interface": t, "name": t, "port_number": 0, "type": ptype}]}}
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
    grep -q 'POST /v3/access/users/authenticate' "$FAKE_GNS3/requests.log"
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

# ── up ─────────────────────────────────────────────────────────────────────

@test "up imports the rendered project, opens it, starts it, configures each node and waits until ready" {
    run scenario up demo --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    r=$(grep -nE '^POST /v3/projects/[^/]+/import\?name=lab-scenario-demo$' "$FAKE_GNS3/requests.log" | cut -d: -f1)
    o=$(grep -nE '^POST /v3/projects/[^/]+/open$' "$FAKE_GNS3/requests.log" | cut -d: -f1)
    s=$(grep -nE '^POST /v3/projects/[^/]+/nodes/start$' "$FAKE_GNS3/requests.log" | cut -d: -f1)
    [ -n "$r" ] && [ -n "$o" ] && [ -n "$s" ] && [ "$r" -lt "$o" ] && [ "$o" -lt "$s" ]
    python3 - "$FAKE_GNS3/projects.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))[0]
assert p["name"] == "lab-scenario-demo", p["name"]
assert {"name": "r770_scenario", "value": "demo"} in p["variables"]
nodes = {n["name"]: n for n in p["topology"]["nodes"]}
assert nodes["a"]["properties"]["image"] == "docker.io/nicolaka/netshoot:0.0.0-fixture"
assert nodes["tap-a"]["properties"]["ports_mapping"][0]["interface"] == "lab-tap0"
assert nodes["tap-b"]["properties"]["ports_mapping"][0]["interface"] == "lab-tap1"
assert nodes["tap-a"]["properties"]["ports_mapping"][0]["type"] == "tap"
PY
    grep -q '^docker exec -i cid-a sh -s$' "$STUB_LOG"
    grep -q '^docker exec -i cid-b sh -s$' "$STUB_LOG"
    grep -q '10.209.0.1/24' "$BATS_TEST_TMPDIR/stdin-cid-a"
    [[ "$output" == *"PASS  every node started"* ]]
    [[ "$output" == *"PASS  ready: a: true"* ]]
}

@test "up refuses an image the bundle does not carry, naming it, and imports nothing" {
    run scenario up needs-ike --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"strongswan"* ]]
    [[ "$output" == *"strongSwan arrives with the next bundle cut"* ]]
    ! grep -q import "$FAKE_GNS3/requests.log" 2>/dev/null
}

@test "up refuses an image that is in the bundle but not loaded" {
    : > "$BATS_TEST_TMPDIR/images.txt"
    run scenario up demo --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"docker.io/nicolaka/netshoot:0.0.0-fixture is not loaded"* ]]
}

@test "up accepts an image docker lists by its short name" {
    echo 'nicolaka/netshoot:0.0.0-fixture' > "$BATS_TEST_TMPDIR/images.txt"
    run scenario up demo --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" != *"is not loaded"* ]]
}

@test "up refuses a scenario that is already up, and --force takes it down first" {
    seed_project p1 lab-scenario-demo opened demo
    run scenario up demo --bundle "$BUNDLE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"demo is already up"* ]]
    run scenario up demo --bundle "$BUNDLE" --force
    echo "$output"
    [ "$status" -eq 0 ]
    d=$(grep -n '^DELETE /v3/projects/p1$' "$FAKE_GNS3/requests.log" | cut -d: -f1)
    i=$(grep -n '/import?name=lab-scenario-demo$' "$FAKE_GNS3/requests.log" | cut -d: -f1)
    [ -n "$d" ] && [ -n "$i" ] && [ "$d" -lt "$i" ]
}

@test "up refuses a same-named project without the kit's marker" {
    seed_project p9 lab-scenario-demo opened ""
    run scenario up demo --bundle "$BUNDLE" --force
    [ "$status" -eq 1 ]
    [[ "$output" == *"without the kit's marker"* ]]
    ! grep -q '^DELETE' "$FAKE_GNS3/requests.log"
}

@test "up skips TAPs an opened project holds, and refuses when fewer than two are free, naming the holder" {
    seed_project p2 other-lab opened "" lab-tap0 lab-tap1
    run scenario up demo --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"taps: lab-tap2 lab-tap3"* ]]
    rm -f "$FAKE_GNS3/projects.json"
    seed_project p2 other-lab opened "" lab-tap0 lab-tap1 lab-tap2
    run scenario up demo --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"fewer than two free kit TAPs (held by: other-lab"* ]]
}

@test "up counts a kit TAP as held whatever the Cloud port's type" {
    SEED_PORT_TYPE=ethernet seed_project p2 other-lab opened "" lab-tap0 lab-tap1
    run scenario up demo --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"taps: lab-tap2 lab-tap3"* ]]
}

@test "up applies FRR and strongSwan config with a bounded retry until the daemon takes it" {
    printf 'hostname a\n' > "$SCENARIO_DIR/demo/nodes/a.frr.conf"
    printf 'connections {}\n' > "$SCENARIO_DIR/demo/nodes/b.swanctl.conf"
    run scenario up demo --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q '^docker exec -i cid-a sh -c cat > /tmp/lab-frr.conf && { i=0; until wf=$(vtysh -c "show watchfrr" 2>/dev/null | grep "^  \[a-z\]") && ! printf "%s\\n" "$wf" | grep -qv " Up \*$" && vtysh -f /tmp/lab-frr.conf; do i=$((i+1)); \[ "$i" -ge 15 \] && exit 1; sleep 2; done; }$' "$STUB_LOG"
    grep -q '^docker exec -i cid-b sh -c mkdir -p /etc/swanctl && cat > /etc/swanctl/swanctl.conf && { i=0; until swanctl --load-all; do i=$((i+1)); \[ "$i" -ge 15 \] && exit 1; sleep 2; done; }$' "$STUB_LOG"
    grep -q 'hostname a' "$BATS_TEST_TMPDIR/stdin-cid-a"
}

frr_apply_cmd() {  # the frr.conf apply command up sent to cid-a, pointed at a scratch file
    local cmd
    cmd=$(sed -n "s/^docker exec -i cid-a sh -c //p" "$STUB_LOG" | grep vtysh)
    printf '%s' "${cmd//\/tmp\/lab-frr.conf/$BATS_TEST_TMPDIR/lab-frr.conf}"
}
fake_vtysh() {  # fake_vtysh <polls-before-all-up> — watchfrr reports ospfd Down for that many polls
    nb="$BATS_TEST_TMPDIR/node-bin"; mkdir -p "$nb"
    cat > "$nb/vtysh" <<SH
#!/bin/sh
if [ "\$1" = -c ]; then
    n=\$(cat "$BATS_TEST_TMPDIR/polls" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$BATS_TEST_TMPDIR/polls"
    [ "$1" -lt 0 ] && exit 1
    printf 'watchfrr global phase: Idle\\n Restart Command: "x"\\n  zebra                Up\\n'
    if [ "\$n" -le "$1" ]; then printf '  ospfd                Down\\n'; else printf '  ospfd                Up\\n'; fi
    exit 0
fi
echo "applied after poll \$(cat "$BATS_TEST_TMPDIR/polls")" >> "$BATS_TEST_TMPDIR/applied.log"
SH
    printf '#!/bin/sh\nexit 0\n' > "$nb/sleep"
    chmod +x "$nb"/*
}

@test "an FRR config is applied only once every daemon watchfrr manages is Up" {
    printf 'hostname a\n' > "$SCENARIO_DIR/demo/nodes/a.frr.conf"
    run scenario up demo --bundle "$BUNDLE"
    [ "$status" -eq 0 ]
    cmd=$(frr_apply_cmd); [ -n "$cmd" ]
    fake_vtysh 2
    run env PATH="$nb:$PATH" sh -c "$cmd" < "$SCENARIO_DIR/demo/nodes/a.frr.conf"
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/applied.log")" = "applied after poll 3" ]
}

@test "an FRR config is never applied while watchfrr cannot be reached, and the retry is bounded" {
    printf 'hostname a\n' > "$SCENARIO_DIR/demo/nodes/a.frr.conf"
    run scenario up demo --bundle "$BUNDLE"
    [ "$status" -eq 0 ]
    cmd=$(frr_apply_cmd); [ -n "$cmd" ]
    fake_vtysh -1
    run env PATH="$nb:$PATH" sh -c "$cmd" < "$SCENARIO_DIR/demo/nodes/a.frr.conf"
    [ "$status" -ne 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/polls")" = 15 ]
    [ ! -e "$BATS_TEST_TMPDIR/applied.log" ]
}

@test "a node config apply stops at once when its file cannot be written, and never runs the loader" {
    printf 'hostname a\n' > "$SCENARIO_DIR/demo/nodes/a.frr.conf"
    printf 'connections {}\n' > "$SCENARIO_DIR/demo/nodes/b.swanctl.conf"
    run scenario up demo --bundle "$BUNDLE"
    [ "$status" -eq 0 ]
    # run each apply command the script sent exactly as the node's sh would,
    # with a cat that cannot write and loaders that record being called
    nb="$BATS_TEST_TMPDIR/node-bin"; mkdir -p "$nb"
    printf '#!/bin/sh\nexit 1\n' > "$nb/cat"
    printf '#!/bin/sh\necho called >> "%s/loader.log"\nexit 1\n' "$BATS_TEST_TMPDIR" > "$nb/vtysh"
    cp "$nb/vtysh" "$nb/swanctl"
    printf '#!/bin/sh\nexit 0\n' > "$nb/mkdir"
    printf '#!/bin/sh\nexit 0\n' > "$nb/sleep"
    chmod +x "$nb"/*
    for cid in cid-a cid-b; do
        cmd=$(sed -n "s/^docker exec -i $cid sh -c //p" "$STUB_LOG" | grep -E 'vtysh|swanctl')
        [ -n "$cmd" ]
        run env PATH="$nb:$PATH" sh -c "$cmd" < /dev/null
        [ "$status" -ne 0 ]
    done
    [ ! -e "$BATS_TEST_TMPDIR/loader.log" ]
}

@test "up dies naming the down command when a node file names a node with no container" {
    printf 'true\n' > "$SCENARIO_DIR/demo/nodes/tap-a.sh"
    run scenario up demo --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"GNS3 reports no container for node tap-a"*"— r770-scenario.sh down demo"* ]]
}

@test "up --taps binds the named TAPs, and refuses one that is held or is not a kit TAP" {
    run scenario up demo --bundle "$BUNDLE" --taps lab-tap3,lab-tap1
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"taps: lab-tap3 lab-tap1"* ]]
    run scenario down demo
    seed_project p2 other-lab opened "" lab-tap2
    run scenario up demo --bundle "$BUNDLE" --taps lab-tap2,lab-tap0
    [ "$status" -eq 1 ]
    [[ "$output" == *"lab-tap2 is held by GNS3 project other-lab"* ]]
    run scenario up demo --bundle "$BUNDLE" --taps eth0,lab-tap0
    [ "$status" -eq 1 ]
    [[ "$output" == *"eth0 is not a kit TAP"* ]]
    run scenario up demo --bundle "$BUNDLE" --taps lab-tap0
    [ "$status" -eq 1 ]
    [[ "$output" == *"--taps takes two different kit TAPs"* ]]
}

@test "up FAILs when the scenario never becomes ready, leaves the nodes up, and prints the down command" {
    echo 1 > "$BATS_TEST_TMPDIR/rc-exec-cid-a"
    run scenario up demo --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  demo did not become ready within 4s"* ]]
    [[ "$output" == *"r770-scenario.sh down demo"* ]]
    ! grep -q '^DELETE' "$FAKE_GNS3/requests.log"
}

@test "up FAILs when the nodes never start, and says how to take them down" {
    touch "$FAKE_GNS3/never-starts"
    run scenario up demo --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  not started after 4s: a b"* ]]
    [[ "$output" == *"r770-scenario.sh down demo"* ]]
}

@test "up dies when GNS3 refuses the import, and starts nothing" {
    touch "$FAKE_GNS3/import-fails"
    run scenario up demo --bundle "$BUNDLE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"GNS3 refused the import"* ]]
    ! grep -q '/nodes/start' "$FAKE_GNS3/requests.log"
}

@test "up --dry-run prints the calls and imports nothing" {
    run scenario up demo --bundle "$BUNDLE" --dry-run
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN: POST /projects/"*"/import?name=lab-scenario-demo"* ]]
    [ ! -s "$FAKE_GNS3/projects.json" ] || ! grep -q lab-scenario-demo "$FAKE_GNS3/projects.json"
}

# ── traffic / status ───────────────────────────────────────────────────────────

up_demo() { run scenario up demo --bundle "$BUNDLE"; [ "$status" -eq 0 ]; : > "$STUB_LOG"; }

@test "traffic refuses a scenario that is not up" {
    run scenario traffic demo
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"demo is not up"* ]]
}

@test "traffic runs traffic.sh in each traffic node, in order, and writes a run record" {
    up_demo
    run scenario traffic demo
    echo "$output"
    [ "$status" -eq 0 ]
    b=$(grep -n '^docker exec -i cid-b sh -s b 5$' "$STUB_LOG" | cut -d: -f1)
    a=$(grep -n '^docker exec -i cid-a sh -s a 5$' "$STUB_LOG" | cut -d: -f1)
    [ -n "$b" ] && [ -n "$a" ] && [ "$b" -lt "$a" ]
    rec=$(find "$KIT_EVIDENCE_DIR" -name 'scenario-demo-fixturehost-*.run')
    [ -n "$rec" ]
    for k in scenario=demo range=10.209.0.0/16 project=lab-scenario-demo taps=lab-tap0,lab-tap1 secs=5 nodes_ok=2 nodes_failed=0 expect=scenarios/demo/expect.txt; do
        grep -qx "$k" "$rec"
    done
    grep -qE '^start=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$rec"
    grep -qE '^end=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$rec"
    [[ "$output" == *"PASS  traffic ran in every node: b a"* ]]
}

@test "SCENARIO_TRAFFIC_SECS overrides the scenario's window" {
    up_demo
    SCENARIO_TRAFFIC_SECS=9 run scenario traffic demo
    [ "$status" -eq 0 ]
    grep -q '^docker exec -i cid-a sh -s a 9$' "$STUB_LOG"
}

@test "traffic WARNs when one node's generator fails and FAILs when none ran" {
    up_demo
    echo 1 > "$BATS_TEST_TMPDIR/rc-execi-cid-b"
    run scenario traffic demo
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"WARN  traffic failed in: b (ran in: a)"* ]]
    echo 1 > "$BATS_TEST_TMPDIR/rc-execi-cid-a"
    run scenario traffic demo
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  no traffic generator ran (failed in: b a)"* ]]
}

@test "traffic refuses when the scenario is up but not ready, and generates nothing" {
    up_demo
    echo 1 > "$BATS_TEST_TMPDIR/rc-exec-cid-a"
    run scenario traffic demo
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"up but not ready"* ]]
    ! grep -q 'sh -s b' "$STUB_LOG"
}

@test "status lists each scenario's state, TAPs and last run record" {
    up_demo
    run scenario traffic demo
    run scenario status
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"demo"*"up"*"lab-tap0,lab-tap1"*"scenario-demo-fixturehost-"* ]]
    [[ "$output" == *"needs-ike"*"down"*"none"* ]]
}

@test "status without a reachable GNS3 still lists the pack, state unknown" {
    touch "$FAKE_GNS3/down"
    run scenario status
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"running state unknown"* ]]
    [[ "$output" == *"demo"*"unknown"* ]]
}

@test "status reports unknown, not down, when GNS3 cannot list its projects" {
    touch "$FAKE_GNS3/projects-fail"
    run scenario status
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"demo"*"unknown"* ]]
    [[ "$output" != *" down "* ]]
}

@test "status reports a closed marked project as closed, not up" {
    seed_project p1 lab-scenario-demo closed demo lab-tap0 lab-tap1
    run scenario status
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"demo             closed"* ]]
    [[ "$output" != *"demo             up"* ]]
}
