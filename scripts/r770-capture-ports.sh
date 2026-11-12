#!/usr/bin/env bash
#
# r770-capture-ports.sh — make PHYSICAL capture ports ready for Malcolm:
# silent (no address, no ARP), promiscuous, offloads off, and the same after
# a reboot.
#
#   r770-capture-ports.sh apply  --capture-ifs "<if> [<if> ...]"    (GATED)
#   r770-capture-ports.sh status --capture-ifs "<if> [<if> ...]"    read-only
#
#   --capture-ifs  the ports, from discovery (ip -br link); never guessed.
#                  lab_mirror0 in the list is passed over: labnet owns it.
#   --yes / --non-interactive / --dry-run / --force   as everywhere in the kit
#
#   CAPTURE_PORTS_WAIT_SECS 10   how long apply waits, after networkctl reload,
#                                for every port to be promiscuous with no address
#
#   0  done · 2  done with warnings · 1  refused or failed
#
# Per port: /etc/systemd/network/05-capture-<if>.network (from the kit's
# config/networkd/capture-port.network.template) and the boot-time unit
# r770-capture-offloads@<if>.service. No .link file: one that matches a
# physical port replaces the distribution's default and the port would lose
# its predictable name at the next boot.
#
# Refuses, before any write, a port that does not exist, is not physical,
# has a master (rule 8), carries an address, or holds the default route
# (a link-local one is let through: a port that is merely up has one, and
# the .network file removes it), and refuses when ethtool is not installed.
# The proof afterwards fails ANY address, as configure would.
# Run by r770-malcolm-deploy.sh full as its `capture` step, before configure.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

CAPTURE_IFS=""
NETD="/etc/systemd/network"
UNITD="/etc/systemd/system"
OFFL_UNIT="r770-capture-offloads@.service"
TPL="$KIT_CONFIG_DIR/networkd/capture-port.network.template"
KIT_OWNED="lab_mirror0"          # capture ends another step owns
WAIT_SECS="${CAPTURE_PORTS_WAIT_SECS:-10}"
PORTS=()
STAGE=""
# usage returns, so the help branch of the dispatch below reaches the end of
# the script: every other branch ends in footer's or die's exit, and the
# linter on Ubuntu 24.04 then reports the gate's callbacks (only ever invoked
# by name) as unreachable. Found by the suite on the VM, final pass.
usage() { usage_from_header 3; }

ports_resolve() {  # fill PORTS with the physical ports named, after every refusal
    local i sys a; sys="$(p /sys/class/net)"
    [ -n "$CAPTURE_IFS" ] || die "--capture-ifs \"<if> ...\" is required — take the names from ip -br link (try --help)"
    PORTS=()
    for i in $CAPTURE_IFS; do
        case " $KIT_OWNED " in *" $i "*) note "$i: passed over — r770-gns3-deploy.sh labnet owns it"; continue ;; esac
        [ -e "$sys/$i" ] || die "$i does not exist on this host (ip -br link)"
        net_is_physical "$i" || die "$i is not a physical interface — this step prepares hardware ports only"
        if [ -e "$sys/$i/master" ] || [ -L "$sys/$i/master" ]; then
            die "$i has a master ($(basename "$(readlink "$sys/$i/master" 2>/dev/null || echo unknown)")) — rule 8: a capture port is never bridged"
        fi
        if ip route show default 2>/dev/null | grep -qw "dev $i"; then
            die "$i holds the default route — that is the management path, not a capture port"
        fi
        a=$(ip -o addr show dev "$i" 2>/dev/null | grep -E ' inet6? ' | grep -vc 'scope link' || true)
        [ "$a" -eq 0 ] || die "$i carries an address — a capture port never has one; remove it from the host's network config first (ip -o addr show dev $i)"
        PORTS+=("$i")
    done
}
ports_stage() {  # render every port's file into STAGE
    local i
    for i in "${PORTS[@]}"; do
        DRY=0 render "$TPL" "$STAGE/05-capture-$i.network" "CAPTURE_IF=$i" >/dev/null
    done
}
ports_current() {
    local i
    for i in "${PORTS[@]}"; do
        printf '    %-10s %s\n' "$i" "$(ip -br link show dev "$i" 2>/dev/null | awk '{print $2, $3}' || true)"
        printf '    %-10s file: %s\n' "" "$([ -e "$(p "$NETD")/05-capture-$i.network" ] && echo present || echo absent)"
    done
}
ports_proposed() {
    local f i
    echo "    install into $NETD, then networkctl reload:"
    for f in "$STAGE"/*; do echo "    == $(basename "$f")"; sed 's/^/    | /' "$f"; done
    echo "    install $UNITD/$OFFL_UNIT, daemon-reload, and enable:"
    for i in "${PORTS[@]}"; do echo "    r770-capture-offloads@$i.service"; done
}
port_addrs() {  # port_addrs <if> — how many addresses of any kind, link-local included
    ip -o addr show dev "$1" 2>/dev/null | grep -c . || true
}
ports_settled() {  # every port promiscuous and carrying no address: what the reload should produce
    local i sys flags; sys="$(p /sys/class/net)"
    for i in "${PORTS[@]}"; do
        flags=$(cat "$sys/$i/flags" 2>/dev/null || echo 0)
        (( flags & 0x100 )) || return 1
        [ "$(port_addrs "$i")" -eq 0 ] || return 1
    done
}
ports_wait() {  # networkctl reload returns before networkd has reconfigured the links
    local waited=0
    until ports_settled; do
        [ "$waited" -ge "$WAIT_SECS" ] && return 0
        sleep 1; waited=$((waited + 1))
    done
}
port_assert() {  # port_assert <if> — one PASS, or one FAIL per fault
    local i=$1 sys bad=0 a flags offl; sys="$(p /sys/class/net)"
    # strict: configure (capture_json) refuses a capture port with any address, link-local included
    a=$(port_addrs "$i")
    [ "$a" -eq 0 ] || { fail "$i: carries an address (ip -o addr show dev $i)"; bad=1; }
    if [ -e "$sys/$i/master" ] || [ -L "$sys/$i/master" ]; then fail "$i: has a master (rule 8)"; bad=1; fi
    flags=$(cat "$sys/$i/flags" 2>/dev/null || echo 0)
    (( flags & 0x100 )) || { fail "$i: not promiscuous — networkctl status $i"; bad=1; }
    if command -v ethtool >/dev/null 2>&1; then
        offl=$(ethtool -k "$i" 2>/dev/null | grep -E '^(generic-receive-offload|large-receive-offload|tcp-segmentation-offload):' | grep -c ': on' || true)
        [ "$offl" -eq 0 ] || { fail "$i: $offl offload(s) still on — ethtool -k $i"; bad=1; }
    else
        skip "$i: offloads unchecked: ethtool not installed"
    fi
    [ "$bad" -eq 0 ] && pass "$i: no address, no master, promiscuous, offloads off"
    return 0
}

cmd_apply() {
    banner "capture ports — silent, promiscuous, offloads off, across reboots"
    need_root
    case "$WAIT_SECS" in ''|*[!0-9]*) die "CAPTURE_PORTS_WAIT_SECS must be whole seconds (got '$WAIT_SECS')" ;; esac
    ports_resolve
    if [ "${#PORTS[@]}" -eq 0 ]; then skip "no physical capture port named — nothing to prepare"; footer "capture ports"; fi
    # the boot-time unit's ExecStart is /usr/sbin/ethtool: without it the
    # offloads are never turned off, now or at any boot
    require_pkg ethtool
    [ "$(systemctl is-active systemd-networkd 2>/dev/null)" = "active" ] \
        || die "systemd-networkd is not active — this step installs networkd files; nothing was written"
    local netd unitd f i changed=0 rb
    netd="$(p "$NETD")"; unitd="$(p "$UNITD")"
    STAGE=$(mktemp -d)
    trap 'rm -rf "$STAGE"' EXIT
    ports_stage
    for f in "$STAGE"/*; do cmp -s "$f" "$netd/$(basename "$f")" || changed=1; done
    cmp -s "$KIT_CONFIG_DIR/systemd/$OFFL_UNIT" "$unitd/$OFFL_UNIT" || changed=1
    # the template is shared with labnet's lab_mirror0 instance: its presence
    # says nothing about this port's own instance
    for i in "${PORTS[@]}"; do
        systemctl is-enabled --quiet "r770-capture-offloads@$i.service" 2>/dev/null || changed=1
    done
    [ "$FORCE" = "1" ] && changed=1
    if [ "$changed" -eq 0 ]; then
        pass "capture port files already in place in $NETD"
    else
        # the template stays: labnet's r770-capture-offloads@lab_mirror0 uses it too
        rb=""
        for i in "${PORTS[@]}"; do rb="${rb}rm $NETD/05-capture-$i.network; systemctl disable r770-capture-offloads@$i.service; "; done
        rb="${rb}networkctl reload"
        # the reload leaves a live port promiscuous with ARP off until a link reset
        for i in "${PORTS[@]}"; do rb="$rb; ip link set $i promisc off arp on"; done
        rb="$rb   (or reboot; offloads come back at the next boot; $UNITD/$OFFL_UNIT stays: labnet's lab_mirror0 instance shares it)"
        gate "prepare physical capture ports (${PORTS[*]})" ports_current ports_proposed "$rb"
        if [ "$DRY" = "1" ]; then footer "capture ports"; fi
        run mkdir -p "$netd" "$unitd" || die "could not create $NETD or $UNITD"
        for f in "$STAGE"/*; do
            run install -m 0644 "$f" "$netd/$(basename "$f")" || die "could not install $(basename "$f")"
        done
        run install -m 0644 "$KIT_CONFIG_DIR/systemd/$OFFL_UNIT" "$unitd/$OFFL_UNIT" || die "could not install $OFFL_UNIT"
        run systemctl daemon-reload || die "daemon-reload failed"
        for i in "${PORTS[@]}"; do
            run systemctl enable "r770-capture-offloads@$i.service" || die "could not enable the offload unit for $i"
        done
        run networkctl reload || die "networkctl reload failed — journalctl -u systemd-networkd"
        if command -v ethtool >/dev/null 2>&1; then
            for i in "${PORTS[@]}"; do
                run ethtool -K "$i" tso off gso off gro off lro off || warn "ethtool -K $i failed — the check below says which offloads are still on"
            done
        fi
    fi
    ports_wait
    for i in "${PORTS[@]}"; do port_assert "$i"; done
    footer "capture ports"
}

cmd_status() {
    banner "capture ports — status"
    ports_resolve
    local i
    for i in "${PORTS[@]}"; do port_assert "$i"; done
    footer "capture ports"
}

SUB="${1:-}"; [ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
    case "$1" in
        --capture-ifs) CAPTURE_IFS="${2:-}"; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             common_flag "$1" || die "unknown option: $1 (try --help)" ;;
    esac
    shift
done
kit_init "r770-capture-ports"
case "$SUB" in
    apply)  cmd_apply ;;
    status) cmd_status ;;
    -h|--help|help|"") usage ;;
    *) die "unknown subcommand: $SUB (try --help)" ;;
esac
