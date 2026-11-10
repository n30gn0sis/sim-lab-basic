#!/usr/bin/env bash
#
# r770-staging-vm.sh — drive the Proxmox VM that stands in for the R770 during
# a rehearsal. Runs on the OPERATOR'S machine: neither the staging host nor the
# R770. Every change to the VM is one `qm` command sent over ssh to the
# hypervisor; nothing here destroys a VM, a disk or a snapshot.
#
#   r770-staging-vm.sh status    --pve H --vmid N
#   r770-staging-vm.sh rollback  --pve H --vmid N --snapshot NAME        (GATED: discards the VM's state)
#   r770-staging-vm.sh start     --pve H --vmid N
#   r770-staging-vm.sh stop      --pve H --vmid N
#   r770-staging-vm.sh snapshot  --pve H --vmid N --snapshot NAME [--description TEXT]
#   r770-staging-vm.sh airgap on|off --pve H --vmid N --wan-net netN --mgmt-host G --probe IP:PORT
#   r770-staging-vm.sh wait-ssh SECONDS --mgmt-host G
#   r770-staging-vm.sh tunnel    --mgmt-host G --local-port N           (foreground; Ctrl-C ends it)
#
#   --pve H        the hypervisor's ssh host (key login; never a password)
#   --vmid N       the VM
#   --wan-net netN the VM's internet-facing NIC, as `status` names it; airgap sets it link-down
#   --mgmt-host G  the guest's ssh host, reached on a NIC airgap does not touch
#   --probe IP:PORT an outside address the guest reaches when it is NOT air-gapped
#   --yes / --non-interactive / --dry-run   as everywhere in the kit
#
#   0  done · 2  done with warnings · 1  refused or failed
#
# airgap proves what it did: the flag is read back from the VM's config, and
# the probe is run INSIDE the guest. On: the probe must fail. Off: it must
# succeed. A guest that cannot be asked is a FAIL, never a pass.
#
# Nothing is defaulted: the VM, the hypervisor and the snapshot are arguments
# the operator takes from `status` and `qm list`, never names this script picks.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"

PVE=""; VMID=""; SNAP=""; DESC=""; WAN_NET=""; MGMT=""; PROBE=""; LPORT=""
usage() { usage_from_header 3; exit 0; }

need_arg() {  # need_arg <flag> <value> — die naming the flag when the value is empty
    [ -n "$2" ] || die "$SUB needs $1"
}
valid() {  # valid <flag> <value> <regex> — die when a given value is not of the expected shape
    [ -z "$2" ] && return 0
    [[ "$2" =~ $3 ]] || die "$1 '$2' is not acceptable (expected $3)"
}
pve()     { ssh -o BatchMode=yes -o ConnectTimeout=10 "$PVE" "$@"; }          # reads
pve_run() { run ssh -o BatchMode=yes -o ConnectTimeout=10 "$PVE" "$@"; }      # changes; honours --dry-run
vm_state() { pve qm status "$VMID" 2>/dev/null | awk '/^status:/ { print $2 }'; }
snap_exists() {  # snap_exists <name>
    pve qm listsnapshot "$VMID" 2>/dev/null \
        | awk -v n="$1" '{ for (i = 1; i < NF; i++) if ($i == "`->" && $(i + 1) == n && n != "current") f = 1 } END { exit !f }'
}
state_or_die() {
    STATE=$(vm_state)
    [ -n "$STATE" ] || die "cannot read VM $VMID on $PVE — is the ssh host right, and does the VM exist?"
}

cmd_status() {
    state_or_die
    printf 'vm %s on %s: %s\n' "$VMID" "$PVE" "$STATE"
    pve qm listsnapshot "$VMID"
    pve qm config "$VMID" | grep -E '^(memory|parent|net[0-9]+|ipconfig[0-9]+):'
    return 0
}

rb_current()  { printf 'vm %s is %s\n' "$VMID" "$STATE"; pve qm listsnapshot "$VMID"; }
rb_proposed() { printf 'qm rollback %s %s — disk, config and NICs return to that snapshot\n' "$VMID" "$SNAP"; }
cmd_rollback() {
    need_arg --snapshot "$SNAP"; state_or_die
    snap_exists "$SNAP" || die "VM $VMID has no snapshot '$SNAP' (see: status)"
    gate "roll VM $VMID back to $SNAP" rb_current rb_proposed \
        "none — everything written to the VM since '$SNAP' is lost; take a snapshot first to keep it"
    pve_run qm rollback "$VMID" "$SNAP" || die "qm rollback failed — read the line above; the VM may be locked"
    if [ "$DRY" = "1" ]; then note "DRY-RUN: VM $VMID would be rolled back to $SNAP"
    else pass "VM $VMID rolled back to $SNAP"; fi
    footer "rollback"
}

cmd_start() {
    state_or_die
    if [ "$STATE" = "running" ]; then pass "VM $VMID already running"; footer "start"; fi
    pve_run qm start "$VMID" || die "qm start failed"
    if [ "$DRY" = "1" ]; then note "DRY-RUN: VM $VMID would be started"; else pass "VM $VMID started"; fi
    footer "start"
}

cmd_stop() {
    state_or_die
    if [ "$STATE" = "stopped" ]; then pass "VM $VMID already stopped"; footer "stop"; fi
    pve_run qm shutdown "$VMID" --timeout 180 || die "qm shutdown failed or timed out — the guest did not power off"
    if [ "$DRY" = "1" ]; then note "DRY-RUN: VM $VMID would be shut down"; else pass "VM $VMID shut down"; fi
    footer "stop"
}

cmd_snapshot() {
    need_arg --snapshot "$SNAP"; state_or_die
    snap_exists "$SNAP" && die "snapshot '$SNAP' already exists on VM $VMID — snapshots are never overwritten; choose another name"
    if [ -n "$DESC" ]; then pve_run qm snapshot "$VMID" "$SNAP" --description "'$DESC'" || die "qm snapshot failed"
    else pve_run qm snapshot "$VMID" "$SNAP" || die "qm snapshot failed"; fi
    if [ "$DRY" = "1" ]; then note "DRY-RUN: snapshot $SNAP would be taken"; else pass "snapshot $SNAP taken of VM $VMID ($STATE)"; fi
    footer "snapshot"
}

guest() { ssh -o BatchMode=yes -o ConnectTimeout=5 "$MGMT" "$@"; }
net_value() { pve qm config "$VMID" | sed -n "s/^${WAN_NET}: //p"; }

cmd_airgap() {
    local want="${ARGS[0]:-}" cur new ip port now prc
    case "$want" in on|off) ;; *) die "airgap needs on or off" ;; esac
    need_arg --wan-net "$WAN_NET"; need_arg --mgmt-host "$MGMT"; need_arg --probe "$PROBE"
    cur=$(net_value)
    [ -n "$cur" ] || die "VM $VMID has no $WAN_NET (see: status)"
    [[ "$cur" =~ ^[A-Za-z0-9=:,._-]+$ ]] || die "$WAN_NET's value '$cur' holds a character this script will not send through a shell"
    if [ "$want" = "on" ]; then
        case "$cur" in
            *link_down=1*) note "$WAN_NET already link-down" ;;
            *) pve_run qm set "$VMID" "--$WAN_NET" "${cur},link_down=1" || die "qm set failed" ;;
        esac
    else
        new=${cur//,link_down=1/}
        if [ "$new" = "$cur" ]; then note "$WAN_NET already link-up"
        else pve_run qm set "$VMID" "--$WAN_NET" "$new" || die "qm set failed"; fi
    fi
    if [ "$DRY" = "1" ]; then
        if [ "$want" = "on" ]; then note "DRY-RUN: $WAN_NET would be link-down; nothing was probed"
        else note "DRY-RUN: $WAN_NET would be link-up; nothing was probed"; fi
        footer "airgap $want"
    fi

    now=$(net_value)
    if [ "$want" = "on" ]; then
        case "$now" in *link_down=1*) pass "$WAN_NET has link_down=1 in VM $VMID's config" ;;
                       *) fail "$WAN_NET does not show link_down=1 after qm set" ;; esac
    else
        case "$now" in *link_down=1*) fail "$WAN_NET still shows link_down=1 after qm set" ;;
                       *) pass "$WAN_NET has no link_down in VM $VMID's config" ;; esac
    fi

    ip=${PROBE%:*}; port=${PROBE##*:}
    if ! guest true; then
        fail "guest $MGMT did not answer — the probe was not run, so the air gap is unproven"
    else
        guest "timeout 5 bash -c 'exec 3<>/dev/tcp/${ip}/${port}'"; prc=$?
        case "$prc" in
            255|126|127) fail "the probe could not be run in guest $MGMT (exit $prc) — the air gap is unproven" ;;
            0) if [ "$want" = "on" ]; then fail "guest still reaches $PROBE — the air gap is NOT in effect"
               else pass "guest reaches $PROBE"; fi ;;
            *) if [ "$want" = "on" ]; then pass "guest cannot reach $PROBE"
               else fail "guest cannot reach $PROBE although $WAN_NET is link-up"; fi ;;
        esac
    fi
    footer "airgap $want"
}

cmd_wait_ssh() {
    local secs="${ARGS[0]:-}" deadline
    [[ "$secs" =~ ^[0-9]+$ ]] || die "wait-ssh needs a number of seconds"
    need_arg --mgmt-host "$MGMT"
    deadline=$((SECONDS + secs))
    while :; do
        if guest true 2>/dev/null; then pass "guest answers on $MGMT"; footer "wait-ssh"; fi
        [ "$SECONDS" -ge "$deadline" ] && break
        sleep 5
    done
    fail "guest $MGMT did not answer within $secs s"
    footer "wait-ssh"
}

cmd_tunnel() {
    need_arg --mgmt-host "$MGMT"; need_arg --local-port "$LPORT"
    note "https on 127.0.0.1:$LPORT -> $MGMT's 443; Ctrl-C ends it"
    run ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -L "127.0.0.1:${LPORT}:127.0.0.1:443" "$MGMT"
}

SUB="${1:-}"; [ $# -gt 0 ] && shift
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)     usage ;;
        --pve)         PVE="${2:-}"; shift ;;
        --vmid)        VMID="${2:-}"; shift ;;
        --snapshot)    SNAP="${2:-}"; shift ;;
        --description) DESC="${2:-}"; shift ;;
        --wan-net)     WAN_NET="${2:-}"; shift ;;
        --mgmt-host)   MGMT="${2:-}"; shift ;;
        --probe)       PROBE="${2:-}"; shift ;;
        --local-port)  LPORT="${2:-}"; shift ;;
        -*)            common_flag "$1" || die "unknown option: $1 (try --help)" ;;
        *)             ARGS+=("$1") ;;
    esac
    shift
done
case "$SUB" in -h|--help|help|"") usage ;; esac
SELF="r770-staging-vm"
valid --pve "$PVE" '^[A-Za-z0-9][A-Za-z0-9._-]*$'
valid --vmid "$VMID" '^[0-9]+$'
valid --snapshot "$SNAP" '^[A-Za-z][A-Za-z0-9_-]*$'
valid --description "$DESC" '^[A-Za-z0-9 ._,-]+$'
valid --wan-net "$WAN_NET" '^net[0-9]+$'
valid --mgmt-host "$MGMT" '^[A-Za-z0-9][A-Za-z0-9._-]*$'
valid --probe "$PROBE" '^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$'
valid --local-port "$LPORT" '^[0-9]{2,5}$'
kit_init "r770-staging-vm"
case "$SUB" in
    status|rollback|start|stop|snapshot)
        need_arg --pve "$PVE"; need_arg --vmid "$VMID"; "cmd_$SUB" ;;
    airgap)   need_arg --pve "$PVE"; need_arg --vmid "$VMID"; cmd_airgap ;;
    wait-ssh) cmd_wait_ssh ;;
    tunnel)   cmd_tunnel ;;
    *) die "unknown subcommand: $SUB (try --help)" ;;
esac
