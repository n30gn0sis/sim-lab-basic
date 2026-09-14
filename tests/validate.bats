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
    for a in host cpu-ram storage network virtualization gns3 wan capture monitoring backup airgap portal; do
        [[ "$output" == *"$a"* ]]
    done
}

@test "checks that cannot run are SKIPPED with a reason, present in the report, and do not change the exit code" {
    run validate --area host --area cpu-ram --area gns3 --area wan --area backup --area monitoring --area portal
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
