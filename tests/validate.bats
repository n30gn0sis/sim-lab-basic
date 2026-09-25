#!/usr/bin/env bats
#
# The validation suite's contract: every check produces a row; a check that
# cannot run is SKIPPED with a reason and still appears; interfaces are never
# discovered; a FAIL carries a diagnosis and drives the exit code; indexing
# lag is a WARN, not a capture failure.

load helpers/fixtures
load helpers/stubs

setup() {
    kit_test_env
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-validate.sh"
    make_root "$ROOT"
    export OUT="$BATS_TEST_TMPDIR/out"
    stub systemctl 'case "$*" in "is-active ssh") echo active;; "is-active gns3") echo inactive;; *) echo inactive;; esac'
    stub apt-get 'echo "file:/srv/repo/apt/./Packages"'
    stub dpkg 'exit 1'
    stub findmnt 'case "$1 $2" in "-n -o") [ "$3" = TARGET ] && echo "$5" || echo 100G;; esac'
    stub nproc 'echo 64'
    stub free 'echo "Mem: 125 4 121"'
    stub curl 'echo'
    stub ss 'echo'
    stub ip 'echo'
    export VALIDATE_AIRGAP_CMD="$BIN/airgap-stub"
    stub airgap-stub 'echo "PASS  apt: every index target is file: (1 target(s))"; echo "SKIP  dnsmasq: not installed (Phase 5 not built)"; exit 0'
}

validate() { kit_run "$SCRIPT" --out "$OUT" "$@"; }
report() { cat "$OUT"/validation-*.md; }

@test "--list prints every area" {
    run validate --list
    [ "$status" -eq 0 ]
    for a in host cpu-ram storage network virtualization gns3 wan capture backup airgap portal; do
        [[ "$output" == *"$a"* ]]
    done
}

@test "checks that cannot run are SKIPPED with a reason, present in the report, and do not change the exit code" {
    run validate --area host --area cpu-ram --area gns3 --area wan --area backup --area portal
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  host/chrony: chronyc not installed (Phase 5 not built)"* ]]
    [[ "$output" == *"SKIP  cpu-ram/threads: 64 (--expect-threads not given)"* ]]
    [[ "$output" == *"SKIP  gns3/unit: inactive (Phase 8 not built"* ]]
    [[ "$output" == *"SKIP  wan/impairment: not opted in"* ]]
    [[ "$output" == *"SKIP  backup/restore: restic not installed (Phase 15 not built)"* ]]
    [[ "$output" == *"SKIP  portal/vhosts: no /etc/nginx/ssl/ca.crt (Phase 13 not built)"* ]]
    run report
    [[ "$output" == *"## SKIPPED"* ]]
    [[ "$output" == *"- gns3 / unit"* ]]
    [[ "$output" == *"| chrony | Leap status Normal | chronyc not installed | SKIP | Phase 5 not built |"* ]]
}

@test "the report has one five-column row per check and a summary" {
    run validate --area host --area cpu-ram
    [ "$status" -eq 0 ]
    checks=$(printf '%s\n' "$output" | grep -cE '^(PASS|WARN|FAIL|SKIP)  (host|cpu-ram)/')
    rows=$(grep -cE '^\| [^|]+ \| [^|]+ \| [^|]+ \| (PASS|WARN|FAIL|SKIP) \| [^|]+ \|$' "$OUT"/validation-*.md)
    echo "checks=$checks rows=$rows"
    [ "$checks" -eq "$rows" ]
    grep -q '^Summary: ' "$OUT"/validation-*.md
}

@test "a FAIL drives exit 1 and carries a diagnosis" {
    stub apt-get 'echo "https://archive.ubuntu.com/ubuntu/dists/noble/InRelease"'
    run validate --area host
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  host/apt-local"* ]]
    run report
    [[ "$output" == *"## FAIL diagnoses"* ]]
    [[ "$output" == *"host/apt-local: an upstream source survived"* ]]
}

@test "hardware expectations are arguments: threads and RAM pass against what is given" {
    run validate --area cpu-ram --expect-threads 64 --expect-ram-gb 128
    echo "$output"
    [[ "$output" == *"PASS  cpu-ram/threads: 64"* ]]
    [[ "$output" == *"PASS  cpu-ram/ram-gb: 125"* ]]
    run validate --area cpu-ram --expect-threads 32
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  cpu-ram/threads: 64"* ]]
}

@test "capture interfaces are never discovered: without --capture-ifs the area SKIPs" {
    run validate --area network
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  network/capture: no --capture-ifs given"* ]]
    [[ "$output" == *"SKIP  network/mgmt: no --mgmt-if given"* ]]
}

@test "a capture port carrying an address is a FAIL with the rule in its diagnosis" {
    stub ip 'case "$*" in *"addr show cap0"*) echo "2: cap0 inet 10.0.0.9/24 scope global cap0";; *"link show cap0"*) echo "2: cap0: <BROADCAST,PROMISC,UP>";; *) echo;; esac'
    run validate --area network --capture-ifs "cap0"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  network/capture cap0 address: 1 address(es)"* ]]
    [[ "$output" == *"PASS  network/capture cap0 promisc"* ]]
    run report
    [[ "$output" == *"capture ports never get an IP"* ]]
}

@test "a replay is opt-in, and the Arkime comparison is a WARN (indexing lag), not a FAIL" {
    run validate --area capture
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  capture/tcpreplay: not opted in (--feed IF --pcap FILE) (injects traffic)"* ]]
    stub tcpreplay 'echo "Actual: 1234 packets (100000 bytes) sent in 0.5 seconds"'
    echo pcap > "$BATS_TEST_TMPDIR/ref.pcap"
    run validate --area capture --feed cap0 --pcap "$BATS_TEST_TMPDIR/ref.pcap"
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"PASS  capture/tcpreplay: 1234 packets into cap0"* ]]
    [[ "$output" == *"WARN  capture/arkime-count"* ]]
}

@test "the airgap area folds the posture script's rows in, under its own verdicts" {
    run validate --area airgap
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  airgap/apt: every index target is file:"* ]]
    [[ "$output" == *"SKIP  airgap/dnsmasq: not installed (Phase 5 not built)"* ]]
    stub airgap-stub 'echo "FAIL  snapd is installed — it phones home"; exit 1'
    run validate --area airgap
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  airgap/snapd is installed"* ]]
}

@test "an unknown area is rejected" {
    run validate --area frobnicate
    [ "$status" -eq 1 ]
}

# fake_lab_sys [ageing] [physical-port] [multicast_snooping] — br-lab with
# lab-mon0 as a port whose veth peer is lab_mirror0 (ifindex 21 <-> iflink
# 21), under $ROOT
fake_lab_sys() {
    local s="$ROOT/sys/class/net"
    mkdir -p "$s/br-lab/bridge" "$s/br-lab/brif" "$s/lab-mon0" "$s/lab_mirror0" "$s/lab-tap0"
    echo "${1:-0}" > "$s/br-lab/bridge/ageing_time"
    echo "${3:-0}" > "$s/br-lab/bridge/multicast_snooping"
    touch "$s/br-lab/brif/lab-mon0" "$s/br-lab/brif/lab-tap0"
    echo 21 > "$s/lab-mon0/ifindex"; echo 22 > "$s/lab-mon0/iflink"
    echo 22 > "$s/lab_mirror0/ifindex"; echo 21 > "$s/lab_mirror0/iflink"
    echo 30 > "$s/lab-tap0/ifindex"; echo 30 > "$s/lab-tap0/iflink"
    if [ -n "${2:-}" ]; then mkdir -p "$s/$2/device"; touch "$s/br-lab/brif/$2"; echo 40 > "$s/$2/ifindex"; echo 40 > "$s/$2/iflink"; fi
}

@test "the lab bridge is never guessed: without --lab-bridge its rows SKIP" {
    run validate --area network
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  network/lab-bridge: no --lab-bridge given"* ]]
}

@test "a correct lab bridge PASSes hub mode, no physical port, and the mirror wiring" {
    fake_lab_sys
    stub ip 'case "$*" in *"link show lab_mirror0"*) echo "22: lab_mirror0@lab-mon0: <BROADCAST,NOARP,PROMISC,UP>";; esac; exit 0'
    run validate --area network --lab-bridge br-lab --capture-ifs lab_mirror0
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  network/lab-bridge br-lab hub"* ]]
    [[ "$output" == *"PASS  network/lab-bridge br-lab multicast snooping"* ]]
    [[ "$output" == *"PASS  network/lab-bridge br-lab physical ports"* ]]
    [[ "$output" == *"PASS  network/lab-bridge br-lab mirror"* ]]
    [[ "$output" == *"PASS  network/lab-mirror lab_mirror0 address"* ]]
}

@test "a lab bridge that learns MACs, or holds a physical port, is a FAIL with a diagnosis" {
    fake_lab_sys 30000 eno1
    stub ip 'case "$*" in *"link show lab_mirror0"*) echo "22: lab_mirror0@lab-mon0: <PROMISC,UP>";; esac; exit 0'
    run validate --area network --lab-bridge br-lab --capture-ifs lab_mirror0
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  network/lab-bridge br-lab hub: ageing_time 30000"* ]]
    [[ "$output" == *"FAIL  network/lab-bridge br-lab physical ports: eno1"* ]]
    run report
    [[ "$output" == *"never touches a physical port"* ]]
}

@test "a mirror capture end with a link-local address is a FAIL; no capture interface fed by the bridge is a FAIL" {
    fake_lab_sys
    stub ip 'case "$*" in *"addr show lab_mirror0"*) echo "22: lab_mirror0    inet6 fe80::1/64 scope link";; *"link show lab_mirror0"*) echo "22: lab_mirror0: <PROMISC,UP>";; esac; exit 0'
    run validate --area network --lab-bridge br-lab --capture-ifs lab_mirror0
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  network/lab-mirror lab_mirror0 address: 1 address(es)"* ]]
    mkdir -p "$ROOT/sys/class/net/cap9"; echo 50 > "$ROOT/sys/class/net/cap9/iflink"
    run validate --area network --lab-bridge br-lab --capture-ifs cap9
    echo "$output"
    [[ "$output" == *"FAIL  network/lab-bridge br-lab mirror: no --capture-ifs interface is fed by a port of br-lab"* ]]
}

@test "a lab bridge that snoops multicast is a FAIL with a diagnosis (F7)" {
    fake_lab_sys 0 "" 1
    stub ip 'case "$*" in *"link show lab_mirror0"*) echo "22: lab_mirror0@lab-mon0: <PROMISC,UP>";; esac; exit 0'
    run validate --area network --lab-bridge br-lab --capture-ifs lab_mirror0
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  network/lab-bridge br-lab multicast snooping: multicast_snooping 1"* ]]
    run report
    [[ "$output" == *"MulticastSnooping=no"* ]]
}

@test "--lab-bridge naming a bridge that does not exist is a FAIL pointing at labnet (F12)" {
    run validate --area network --lab-bridge br-nope
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  network/lab-bridge br-nope: absent or not a bridge"* ]]
    run report
    [[ "$output" == *"r770-gns3-deploy.sh labnet creates it"* ]]
}

@test "capture offloads on the mirror end PASS when off and FAIL when on (F3)" {
    fake_lab_sys
    stub ip 'case "$*" in *"link show lab_mirror0"*) echo "22: lab_mirror0@lab-mon0: <PROMISC,UP>";; esac; exit 0'
    stub ethtool 'printf "tcp-segmentation-offload: %s\ngeneric-receive-offload: %s\nlarge-receive-offload: off [fixed]\n" "${OFFL:-off}" "${OFFL:-off}"'
    run validate --area network --lab-bridge br-lab --capture-ifs lab_mirror0
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  network/capture lab_mirror0 offloads: off"* ]]
    OFFL=on run validate --area network --lab-bridge br-lab --capture-ifs lab_mirror0
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  network/capture lab_mirror0 offloads: 2 still on"* ]]
}

@test "a capture interface enslaved to a bridge is a FAIL (rule 8); one with no master PASSes (F9)" {
    fake_lab_sys
    stub ip 'case "$*" in *"link show"*) echo "3: x: <PROMISC,UP>";; esac; exit 0'
    mkdir -p "$ROOT/sys/class/net/cap0"
    run validate --area network --capture-ifs "lab_mirror0 cap0"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  network/capture lab_mirror0 master: none"* ]]
    [[ "$output" == *"PASS  network/capture cap0 master: none"* ]]
    ln -s ../br-lab "$ROOT/sys/class/net/cap0/master"
    run validate --area network --capture-ifs "lab_mirror0 cap0"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  network/capture cap0 master: br-lab"* ]]
    run report
    [[ "$output" == *"never bridged to the lab fabric"* ]]
}
