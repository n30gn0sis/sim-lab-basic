#!/usr/bin/env bats
# r770-staging-vm.sh: the operator-side VM driver, with ssh stubbed. No test
# reaches a hypervisor or a guest.
load helpers/stubs

setup() {
    kit_test_env
    SCRIPT="$BATS_TEST_DIRNAME/../harness/r770-staging-vm.sh"
    export QM_CONFIG="$BATS_TEST_TMPDIR/qm.conf" QM_SNAPS="$BATS_TEST_TMPDIR/qm.snaps"
    printf 'name: r770-test\nmemory: 16384\nnet0: virtio=BC:24:11:00:00:01,bridge=vmbr0\nnet1: virtio=BC:24:11:00:00:02,bridge=vmbr9\n' > "$QM_CONFIG"
    printf '%s\n' '`-> clean-a    2026-01-01 00:00:00    a clean base' ' `-> current    You are here!' > "$QM_SNAPS"
    # The probe's answer depends on the NIC: PROBE_UP_RC while net0 has no
    # link_down=1, PROBE_DOWN_RC once it has. QM_EMPTY_ON=N: the Nth `qm config`
    # read prints nothing. GUEST_FAIL_FIRST=N: the first N `true` calls fail.
    stub ssh '
echo "ssh $*" >> "$STUB_LOG"
case "$*" in
    *"/dev/tcp/"*)          if grep -q "^net0:.*link_down=1" "$QM_CONFIG"; then exit "${PROBE_DOWN_RC:-1}"; else exit "${PROBE_UP_RC:-0}"; fi ;;
    "-N "*|*" -N "*)         exit "${TUNNEL_RC:-0}" ;;
    *" qm status "*)        echo "status: ${VM_STATE:-stopped}" ;;
    *" qm config "*)        [ "${QM_CONFIG_FAIL:-0}" = 1 ] && exit 255
                            n=$(cat "$QM_CONFIG.reads" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$QM_CONFIG.reads"
                            [ "${QM_EMPTY_ON:-}" = "$n" ] && exit 0
                            cat "$QM_CONFIG" ;;
    *" qm listsnapshot "*)  [ "${SNAPS_FAIL:-0}" = 1 ] && exit 255
                            cat "$QM_SNAPS" ;;
    *" qm set "*)           [ "${QMSET_RC:-0}" != 0 ] && exit "$QMSET_RC"
                            prev=""; for a in "$@"; do
                                case "$prev" in --net*) sed -i "s|^${prev#--}: .*|${prev#--}: $a|" "$QM_CONFIG" ;; esac
                                prev="$a"; done ;;
    *" true")               n=$(cat "$QM_CONFIG.true" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$QM_CONFIG.true"
                            [ "$n" -le "${GUEST_FAIL_FIRST:-0}" ] && exit 255
                            exit "${GUEST_RC:-0}" ;;
esac
exit 0'
    cd "$BATS_TEST_TMPDIR"
}
vm() { kit_run "$SCRIPT" "$@"; }


@test "every subcommand refuses without --pve and --vmid, and refuses a value that is not a name or a number" {
    run vm status --vmid 9770
    [ "$status" -eq 1 ]; [[ "$output" == *"needs --pve"* ]]
    run vm status --pve pve
    [ "$status" -eq 1 ]; [[ "$output" == *"needs --vmid"* ]]
    run vm status --pve pve --vmid '9770;reboot'
    [ "$status" -eq 1 ]; [[ "$output" == *"--vmid"* ]]
    run vm status --pve 'pve host' --vmid 9770
    [ "$status" -eq 1 ]; [[ "$output" == *"--pve"* ]]
    ! grep -q '^ssh' "$STUB_LOG"
}

@test "status prints the state, the snapshots and the NICs, and changes nothing" {
    VM_STATE=running run vm status --pve pve --vmid 9770
    echo "$output"; [ "$status" -eq 0 ]
    [[ "$output" == *"running"* && "$output" == *"clean-a"* && "$output" == *"net0: virtio"* && "$output" == *"name: r770-test"* ]]
    ! grep -qE ' qm (set|start|shutdown|rollback|snapshot) ' "$STUB_LOG"
}

@test "rollback refuses a snapshot the VM does not have" {
    run vm rollback --pve pve --vmid 9770 --snapshot nope
    [ "$status" -eq 1 ]; [[ "$output" == *"no snapshot 'nope'"* ]]
    ! grep -q ' qm rollback ' "$STUB_LOG"
}

@test "rollback is gated: an unattended run without --yes stops and rolls nothing back" {
    KIT_YES=0 run vm rollback --pve pve --vmid 9770 --snapshot clean-a
    [ "$status" -eq 1 ]
    [[ "$output" == *"-- current --"* && "$output" == *"name: r770-test"* && "$output" == *"-- proposed --"* && "$output" == *"-- rollback --"* ]]
    ! grep -q ' qm rollback ' "$STUB_LOG"
}

@test "rollback with --yes runs exactly qm rollback <vmid> <snapshot>" {
    run vm rollback --pve pve --vmid 9770 --snapshot clean-a --yes
    echo "$output"; [ "$status" -eq 0 ]
    grep -q 'pve qm rollback 9770 clean-a$' "$STUB_LOG"
}

@test "--dry-run prints the command and runs none that changes the VM" {
    run vm rollback --pve pve --vmid 9770 --snapshot clean-a --dry-run
    [ "$status" -eq 0 ]; [[ "$output" == *"DRY-RUN:"*"qm rollback 9770 clean-a"* ]]
    VM_STATE=stopped run vm start --pve pve --vmid 9770 --dry-run
    [ "$status" -eq 0 ]; [[ "$output" == *"DRY-RUN:"*"qm start 9770"* ]]
    ! grep -qE ' qm (start|rollback) ' "$STUB_LOG"
}

@test "start and stop are idempotent" {
    VM_STATE=running run vm start --pve pve --vmid 9770
    [ "$status" -eq 0 ]; [[ "$output" == *"already running"* ]]
    VM_STATE=stopped run vm stop --pve pve --vmid 9770
    [ "$status" -eq 0 ]; [[ "$output" == *"already stopped"* ]]
    run grep -qE ' qm (start|shutdown) ' "$STUB_LOG"; [ "$status" -ne 0 ]
    VM_STATE=stopped run vm start --pve pve --vmid 9770
    [ "$status" -eq 0 ]; grep -q 'pve qm start 9770$' "$STUB_LOG"
    VM_STATE=running run vm stop --pve pve --vmid 9770
    [ "$status" -eq 0 ]; grep -q 'pve qm shutdown 9770 --timeout 180$' "$STUB_LOG"
}

@test "snapshot never overwrites: an existing name is refused, a new one is taken with its description quoted" {
    run vm snapshot --pve pve --vmid 9770 --snapshot clean-a
    [ "$status" -eq 1 ]; [[ "$output" == *"already exists"* ]]
    run grep -q ' qm snapshot ' "$STUB_LOG"; [ "$status" -ne 0 ]
    run vm snapshot --pve pve --vmid 9770 --snapshot clean-b --description 'key and second NIC'
    echo "$output"; [ "$status" -eq 0 ]
    grep -qF "pve qm snapshot 9770 clean-b --description 'key and second NIC'" "$STUB_LOG"
    run vm snapshot --pve pve --vmid 9770 --snapshot clean-c --description 'x; reboot'
    [ "$status" -eq 1 ]; [[ "$output" == *"--description"* ]]
}

@test "the script holds no command that destroys a VM, a disk or a snapshot" {
    run grep -nE 'qm (destroy|delsnapshot|unlink)|pct destroy|lvremove|zfs destroy' "$SCRIPT"
    [ "$status" -ne 0 ]
}

@test "a snapshot exists only when its NAME matches: description words and the current pseudo-entry are not snapshots" {
    run vm snapshot --pve pve --vmid 9770 --snapshot base
    echo "$output"; [ "$status" -eq 0 ]
    grep -q 'pve qm snapshot 9770 base$' "$STUB_LOG"
    run vm rollback --pve pve --vmid 9770 --snapshot base --yes
    [ "$status" -eq 1 ]; [[ "$output" == *"no snapshot 'base'"* ]]
    run vm rollback --pve pve --vmid 9770 --snapshot current --yes
    [ "$status" -eq 1 ]; [[ "$output" == *"no snapshot 'current'"* ]]
    ! grep -q ' qm rollback ' "$STUB_LOG"
}


AG=(--pve pve --vmid 9770 --wan-net net0 --mgmt-host guest --probe 192.0.2.1:80)

@test "status exits 1, never 0, when the snapshot list or the config cannot be read" {
    QM_CONFIG_FAIL=1 VM_STATE=running run vm status --pve pve --vmid 9770
    [ "$status" -eq 1 ]; [[ "$output" == *"cannot read"* ]]
    SNAPS_FAIL=1 VM_STATE=running run vm status --pve pve --vmid 9770
    [ "$status" -eq 1 ]; [[ "$output" == *"cannot read"* ]]
}

@test "a snapshot name is 2 to 40 characters" {
    run vm snapshot --pve pve --vmid 9770 --snapshot a
    [ "$status" -eq 1 ]; [[ "$output" == *"--snapshot"* ]]
    run vm snapshot --pve pve --vmid 9770 --snapshot "a$(printf 'b%.0s' $(seq 1 40))"
    [ "$status" -eq 1 ]; [[ "$output" == *"--snapshot"* ]]
    run vm snapshot --pve pve --vmid 9770 --snapshot "a$(printf 'b%.0s' $(seq 1 39))" --dry-run
    [ "$status" -eq 0 ]
    run vm snapshot --pve pve --vmid 9770 --snapshot ab --dry-run
    [ "$status" -eq 0 ]
}

@test "extra positional arguments are refused, with no ssh" {
    run vm status foo --pve pve --vmid 9770
    [ "$status" -eq 1 ]; [[ "$output" == *"unexpected argument"* ]]
    run vm rollback foo --pve pve --vmid 9770 --snapshot clean-a
    [ "$status" -eq 1 ]; [[ "$output" == *"unexpected argument"* ]]
    run vm airgap on off "${AG[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"unexpected argument"* ]]
    run vm wait-ssh 5 6 --mgmt-host guest
    [ "$status" -eq 1 ]; [[ "$output" == *"unexpected argument"* ]]
    run vm tunnel extra --mgmt-host guest --local-port 8443
    [ "$status" -eq 1 ]; [[ "$output" == *"unexpected argument"* ]]
    run grep -q '^ssh' "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "airgap refuses a probe whose octets or port are out of range, before any ssh" {
    for pr in 192.0.2.300:80 1.2.3.4:0 1.2.3.4:99999 256.1.1.1:80; do
        run vm airgap on --pve pve --vmid 9770 --wan-net net0 --mgmt-host guest --probe "$pr"
        [ "$status" -eq 1 ]; [[ "$output" == *"--probe"* ]]
    done
    run grep -q '^ssh' "$STUB_LOG"; [ "$status" -ne 0 ]
}

# airgap: the probe's answer depends on the NIC, so one run sees "reachable
# before, unreachable after".
down_cfg() { sed -i 's|^net0: .*|&,link_down=1|' "$QM_CONFIG"; }
up_cfg() { sed -i 's|,link_down=1||' "$QM_CONFIG"; }

@test "airgap on: positive control first, then qm set, then read-back, then the probe fails; only net0 changes" {
    run vm airgap on "${AG[@]}"
    echo "$output"; [ "$status" -eq 0 ]
    grep -q 'pve qm set 9770 --net0 virtio=BC:24:11:00:00:01,bridge=vmbr0,link_down=1$' "$STUB_LOG"
    grep -q '^net1: virtio=BC:24:11:00:00:02,bridge=vmbr9$' "$QM_CONFIG"
    [[ "$output" == *"PASS  "*"positive control"* && "$output" == *"PASS  "*"link_down"* && "$output" == *"PASS  "*"cannot reach 192.0.2.1:80"* ]]
    seq=$(grep -oE 'dev/tcp|qm set|qm config' "$STUB_LOG" | tr '\n' ' ')
    [ "$seq" = "qm config dev/tcp qm set qm config dev/tcp " ]
}

@test "airgap on FAILs when the guest can still reach out after link_down" {
    PROBE_DOWN_RC=0 run vm airgap on "${AG[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  "*"still reaches 192.0.2.1:80"* ]]
}

@test "airgap on with a probe that fails BEFORE the gap: probe cannot prove the gap, nothing is sent" {
    PROBE_UP_RC=1 run vm airgap on "${AG[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  "*"probe cannot prove the gap"* ]]
    run grep -q ' qm set ' "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "airgap on FAILs, never passes, when the guest cannot be asked" {
    GUEST_RC=255 run vm airgap on "${AG[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  "*"probe was not run"* ]]
    [[ "$output" != *"PASS  "* ]]
    run grep -q ' qm set ' "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "airgap on when already link-down: WARN no positive control, nothing set, exit 2" {
    down_cfg
    run vm airgap on "${AG[@]}"
    echo "$output"; [ "$status" -eq 2 ]
    [[ "$output" == *"WARN  "*"no positive control"* && "$output" == *"already link-down"* ]]
    run grep -q ' qm set ' "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "airgap off strips the flag, reads it back live, and wants the probe to succeed" {
    down_cfg
    run vm airgap off "${AG[@]}"
    echo "$output"; [ "$status" -eq 0 ]
    grep -q 'pve qm set 9770 --net0 virtio=BC:24:11:00:00:01,bridge=vmbr0$' "$STUB_LOG"
    down_cfg
    PROBE_UP_RC=1 run vm airgap off "${AG[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  "*"cannot reach"* ]]
}

@test "airgap off FAILs when the guest cannot be asked" {
    down_cfg
    GUEST_RC=255 run vm airgap off "${AG[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  "*"probe was not run"* ]]
    [[ "$output" != *"PASS  "*"guest reaches"* ]]
}

@test "airgap reads the live value: every qm config is asked with --current" {
    run vm airgap on "${AG[@]}"
    [ "$status" -eq 0 ]
    grep -q ' qm config 9770 --current$' "$STUB_LOG"
    run grep -E ' qm config ' "$STUB_LOG"
    [ "$(printf '%s\n' "$output" | grep -vc -- '--current$')" -eq 0 ]
}

@test "airgap FAILs 'could not read' on an empty read-back, in both directions" {
    QM_EMPTY_ON=2 run vm airgap on "${AG[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  "*"could not read"* && "$output" != *"PASS  "*"has link_down=1"* ]]
    rm -f "$QM_CONFIG.reads"; down_cfg
    QM_EMPTY_ON=2 run vm airgap off "${AG[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  "*"could not read"* && "$output" != *"PASS  "*"no link_down"* ]]
}

@test "airgap FAILs 'probe could not be run' on every exit code but 0, 1 and 124" {
    for rc in 125 126 127 137 255; do
        up_cfg
        PROBE_DOWN_RC=$rc run vm airgap on "${AG[@]}"
        [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  "*"probe could not be run"* ]]
        [[ "$output" != *"PASS  "*"cannot reach"* ]]
    done
    down_cfg
    PROBE_UP_RC=137 run vm airgap off "${AG[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  "*"probe could not be run"* ]]
}

@test "airgap on: a timeout (124) after link_down means unreachable" {
    PROBE_DOWN_RC=124 run vm airgap on "${AG[@]}"
    [ "$status" -eq 0 ]; [[ "$output" == *"PASS  "*"cannot reach 192.0.2.1:80"* ]]
}

@test "airgap: a failing qm set is exit 1 and no PASS for the flag" {
    QMSET_RC=3 run vm airgap on "${AG[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"qm set failed"* && "$output" != *"PASS  "*"has link_down=1"* ]]
}

@test "airgap --dry-run changes nothing, probes nothing and claims nothing" {
    run vm airgap on "${AG[@]}" --dry-run
    [ "$status" -eq 0 ]; [[ "$output" == *"DRY-RUN:"*"link_down=1"* ]]
    [[ "$output" != *"PASS  "* ]]
    run grep -qE ' qm set |/dev/tcp/' "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "wait-ssh passes when the guest answers, also after a failed attempt, and fails when the time runs out" {
    stub sleep 'exit 0'
    GUEST_RC=0 run vm wait-ssh 0 --mgmt-host guest
    [ "$status" -eq 0 ]; [[ "$output" == *"PASS  "*"guest answers"* ]]
    rm -f "$QM_CONFIG.true"
    GUEST_FAIL_FIRST=1 run vm wait-ssh 30 --mgmt-host guest
    [ "$status" -eq 0 ]; [[ "$output" == *"PASS  "*"guest answers"* ]]
    [ "$(cat "$QM_CONFIG.true")" = 2 ]
    GUEST_RC=255 run vm wait-ssh 0 --mgmt-host guest
    [ "$status" -eq 1 ]; [[ "$output" == *"did not answer within 0 s"* ]]
    run vm wait-ssh soon --mgmt-host guest
    [ "$status" -eq 1 ]; [[ "$output" == *"seconds"* ]]
}

@test "tunnel forwards a loopback port to the guest's 443 and nothing else; its exit code is judged" {
    run vm tunnel --mgmt-host guest --local-port 8443 --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN:"*"-N"*"127.0.0.1:8443:127.0.0.1:443"*"guest"* && "$output" == *"ServerAliveInterval=30"* ]]
    [[ "$output" != *"PASS  "* ]]
    run vm tunnel --mgmt-host guest
    [ "$status" -eq 1 ]; [[ "$output" == *"needs --local-port"* ]]
    TUNNEL_RC=0 run vm tunnel --mgmt-host guest --local-port 8443
    [ "$status" -eq 0 ]; [[ "$output" == *"PASS  "* ]]
    TUNNEL_RC=130 run vm tunnel --mgmt-host guest --local-port 8443
    [ "$status" -eq 0 ]; [[ "$output" == *"PASS  "* ]]
    TUNNEL_RC=255 run vm tunnel --mgmt-host guest --local-port 8443
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  "*"255"* ]]
}

@test "the harness is operator-side only: nothing shipped references harness/" {
    run grep -rn 'harness/' "$BATS_TEST_DIRNAME/../scripts" "$BATS_TEST_DIRNAME/../staging" "$BATS_TEST_DIRNAME/../config"
    [ "$status" -ne 0 ]
}
