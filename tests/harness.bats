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
    # the dedicated key's private half on the operator's machine (a fixture, never a real key)
    KEY="$BATS_TEST_TMPDIR/keys/agent"; mkdir -p "${KEY%/*}"
    printf -- '-----BEGIN OPENSSH %s KEY-----
fixture-key-material
-----END OPENSSH %s KEY-----
' PRIVATE PRIVATE > "$KEY"
    printf 'ssh-ed25519 AAAAfixture agent
' > "$KEY.pub"
    SSHCFG="$KIT_EVIDENCE_DIR/r770-staging-vm-pve-9770.ssh_config"
    GUEST_KH="$KIT_EVIDENCE_DIR/r770-staging-vm-pve-9770.known_hosts"
    # wait-ssh and tunnel reach the guest through the hypervisor, so they name it too
    GS=(--pve pve --vmid 9770 --mgmt-host guest --guest-user ubuntu)
    cd "$BATS_TEST_TMPDIR"
}
# every call carries the hypervisor login; tests about those flags call bare()
vm() { kit_run "$SCRIPT" "$@" --pve-user root --identity "$KEY"; }
bare() { kit_run "$SCRIPT" "$@"; }


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
    [[ "$output" == *"== GATE: start VM 9770 =="*"-- proposed --"*"qm start 9770"*"-- rollback --"*"DRY-RUN:"* ]]
    VM_STATE=running run vm stop --pve pve --vmid 9770 --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"== GATE: stop VM 9770 =="*"-- proposed --"*"qm shutdown 9770 --timeout 180"*"-- rollback --"*"DRY-RUN:"*"qm shutdown 9770"* ]]
    ! grep -qE ' qm (start|shutdown|rollback) ' "$STUB_LOG"
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

@test "start is gated: real state, the exact qm line, stop as rollback; unattended without --yes nothing starts" {
    VM_STATE=stopped KIT_YES=0 run vm start --pve pve --vmid 9770
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"== GATE: start VM 9770 =="* && "$output" == *"-- current --"*"vm 9770 on pve is stopped"*"name: r770-test"* ]]
    [[ "$output" == *"-- proposed --"*"qm start 9770"* && "$output" == *"-- rollback --"*"r770-staging-vm.sh stop --pve pve --pve-user root --identity $KEY --vmid 9770"* ]]
    [[ "$output" == *"non-interactive"* ]]
    run grep -q ' qm start ' "$STUB_LOG"; [ "$status" -ne 0 ]
    VM_STATE=stopped KIT_YES=0 run vm start --pve pve --vmid 9770 --yes
    echo "$output"; [ "$status" -eq 0 ]
    [[ "$output" == *"-- accepted via --yes --"* && "$output" == *"PASS  VM 9770 started"* ]]
    grep -q 'pve qm start 9770$' "$STUB_LOG"
}

@test "stop is gated: real state, the exact qm line, start as rollback; unattended without --yes nothing shuts down" {
    VM_STATE=running KIT_YES=0 run vm stop --pve pve --vmid 9770
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"== GATE: stop VM 9770 =="* && "$output" == *"-- current --"*"vm 9770 on pve is running"* ]]
    [[ "$output" == *"-- proposed --"*"qm shutdown 9770 --timeout 180"* && "$output" == *"-- rollback --"*"r770-staging-vm.sh start --pve pve --pve-user root --identity $KEY --vmid 9770"* ]]
    [[ "$output" == *"-- proposed --"*"unsaved state in the guest is lost"*"-- rollback --"* ]]
    rb=${output##*-- rollback --}; [[ "${rb%%$'\n'non-interactive*}" != *"lost"* ]]
    run grep -q ' qm shutdown ' "$STUB_LOG"; [ "$status" -ne 0 ]
    VM_STATE=running KIT_YES=0 run vm stop --pve pve --vmid 9770 --yes
    [ "$status" -eq 0 ]; [[ "$output" == *"-- accepted via --yes --"* ]]
    grep -q 'pve qm shutdown 9770 --timeout 180$' "$STUB_LOG"
}

@test "start and stop that change nothing meet no gate, even unattended without --yes" {
    VM_STATE=running KIT_YES=0 run vm start --pve pve --vmid 9770
    [ "$status" -eq 0 ]; [[ "$output" == *"PASS  VM 9770 already running"* && "$output" != *"GATE"* ]]
    VM_STATE=stopped KIT_YES=0 run vm stop --pve pve --vmid 9770
    [ "$status" -eq 0 ]; [[ "$output" == *"PASS  VM 9770 already stopped"* && "$output" != *"GATE"* ]]
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


AG=(--pve pve --vmid 9770 --wan-net net0 --mgmt-host guest --guest-user ubuntu --probe 192.0.2.1:80)

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
    run vm wait-ssh 5 6 "${GS[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"unexpected argument"* ]]
    run vm tunnel extra "${GS[@]}" --local-port 8443
    [ "$status" -eq 1 ]; [[ "$output" == *"unexpected argument"* ]]
    run grep -q '^ssh' "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "airgap refuses a probe whose octets or port are out of range, before any ssh" {
    for pr in 192.0.2.300:80 1.2.3.4:0 1.2.3.4:99999 256.1.1.1:80; do
        run vm airgap on --pve pve --vmid 9770 --wan-net net0 --mgmt-host guest --guest-user ubuntu --probe "$pr"
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
    [[ "$output" == *"== GATE: air-gap VM 9770 (net0 link-down) =="*"-- proposed --"*"qm set 9770 --net0 "*"-- rollback --"*"DRY-RUN:"* ]]
    [[ "$output" != *"PASS  "* ]]
    run grep -qE ' qm set |/dev/tcp/' "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "airgap on is gated after the positive control: the live net0, the exact qm set, airgap off as rollback" {
    KIT_YES=0 run vm airgap on "${AG[@]}"
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"PASS  "*"positive control"* ]]     # read-only, so it runs before the question
    [[ "$output" == *"== GATE: air-gap VM 9770 (net0 link-down) =="* ]]
    [[ "$output" == *"-- current --"*"net0: virtio=BC:24:11:00:00:01,bridge=vmbr0"* ]]
    [[ "$output" == *"-- proposed --"*"qm set 9770 --net0 virtio=BC:24:11:00:00:01,bridge=vmbr0,link_down=1"* ]]
    [[ "$output" == *"-- rollback --"*"r770-staging-vm.sh airgap off --pve pve --pve-user root --identity $KEY --vmid 9770 --wan-net net0"*"an equivalent net0 value (Proxmox may reorder its keys)"* ]]
    run grep -q ' qm set ' "$STUB_LOG"; [ "$status" -ne 0 ]
    KIT_YES=0 run vm airgap on "${AG[@]}" --yes
    echo "$output"; [ "$status" -eq 0 ]; [[ "$output" == *"-- accepted via --yes --"* ]]
    grep -q 'pve qm set 9770 --net0 virtio=BC:24:11:00:00:01,bridge=vmbr0,link_down=1$' "$STUB_LOG"
}

@test "airgap off is gated: the live net0, the exact qm set, airgap on as rollback" {
    down_cfg
    KIT_YES=0 run vm airgap off "${AG[@]}"
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"== GATE: reconnect VM 9770 (net0 link-up) =="* ]]
    [[ "$output" == *"-- current --"*"net0: virtio=BC:24:11:00:00:01,bridge=vmbr0,link_down=1"* ]]
    [[ "$output" == *"-- proposed --"*"qm set 9770 --net0 virtio=BC:24:11:00:00:01,bridge=vmbr0"* ]]
    [[ "$output" == *"-- rollback --"*"r770-staging-vm.sh airgap on --pve pve --pve-user root --identity $KEY --vmid 9770 --wan-net net0"* ]]
    run grep -q ' qm set ' "$STUB_LOG"; [ "$status" -ne 0 ]
    KIT_YES=0 run vm airgap off "${AG[@]}" --yes
    [ "$status" -eq 0 ]; grep -q 'pve qm set 9770 --net0 virtio=BC:24:11:00:00:01,bridge=vmbr0$' "$STUB_LOG"
}

@test "airgap already in the asked state meets no gate, even unattended without --yes" {
    KIT_YES=0 run vm airgap off "${AG[@]}"
    echo "$output"; [ "$status" -eq 0 ]
    [[ "$output" != *"GATE"* && "$output" == *"PASS  "*"guest reaches 192.0.2.1:80"* ]]
    down_cfg
    KIT_YES=0 run vm airgap on "${AG[@]}"
    echo "$output"; [ "$status" -eq 2 ]
    [[ "$output" != *"GATE"* && "$output" == *"PASS  "*"cannot reach 192.0.2.1:80"* ]]
    run grep -q ' qm set ' "$STUB_LOG"; [ "$status" -ne 0 ]
}

@test "wait-ssh passes when the guest answers, also after a failed attempt, and fails when the time runs out" {
    stub sleep 'exit 0'
    GUEST_RC=0 run vm wait-ssh 0 "${GS[@]}"
    [ "$status" -eq 0 ]; [[ "$output" == *"PASS  "*"guest answers"* ]]
    rm -f "$QM_CONFIG.true"
    GUEST_FAIL_FIRST=1 run vm wait-ssh 30 "${GS[@]}"
    [ "$status" -eq 0 ]; [[ "$output" == *"PASS  "*"guest answers"* ]]
    [ "$(cat "$QM_CONFIG.true")" = 2 ]
    GUEST_RC=255 run vm wait-ssh 0 "${GS[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"did not answer within 0 s"* ]]
    run vm wait-ssh soon "${GS[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"seconds"* ]]
}

@test "tunnel forwards a loopback port to the guest's 443 and nothing else; its exit code is judged" {
    run vm tunnel "${GS[@]}" --local-port 8443 --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN:"*"-N"*"127.0.0.1:8443:127.0.0.1:443"*"guest"* && "$output" == *"ServerAliveInterval=30"* ]]
    [[ "$output" != *"PASS  "* ]]
    run vm tunnel "${GS[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"needs --local-port"* ]]
    TUNNEL_RC=0 run vm tunnel "${GS[@]}" --local-port 8443
    [ "$status" -eq 0 ]; [[ "$output" == *"PASS  "* ]]
    TUNNEL_RC=130 run vm tunnel "${GS[@]}" --local-port 8443
    [ "$status" -eq 0 ]; [[ "$output" == *"PASS  "* ]]
    TUNNEL_RC=255 run vm tunnel "${GS[@]}" --local-port 8443
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  "*"255"* ]]
}

@test "the harness is operator-side only: nothing shipped references harness/" {
    run grep -rn 'harness/' "$BATS_TEST_DIRNAME/../scripts" "$BATS_TEST_DIRNAME/../staging" "$BATS_TEST_DIRNAME/../config"
    [ "$status" -ne 0 ]
}

# ── the per-run ssh config (#25) ────────────────────────────────────────────

@test "--pve-user and --identity are required by every subcommand, shape-checked, and the key must be a private key file" {
    local i a
    for i in 1 2 3; do
        case "$i" in
            1) a=(status --pve pve --vmid 9770) ;;
            2) a=(wait-ssh 0 "${GS[@]}") ;;
            3) a=(tunnel "${GS[@]}" --local-port 8443) ;;
        esac
        run bare "${a[@]}" --identity "$KEY"
        [ "$status" -eq 1 ]; [[ "$output" == *"needs --pve-user"* ]]
        run bare "${a[@]}" --pve-user root
        [ "$status" -eq 1 ]; [[ "$output" == *"needs --identity"* ]]
    done
    run bare status --pve pve --vmid 9770 --pve-user 'root;id' --identity "$KEY"
    [ "$status" -eq 1 ]; [[ "$output" == *"--pve-user"* ]]
    run bare status --pve pve --vmid 9770 --pve-user root --identity "keys/agent"
    [ "$status" -eq 1 ]; [[ "$output" == *"--identity"* ]]
    run bare status --pve pve --vmid 9770 --pve-user root --identity "$BATS_TEST_TMPDIR/keys/absent"
    [ "$status" -eq 1 ]; [[ "$output" == *"no such readable file"* ]]
    run bare status --pve pve --vmid 9770 --pve-user root --identity "$KEY.pub"
    [ "$status" -eq 1 ]; [[ "$output" == *"not a private key"* ]]
    ! grep -q '^ssh' "$STUB_LOG"
    [ ! -e "$SSHCFG" ]
}

@test "the guest subcommands need --pve, --vmid and --guest-user: the guest is reached only through the hypervisor" {
    run vm wait-ssh 0 --mgmt-host guest --guest-user ubuntu --vmid 9770
    [ "$status" -eq 1 ]; [[ "$output" == *"needs --pve"* ]]
    run vm tunnel --mgmt-host guest --guest-user ubuntu --pve pve --local-port 8443
    [ "$status" -eq 1 ]; [[ "$output" == *"needs --vmid"* ]]
    run vm wait-ssh 0 --pve pve --vmid 9770 --mgmt-host guest
    [ "$status" -eq 1 ]; [[ "$output" == *"needs --guest-user"* ]]
    run vm airgap on --pve pve --vmid 9770 --wan-net net0 --mgmt-host guest --probe 192.0.2.1:80
    [ "$status" -eq 1 ]; [[ "$output" == *"needs --guest-user"* ]]
    run vm wait-ssh 0 "${GS[@]}" --guest-user 'ubuntu x'
    [ "$status" -eq 1 ]; [[ "$output" == *"--guest-user"* ]]
    ! grep -q '^ssh' "$STUB_LOG"
}

@test "the per-run ssh config: the hypervisor alias with the key and strict checking, the guest only by ProxyJump with its own known_hosts, no secret" {
    run vm wait-ssh 0 "${GS[@]}"
    echo "$output"; [ "$status" -eq 0 ]
    cat "$SSHCFG"
    run awk '/^Host /{h=$2} h=="r770-staging-pve" && NF {print $1, $2}' "$SSHCFG"
    [[ "$output" == *"HostName pve"* && "$output" == *"User root"* ]]
    [[ "$output" == *"IdentityFile \"$KEY\""* && "$output" == *"IdentitiesOnly yes"* ]]
    [[ "$output" == *"BatchMode yes"* && "$output" == *"StrictHostKeyChecking yes"* ]]
    [[ "$output" != *"UserKnownHostsFile"* && "$output" != *"accept-new"* ]]
    run awk '/^Host /{h=$2} h=="guest" && NF {print $1, $2}' "$SSHCFG"
    [[ "$output" == *"ProxyJump r770-staging-pve"* && "$output" == *"IdentityFile \"$KEY\""* ]]
    [[ "$output" == *"StrictHostKeyChecking accept-new"* && "$output" == *"UserKnownHostsFile \"$GUEST_KH\""* ]]
    [ "$(grep -c '^Host ' "$SSHCFG")" -eq 2 ]
    ! grep -q 'fixture-key-material\|PRIVATE' "$SSHCFG"
    # a hypervisor-only run has no guest stanza at all
    run vm status --pve pve --vmid 9770
    [ "$status" -eq 0 ]
    [ "$(grep -c '^Host ' "$SSHCFG")" -eq 1 ]
}

@test "the per-run ssh config is mode 0600, even over a looser file, and is rewritten from the arguments every run" {
    mkdir -p "$KIT_EVIDENCE_DIR"
    printf 'Host r770-staging-pve\n    HostName 198.51.100.66\n' > "$SSHCFG"; chmod 644 "$SSHCFG"
    run vm status --pve pve --vmid 9770
    echo "$output"; [ "$status" -eq 0 ]
    [ "$(stat -c %a "$SSHCFG")" = 600 ]
    ! grep -q 198.51.100.66 "$SSHCFG"
    grep -q '^    HostName pve$' "$SSHCFG"
    [ -z "$(find "$KIT_EVIDENCE_DIR" -name '*.tmp.*')" ]
}

@test "every ssh call goes through the per-run config with -F, the guest as user@host, and ~/.ssh is never touched" {
    export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME/.ssh"
    printf 'Host *\n    User someone-else\n' > "$HOME/.ssh/config"
    before=$(ls -la "$HOME/.ssh"; cat "$HOME/.ssh/config")
    run vm status --pve pve --vmid 9770;              [ "$status" -eq 0 ]
    run vm airgap on "${AG[@]}";                      [ "$status" -eq 0 ]
    run vm wait-ssh 0 "${GS[@]}";                     [ "$status" -eq 0 ]
    TUNNEL_RC=0 run vm tunnel "${GS[@]}" --local-port 8443; [ "$status" -eq 0 ]
    cat "$STUB_LOG"
    run grep -c '^ssh ' "$STUB_LOG"; [ "$output" -gt 0 ]
    run grep -vc "^ssh -F $SSHCFG " "$STUB_LOG"; [ "$output" = 0 ]
    grep -q "^ssh -F $SSHCFG r770-staging-pve qm status 9770" "$STUB_LOG"
    grep -q "^ssh -F $SSHCFG ubuntu@guest true" "$STUB_LOG"
    grep -q "^ssh -F $SSHCFG -N .*ubuntu@guest$" "$STUB_LOG"
    [ "$before" = "$(ls -la "$HOME/.ssh"; cat "$HOME/.ssh/config")" ]
    # no scp and no ssh outside the four helpers anywhere in the script
    run grep -nE '(^|[^-])\bscp\b|(run |^|[|(] *)ssh (-o|-N|"\$)' "$SCRIPT"
    echo "$output"; [ "$status" -ne 0 ]
}

@test "an evidence directory ssh cannot carry safely (space, \$, ;, quote, %) is refused before any ssh" {
    for d in "with space" 'dollar$x' 'semi;colon' 'quo"te' 'per%cent'; do
        KIT_EVIDENCE_DIR="$BATS_TEST_TMPDIR/$d" run vm status --pve pve --vmid 9770
        echo "$d: $output"
        [ "$status" -eq 1 ]; [[ "$output" == *"[A-Za-z0-9._/-]"* ]]
        [ ! -e "$BATS_TEST_TMPDIR/$d/r770-staging-vm-pve-9770.ssh_config" ]
    done
    ! grep -q '^ssh' "$STUB_LOG"
}
