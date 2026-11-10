#!/usr/bin/env bats
# r770-staging-vm.sh: the operator-side VM driver, with ssh stubbed. No test
# reaches a hypervisor or a guest.
load helpers/stubs

setup() {
    kit_test_env
    SCRIPT="$BATS_TEST_DIRNAME/../harness/r770-staging-vm.sh"
    export QM_CONFIG="$BATS_TEST_TMPDIR/qm.conf" QM_SNAPS="$BATS_TEST_TMPDIR/qm.snaps"
    printf 'memory: 16384\nnet0: virtio=BC:24:11:00:00:01,bridge=vmbr0\nnet1: virtio=BC:24:11:00:00:02,bridge=vmbr9\n' > "$QM_CONFIG"
    printf '%s\n' '`-> clean-a    2026-01-01 00:00:00    a clean base' ' `-> current    You are here!' > "$QM_SNAPS"
    stub ssh '
echo "ssh $*" >> "$STUB_LOG"
case "$*" in
    *"/dev/tcp/"*)          exit "${PROBE_RC:-1}" ;;
    *" qm status "*)        echo "status: ${VM_STATE:-stopped}" ;;
    *" qm config "*)        cat "$QM_CONFIG" ;;
    *" qm listsnapshot "*)  cat "$QM_SNAPS" ;;
    *" qm set "*)           prev=""; for a in "$@"; do
                                case "$prev" in --net*) sed -i "s|^${prev#--}: .*|${prev#--}: $a|" "$QM_CONFIG" ;; esac
                                prev="$a"; done ;;
    *" true")               exit "${GUEST_RC:-0}" ;;
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
    [[ "$output" == *"running"* && "$output" == *"clean-a"* && "$output" == *"net0: virtio"* ]]
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
    [[ "$output" == *"-- current --"* && "$output" == *"-- proposed --"* && "$output" == *"-- rollback --"* ]]
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

@test "airgap needs the NIC, the guest and the probe, and refuses a probe that is not address:port" {
    run vm airgap on --pve pve --vmid 9770 --mgmt-host guest --probe 192.0.2.1:80
    [ "$status" -eq 1 ]; [[ "$output" == *"needs --wan-net"* ]]
    run vm airgap on --pve pve --vmid 9770 --wan-net net0 --probe 192.0.2.1:80
    [ "$status" -eq 1 ]; [[ "$output" == *"needs --mgmt-host"* ]]
    run vm airgap on --pve pve --vmid 9770 --wan-net net0 --mgmt-host guest
    [ "$status" -eq 1 ]; [[ "$output" == *"needs --probe"* ]]
    run vm airgap on --pve pve --vmid 9770 --wan-net net0 --mgmt-host guest --probe 'example.com:80'
    [ "$status" -eq 1 ]; [[ "$output" == *"--probe"* ]]
    run vm airgap sideways "${AG[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"on or off"* ]]
    ! grep -q ' qm set ' "$STUB_LOG"
}

@test "airgap on sets link_down on the named NIC only, and passes when the guest's probe fails" {
    PROBE_RC=1 run vm airgap on "${AG[@]}"
    echo "$output"; [ "$status" -eq 0 ]
    grep -q 'pve qm set 9770 --net0 virtio=BC:24:11:00:00:01,bridge=vmbr0,link_down=1$' "$STUB_LOG"
    grep -q '^net1: virtio=BC:24:11:00:00:02,bridge=vmbr9$' "$QM_CONFIG"
    [[ "$output" == *"PASS  "*"link_down"* && "$output" == *"PASS  "*"cannot reach 192.0.2.1:80"* ]]
}

@test "airgap on FAILs when the guest can still reach out" {
    PROBE_RC=0 run vm airgap on "${AG[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  "*"still reaches 192.0.2.1:80"* ]]
}

@test "airgap on FAILs, never passes, when the guest cannot be asked" {
    GUEST_RC=255 PROBE_RC=1 run vm airgap on "${AG[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  "*"probe was not run"* ]]
}

@test "airgap on twice sets nothing the second time; airgap off strips the flag and wants the probe to succeed" {
    PROBE_RC=1 vm airgap on "${AG[@]}" >/dev/null
    : > "$STUB_LOG"
    PROBE_RC=1 run vm airgap on "${AG[@]}"
    [ "$status" -eq 0 ]; [[ "$output" == *"already link-down"* ]]
    run grep -q ' qm set ' "$STUB_LOG"; [ "$status" -ne 0 ]
    PROBE_RC=0 run vm airgap off "${AG[@]}"
    echo "$output"; [ "$status" -eq 0 ]
    grep -q 'pve qm set 9770 --net0 virtio=BC:24:11:00:00:01,bridge=vmbr0$' "$STUB_LOG"
    PROBE_RC=1 run vm airgap off "${AG[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  "*"cannot reach"* ]]
}

@test "airgap --dry-run changes nothing and claims nothing" {
    run vm airgap on "${AG[@]}" --dry-run
    [ "$status" -eq 0 ]; [[ "$output" == *"DRY-RUN:"*"link_down=1"* ]]
    [[ "$output" != *"PASS  "* ]]
    ! grep -q ' qm set ' "$STUB_LOG"
}

@test "wait-ssh passes when the guest answers and fails when the time runs out" {
    GUEST_RC=0 run vm wait-ssh 0 --mgmt-host guest
    [ "$status" -eq 0 ]; [[ "$output" == *"PASS  "*"guest answers"* ]]
    GUEST_RC=255 run vm wait-ssh 0 --mgmt-host guest
    [ "$status" -eq 1 ]; [[ "$output" == *"did not answer within 0 s"* ]]
    run vm wait-ssh soon --mgmt-host guest
    [ "$status" -eq 1 ]; [[ "$output" == *"seconds"* ]]
}

@test "tunnel forwards a loopback port to the guest's 443 and nothing else" {
    run vm tunnel --mgmt-host guest --local-port 8443 --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN:"*"-N"*"127.0.0.1:8443:127.0.0.1:443"*"guest"* ]]
    run vm tunnel --mgmt-host guest
    [ "$status" -eq 1 ]; [[ "$output" == *"needs --local-port"* ]]
}

@test "airgap FAILs, never passes, when the probe could not be run; a timeout still means unreachable" {
    for rc in 255 127 126; do
        GUEST_RC=0 PROBE_RC=$rc run vm airgap on "${AG[@]}"
        [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  "*"probe could not be run"* ]]
        [[ "$output" != *"PASS  "*"cannot reach"* ]]
    done
    GUEST_RC=0 PROBE_RC=255 run vm airgap off "${AG[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  "*"probe could not be run"* ]]
    GUEST_RC=0 PROBE_RC=124 run vm airgap on "${AG[@]}"
    [ "$status" -eq 0 ]; [[ "$output" == *"PASS  "*"cannot reach 192.0.2.1:80"* ]]
}
