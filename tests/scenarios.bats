#!/usr/bin/env bats
#
# The scenario pack's content, linted offline: layout, project JSON, the two
# TAP-type Cloud ports, images the bundle can carry, addresses that stay in
# each scenario's own range, and shell that shellcheck accepts. Whether FRR
# converges or a tunnel carries traffic is proven on the staging rehearsal.

setup() { cd "$BATS_TEST_DIRNAME/.."; }

lint() { run python3 tests/helpers/lint_scenarios.py "$1"; echo "$output"; [ "$status" -eq 0 ]; }

@test "the pack holds the scenarios the kit documents" {
    for s in client-server ipsec-esp ipsec-ike ospf bgp dns tls ssh s0-w1 s1-w1-ss; do [ -f "scenarios/$s/scenario.conf" ] || { echo "missing $s"; false; }; done
    [ "$(find scenarios -mindepth 2 -maxdepth 2 -name scenario.conf | wc -l)" -eq 10 ]
}

@test "the dns scenario's responder answers A under scenario.lab and NXDOMAIN otherwise" {
    prog="$BATS_TEST_TMPDIR/lab-dns.py"
    sed -n "/^cat > \/tmp\/lab-dns.py <<'PY'$/,/^PY$/p" scenarios/dns/nodes/ns.sh | sed '1d;$d' > "$prog"
    [ -s "$prog" ]
    DNS_BIND=127.0.0.1 DNS_PORT=53053 python3 "$prog" & pid=$!
    sleep 1
    run python3 - <<'PY'
import socket, struct
def ask(name, qtype=1):
    q = b"\x12\x34\x01\x00" + struct.pack(">HHHH", 1, 0, 0, 0)
    q += b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\x00" + struct.pack(">HH", qtype, 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(2)
    s.sendto(q, ("127.0.0.1", 53053)); r, _ = s.recvfrom(512)
    return r
r = ask("www.scenario.lab")
print("id", r[:2].hex(), "rcode", r[3] & 0x0f, "an", struct.unpack(">H", r[6:8])[0], "ip", socket.inet_ntoa(r[-4:]))
r = ask("nothere.example")
print("id", r[:2].hex(), "rcode", r[3] & 0x0f, "an", struct.unpack(">H", r[6:8])[0])
PY
    kill "$pid"
    echo "$output"
    [ "${lines[0]}" = "id 1234 rcode 0 an 1 ip 10.206.0.99" ]
    [ "${lines[1]}" = "id 1234 rcode 3 an 0" ]
}

@test "every scenario has its files and a complete scenario.conf, and ranges are unique" { lint layout; }
@test "every project parses as JSON and carries the kit's name, id and marker tokens" { lint json; }
@test "every project has exactly two TAP-type Cloud ports and the nodes the scenario names" { lint topology; }
@test "every image is bundled or upstream-pending, and nodes use only the scenario's image tokens" { lint images; }
@test "every address a scenario names lies in its own range" { lint addresses; }
@test "every expect.txt line is proto|port|src|dst inside the scenario's range" { lint expect; }
@test "every events/*.txt line is t|action|arg, a known action, t non-decreasing, profiles that exist" { lint events; }
@test "every pcap-expect.txt row is file|mode|filter|expectation|label, with a mode and expectation that agree" { lint pcap-expect; }

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

@test "every expect.txt row translates (scripts/lib/expect.sh), so dashboards and check can use it" {
    run bash -c '. scripts/lib/common.sh; . scripts/lib/expect.sh
        for d in scenarios/*/; do
            while IFS="|" read -r n p port s t; do
                w=$(expect_problem "$p" "$port" "$s" "$t")
                [ -z "$w" ] || { echo "$d expect.txt row $n: $w"; exit 1; }
            done < <(expect_rows "$d")
        done'
    echo "$output"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
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

@test "the layout lint accepts a range list and rejects a CIDR shared between scenarios" {
    d="$BATS_TEST_TMPDIR/pack"; mkdir -p "$d"
    for s in one two; do
        mkdir -p "$d/$s/project" "$d/$s/nodes"
        cp scenarios/client-server/project/client-server.gns3 "$d/$s/project/$s.gns3"
        printf 'name=%s\ndescription=x\nimages=netshoot\ntraffic_secs=10\nready=cl|true\ntraffic_nodes=cl\n' "$s" > "$d/$s/scenario.conf"
    done
    echo 'range=198.18.10.0/24 10.210.0.0/16' >> "$d/one/scenario.conf"
    echo 'range=198.18.11.0/24 10.211.0.0/16' >> "$d/two/scenario.conf"
    printf '#!/bin/sh\nping -c 1 198.18.10.2\n' > "$d/one/traffic.sh"
    printf 'icmp||198.18.10.0/30|10.210.1.0/24\n' > "$d/one/expect.txt"
    printf '#!/bin/sh\nping -c 1 198.18.11.2\n' > "$d/two/traffic.sh"
    printf 'icmp||198.18.11.0/30|10.211.1.0/24\n' > "$d/two/expect.txt"
    SCENARIOS_ROOT="$d" run python3 tests/helpers/lint_scenarios.py layout; echo "$output"; [ "$status" -eq 0 ]
    SCENARIOS_ROOT="$d" run python3 tests/helpers/lint_scenarios.py addresses; echo "$output"; [ "$status" -eq 0 ]
    SCENARIOS_ROOT="$d" run python3 tests/helpers/lint_scenarios.py expect; echo "$output"; [ "$status" -eq 0 ]
    # the second scenario claims a slice inside the first's /16
    sed -i 's|^range=.*|range=198.18.11.0/24 10.210.5.0/24|' "$d/two/scenario.conf"
    SCENARIOS_ROOT="$d" run python3 tests/helpers/lint_scenarios.py layout; echo "$output"
    [ "$status" -ne 0 ]; [[ "$output" == *"overlaps"* ]]
}

@test "s1-w1-ss disables MOBIKE on both gateways, so IKE stays on udp/500 with no NAT (spec X2)" {
    for g in gw-a gw-b; do grep -qE '^\s*mobike\s*=\s*no' "scenarios/s1-w1-ss/nodes/$g.swanctl.conf"; done
}
@test "s1-w1-ss's ISP knows neither site, so any 10.211.x.x address on the outer side is leakage" {
    ! grep -q '10\.211\.' scenarios/s1-w1-ss/nodes/isp1.frr.conf
    ! grep -q '10\.211\.' scenarios/s1-w1-ss/nodes/isp1.sh
}
@test "s1-w1-ss's gateways enable save-keys only when the plugin is present, never assume it" {
    for g in gw-a gw-b; do
        grep -q 'save-keys' "scenarios/s1-w1-ss/nodes/$g.sh"
        grep -qE 'if .*libstrongswan-save-keys\.so' "scenarios/s1-w1-ss/nodes/$g.sh"
    done
}
@test "s1-w1-ss's traffic starts by tearing the IKE SA down, so IKE_SA_INIT is in the window" {
    grep -q 'gw-a) *swanctl --terminate --ike s1' scenarios/s1-w1-ss/traffic.sh
}

@test "the events lint rejects an unknown action, a decreasing t, a missing profile and a bad side" {
    d="$BATS_TEST_TMPDIR/pack"; mkdir -p "$d"; cp -r scenarios/s1-w1-ss "$d/"
    printf '5|note|x\n3|note|y\n4|teleport|a\n4|wan-apply|no-such@a\n4|link-down|c\n4|exec|a\n9999|note|late\n' > "$d/s1-w1-ss/events/bad.txt"
    SCENARIOS_ROOT="$d" run python3 tests/helpers/lint_scenarios.py events
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"line 2: times must not decrease"* ]]
    [[ "$output" == *"unknown action 'teleport'"* ]]
    [[ "$output" == *"no WAN profile 'no-such'"* ]]
    [[ "$output" == *"link-down takes a or b"* ]]
    [[ "$output" == *"exec takes <node>|<command>"* ]]
    [[ "$output" == *"t=9999 is past traffic_secs + idle_secs"* ]]
}
@test "the pcap-expect lint rejects a bad mode, expectation and node" {
    d="$BATS_TEST_TMPDIR/pack"; mkdir -p "$d"; cp -r scenarios/s0-w1 "$d/"
    printf 'outer|weird|x|0|a\ninner-nope|count|x|0|b\nouter|count|x|>=3|c\nouter|distinct esp.spi|esp|>0|d\nouter|count|x|0\n' > "$d/s0-w1/pcap-expect.txt"
    run env SCENARIOS_ROOT="$d" python3 tests/helpers/lint_scenarios.py pcap-expect; echo "$output"
    [ "$status" -ne 0 ]; [ "$(grep -c 'pcap-expect.txt line' <<< "$output")" -eq 5 ]
}

@test "the topology lint rejects Clouds not named tap-a/tap-b, and tap-a carrying __TAP_B__" {
    d="$BATS_TEST_TMPDIR/pack"; mkdir -p "$d"; cp -r scenarios/client-server "$d/"
    f="$d/client-server/project/client-server.gns3"; cp "$f" "$BATS_TEST_TMPDIR/orig"
    python3 -c 'import json, sys; f = sys.argv[1]; p = json.load(open(f)); [n.update(name={"tap-a": "tap-b", "tap-b": "tap-a"}[n["name"]]) for n in p["topology"]["nodes"] if n["name"] in ("tap-a", "tap-b")]; json.dump(p, open(f, "w"))' "$f"
    SCENARIOS_ROOT="$d" run python3 tests/helpers/lint_scenarios.py topology; echo "$output"
    [ "$status" -eq 1 ]; [[ "$output" == *"Cloud tap-a must carry __TAP_A__"* ]]
    cp "$BATS_TEST_TMPDIR/orig" "$f"
    python3 -c 'import json, sys; f = sys.argv[1]; p = json.load(open(f)); [n.update(name="edge") for n in p["topology"]["nodes"] if n["name"] == "tap-a"]; json.dump(p, open(f, "w"))' "$f"
    SCENARIOS_ROOT="$d" run python3 tests/helpers/lint_scenarios.py topology; echo "$output"
    [ "$status" -eq 1 ]; [[ "$output" == *"Clouds must be named exactly tap-a and tap-b"* ]]
}
