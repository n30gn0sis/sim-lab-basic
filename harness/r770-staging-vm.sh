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
#
#   --pve H        the hypervisor's ssh host (key login; never a password)
#   --vmid N       the VM
#   --yes / --non-interactive / --dry-run   as everywhere in the kit
#
#   0  done · 2  done with warnings · 1  refused or failed
#
# Nothing is defaulted: the VM, the hypervisor and the snapshot are arguments
# the operator takes from `status` and `qm list`, never names this script picks.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"

PVE=""; VMID=""; SNAP=""; DESC=""
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
        | awk -v n="$1" '{ for (i = 1; i <= NF; i++) if ($i == n) f = 1 } END { exit !f }'
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

SUB="${1:-}"; [ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)     usage ;;
        --pve)         PVE="${2:-}"; shift ;;
        --vmid)        VMID="${2:-}"; shift ;;
        --snapshot)    SNAP="${2:-}"; shift ;;
        --description) DESC="${2:-}"; shift ;;
        -*)            common_flag "$1" || die "unknown option: $1 (try --help)" ;;
        *)             die "unexpected argument: $1 (try --help)" ;;
    esac
    shift
done
case "$SUB" in -h|--help|help|"") usage ;; esac
SELF="r770-staging-vm"
valid --pve "$PVE" '^[A-Za-z0-9][A-Za-z0-9._-]*$'
valid --vmid "$VMID" '^[0-9]+$'
valid --snapshot "$SNAP" '^[A-Za-z][A-Za-z0-9_-]*$'
valid --description "$DESC" '^[A-Za-z0-9 ._,-]+$'
kit_init "r770-staging-vm"
case "$SUB" in
    status|rollback|start|stop|snapshot)
        need_arg --pve "$PVE"; need_arg --vmid "$VMID"; "cmd_$SUB" ;;
    *) die "unknown subcommand: $SUB (try --help)" ;;
esac
