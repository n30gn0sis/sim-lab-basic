#!/usr/bin/env bash
#
# r770-proxmox-prep.sh — the one-time Proxmox preparation that
# harness/r770-proxmox-e2e.sh expects (docs/deployment-runbook.md, "Rehearsal:
# the whole lab on a throwaway Proxmox clone"). Runs ON THE PROXMOX HOST, as
# root, by the operator. It is never run by an agent and never on the R770.
#
#   r770-proxmox-prep.sh bridge   --node N --bridge B --bridge-cidr CIDR     (GATED)
#   r770-proxmox-prep.sh key      --node N --pubkey FILE --sshkeys PATH      (GATED)
#   r770-proxmox-prep.sh template --node N --template-vmid T --storage S
#                        --snippet-storage SS --image FILE --root-size GB
#                        --data-size GB --bridge B [--capture-bridge CB]
#                        [--memory MIB] [--cores N] [--name NAME]            (GATED)
#   r770-proxmox-prep.sh all      every flag above: bridge, key, then template
#   r770-proxmox-prep.sh staging-vm --node N --vmid V --storage S --bridge B
#                        --image FILE --disk-size GB --memory MIB --cores N
#                        --guest-user U --sshkeys PATH --ip dhcp|CIDR
#                        [--gw IP] [--name NAME]                             (GATED)
#
#   staging-vm is separate from the E2E preparation and never part of all: it
#   creates the INTERNET-CONNECTED staging host (where staging/ cuts a bundle)
#   as a plain cloud-init VM, left stopped. Its --bridge is the opposite of the
#   template's: the one that gives the VM egress, not a host-only one.
#
#   --node N             the node name `hostname` prints here; checked, so a
#                        script copied to the wrong cluster member refuses
#   --bridge B           the host-only bridge (no physical port) for net0 and,
#                        unless --capture-bridge says otherwise, the capture NIC
#   --bridge-cidr CIDR   THIS host's address on B (e.g. 192.0.2.1/24). The
#                        guests get addresses in the same subnet and NO
#                        gateway; the operator reaches them with ssh ProxyJump
#                        through this host, never through a route
#   --pubkey FILE        the operator's public key, already copied to this host
#   --sshkeys PATH       where it is installed: the path the E2E driver's
#                        --sshkeys names (never overwritten when it differs)
#   --template-vmid T    the template's id; refused if the cluster has it
#                        (a template this script built earlier is reported
#                        and left alone)
#   --storage S          where the template's disks go (content: images)
#   --snippet-storage SS a storage with content 'snippets' for the vendor
#                        cloud-config that lays out the volumes on first boot
#   --image FILE         the Ubuntu 24.04 cloud image (noble-server-cloudimg-
#                        amd64.img), downloaded and checked by the operator
#                        against Ubuntu's SHA256SUMS; this script fetches nothing
#   --root-size GB       the root disk (the image is grown to this)
#   --data-size GB       the data disk the nine volumes are carved from
#                        (the 2026-11-10 rehearsal's sizes total 460)
#   --capture-bridge CB  net1, the capture stand-in's bridge (default: B, as
#                        in the 2026-11-12 rehearsal); must be host-only too
#   --memory MIB         template default 16384; staging-vm: required
#   --cores N            template default 8; staging-vm: required
#   --name NAME          default r770-e2e-template (staging-vm: r770-staging)
#   --vmid V             staging-vm: the new VM's id; refused if the cluster
#                        has it (a staging VM this script made is reported)
#   --disk-size GB       staging-vm: its one disk (OS, image store and bundle
#                        together); the cloud image is grown to this
#   --guest-user U       staging-vm: cloud-init's user (key login only)
#   --ip dhcp|CIDR       staging-vm: net0's address; --gw IP its gateway
#   --yes / --non-interactive / --dry-run   as everywhere in the kit
#
#   0  done · 2  done with warnings · 1  refused or failed
#
# The template is never booted here: a booted template would carry one boot's
# cloud-init state, machine-id and host keys into every clone. Its volumes are
# made by each CLONE on its first boot instead, from the vendor cloud-config
# (cicustom vendor=), on the data disk found by its serial (r770e2edata):
# one LVM volume group, one LV per mount point the import preflight demands
# (plus /var/lib/containerd, as rehearsed), ext4, in fstab. A disk that already
# holds a signature is never formatted. net1 gets no ipconfig, so cloud-init
# gives the capture stand-in no address. scsi9 is left free for the media disk.
#
# Reaching a guest: the guests sit on a bridge with no physical port, so the
# operator's machine cannot route to them, and is not meant to. bridge prints
# the ssh_config stanza (ProxyJump through this host) that lets
# r770-proxmox-e2e.sh's plain `ssh <user>@<guest-ip>` arrive; that needs
# AllowTcpForwarding in this host's sshd, which bridge checks. No route is
# added, and the bridge's stanza turns IPv4 forwarding off on it (and IPv6 off
# altogether): bridge then FAILs unless forwarding is off there and no NAT rule
# names the bridge or its subnet, so the guests stay unable to leave the host.
#
# Every change is printed (current · proposed · rollback) and gated; anything
# already in place is reported and left untouched, so a rerun is safe.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"

NODE=""; BRIDGE=""; BRIDGE_CIDR=""; CAP_BRIDGE=""; PUBKEY=""; SSHKEYS=""
TEMPLATE=""; STORAGE=""; SNIP_STORAGE=""; IMAGE=""; ROOT_SIZE=""; DATA_SIZE=""
MEMORY=""; CORES=""; NAME=""      # template defaults are filled after parsing; staging-vm has none
VMID=""; DISK_SIZE=""; GUEST_USER=""; IP=""; GW=""
TPL_DESC="r770-e2e-template"     # how a rerun recognises the template this script built
STG_DESC="r770-staging-vm"       # ... and the staging VM
STG_DISK_GB=200                  # under this, a WARN: one disk holds the OS, the image store and the
                                 # bundle, and the staging preflight wants 150 GB free for the last two
DATA_SERIAL="r770e2edata"        # the data disk's serial: how a clone's first boot finds it
MEDIA_SLOT="scsi9"               # the E2E driver's media disk slot; the template never uses it
SNIPPET="r770-e2e-vendor.yaml"
REHEARSED_DATA_GB=460
usage() { usage_from_header 3; exit 0; }

need_arg() { [ -n "$2" ] || die "$SUB needs $1"; }
valid() {  # valid <flag> <value> <regex> — die when a given value is not of the expected shape
    [ -z "$2" ] && return 0
    [[ "$2" =~ $3 ]] || die "$1 '$2' is not acceptable (expected $3)"
}
valid_ipv4() {  # valid_ipv4 <flag> <a.b.c.d[/n]> — octets 0-255, prefix 1-32
    local v=$2 o
    [ -z "$v" ] && return 0
    for o in $(printf '%s' "${v%/*}" | tr . ' '); do
        [ "$((10#$o))" -le 255 ] || die "$1 '$v' is not acceptable (each octet must be 0-255)"
    done
    case "$v" in */*) { [ "$((10#${v#*/}))" -ge 1 ] && [ "$((10#${v#*/}))" -le 32 ]; } \
        || die "$1 '$v' is not acceptable (the prefix must be 1-32)" ;; esac
}
ip2int() {  # ip2int <a.b.c.d> — the address as one 32-bit integer
    local a b c d
    IFS=. read -r a b c d <<< "$1"
    echo $(( (10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d ))
}
cidr_overlap() {  # cidr_overlap <a.b.c.d[/n]> <a.b.c.d[/n]> — true when the two ranges share any address
    local pa=32 pb=32 p m
    case "$1" in */*) pa=$((10#${1#*/})) ;; esac
    case "$2" in */*) pb=$((10#${2#*/})) ;; esac
    p=$(( pa < pb ? pa : pb ))    # the wider of the two decides: one nests in the other, or they are apart
    m=$(( p == 0 ? 0 : (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF ))
    [ $(( $(ip2int "${1%/*}") & m )) -eq $(( $(ip2int "${2%/*}") & m )) ]
}
cidr_contains() {  # cidr_contains <outer> <inner> — true when every address of inner lies in outer
    local po=32 pi=32
    case "$1" in */*) po=$((10#${1#*/})) ;; esac
    case "$2" in */*) pi=$((10#${2#*/})) ;; esac
    [ "$po" -le "$pi" ] && cidr_overlap "$1" "$2"
}
host_nets() {  # every IPv4 range this host already uses: its addresses with their prefix, its routes, its gateways
    ip -4 -o addr show 2>/dev/null | awk '{ print $4 " (address on " $2 ")" }'
    ip -4 route show 2>/dev/null | awk '
        $1 != "default" { print $1 " (route" ($2 == "dev" ? " on " $3 : "") ")" }
        { for (i = 1; i < NF; i++) if ($i == "via") print $(i + 1) " (gateway)" }'
}

on_node() {  # the tools and the node: refuse anywhere that is not the node named
    local t host
    for t in qm pvesh pvesm; do
        command -v "$t" >/dev/null 2>&1 || die "$t is not here — this script runs ON the Proxmox host"
    done
    host=$(hostname)
    [ "$host" = "$NODE" ] || die "this is node '$host', not '$NODE' — refusing to act on a node you did not name"
    pass "on Proxmox node $NODE"
    need_root
}

# bridge_state <bridge> — ABSENT, NOTBRIDGE, PHYSICAL:<ports>, or HOSTONLY
bridge_state() {
    local sys ports
    sys="$(p /sys/class/net)/$1"
    [ -e "$sys" ] || { echo ABSENT; return; }
    [ -d "$sys/bridge" ] || { echo NOTBRIDGE; return; }
    ports=$(bridge_physical_ports "$1")
    if [ -n "$ports" ]; then echo "PHYSICAL:$ports"; else echo HOSTONLY; fi
}
check_hostonly() {  # check_hostonly <bridge> <what> — FAIL unless it exists with no physical port
    local s
    s=$(bridge_state "$1")
    case "$s" in
        HOSTONLY)   pass "$2: bridge $1 has no physical port (host-only)" ;;
        ABSENT)     # all --dry-run: the bridge step only printed what it would create
                    if [ "$SUB" = "all" ] && [ "$DRY" = "1" ] && [ "$1" = "$BRIDGE" ]; then
                        skip "$2: bridge $1 does not exist yet — the bridge step of this run would create it"; return 0
                    fi
                    fail "$2: bridge $1 does not exist — run: bridge --bridge $1 --bridge-cidr <cidr>"; return 1 ;;
        NOTBRIDGE)  fail "$2: $1 exists but is not a bridge"; return 1 ;;
        *)          fail "$2: bridge $1 has physical port(s) ${s#PHYSICAL:} — not host-only; the clones would not be air-gapped"; return 1 ;;
    esac
}

# ── operator side: how the harness reaches a guest ─────────────────────────
host_patterns() {  # ssh_config Host patterns covering --bridge-cidr: one a.b.c.* per /24 inside it
    local pfx=$((10#${BRIDGE_CIDR#*/})) net n out=""
    [ "$pfx" -ge 24 ] && pfx=24    # ssh patterns stop at the octet: a /25-/30 shares its a.b.c.* with neighbours
    net=$(( $(ip2int "${BRIDGE_CIDR%/*}") & ((0xFFFFFFFF << (32 - pfx)) & 0xFFFFFFFF) ))
    for (( n = 0; n < (1 << (24 - pfx)); n++ )); do
        out="$out $(( (net >> 24) & 255 )).$(( (net >> 16) & 255 )).$(( ((net >> 8) + n) & 255 )).*"
    done
    echo "${out# }"
}
jump_hint() {
    note "On the OPERATOR'S machine, in ~/.ssh/config, so that the E2E driver's plain"
    note "'ssh <user>@<guest-ip>' goes through this host (give each clone an address in $BRIDGE_CIDR):"
    note "  Host $(host_patterns)"
    note "      ProxyJump <your ssh alias for $NODE>"
    [ "$((10#${BRIDGE_CIDR#*/}))" -gt 24 ] \
        && note "(a /${BRIDGE_CIDR#*/} is narrower than the pattern: addresses beside it in that /24 would jump through this host too)"
    note "No route to the subnet, and forwarding is off on $BRIDGE: the guests stay unable to leave this host."
}

# ── bridge ──────────────────────────────────────────────────────────────────
BR_FILE=""
br_current() {
    printf 'bridge %s: absent\n' "$BRIDGE"
    printf '%s: absent\n' "$BR_FILE"
}
br_stanza() {
    printf '# r770-proxmox-prep.sh: host-only bridge for the Proxmox E2E clones.\n'
    printf '# No physical port, by design: it is the hypervisor-side proof of the air gap.\n'
    printf '# Forwarding off on this bridge: what a guest sends is never routed off the host.\n'
    printf 'auto %s\niface %s inet static\n\taddress %s\n\tbridge-ports none\n\tbridge-stp off\n\tbridge-fd 0\n' \
        "$BRIDGE" "$BRIDGE" "$BRIDGE_CIDR"
    printf '\tpost-up sysctl -qw net/ipv4/conf/%s/forwarding=0\n\tpost-up sysctl -qw net/ipv6/conf/%s/disable_ipv6=1\n' \
        "$BRIDGE" "$BRIDGE"
}
# check_egress — FAIL unless this host is unable to carry a guest's traffic off
# the bridge: IPv4 forwarding off on it, no IPv6 on it, and no NAT rule that
# names it or its subnet. The kernel resets every per-interface forwarding
# value whenever net.ipv4.ip_forward changes (a daemon starting, say), so this
# reads what holds NOW; rerun `bridge` after a reboot to prove it again.
check_egress() {
    local f6 v4 nat line c hit=0
    v4=$(cat "$(p "/proc/sys/net/ipv4/conf/$BRIDGE/forwarding")" 2>/dev/null) || v4="?"
    case "$v4" in
        0) pass "$BRIDGE: IPv4 forwarding is off (net.ipv4.conf.$BRIDGE.forwarding=0): nothing a guest sends is routed off this host" ;;
        1) fail "$BRIDGE forwards IPv4 (net.ipv4.conf.$BRIDGE.forwarding=1) — this host would route the guests out; sysctl -w net/ipv4/conf/$BRIDGE/forwarding=0, and keep the post-up line in its stanza" ;;
        *) fail "cannot read net.ipv4.conf.$BRIDGE.forwarding — the guests' isolation is not proven" ;;
    esac
    f6="$(p "/proc/sys/net/ipv6/conf/$BRIDGE/disable_ipv6")"
    if [ ! -e "$f6" ]; then pass "$BRIDGE: no IPv6 on this host"
    elif [ "$(cat "$f6" 2>/dev/null)" = "1" ]; then pass "$BRIDGE: IPv6 is disabled on it"
    else fail "$BRIDGE has IPv6 on — a guest could be routed out over IPv6; sysctl -w net/ipv6/conf/$BRIDGE/disable_ipv6=1, and keep the post-up line in its stanza"
    fi
    if ! command -v iptables-save >/dev/null 2>&1 && ! command -v nft >/dev/null 2>&1; then
        fail "neither iptables-save nor nft is here — whether a NAT rule would carry $BRIDGE out is not proven"; return
    fi
    # Rule 6: a check that read nothing never passes. At least one of the two must
    # answer (nft exits 0 on an empty ruleset, so a real host always gets a read).
    local out read_ok=0
    nat=""
    if command -v iptables-save >/dev/null 2>&1 && out=$(iptables-save -t nat 2>/dev/null); then nat=$out; read_ok=1; fi
    if command -v nft >/dev/null 2>&1 && out=$(nft list ruleset 2>/dev/null); then nat="$nat"$'\n'"$out"; read_ok=1; fi
    if [ "$read_ok" != 1 ]; then
        fail "could not read the NAT rules (iptables-save -t nat and nft list ruleset both failed) — whether a NAT rule would carry $BRIDGE out is not proven"; return
    fi
    nat=$(printf '%s\n' "$nat" | grep -iE 'masquerade|snat' || true)
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if printf '%s\n' "$line" | grep -qE "(^|[^A-Za-z0-9_.-])${BRIDGE//./\\.}([^A-Za-z0-9_.-]|\$)"; then
            fail "a NAT rule names $BRIDGE — it would carry the guests out: $line"; hit=1; continue
        fi
        c=$(nat_covers "$line")
        [ -z "$c" ] || { fail "a NAT rule $c — it would carry the guests out: $line"; hit=1; }
    done <<< "$nat"
    [ "$hit" = 1 ] || pass "no NAT rule names $BRIDGE or covers $BRIDGE_CIDR"
}
# nat_covers <rule> — why a masquerade/snat rule would take $BRIDGE_CIDR's traffic, or
# nothing when it would not. A rule with no source match takes every source (the
# common uplink form '-o vmbr0 -j MASQUERADE'); a named set ('saddr @x') is not read
# here, so it is not proven; a negated source ('! -s X', 'saddr != X') excludes X.
nat_covers() {
    local line=$1 pos neg c ip='([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?'
    neg=$(printf '%s\n' "$line" | grep -oE "(! +(-s|--source)|saddr +!=) +$ip" | awk '{ print $NF }')
    pos=$(printf '%s\n' "$line" | sed -E 's/(! +(-s|--source)|saddr +!=) +[^ ]+//g')
    if printf '%s\n' "$pos" | grep -qE 'saddr +@'; then
        echo "matches its sources through a named set (what it covers is not proven)"; return
    fi
    if printf '%s\n' "$pos" | grep -qE '(^|[[:space:]])(-s|--source|saddr)[[:space:]]'; then
        for c in $(printf '%s\n' "$pos" | grep -oE "$ip"); do
            cidr_overlap "$c" "$BRIDGE_CIDR" && { echo "covers $BRIDGE's subnet ($c)"; return; }
        done
        return
    fi
    for c in $neg; do cidr_contains "$c" "$BRIDGE_CIDR" && return; done
    echo "matches every source${neg:+ except $(printf '%s\n' "$neg" | paste -sd, -)}, $BRIDGE's subnet included"
}
br_proposed() {
    printf 'write %s:\n' "$BR_FILE"
    br_stanza | sed 's/^/  /'
    printf 'ifup %s\n' "$BRIDGE"
}
cmd_bridge() {
    local st fwd taken tcp nets
    banner "bridge — host-only $BRIDGE with $BRIDGE_CIDR on this host"
    on_node
    BR_FILE="$(p /etc/network/interfaces.d)/$BRIDGE"
    tcp=$(sshd -T 2>/dev/null | awk '$1 == "allowtcpforwarding" { print $2 }')
    case "$tcp" in
        yes|all|local) pass "sshd allows TCP forwarding ($tcp): ProxyJump through this host works" ;;
        "")            warn "could not read sshd's AllowTcpForwarding (sshd -T) — ProxyJump needs it yes or local" ;;
        *)             fail "sshd AllowTcpForwarding is '$tcp' — ProxyJump through this host would be refused; set it to local (or yes) in /etc/ssh/sshd_config, then reload ssh" ;;
    esac
    [ "$FAILED" -eq 0 ] || { note "nothing was changed"; footer "bridge"; }
    fwd=$(cat "$(p /proc/sys/net/ipv4/ip_forward)" 2>/dev/null || echo "?")
    [ "$fwd" = "1" ] && note "this host forwards IPv4 (ip_forward=1) — so forwarding is turned off on $BRIDGE itself, and checked below"

    st=$(bridge_state "$BRIDGE")
    case "$st" in
        HOSTONLY)
            pass "bridge $BRIDGE exists with no physical port (host-only) — not changed"
            if ip -4 -o addr show dev "$BRIDGE" 2>/dev/null | grep -qF " ${BRIDGE_CIDR} "; then
                pass "$BRIDGE carries $BRIDGE_CIDR"
            else
                warn "$BRIDGE does not carry $BRIDGE_CIDR — ProxyJump needs this host to have an address in the guests' subnet; add it to $BRIDGE's stanza, then ifdown $BRIDGE && ifup $BRIDGE (that bridge only; never ifreload -a, which touches every interface)"
            fi
            check_egress
            jump_hint; footer "bridge" ;;
        PHYSICAL:*)
            fail "bridge $BRIDGE has physical port(s) ${st#PHYSICAL:} — not host-only; name a new bridge (this script never removes a port from a live one)"
            footer "bridge" ;;
        NOTBRIDGE) die "$BRIDGE exists and is not a bridge — name another" ;;
    esac

    grep -qE '^[[:space:]]*source(-directory)?[[:space:]]+/etc/network/interfaces\.d' "$(p /etc/network/interfaces)" 2>/dev/null \
        || die "/etc/network/interfaces does not source /etc/network/interfaces.d — add 'source /etc/network/interfaces.d/*' to it first"
    grep -qE "^[[:space:]]*(auto|iface)[[:space:]]+${BRIDGE}([[:space:]]|\$)" "$(p /etc/network/interfaces)" 2>/dev/null \
        && die "/etc/network/interfaces already defines $BRIDGE but it is not up — fix that stanza by hand; this script never edits it"
    [ -e "$BR_FILE" ] && die "$BR_FILE exists but $BRIDGE is not up — read it, then ifup $BRIDGE or remove it; not overwritten"
    pass "/etc/network/interfaces sources interfaces.d; $BRIDGE is defined nowhere yet"
    # Either way round: a new subnet holding one of ours, or nested inside a wider one
    # of ours (it would take that range's addresses, the gateway among them, off its uplink).
    # A host always has at least lo: reading no address means `ip` failed, never "no overlap".
    nets=$(host_nets)
    if ! printf '%s\n' "$nets" | grep -qF '(address on '; then
        fail "read no IPv4 address on this host (ip -4 -o addr show printed nothing) — whether $BRIDGE_CIDR overlaps what it uses is not proven"
        note "nothing was changed"; footer "bridge"
    fi
    taken=""
    while read -r net why; do
        [[ "$net" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]] || continue
        cidr_overlap "$net" "$BRIDGE_CIDR" && taken="$taken${taken:+, }$net $why"
    done <<< "$nets"
    [ -z "$taken" ] || die "$BRIDGE_CIDR overlaps what this host already uses: $taken — choose an unused subnet"
    pass "$BRIDGE_CIDR overlaps none of this host's addresses, routes or gateways"

    gate "host-only bridge $BRIDGE" br_current br_proposed \
        "ifdown $BRIDGE && rm $BR_FILE — only once no guest uses it (grep -lE 'bridge=$BRIDGE(,|\$)' /etc/pve/qemu-server/*.conf /etc/pve/lxc/*.conf)"
    if [ "$DRY" = "1" ]; then
        echo "DRY-RUN: write $BR_FILE"
    else
        { mkdir -p "$(dirname "$BR_FILE")" && br_stanza > "$BR_FILE"; } || die "cannot write $BR_FILE"
        pass "$BR_FILE written"
    fi
    run ifup "$BRIDGE" || die "ifup $BRIDGE failed — read the line above; rollback: rm $BR_FILE"
    if [ "$DRY" = "1" ]; then
        skip "dry run: forwarding and NAT on $BRIDGE are checked once it is up"
    else
        check_hostonly "$BRIDGE" "after ifup" || true
        check_egress
    fi
    jump_hint
    footer "bridge"
}

# ── key ─────────────────────────────────────────────────────────────────────
key_current()  { printf '%s: absent\n' "$SSHKEYS"; }
key_proposed() { printf 'install -m 0644 %s %s\n  (%s)\n' "$PUBKEY" "$SSHKEYS" "$(ssh-keygen -l -f "$PUBKEY" 2>/dev/null)"; }
cmd_key() {
    local dest
    banner "key — the cloud-init user's public key at $SSHKEYS"
    on_node
    [ -r "$PUBKEY" ] || die "--pubkey $PUBKEY: no such readable file — copy the operator's .pub here first"
    grep -q 'PRIVATE KEY' "$PUBKEY" && die "--pubkey $PUBKEY is a PRIVATE key — never copy that here; use its .pub"
    grep -q . "$PUBKEY" || die "--pubkey $PUBKEY is empty"
    ssh-keygen -l -f "$PUBKEY" >/dev/null 2>&1 || die "--pubkey $PUBKEY is not an OpenSSH public key (ssh-keygen -l refused it)"
    pass "public key: $(ssh-keygen -l -f "$PUBKEY" 2>/dev/null | head -1)"
    dest=$(p "$SSHKEYS")
    if [ -e "$dest" ]; then
        cmp -s "$PUBKEY" "$dest" || die "$SSHKEYS exists and differs from $PUBKEY — not overwritten; compare them, then choose another --sshkeys or remove it yourself"
        pass "$SSHKEYS already holds this key — not changed"
        footer "key"
    fi
    gate "public key file $SSHKEYS" key_current key_proposed \
        "rm $SSHKEYS — nothing reads it after a clone's cloud-init drive is generated"
    if [ "$DRY" = "1" ]; then
        echo "DRY-RUN: install -m 0644 $PUBKEY $SSHKEYS"
    else
        { mkdir -p "$(dirname "$dest")" && install -m 0644 "$PUBKEY" "$dest"; } || die "cannot write $SSHKEYS"
        pass "$SSHKEYS written"
    fi
    footer "key"
}

# ── template ────────────────────────────────────────────────────────────────
# A clone's first boot. Bash, run as root by cloud-init's runcmd: finds the
# data disk by serial, refuses a disk that holds a signature it did not put
# there, and is idempotent (a rerun mounts what exists). A failure here makes
# cloud-init's status an error, which the E2E driver's provision reports.
vendor_data() {
    cat <<EOF
#cloud-config
# r770-proxmox-prep.sh vendor data: the R770's storage layout on the data disk.
# Written by harness/r770-proxmox-prep.sh; every E2E clone runs it once.
write_files:
  - path: /usr/local/sbin/r770-e2e-layout
    permissions: '0755'
    content: |
      #!/bin/bash
      set -euo pipefail
      serial=$DATA_SERIAL vg=r770e2e
      dev=\$(lsblk -dnpo NAME,SERIAL | awk -v s="\$serial" '\$2 == s { print \$1 }')
      [ "\$(printf '%s\n' "\$dev" | grep -c .)" -eq 1 ] || { echo "r770-e2e-layout: need exactly one disk with serial \$serial, found '\$dev'" >&2; exit 1; }
      if ! vgs "\$vg" >/dev/null 2>&1; then
          if blkid -p "\$dev" >/dev/null 2>&1; then echo "r770-e2e-layout: \$dev already holds a signature; not touched" >&2; exit 1; fi
          pvcreate -q "\$dev"; vgcreate -q "\$vg" "\$dev"
      fi
      # LV, mount point, percent of the VG: the 2026-11-10 rehearsal's proportions
      while read -r lv mnt pct; do
          if ! lvs "\$vg/\$lv" >/dev/null 2>&1; then
              lvcreate -q -y -n "\$lv" -l "\${pct}%VG" "\$vg"
              mkfs.ext4 -q "/dev/\$vg/\$lv"
          fi
          mkdir -p "\$mnt"
          grep -q "^/dev/\$vg/\$lv " /etc/fstab || echo "/dev/\$vg/\$lv \$mnt ext4 defaults,nofail 0 2" >> /etc/fstab
          mountpoint -q "\$mnt" || mount "\$mnt"
      done <<'LAYOUT'
      docker /var/lib/docker 26
      containerd /var/lib/containerd 26
      pcap /data/pcap 8
      index /data/index 8
      staging /data/staging 17
      vms /srv/vms 4
      gns3 /srv/gns3 4
      work /srv/work 2
      backup /srv/backup 2
      LAYOUT
runcmd:
  - [ /usr/local/sbin/r770-e2e-layout ]
EOF
}
SNIP_PATH=""
tp_current() {
    printf 'VMID %s: free on the cluster\n' "$TEMPLATE"
    printf 'image %s\n' "$IMAGE"
    printf 'snippet %s: %s\n' "$SNIP_PATH" "$([ -e "$(p "$SNIP_PATH")" ] && echo 'present, identical' || echo absent)"
}
tp_proposed() {
    printf 'write %s (vendor cloud-config: nine LVs on the disk with serial %s, at each clone'"'"'s first boot)\n' "$SNIP_PATH" "$DATA_SERIAL"
    echo "qm create $TEMPLATE --name $NAME --description $TPL_DESC --ostype l26 --memory $MEMORY --balloon 0 --cores $CORES --cpu host --scsihw virtio-scsi-single --net0 virtio,bridge=$BRIDGE --net1 virtio,bridge=$CAP_BRIDGE --serial0 socket --vga serial0 --agent enabled=0 --ciupgrade 0"
    echo "qm set $TEMPLATE --scsi0 $STORAGE:0,import-from=$IMAGE"
    echo "qm disk resize $TEMPLATE scsi0 ${ROOT_SIZE}G"
    echo "qm set $TEMPLATE --scsi1 $STORAGE:$DATA_SIZE,serial=$DATA_SERIAL"
    echo "qm set $TEMPLATE --ide2 $STORAGE:cloudinit --boot order=scsi0 --cicustom vendor=$SNIP_STORAGE:snippets/$SNIPPET"
    echo "qm template $TEMPLATE   (never booted; $MEDIA_SLOT stays free)"
}
storage_has() {  # storage_has <storage> <content> — active, and offers that content
    pvesm status --content "$2" 2>/dev/null | awk -v s="$1" 'NR > 1 && $1 == s && $3 == "active" { f = 1 } END { exit !f }'
}
need_free_vmid() {  # need_free_vmid <id> — die unless the cluster would hand out this id
    local out
    out=$(pvesh get /cluster/nextid --vmid "$1" 2>&1) || true
    [ "$(printf '%s' "$out" | tr -d '"[:space:]')" = "$1" ] \
        || die "VMID $1 is not free on the cluster (pvesh said: $(printf '%s' "$out" | head -1))"
    pass "VMID $1 is free on the cluster"
}
need_cloud_image() {  # the operator's downloaded Ubuntu cloud image, as qcow2
    command -v qemu-img >/dev/null 2>&1 || die "qemu-img is not here — it ships with Proxmox VE"
    [ -r "$IMAGE" ] || die "--image $IMAGE: no such readable file — download noble-server-cloudimg-amd64.img and check it against Ubuntu's SHA256SUMS first"
    qemu-img info "$IMAGE" 2>/dev/null | grep -qE '^file format: qcow2' \
        || die "--image $IMAGE is not a qcow2 image (qemu-img info) — the Ubuntu cloud image is"
    pass "image $IMAGE is qcow2"
}
cmd_template() {
    local cfg snip rb
    banner "template — Ubuntu 24.04 cloud-init template $TEMPLATE"
    on_node
    command -v qemu-img >/dev/null 2>&1 || die "qemu-img is not here — it ships with Proxmox VE"
    # Proxmox's default (ciupgrade=1) writes package_upgrade into every clone's
    # user-data: an apt run on first boot from a host-only bridge, i.e. an
    # attempt to reach the internet that the air-gapped clone must never make.
    qm help create --verbose 2>/dev/null | grep -q -- '-ciupgrade' \
        || die "this Proxmox's qm has no ciupgrade option (Proxmox VE 8+) — a clone could not be kept from running apt against the internet on first boot"

    cfg=$(qm config "$TEMPLATE" 2>/dev/null) || cfg=""
    if [ -n "$cfg" ]; then
        if printf '%s\n' "$cfg" | grep -q '^template: 1' && printf '%s\n' "$cfg" | grep -qE "^description: ${TPL_DESC}\$"; then
            pass "template $TEMPLATE already exists and is this script's ($TPL_DESC) — not changed"
            if printf '%s\n' "$cfg" | grep -q "^${MEDIA_SLOT}:"; then fail "template $TEMPLATE uses $MEDIA_SLOT, the E2E driver's media slot"; fi
            printf '%s\n' "$cfg" | grep -q 'cloudinit' || fail "template $TEMPLATE has no cloud-init drive"
            printf '%s\n' "$cfg" | grep -q '^ciupgrade: 0' \
                || fail "template $TEMPLATE leaves cloud-init's package upgrade on — a clone would try apt against the internet; qm set $TEMPLATE --ciupgrade 0"
            footer "template"
        fi
        die "VMID $TEMPLATE exists and is not this script's template — choose a free --template-vmid (pvesh get /cluster/nextid)"
    fi
    need_free_vmid "$TEMPLATE"

    storage_has "$STORAGE" images || die "storage '$STORAGE' is not active with content 'images' here (pvesm status --content images)"
    pass "storage $STORAGE: active, holds VM images"
    storage_has "$SNIP_STORAGE" snippets \
        || die "storage '$SNIP_STORAGE' is not active with content 'snippets' — enable it (Datacenter → Storage → Content) or name one that has it"
    pass "storage $SNIP_STORAGE: active, holds snippets"
    SNIP_PATH=$(pvesm path "$SNIP_STORAGE:snippets/$SNIPPET" 2>/dev/null) || SNIP_PATH=""
    [[ "$SNIP_PATH" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "cannot resolve $SNIP_STORAGE:snippets/$SNIPPET to a path (pvesm path)"
    snip=$(p "$SNIP_PATH")
    if [ -e "$snip" ]; then
        [ "$(cat "$snip")" = "$(vendor_data)" ] \
            || die "$SNIP_PATH exists and is not this script's vendor data — not overwritten; read it, then remove it or move it aside"
        pass "$SNIP_PATH already holds this vendor data"
    fi

    need_cloud_image
    check_hostonly "$BRIDGE" "net0 (management)"
    check_hostonly "$CAP_BRIDGE" "net1 (capture stand-in)"
    [ "$FAILED" -eq 0 ] || { note "nothing was created"; footer "template"; }
    [ "$ROOT_SIZE" -ge 16 ] || die "--root-size $ROOT_SIZE GB is too small for Ubuntu plus the kit (16 at least)"
    [ "$DATA_SIZE" -ge "$REHEARSED_DATA_GB" ] \
        || warn "--data-size $DATA_SIZE GB is under the rehearsed $REHEARSED_DATA_GB GB — the nine volumes shrink in proportion; Malcolm's images may not fit /var/lib/docker"

    rb="qm destroy $TEMPLATE --purge 1, then rm $SNIP_PATH — only while no clone of it is still wanted"
    gate "cloud-init template $TEMPLATE" tp_current tp_proposed "$rb"
    if [ ! -e "$snip" ]; then
        if [ "$DRY" = "1" ]; then
            echo "DRY-RUN: write $SNIP_PATH"
        else
            { mkdir -p "$(dirname "$snip")" && vendor_data > "$snip"; } || die "cannot write $SNIP_PATH"
            pass "$SNIP_PATH written"
        fi
    fi
    run qm create "$TEMPLATE" --name "$NAME" --description "$TPL_DESC" --ostype l26 --memory "$MEMORY" --balloon 0 \
        --cores "$CORES" --cpu host --scsihw virtio-scsi-single --net0 "virtio,bridge=$BRIDGE" \
        --net1 "virtio,bridge=$CAP_BRIDGE" --serial0 socket --vga serial0 --agent enabled=0 --ciupgrade 0 \
        || die "qm create failed — if VM $TEMPLATE now exists: $rb"
    run qm set "$TEMPLATE" --scsi0 "$STORAGE:0,import-from=$IMAGE" || die "importing the image failed — rollback: $rb"
    run qm disk resize "$TEMPLATE" scsi0 "${ROOT_SIZE}G" || die "growing the root disk failed — rollback: $rb"
    run qm set "$TEMPLATE" --scsi1 "$STORAGE:$DATA_SIZE,serial=$DATA_SERIAL" || die "adding the data disk failed — rollback: $rb"
    run qm set "$TEMPLATE" --ide2 "$STORAGE:cloudinit" --boot order=scsi0 --cicustom "vendor=$SNIP_STORAGE:snippets/$SNIPPET" \
        || die "adding the cloud-init drive failed — rollback: $rb"
    run qm template "$TEMPLATE" || die "qm template failed — VM $TEMPLATE is left a plain, never-booted VM; rollback: $rb"
    if [ "$DRY" = "1" ]; then note "DRY-RUN: template $TEMPLATE would be read back and checked"; footer "template"; fi

    cfg=$(qm config "$TEMPLATE" 2>/dev/null) || cfg=""
    if printf '%s\n' "$cfg" | grep -q '^template: 1'; then pass "VM $TEMPLATE is a template"; else fail "VM $TEMPLATE is not a template (qm config)"; fi
    if printf '%s\n' "$cfg" | grep -q 'cloudinit'; then pass "cloud-init drive present"; else fail "no cloud-init drive in VM $TEMPLATE's config"; fi
    if printf '%s\n' "$cfg" | grep -q "serial=$DATA_SERIAL"; then pass "data disk carries serial $DATA_SERIAL"; else fail "no disk with serial $DATA_SERIAL"; fi
    if printf '%s\n' "$cfg" | grep -q "^${MEDIA_SLOT}:"; then fail "$MEDIA_SLOT is in use"; else pass "$MEDIA_SLOT is free for the media disk"; fi
    if printf '%s\n' "$cfg" | grep -q '^ipconfig1:'; then fail "net1 has an ipconfig — the capture stand-in must get no address"
    else pass "net1 (capture stand-in) has no ipconfig: no address"; fi
    if printf '%s\n' "$cfg" | grep -q '^ciupgrade: 0'; then pass "cloud-init package upgrade is off: a clone never tries apt against the internet"
    else fail "cloud-init package upgrade is on (ciupgrade) in VM $TEMPLATE"; fi
    note "next: provision ONE clone with r770-proxmox-e2e.sh, run r770-install.sh discover in it, and fill install.conf from its output"
    footer "template"
}

# ── staging-vm ──────────────────────────────────────────────────────────────
# The staging host: where staging/r770-build-bundle.sh runs. It needs the
# internet, so it is everything the E2E template is not: its bridge must give
# it egress, it is never air-gapped, and it never sits on the clones' subnet.
# Docker and the kit are the operator's next steps inside it, judged by
# staging/r770-staging-preflight.sh; this step only makes the VM, stopped.
stg_ipconfig() { if [ "$IP" = "dhcp" ]; then printf 'ip=dhcp'; else printf 'ip=%s%s' "$IP" "${GW:+,gw=$GW}"; fi; }
stg_current() {
    printf 'VMID %s: free on the cluster\n' "$VMID"
    printf 'bridge %s: %s\n' "$BRIDGE" "$(bridge_state "$BRIDGE")"
    printf 'image %s\n' "$IMAGE"
}
stg_proposed() {
    echo "qm create $VMID --name $NAME --description $STG_DESC --ostype l26 --memory $MEMORY --balloon 0 --cores $CORES --cpu host --scsihw virtio-scsi-single --net0 virtio,bridge=$BRIDGE --serial0 socket --vga serial0 --agent enabled=0"
    echo "qm set $VMID --scsi0 $STORAGE:0,import-from=$IMAGE"
    echo "qm disk resize $VMID scsi0 ${DISK_SIZE}G"
    echo "qm set $VMID --ide2 $STORAGE:cloudinit --boot order=scsi0 --ciuser $GUEST_USER --sshkeys $SSHKEYS --ipconfig0 $(stg_ipconfig)"
    echo "(left stopped: nothing is booted here)"
}
cmd_staging_vm() {
    local cfg st rb keys
    banner "staging-vm — the internet-connected staging host, VM $VMID"
    on_node

    cfg=$(qm config "$VMID" 2>/dev/null) || cfg=""
    if [ -n "$cfg" ]; then
        if printf '%s\n' "$cfg" | grep -qE "^description: ${STG_DESC}\$"; then
            pass "VM $VMID already exists and is this script's staging VM ($STG_DESC) — not changed"
            printf '%s\n' "$cfg" | grep -q '^template: 1' && fail "VM $VMID is a template — the staging host must be a plain VM"
            footer "staging-vm"
        fi
        die "VMID $VMID exists and is not this script's staging VM — choose a free --vmid (pvesh get /cluster/nextid)"
    fi
    need_free_vmid "$VMID"

    storage_has "$STORAGE" images || die "storage '$STORAGE' is not active with content 'images' here (pvesm status --content images)"
    pass "storage $STORAGE: active, holds VM images"
    need_cloud_image

    keys=$(p "$SSHKEYS")
    [ -r "$keys" ] || die "--sshkeys $SSHKEYS: no such readable file on this host — install the operator's key first (the key step)"
    grep -q 'PRIVATE KEY' "$keys" && die "--sshkeys $SSHKEYS is a PRIVATE key — cloud-init needs the .pub"
    ssh-keygen -l -f "$keys" >/dev/null 2>&1 || die "--sshkeys $SSHKEYS is not an OpenSSH public key (ssh-keygen -l refused it)"
    pass "cloud-init key: $(ssh-keygen -l -f "$keys" 2>/dev/null | head -1)"

    st=$(bridge_state "$BRIDGE")
    case "$st" in
        ABSENT)     die "bridge $BRIDGE does not exist — name the bridge that carries this host's uplink (ip -br link)" ;;
        NOTBRIDGE)  die "$BRIDGE exists and is not a bridge — name a bridge" ;;
        PHYSICAL:*) pass "bridge $BRIDGE carries physical port(s) ${st#PHYSICAL:}: the staging VM's way to the internet" ;;
        HOSTONLY)   warn "bridge $BRIDGE has no physical port — the staging VM reaches the internet only if this host routes or NATs for it, and the fetch needs the internet. Never put it on the E2E clones' host-only bridge: that would join an internet-connected VM to the air-gapped subnet" ;;
    esac
    if [ "$IP" != "dhcp" ] && [ -z "$GW" ]; then
        warn "--ip $IP with no --gw: the VM gets no default route, so the fetch reaches the internet only through a proxy on that subnet"
    fi
    [ "$DISK_SIZE" -ge 16 ] || die "--disk-size $DISK_SIZE GB is too small for Ubuntu (16 at least)"
    [ "$DISK_SIZE" -ge "$STG_DISK_GB" ] \
        || warn "--disk-size $DISK_SIZE GB is under $STG_DISK_GB GB — this one disk holds the OS, the container image store and the bundle; staging/r770-staging-preflight.sh will likely refuse it"

    rb="qm destroy $VMID --purge 1 — nothing else is created or changed by this step"
    gate "staging VM $VMID" stg_current stg_proposed "$rb"
    run qm create "$VMID" --name "$NAME" --description "$STG_DESC" --ostype l26 --memory "$MEMORY" --balloon 0 \
        --cores "$CORES" --cpu host --scsihw virtio-scsi-single --net0 "virtio,bridge=$BRIDGE" \
        --serial0 socket --vga serial0 --agent enabled=0 \
        || die "qm create failed — if VM $VMID now exists: $rb"
    run qm set "$VMID" --scsi0 "$STORAGE:0,import-from=$IMAGE" || die "importing the image failed — rollback: $rb"
    run qm disk resize "$VMID" scsi0 "${DISK_SIZE}G" || die "growing the disk failed — rollback: $rb"
    run qm set "$VMID" --ide2 "$STORAGE:cloudinit" --boot order=scsi0 --ciuser "$GUEST_USER" \
        --sshkeys "$SSHKEYS" --ipconfig0 "$(stg_ipconfig)" \
        || die "adding the cloud-init drive failed — rollback: $rb"
    if [ "$DRY" = "1" ]; then note "DRY-RUN: VM $VMID would be read back and checked"; footer "staging-vm"; fi

    cfg=$(qm config "$VMID" 2>/dev/null) || cfg=""
    if printf '%s\n' "$cfg" | grep -qE "^description: ${STG_DESC}\$"; then pass "VM $VMID exists and carries $STG_DESC"
    else fail "VM $VMID does not read back with description $STG_DESC (qm config)"; fi
    if printf '%s\n' "$cfg" | grep -q 'cloudinit'; then pass "cloud-init drive present"; else fail "no cloud-init drive in VM $VMID's config"; fi
    if printf '%s\n' "$cfg" | grep -q '^ipconfig0:'; then pass "net0 has its ipconfig ($(stg_ipconfig))"; else fail "net0 has no ipconfig0"; fi
    note "next, from the operator's machine: harness/r770-staging-vm.sh start --pve <ssh-host> --vmid $VMID;"
    note "then, inside it: install Docker CE, clone the kit, and run staging/r770-staging-preflight.sh"
    footer "staging-vm"
}

# ── all ─────────────────────────────────────────────────────────────────────
cmd_all() {
    local s rc warned=""
    for s in bridge key template; do
        rc=0; ( "cmd_$s" ) || rc=$?    # each step's footer exits its subshell, not this script
        case "$rc" in
            0) ;;
            2) warned="$warned $s" ;;
            *) die "step '$s' refused or failed (exit $rc) — nothing after it ran; fix it, then rerun all: finished steps are reported, not redone" ;;
        esac
    done
    banner "all — bridge, key and template"
    [ -z "$warned" ] || warn "steps finished with warnings:$warned — read and disposition each"
    if [ "$DRY" = 1 ]; then    # nothing was changed, so nothing is proven prepared (rule 6)
        skip "dry run: nothing was prepared — rerun without --dry-run to prepare it"
        footer "all"
    fi
    pass "this host is prepared for r770-proxmox-e2e.sh (--bridge $BRIDGE --sshkeys $SSHKEYS --template-vmid $TEMPLATE)"
    footer "all"
}

SUB="${1:-}"; [ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)          usage ;;
        --node)             NODE="${2:-}"; shift ;;
        --bridge)           BRIDGE="${2:-}"; shift ;;
        --bridge-cidr)      BRIDGE_CIDR="${2:-}"; shift ;;
        --capture-bridge)   CAP_BRIDGE="${2:-}"; shift ;;
        --pubkey)           PUBKEY="${2:-}"; shift ;;
        --sshkeys)          SSHKEYS="${2:-}"; shift ;;
        --template-vmid)    TEMPLATE="${2:-}"; shift ;;
        --storage)          STORAGE="${2:-}"; shift ;;
        --snippet-storage)  SNIP_STORAGE="${2:-}"; shift ;;
        --image)            IMAGE="${2:-}"; shift ;;
        --root-size)        ROOT_SIZE="${2:-}"; shift ;;
        --data-size)        DATA_SIZE="${2:-}"; shift ;;
        --memory)           MEMORY="${2:-}"; shift ;;
        --cores)            CORES="${2:-}"; shift ;;
        --name)             NAME="${2:-}"; shift ;;
        --vmid)             VMID="${2:-}"; shift ;;
        --disk-size)        DISK_SIZE="${2:-}"; shift ;;
        --guest-user)       GUEST_USER="${2:-}"; shift ;;
        --ip)               IP="${2:-}"; shift ;;
        --gw)               GW="${2:-}"; shift ;;
        -*)                 common_flag "$1" || die "unknown option: $1 (try --help)" ;;
        *)                  die "unexpected argument: $1 (try --help)" ;;
    esac
    shift
done
case "$SUB" in -h|--help|help|"") usage ;; esac
SELF="r770-proxmox-prep"
# These regexes are the shell-safety guarantee for every value written into a
# file or a command line here: loosening one needs that use re-audited.
valid --node "$NODE" '^[A-Za-z0-9][A-Za-z0-9.-]*$'
valid --bridge "$BRIDGE" '^[A-Za-z][A-Za-z0-9_.-]{0,14}$'
valid --capture-bridge "$CAP_BRIDGE" '^[A-Za-z][A-Za-z0-9_.-]{0,14}$'
valid --bridge-cidr "$BRIDGE_CIDR" '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'; valid_ipv4 --bridge-cidr "$BRIDGE_CIDR"
[ -z "$BRIDGE_CIDR" ] || { [ "$((10#${BRIDGE_CIDR#*/}))" -ge 16 ] && [ "$((10#${BRIDGE_CIDR#*/}))" -le 30 ]; } \
    || die "--bridge-cidr '$BRIDGE_CIDR' is not acceptable (a lab subnet is /16 to /30: room for the guests, and few enough ssh Host patterns)"
valid --pubkey "$PUBKEY" '^[A-Za-z0-9._/-]+$'
valid --sshkeys "$SSHKEYS" '^/[A-Za-z0-9._/-]+$'
valid --template-vmid "$TEMPLATE" '^[1-9][0-9]{2,8}$'
valid --storage "$STORAGE" '^[A-Za-z][A-Za-z0-9_-]*$'
valid --snippet-storage "$SNIP_STORAGE" '^[A-Za-z][A-Za-z0-9_-]*$'
valid --image "$IMAGE" '^/[A-Za-z0-9._/-]+$'
valid --root-size "$ROOT_SIZE" '^[1-9][0-9]{0,4}$'
valid --data-size "$DATA_SIZE" '^[1-9][0-9]{0,5}$'
valid --memory "$MEMORY" '^[1-9][0-9]{3,6}$'
valid --cores "$CORES" '^[1-9][0-9]{0,2}$'
valid --name "$NAME" '^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$'
valid --vmid "$VMID" '^[1-9][0-9]{2,8}$'
valid --disk-size "$DISK_SIZE" '^[1-9][0-9]{0,5}$'
valid --guest-user "$GUEST_USER" '^[a-z_][a-z0-9_-]{0,31}$'
[ "$IP" = "dhcp" ] || { valid --ip "$IP" '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'; valid_ipv4 --ip "$IP"; }
valid --gw "$GW" '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; valid_ipv4 --gw "$GW"
case "$SUB" in bridge|key|template|all|staging-vm) ;; *) die "unknown subcommand: $SUB (try --help)" ;; esac
need_arg --node "$NODE"
case "$SUB" in bridge|template|all|staging-vm) need_arg --bridge "$BRIDGE" ;; esac
case "$SUB" in bridge|all) need_arg --bridge-cidr "$BRIDGE_CIDR" ;; esac
case "$SUB" in key|all) need_arg --pubkey "$PUBKEY"; need_arg --sshkeys "$SSHKEYS" ;; esac
case "$SUB" in template|all)
    need_arg --template-vmid "$TEMPLATE"; need_arg --storage "$STORAGE"; need_arg --snippet-storage "$SNIP_STORAGE"
    need_arg --image "$IMAGE"; need_arg --root-size "$ROOT_SIZE"; need_arg --data-size "$DATA_SIZE"
    : "${MEMORY:=16384}" "${CORES:=8}" "${NAME:=r770-e2e-template}" ;; esac
case "$SUB" in staging-vm)
    need_arg --vmid "$VMID"; need_arg --storage "$STORAGE"; need_arg --image "$IMAGE"
    need_arg --disk-size "$DISK_SIZE"; need_arg --memory "$MEMORY"; need_arg --cores "$CORES"
    need_arg --guest-user "$GUEST_USER"; need_arg --sshkeys "$SSHKEYS"; need_arg --ip "$IP"
    [ "$IP" != "dhcp" ] || [ -z "$GW" ] || die "--gw is for a static --ip; with dhcp the gateway comes from DHCP"
    : "${NAME:=r770-staging}" ;; esac
[ -n "$CAP_BRIDGE" ] || CAP_BRIDGE="$BRIDGE"
kit_init "r770-proxmox-prep"
"cmd_${SUB//-/_}"
