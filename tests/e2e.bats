#!/usr/bin/env bats
#
# r770-e2e.sh against stubbed children: the runner's own contract. Which
# child runs in which order with which arguments, how each exit becomes a
# report row, and that nothing is left up.

load helpers/stubs

setup() {
    kit_test_env
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-e2e.sh"
    export T="$BATS_TEST_TMPDIR"
    export SCENARIO_DIR="$T/scenarios"
    for s in demo-a demo-b; do mkdir -p "$SCENARIO_DIR/$s"; printf 'name=%s\n' "$s" > "$SCENARIO_DIR/$s/scenario.conf"; done
    printf 'demo-a  10.250.0.0/16  a\n      runnable with this bundle\ndemo-b  10.251.0.0/16  b\n      runnable with this bundle\n' > "$T/list.out"
    mkdir -p "$T/bundle"
    stub validate-stub 'echo "validate $*" >> "$STUB_LOG"; f="$T/rc-validate-$2"; [ -f "$f" ] && exit "$(cat "$f")"; exit 0'
    stub scenario-stub '
echo "scenario $*" >> "$STUB_LOG"
sub=$1; s=${2:-}
case "$sub" in
  list)    cat "$T/list.out" ;;
  status)  cat "$T/status.out" 2>/dev/null ;;
  down)    if [ -f "$T/int-down-$s" ]; then rm -f "$T/int-down-$s"; pg=$(cut -d" " -f5 /proc/$$/stat); kill -INT -- "-$pg"; sleep 1; fi
           echo done >> "$T/down-done-$s" ;;
  traffic) echo "      run record: $T/rec-$s.run"; [ -f "$T/term-traffic-$s" ] && kill -TERM "$PPID" && sleep 5 ;;
  check)   cat "$T/check-$s.out" 2>/dev/null ;;
esac
f="$T/rc-$sub-$s"; [ -f "$f" ] && exit "$(cat "$f")"; exit 0'
    export E2E_VALIDATE_CMD="$BIN/validate-stub" E2E_SCENARIO_CMD="$BIN/scenario-stub"
}

e2e() { kit_run "$SCRIPT" "$@"; }
full() { e2e --bundle "$T/bundle" --capture-ifs lab_mirror0 --lab-bridge br-lab "$@"; }
calls() { sed -n 's/^\(validate\|scenario\) //p' "$STUB_LOG"; }

@test "the whole run: validate areas, then up/traffic/down per scenario, then check each against its own run record" {
    run full
    echo "$output"
    [ "$status" -eq 0 ]
    logdir=$(ls -d "$KIT_EVIDENCE_DIR"/e2e-*/ | head -1); logdir=${logdir%/}
    run calls
    [ "${lines[0]}" = "--area network --lab-bridge br-lab --capture-ifs lab_mirror0 --out $logdir" ]
    [ "${lines[1]}" = "--area capture --out $logdir" ]
    [ "${lines[2]}" = "--area gns3 --out $logdir" ]
    [ "${lines[3]}" = "status" ]
    [ "${lines[4]}" = "list --bundle $T/bundle" ]
    [ "${lines[5]}" = "up demo-a --bundle $T/bundle" ]
    [ "${lines[6]}" = "traffic demo-a" ]
    [ "${lines[7]}" = "down demo-a" ]
    [ "${lines[8]}" = "up demo-b --bundle $T/bundle" ]
    [ "${lines[9]}" = "traffic demo-b" ]
    [ "${lines[10]}" = "down demo-b" ]
    [ "${lines[11]}" = "check demo-a --run $T/rec-demo-a.run" ]
    [ "${lines[12]}" = "check demo-b --run $T/rec-demo-b.run" ]
    report="$logdir.md"
    grep -q '^| check demo-b | PASS |' "$report"
    grep -q '^| validate network | PASS |' "$report"
}

@test "--capture-ifs, --lab-bridge and --bundle are required; nothing is guessed and no child runs" {
    run e2e --bundle "$T/bundle" --lab-bridge br-lab
    [ "$status" -eq 1 ]; [[ "$output" == *"--capture-ifs"* ]]
    run e2e --bundle "$T/bundle" --capture-ifs lab_mirror0
    [ "$status" -eq 1 ]; [[ "$output" == *"--lab-bridge"* ]]
    run e2e --capture-ifs lab_mirror0 --lab-bridge br-lab
    [ "$status" -eq 1 ]; [[ "$output" == *"--bundle"* ]]
    [ ! -s "$STUB_LOG" ]
}

@test "--skip-validate runs no validation, and needs no interface or bridge" {
    run e2e --bundle "$T/bundle" --skip-validate
    echo "$output"
    [ "$status" -eq 0 ]
    run grep -c '^validate ' "$STUB_LOG"
    [ "$output" = 0 ]
}

@test "an unknown --scenarios name is refused before any child runs" {
    run full --scenarios demo-a,nope
    [ "$status" -eq 1 ]
    [[ "$output" == *"no scenario 'nope'"* ]]
    [ ! -s "$STUB_LOG" ]
}

@test "--scenarios runs only the named ones, in the order given" {
    run full --scenarios demo-b
    [ "$status" -eq 0 ]
    run grep -c 'demo-a' "$STUB_LOG"
    [ "$output" = 0 ]
    grep -q '^scenario check demo-b --run ' "$STUB_LOG"
}

@test "a failed up is a FAIL, the scenario is still taken down, and the others still run" {
    echo 1 > "$T/rc-up-demo-a"
    run full
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  up demo-a"* ]]
    grep -q '^scenario down demo-a' "$STUB_LOG"
    ! grep -q '^scenario traffic demo-a' "$STUB_LOG"
    ! grep -q '^scenario check demo-a' "$STUB_LOG"
    grep -q '^scenario check demo-b --run ' "$STUB_LOG"
}

@test "a scenario this bundle cannot run is a SKIP with the reason, and is never up" {
    printf 'demo-a  10.250.0.0/16  a\n      runnable with this bundle\ndemo-b  10.251.0.0/16  b\n      NOT runnable: missing strongswan\n' > "$T/list.out"
    run full
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  up demo-b: not runnable with this bundle"* ]]
    ! grep -q '^scenario up demo-b' "$STUB_LOG"
}

@test "a check that SKIPped (Malcolm not answering) is a WARN in the report, never a PASS" {
    printf 'SKIP  Arkime did not answer on 127.0.0.1:8443 — start Malcolm\n\nREADY — check: 0 check(s) passed, 1 skipped\n' > "$T/check-demo-a.out"
    run full
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"WARN  check demo-a: skipped: Arkime did not answer"* ]]
}

@test "a failing check makes the run exit 1, and the report says which" {
    echo 1 > "$T/rc-check-demo-b"
    run full
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  check demo-b"* ]]
}

@test "an interrupted run takes down the scenario that is up at that moment" {
    touch "$T/term-traffic-demo-a"
    run full
    echo "$output"
    [ "$status" -ne 0 ]
    grep -q '^scenario down demo-a' "$STUB_LOG"
    ! grep -q '^scenario up demo-b' "$STUB_LOG"
}

@test "a run in which no scenario ran is a FAIL, never READY: nothing was proven" {
    printf 'demo-a  10.250.0.0/16  a\n      NOT runnable: missing strongswan\ndemo-b  10.251.0.0/16  b\n      NOT runnable: missing strongswan\n' > "$T/list.out"
    run full
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  scenarios: no scenario ran and was judged in Malcolm"* ]]
}

@test "a scenario that is already up (not brought up by this run) is refused before any scenario is touched" {
    printf 'demo-a           up         taps lab-tap0,lab-tap1          last run none\ndemo-b           down       taps -                          last run none\n' > "$T/status.out"
    run full
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"demo-a is already up"* ]]
    ! grep -qE '^scenario (up|down|traffic) ' "$STUB_LOG"
}

@test "a second interrupt during teardown does not stop down: the scenario is still taken down" {
    touch "$T/term-traffic-demo-a" "$T/int-down-demo-a"
    run setsid -w env PATH="$KIT_PATH" "$SCRIPT" --bundle "$T/bundle" --capture-ifs lab_mirror0 --lab-bridge br-lab
    echo "$output"
    [ "$status" -ne 0 ]
    [ "$(cat "$T/down-done-demo-a" 2>/dev/null)" = "done" ]
}
