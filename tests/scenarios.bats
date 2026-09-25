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
