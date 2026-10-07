#!/usr/bin/env bats
# r770-wan.sh: impairment profiles on kit TAPs only, tc stubbed.
load helpers/fixtures
load helpers/stubs

setup() {
    kit_test_env
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-wan.sh"
    make_root "$ROOT"
    for i in 0 1; do mkdir -p "$ROOT/sys/class/net/lab-tap$i"; done
    mkdir -p "$ROOT/sys/class/net/eno1" "$ROOT/run"
    export ROOT
    stub_log tc
}
wan() { kit_run "$SCRIPT" "$@"; }

@test "apply refuses an interface that is not a kit TAP, before any tc" {
    run wan apply branch-wan eno1
    [ "$status" -eq 1 ]; [[ "$output" == *"not a kit TAP"* ]]
    ! grep -q '^tc' "$STUB_LOG"
    run wan apply branch-wan lab-tap7
    [ "$status" -eq 1 ]; [[ "$output" == *"does not exist"* ]]
}

@test "apply refuses an unknown profile and a malformed one, naming the key" {
    run wan apply no-such lab-tap0
    [ "$status" -eq 1 ]; [[ "$output" == *"no profile"* ]]
    mkdir -p "$BATS_TEST_TMPDIR/profiles"
    printf 'rate=20mbps\ndelay=40ms\n' > "$BATS_TEST_TMPDIR/profiles/bad.conf"
    WAN_PROFILE_DIR="$BATS_TEST_TMPDIR/profiles" run wan apply bad lab-tap0
    [ "$status" -eq 1 ]; [[ "$output" == *"rate=20mbps"* ]]
    printf 'delay=40ms\n' > "$BATS_TEST_TMPDIR/profiles/norate.conf"
    WAN_PROFILE_DIR="$BATS_TEST_TMPDIR/profiles" run wan apply norate lab-tap0
    [ "$status" -eq 1 ]; [[ "$output" == *"rate="* ]]
    ! grep -q '^tc' "$STUB_LOG"
}

@test "apply shapes with HTB then netem, records the profile, and show names it" {
    run wan apply branch-wan lab-tap0
    echo "$output"; [ "$status" -eq 0 ]
    grep -q 'tc qdisc replace dev lab-tap0 root handle 1: htb default 10' "$STUB_LOG"
    grep -q 'tc class replace dev lab-tap0 parent 1: classid 1:10 htb rate 20mbit' "$STUB_LOG"
    grep -qE 'tc qdisc replace dev lab-tap0 parent 1:10 handle 10: netem delay 40ms 5ms .*loss 0.2%' "$STUB_LOG"
    [ "$(cat "$ROOT/run/r770-wan/lab-tap0")" = branch-wan ]
    [[ "$output" == *"current"* && "$output" == *"proposed"* && "$output" == *"rollback"* ]]
    run wan show
    [[ "$output" == *"lab-tap0"*"branch-wan"* && "$output" == *"lab-tap1"*"clean"* ]]
}

@test "clear removes the qdisc and the record; --all covers every kit TAP; idempotent" {
    wan apply branch-wan lab-tap0 >/dev/null
    run wan clear lab-tap0; [ "$status" -eq 0 ]
    grep -q 'tc qdisc del dev lab-tap0 root' "$STUB_LOG"
    [ ! -e "$ROOT/run/r770-wan/lab-tap0" ]
    run wan clear lab-tap0; [ "$status" -eq 0 ]; [[ "$output" == *"already clean"* ]]
    run wan clear --all; [ "$status" -eq 0 ]
    grep -q 'tc qdisc del dev lab-tap1 root' "$STUB_LOG"
    run wan clear eno1; [ "$status" -eq 1 ]
}

@test "every shipped profile parses" {
    for f in "$BATS_TEST_DIRNAME"/../config/wan/profiles/*.conf; do
        run wan apply "$(basename "$f" .conf)" lab-tap0; echo "$f: $output"; [ "$status" -eq 0 ]
    done
}
