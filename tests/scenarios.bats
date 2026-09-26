#!/usr/bin/env bats
#
# The scenario pack's content, linted offline: layout, project JSON, the two
# TAP-type Cloud ports, images the bundle can carry, addresses that stay in
# each scenario's own range, and shell that shellcheck accepts. Whether FRR
# converges or a tunnel carries traffic is proven on the staging rehearsal.

setup() { cd "$BATS_TEST_DIRNAME/.."; }

lint() { run python3 tests/helpers/lint_scenarios.py "$1"; echo "$output"; [ "$status" -eq 0 ]; }

@test "the pack holds the scenarios the kit documents" {
    for s in client-server ipsec-esp ipsec-ike ospf bgp; do [ -f "scenarios/$s/scenario.conf" ] || { echo "missing $s"; false; }; done
    [ "$(find scenarios -mindepth 2 -maxdepth 2 -name scenario.conf | wc -l)" -eq 5 ]
}

@test "every scenario has its files and a complete scenario.conf, and ranges are unique" { lint layout; }
@test "every project parses as JSON and carries the kit's name, id and marker tokens" { lint json; }
@test "every project has exactly two TAP-type Cloud ports and the nodes the scenario names" { lint topology; }
@test "every image is bundled or upstream-pending, and nodes use only the scenario's image tokens" { lint images; }
@test "every address a scenario names lies in its own range" { lint addresses; }
@test "every expect.txt line is proto|port|src|dst inside the scenario's range" { lint expect; }

@test "every BGP neighbor keeps alive at 10s or less, so any traffic window carries the session" {
    # the session comes up during `up`, before any capture starts; at FRR's 60s default a
    # traffic window can hold no BGP packet at all, and expect.txt's tcp/179 row would miss
    for f in scenarios/*/nodes/*.frr.conf; do
        awk -v f="$f" '
            $1 == "neighbor" && $3 == "remote-as" { peer[$2] = 1 }
            $1 == "neighbor" && $3 == "timers" && $4 ~ /^[0-9]+$/ && $4 <= 10 { fast[$2] = 1 }
            END { for (p in peer) if (!(p in fast)) { print f ": neighbor " p " has no timers <=10s"; bad = 1 }; exit bad }
        ' "$f"
    done
}

@test "every iperf3 client is rate-capped, so the mirror's capture keeps every packet" {
    # uncapped, iperf3 floods br-lab at line rate and the capture side drops packets —
    # including the control-plane ones (BGP, OSPF) each expect.txt promises
    run grep -nE 'iperf3 -c' scenarios/*/traffic.sh
    [ "${#lines[@]}" -ge 1 ]
    for l in "${lines[@]}"; do [[ "$l" == *" -b "[0-9]*M* ]] || { echo "uncapped: $l"; false; }; done
}

@test "ipsec-ike's traffic starts by tearing the IKE SA down, so the window carries a fresh IKE_SA_INIT" {
    # up's ready ping negotiates IKE before any capture starts, and a rekey or reauth stays on
    # 4500 — only a fresh IKE_SA_INIT (the trap re-initiating on cl-a's ping) crosses udp/500
    grep -qx 'traffic_nodes=gw-a cl-b cl-a' scenarios/ipsec-ike/scenario.conf
    grep -qE '^ *gw-a\) swanctl --terminate --ike lab' scenarios/ipsec-ike/traffic.sh
    grep -qx 'udp|500|10.202.0.1/32|10.202.0.2/32' scenarios/ipsec-ike/expect.txt
    grep -qx 'udp|4500|10.202.0.1/32|10.202.0.2/32' scenarios/ipsec-ike/expect.txt
}

@test "every traffic.sh and node script is shellcheck-clean as POSIX sh" {
    run shellcheck -s sh scenarios/*/traffic.sh scenarios/*/nodes/*.sh
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "the topology lint rejects one Cloud carrying both TAPs" {
    d="$BATS_TEST_TMPDIR/pack"; mkdir -p "$d"; cp -r scenarios/client-server "$d/"
    python3 - "$d/client-server/project/client-server.gns3" <<'PY'
import json, sys
f = sys.argv[1]; p = json.load(open(f))
nodes = p["topology"]["nodes"]
a = next(n for n in nodes if n["name"] == "tap-a"); b = next(n for n in nodes if n["name"] == "tap-b")
a["properties"]["ports_mapping"].append(dict(b["properties"]["ports_mapping"][0], port_number=1))
nodes.remove(b)
for l in p["topology"]["links"]:
    for e in l["nodes"]:
        if e["node_id"] == b["node_id"]:
            e["node_id"] = a["node_id"]; e["port_number"] = 1
json.dump(p, open(f, "w"))
PY
    SCENARIOS_ROOT="$d" run python3 tests/helpers/lint_scenarios.py topology
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"expected two Cloud nodes"* ]]
}

@test "the layout lint rejects a node file the script would silently ignore" {
    d="$BATS_TEST_TMPDIR/pack"; mkdir -p "$d"; cp -r scenarios/client-server "$d/"
    echo 'hostname srv' > "$d/client-server/nodes/srv.conf"
    SCENARIOS_ROOT="$d" run python3 tests/helpers/lint_scenarios.py layout
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"nodes/srv.conf"* ]]
}

@test "the json lint rejects a project revision of 10 or more" {
    d="$BATS_TEST_TMPDIR/pack"; mkdir -p "$d"; cp -r scenarios/client-server "$d/"
    sed -i 's/"revision": [0-9]*/"revision": 10/' "$d/client-server/project/client-server.gns3"
    grep -q '"revision": 10' "$d/client-server/project/client-server.gns3"
    SCENARIOS_ROOT="$d" run python3 tests/helpers/lint_scenarios.py json
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"revision"* ]]
}
