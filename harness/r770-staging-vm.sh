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
# airgap proves what it did, and proves the probe can tell the difference.
#   on   NIC link-up: the probe is run FIRST in the guest and must succeed (the
#        positive control); if it does not, FAIL and nothing is sent ("probe
#        cannot prove the gap"). Only then is link_down=1 set, read back with
#        `qm config --current` (the live value, not a pending one), and the
#        probe run again: it must now fail. NIC already link-down: there is no
#        positive control to run, so a WARN says so and the run ends 2, not 0.
#   off  link_down is removed, read back, and the probe must succeed.
# Probe exit 0 = reachable; only 1 and 124 (timeout) = unreachable; any other
# code is a FAIL ("probe could not be run"). An empty read-back is a FAIL
# ("could not read"). A guest that cannot be asked is a FAIL, never a pass.
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
valid_probe_range() {  # the shape was checked; now the octets (0-255) and the port (1-65535)
    local o port=${PROBE##*:}
    [ -z "$PROBE" ] && return 0
    for o in $(printf '%s' "${PROBE%:*}" | tr . ' '); do
        [ "$((10#$o))" -le 255 ] || die "--probe '$PROBE' is not acceptable (each address octet must be 0-255)"
    done
    { [ "$((10#$port))" -ge 1 ] && [ "$((10#$port))" -le 65535 ]; } || die "--probe '$PROBE' is not acceptable (the port must be 1-65535)"
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
    local snaps cfg
    state_or_die
    snaps=$(pve qm listsnapshot "$VMID") || die "cannot read VM $VMID's snapshots on $PVE"
    cfg=$(pve qm config "$VMID" --current) || die "cannot read VM $VMID's config on $PVE"
    [ -n "$cfg" ] || die "cannot read VM $VMID's config on $PVE (it came back empty)"
    printf 'vm %s on %s: %s\n' "$VMID" "$PVE" "$STATE"
    printf '%s\n' "$snaps"
    printf '%s\n' "$cfg" | grep -E '^(name|memory|parent|net[0-9]+|ipconfig[0-9]+):'
    return 0
}

rb_current() {
    printf 'vm %s is %s\n' "$VMID" "$STATE"
    pve qm config "$VMID" --current | grep -E '^name:' || echo "name: (could not be read — is --vmid right?)"
    pve qm listsnapshot "$VMID"
}
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
net_value() { pve qm config "$VMID" --current | sed -n "s/^${WAN_NET}: //p"; }
probe() { guest "timeout 5 bash -c 'exec 3<>/dev/tcp/${PROBE%:*}/${PROBE##*:}'"; }

cmd_airgap() {
    local want="${ARGS[0]:-}" cur target now prc was_down=0
    case "$want" in on|off) ;; *) die "airgap needs on or off" ;; esac
    need_arg --wan-net "$WAN_NET"; need_arg --mgmt-host "$MGMT"; need_arg --probe "$PROBE"
    cur=$(net_value)
    [ -n "$cur" ] || die "VM $VMID has no $WAN_NET, or its config could not be read (see: status)"
    [[ "$cur" =~ ^[A-Za-z0-9=:,._-]+$ ]] || die "$WAN_NET's value '$cur' holds a character this script will not send through a shell"
    case "$cur" in *link_down=1*) was_down=1 ;; esac
    if [ "$want" = "on" ]; then
        if [ "$was_down" = "1" ]; then target=$cur; else target="${cur},link_down=1"; fi
    else
        target=${cur//,link_down=1/}
    fi

    if [ "$DRY" = "1" ]; then
        if [ "$target" != "$cur" ]; then pve_run qm set "$VMID" "--$WAN_NET" "$target"
        else note "$WAN_NET is already as wanted"; fi
        note "DRY-RUN: $WAN_NET would be set link-$want; nothing was probed"
        footer "airgap $want"
    fi

    if [ "$want" = "on" ] && [ "$was_down" = "0" ]; then
        # Positive control: the probe must succeed BEFORE the gap, or its failure afterwards proves nothing.
        guest true || { fail "guest $MGMT did not answer — the probe was not run, so the air gap is unproven"; footer "airgap $want"; }
        probe; prc=$?
        if [ "$prc" -ne 0 ]; then
            fail "the probe to $PROBE exited $prc in guest $MGMT while $WAN_NET is link-up — probe cannot prove the gap; nothing was changed"
            footer "airgap $want"
        fi
        pass "positive control: guest reaches $PROBE before the gap"
    elif [ "$want" = "on" ]; then
        warn "$WAN_NET was already link-down: no positive control could be run, so a failing probe cannot be told from a broken one"
    fi

    if [ "$target" != "$cur" ]; then pve_run qm set "$VMID" "--$WAN_NET" "$target" || die "qm set failed"
    else note "$WAN_NET already link-$want"; fi

    now=$(net_value)
    if [ -z "$now" ]; then
        fail "could not read $WAN_NET back from VM $VMID's config — the change is unproven"
        footer "airgap $want"
    fi
    if [ "$want" = "on" ]; then
        case "$now" in *link_down=1*) pass "$WAN_NET has link_down=1 in VM $VMID's live config" ;;
                       *) fail "$WAN_NET does not show link_down=1 after qm set" ;; esac
    else
        case "$now" in *link_down=1*) fail "$WAN_NET still shows link_down=1 after qm set" ;;
                       *) pass "$WAN_NET has no link_down in VM $VMID's live config" ;; esac
    fi

    if ! guest true; then
        fail "guest $MGMT did not answer — the probe was not run, so the air gap is unproven"
    else
        probe; prc=$?
        case "$prc" in
            0) if [ "$want" = "on" ]; then fail "guest still reaches $PROBE — the air gap is NOT in effect"
               else pass "guest reaches $PROBE"; fi ;;
            1|124) if [ "$want" = "on" ]; then pass "guest cannot reach $PROBE"
                   else fail "guest cannot reach $PROBE although $WAN_NET is link-up"; fi ;;
            *) fail "the probe could not be run in guest $MGMT (exit $prc) — the air gap is unproven" ;;
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
    local rc
    need_arg --mgmt-host "$MGMT"; need_arg --local-port "$LPORT"
    note "https on 127.0.0.1:$LPORT -> $MGMT's 443; Ctrl-C ends it"
    run ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -L "127.0.0.1:${LPORT}:127.0.0.1:443" "$MGMT"; rc=$?
    if [ "$DRY" = "1" ]; then
        note "DRY-RUN: the tunnel would be opened"
    else
        case "$rc" in
            0|130) pass "tunnel to $MGMT ended (exit $rc)" ;;
            *) fail "the tunnel's ssh ended with exit $rc" ;;
        esac
    fi
    footer "tunnel"
}

no_extra() {  # no_extra <max> — the subcommand takes at most <max> positional arguments
    [ "${#ARGS[@]}" -le "$1" ] || die "unexpected argument: ${ARGS[$1]} (try --help)"
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
# These regexes are the shell-safety guarantee for every value interpolated into
# a remote command: loosening one needs the remote quoting re-audited.
valid --pve "$PVE" '^[A-Za-z0-9][A-Za-z0-9._-]*$'
valid --vmid "$VMID" '^[0-9]+$'
valid --snapshot "$SNAP" '^[A-Za-z][A-Za-z0-9_-]{1,39}$'
valid --description "$DESC" '^[A-Za-z0-9 ._,-]+$'
valid --wan-net "$WAN_NET" '^net[0-9]+$'
valid --mgmt-host "$MGMT" '^[A-Za-z0-9][A-Za-z0-9._-]*$'
valid --probe "$PROBE" '^([0-9]{1,3}\.){3}[0-9]{1,3}:[0-9]{1,5}$'
valid_probe_range
valid --local-port "$LPORT" '^[0-9]{2,5}$'
kit_init "r770-staging-vm"
case "$SUB" in
    status|rollback|start|stop|snapshot)
        no_extra 0; need_arg --pve "$PVE"; need_arg --vmid "$VMID"; "cmd_$SUB" ;;
    airgap)   no_extra 1; need_arg --pve "$PVE"; need_arg --vmid "$VMID"; cmd_airgap ;;
    wait-ssh) no_extra 1; cmd_wait_ssh ;;
    tunnel)   no_extra 0; cmd_tunnel ;;
    *) die "unknown subcommand: $SUB (try --help)" ;;
esac
