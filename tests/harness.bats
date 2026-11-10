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
    ! grep -qE ' qm (start|shutdown) ' "$STUB_LOG"
    VM_STATE=stopped run vm start --pve pve --vmid 9770
    [ "$status" -eq 0 ]; grep -q 'pve qm start 9770$' "$STUB_LOG"
    VM_STATE=running run vm stop --pve pve --vmid 9770
    [ "$status" -eq 0 ]; grep -q 'pve qm shutdown 9770 --timeout 180$' "$STUB_LOG"
}

@test "snapshot never overwrites: an existing name is refused, a new one is taken with its description quoted" {
    run vm snapshot --pve pve --vmid 9770 --snapshot clean-a
    [ "$status" -eq 1 ]; [[ "$output" == *"already exists"* ]]
    ! grep -q ' qm snapshot ' "$STUB_LOG"
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
