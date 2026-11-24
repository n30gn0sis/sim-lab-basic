#!/usr/bin/env bats
# harness/r770-proxmox-prep.sh: the one-time Proxmox preparation for the E2E
# run — host-only bridge, public key file, cloud-init template. Every Proxmox
# tool is stubbed and every file lands under $KIT_ROOT; no test reaches a
# hypervisor. A "VM" below is one file under $BATS_TEST_TMPDIR.
load helpers/stubs

setup() {
    kit_test_env
    SCRIPT="$BATS_TEST_DIRNAME/../harness/r770-proxmox-prep.sh"
    export S="$BATS_TEST_TMPDIR/pve"; mkdir -p "$S"
    mkdir -p "$ROOT/etc/network/interfaces.d" "$ROOT/proc/sys/net/ipv4" "$ROOT/sys/class/net"
    printf 'auto lo\niface lo inet loopback\n\nsource /etc/network/interfaces.d/*\n' > "$ROOT/etc/network/interfaces"
    echo 0 > "$ROOT/proc/sys/net/ipv4/ip_forward"
    # vmbr0 carries the uplink eno1 (physical); the e2e bridge does not exist yet
    mkdir -p "$ROOT/sys/class/net/eno1/device" "$ROOT/sys/class/net/vmbr0/bridge" "$ROOT/sys/class/net/vmbr0/brif/eno1"
    # Knobs: NODE_NAME, TAKEN (a VMID the cluster has), NO_SNIPPETS, RAW_IMAGE,
    # TCPFWD, ADDR_TAKEN, QM_RC (a qm subcommand that fails), OLD_PVE (no ciupgrade)
    stub hostname 'echo "${NODE_NAME:-pve1}"'
    stub qm '
echo "qm $*" >> "$STUB_LOG"
[ -n "${QM_RC:-}" ] && [ "$1" = "${QM_RC%%:*}" ] && exit "${QM_RC#*:}"
case "$1" in
    help)     [ "${OLD_PVE:-0}" = 1 ] || echo "  -ciupgrade <boolean>   (default = 1)" ;;
    config)   [ -f "$S/vm-$2.conf" ] || exit 2; cat "$S/vm-$2.conf" ;;
    create)   id=$2; shift 2; : > "$S/vm-$id.conf"; prev=""
              for a in "$@"; do case "$prev" in
                  --description) echo "description: $a" >> "$S/vm-$id.conf" ;;
                  --net0) echo "net0: $a" >> "$S/vm-$id.conf" ;;
                  --net1) echo "net1: $a" >> "$S/vm-$id.conf" ;;
                  --ciupgrade) echo "ciupgrade: $a" >> "$S/vm-$id.conf" ;;
              esac; prev=$a; done ;;
    set)      id=$2; shift 2; prev=""
              for a in "$@"; do case "$prev" in
                  --scsi0) echo "scsi0: local-lvm:vm-$id-disk-0,size=3584M" >> "$S/vm-$id.conf" ;;
                  --scsi1) echo "scsi1: local-lvm:vm-$id-disk-1,$a" >> "$S/vm-$id.conf" ;;
                  --ide2)  echo "ide2: local-lvm:vm-$id-cloudinit,media=cdrom" >> "$S/vm-$id.conf" ;;
                  --cicustom) echo "cicustom: $a" >> "$S/vm-$id.conf" ;;
                  --ipconfig0) echo "ipconfig0: $a" >> "$S/vm-$id.conf" ;;
              esac; prev=$a; done ;;
    template) echo "template: 1" >> "$S/vm-$2.conf" ;;
esac
exit 0'
    stub pvesh '
id=${!#}
if [ -f "$S/vm-$id.conf" ] || [ "$id" = "${TAKEN:-}" ]; then echo "400 Parameter verification failed. vmid: VM $id already exists" >&2; exit 2; fi
echo "$id"'
    stub pvesm '
echo "pvesm $*" >> "$STUB_LOG"
case "$*" in
    "status --content images")   printf "Name Type Status Total Used Available %%\nlocal-lvm lvmthin active 1 1 1 1%%\n" ;;
    "status --content snippets") printf "Name Type Status Total Used Available %%\n"
                                 [ "${NO_SNIPPETS:-0}" = 1 ] || printf "local dir active 1 1 1 1%%\n" ;;
    "path local:snippets/"*)     l=${!#}; echo "/var/lib/vz/snippets/${l##*/}" ;;
    *)                           exit 2 ;;
esac'
    stub qemu-img 'if [ "${RAW_IMAGE:-0}" = 1 ]; then echo "file format: raw"; else echo "file format: qcow2"; fi'
    stub sshd 'echo "allowtcpforwarding ${TCPFWD:-yes}"'
    # The host's own addresses and routes, as `ip` prints them; the script does the overlap
    # arithmetic itself, so the stub only reports what is there (ADDR_TAKEN, ROUTES).
    stub ip '
[ "${IP_EMPTY:-0}" = 1 ] && exit 1    # a missing tool or a failing namespace: nothing read
case "$*" in
    "-4 -o addr show dev "*) [ -f "$S/br-${!#}" ] && echo "5: ${!#}    inet $(cat "$S/br-${!#}") brd x scope global ${!#}" ; exit 0 ;;
    "-4 -o addr show")       echo "1: lo    inet 127.0.0.1/8 scope host lo"
                             [ -n "${ADDR_TAKEN:-}" ] && echo "2: vmbr0    inet $ADDR_TAKEN brd x scope global vmbr0" ; exit 0 ;;
    "-4 route show")         [ -n "${ROUTES:-}" ] && printf "%s\n" "$ROUTES" ; exit 0 ;;
esac'
    # ifup runs the stanza: brings the bridge up and applies its post-up sysctls
    # (FWD_STUCK=1: something has turned forwarding back on, as an ip_forward write does)
    stub ifup '
echo "ifup $*" >> "$STUB_LOG"; f="$KIT_ROOT/etc/network/interfaces.d/$1"
mkdir -p "$KIT_ROOT/sys/class/net/$1/bridge" "$KIT_ROOT/proc/sys/net/ipv4/conf/$1" "$KIT_ROOT/proc/sys/net/ipv6/conf/$1"
sed -n "s/^[[:space:]]*address //p" "$f" > "$S/br-$1"
echo 1 > "$KIT_ROOT/proc/sys/net/ipv4/conf/$1/forwarding"; echo 0 > "$KIT_ROOT/proc/sys/net/ipv6/conf/$1/disable_ipv6"
grep -q "post-up sysctl -qw net/ipv4/conf/$1/forwarding=0" "$f" && [ "${FWD_STUCK:-0}" != 1 ] && echo 0 > "$KIT_ROOT/proc/sys/net/ipv4/conf/$1/forwarding"
grep -q "post-up sysctl -qw net/ipv6/conf/$1/disable_ipv6=1" "$f" && echo 1 > "$KIT_ROOT/proc/sys/net/ipv6/conf/$1/disable_ipv6"
exit 0'
    stub iptables-save '[ "${NAT_READ_FAIL:-0}" = 1 ] && exit 1; echo "-A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE"; [ -n "${NAT_RULE:-}" ] && echo "$NAT_RULE"; exit 0'
    stub nft '[ "${NAT_READ_FAIL:-0}" = 1 ] && exit 1; [ -n "${NFT_RULE:-}" ] && echo "$NFT_RULE"; exit 0'
    stub ssh-keygen 'grep -q "^ssh-" "${!#}" || exit 1; echo "256 SHA256:fixture operator@fixture (ED25519)"'
    PUB="$BATS_TEST_TMPDIR/operator.pub"; echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFIXTURE operator@fixture" > "$PUB"
    IMG="$BATS_TEST_TMPDIR/noble-server-cloudimg-amd64.img"; echo qcow2 > "$IMG"
    BR=(--node pve1 --bridge vmbr9 --bridge-cidr 192.0.2.1/24)
    KY=(--node pve1 --pubkey "$PUB" --sshkeys /root/r770-e2e.pub)
    TP=(--node pve1 --template-vmid 9000 --storage local-lvm --snippet-storage local --image "$IMG"
        --root-size 64 --data-size 460 --bridge vmbr9)
    SV=(--node pve1 --vmid 9100 --storage local-lvm --bridge vmbr0 --image "$IMG" --disk-size 300
        --memory 8192 --cores 4 --guest-user stager --sshkeys /root/r770-e2e.pub --ip dhcp)
    SNIP="$ROOT/var/lib/vz/snippets/r770-e2e-vendor.yaml"
    cd "$BATS_TEST_TMPDIR"
}
prep() { kit_run "$SCRIPT" "$@"; }
hostonly() {  # an existing host-only bridge, isolated as bridge leaves it
    mkdir -p "$ROOT/sys/class/net/$1/bridge" "$ROOT/proc/sys/net/ipv4/conf/$1" "$ROOT/proc/sys/net/ipv6/conf/$1"
    echo "192.0.2.1/24" > "$S/br-$1"
    echo 0 > "$ROOT/proc/sys/net/ipv4/conf/$1/forwarding"; echo 1 > "$ROOT/proc/sys/net/ipv6/conf/$1/disable_ipv6"
}
changes() { grep -E '^(qm (create|set|disk|template)|ifup) ' "$STUB_LOG"; }

# ── refusals before anything is touched ────────────────────────────────────

@test "a missing or malformed value is refused before anything runs" {
    run prep bridge --bridge vmbr9 --bridge-cidr 192.0.2.1/24
    [ "$status" -eq 1 ]; [[ "$output" == *"needs --node"* ]]
    run prep bridge "${BR[@]}" --bridge 'vmbr9;reboot'
    [ "$status" -eq 1 ]; [[ "$output" == *"--bridge"* ]]
    run prep bridge "${BR[@]}" --bridge-cidr 192.0.2.300/24
    [ "$status" -eq 1 ]; [[ "$output" == *"--bridge-cidr"* ]]
    run prep key "${KY[@]}" --sshkeys 'relative.pub'
    [ "$status" -eq 1 ]; [[ "$output" == *"--sshkeys"* ]]
    run prep template "${TP[@]}" --image '/tmp/x img'
    [ "$status" -eq 1 ]; [[ "$output" == *"--image"* ]]
    for f in --template-vmid --storage --snippet-storage --image --root-size --data-size; do
        args=(); skipnext=0
        for a in "${TP[@]}"; do
            if [ "$skipnext" = 1 ]; then skipnext=0; continue; fi
            [ "$a" = "$f" ] && { skipnext=1; continue; }
            args+=("$a")
        done
        run prep template "${args[@]}"
        [ "$status" -eq 1 ]; [[ "$output" == *"needs $f"* ]]
    done
    run prep frobnicate --node pve1
    [ "$status" -eq 1 ]; [[ "$output" == *"unknown subcommand"* ]]
    [ ! -s "$STUB_LOG" ]
}

@test "the help prints the whole header" {
    run prep --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"bridge"*"ProxyJump"*"a rerun is safe"* ]]
}

@test "a node other than the one named is refused, and nothing changes" {
    NODE_NAME=pve2 run prep bridge "${BR[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"node 'pve2', not 'pve1'"* ]]
    [ ! -e "$ROOT/etc/network/interfaces.d/vmbr9" ]
    run changes; [ "$status" -ne 0 ]
}

# ── bridge ──────────────────────────────────────────────────────────────────

@test "bridge writes a host-only stanza, brings it up, and prints the ProxyJump stanza" {
    run prep bridge "${BR[@]}"
    echo "$output"; [ "$status" -eq 0 ]
    f="$ROOT/etc/network/interfaces.d/vmbr9"
    grep -q '^auto vmbr9$' "$f"; grep -qP '^\taddress 192.0.2.1/24$' "$f"; grep -qP '^\tbridge-ports none$' "$f"
    grep -q '^ifup vmbr9$' "$STUB_LOG"
    [[ "$output" == *"GATE: host-only bridge vmbr9"*"-- rollback --"*"ifdown vmbr9"* ]]
    [[ "$output" == *"/etc/pve/qemu-server/*.conf /etc/pve/lxc/*.conf"* ]]   # containers can hold the bridge too
    [[ "$output" == *"PASS  after ifup: bridge vmbr9 has no physical port"* ]]
    cidr=${BR[5]}   # the guests' /24, built from the CIDR (a literal a.b.c reads as a pin to no-pins.bats)
    [[ "$output" == *"Host ${cidr%.*}.*"*"ProxyJump <your ssh alias for pve1>"* ]]
    [[ "$output" == *"--nameserver ${cidr%/*} --searchdomain <domain>"* ]]   # the clones' resolver: this host's bridge address
    grep -qP '^\tpost-up sysctl -qw net/ipv4/conf/vmbr9/forwarding=0$' "$f"
    grep -qP '^\tpost-up sysctl -qw net/ipv6/conf/vmbr9/disable_ipv6=1$' "$f"
    [[ "$output" == *"PASS  vmbr9: IPv4 forwarding is off"* ]]
    [[ "$output" == *"PASS  vmbr9: IPv6 is disabled on it"* ]]
    [[ "$output" == *"PASS  no NAT rule names vmbr9 or covers 192.0.2.1/24"* ]]   # docker's own MASQUERADE is not ours
}

@test "bridge FAILs when forwarding on the bridge does not stay off" {
    FWD_STUCK=1 run prep bridge "${BR[@]}"
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  vmbr9 forwards IPv4 (net.ipv4.conf.vmbr9.forwarding=1)"* ]]
}

@test "bridge FAILs on a NAT rule that names the bridge or covers its subnet, and passes others" {
    NAT_RULE="-A POSTROUTING -i vmbr9 -o vmbr0 -j MASQUERADE" run prep bridge "${BR[@]}"
    echo "$output"; [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  a NAT rule names vmbr9"* ]]
    rm -rf "$ROOT/etc/network/interfaces.d/vmbr9" "$ROOT/sys/class/net/vmbr9"
    NAT_RULE="-A POSTROUTING -s 192.0.0.0/16 -o vmbr0 -j MASQUERADE" run prep bridge "${BR[@]}"
    echo "$output"; [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  a NAT rule covers vmbr9's subnet (192.0.0.0/16)"* ]]
    rm -rf "$ROOT/etc/network/interfaces.d/vmbr9" "$ROOT/sys/class/net/vmbr9"
    NAT_RULE="-A POSTROUTING -i vmbr90 -s 198.51.100.0/24 -j MASQUERADE" run prep bridge "${BR[@]}"   # a longer name, another subnet
    echo "$output"; [ "$status" -eq 0 ]
}

@test "bridge FAILs on a NAT rule with no source match, in iptables and nft form, and on a named-set source (F1)" {
    NAT_RULE="-A POSTROUTING -o vmbr0 -j MASQUERADE" run prep bridge "${BR[@]}"
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  a NAT rule matches every source, vmbr9's subnet included"* ]]
    [[ "$output" != *"PASS  no NAT rule"* ]]
    rm -rf "$ROOT/etc/network/interfaces.d/vmbr9" "$ROOT/sys/class/net/vmbr9"
    NFT_RULE='		oifname "vmbr0" masquerade' run prep bridge "${BR[@]}"
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  a NAT rule matches every source, vmbr9's subnet included"* ]]
    rm -rf "$ROOT/etc/network/interfaces.d/vmbr9" "$ROOT/sys/class/net/vmbr9"
    NFT_RULE='		ip saddr @lan_nets oifname "vmbr0" masquerade' run prep bridge "${BR[@]}"
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  a NAT rule matches its sources through a named set"* ]]
}

@test "the NAT check FAILs when neither iptables-save nor nft could be read, never a pass on nothing (N1)" {
    NAT_READ_FAIL=1 run prep bridge "${BR[@]}"
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  could not read the NAT rules (iptables-save -t nat and nft list ruleset both failed)"* ]]
    [[ "$output" != *"PASS  no NAT rule"* ]]
}

@test "a negated source that excludes the whole lab subnet passes; one that excludes only part of it FAILs" {
    NAT_RULE="-A POSTROUTING ! -s 192.0.0.0/16 -o vmbr0 -j MASQUERADE" run prep bridge "${BR[@]}"
    echo "$output"; [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  no NAT rule names vmbr9 or covers 192.0.2.1/24"* ]]
    rm -rf "$ROOT/etc/network/interfaces.d/vmbr9" "$ROOT/sys/class/net/vmbr9"
    NAT_RULE="-A POSTROUTING ! -s 192.0.2.0/25 -o vmbr0 -j MASQUERADE" run prep bridge "${BR[@]}"
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  a NAT rule matches every source except 192.0.2.0/25, vmbr9's subnet included"* ]]
}

@test "bridge never calls the overlap check a pass when ip read no address (F2), and changes nothing" {
    IP_EMPTY=1 run prep bridge "${BR[@]}"
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  read no IPv4 address on this host"* ]]
    [[ "$output" != *"overlaps none"* ]]
    [[ "$output" != *"GATE:"* ]]
    [ ! -e "$ROOT/etc/network/interfaces.d/vmbr9" ]
    run changes; [ "$status" -ne 0 ]
}

@test "an existing host-only bridge with forwarding on is a FAIL, not a pass" {
    hostonly vmbr9; echo 1 > "$ROOT/proc/sys/net/ipv4/conf/vmbr9/forwarding"
    run prep bridge "${BR[@]}"
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  vmbr9 forwards IPv4"* ]]
    run changes; [ "$status" -ne 0 ]
}

@test "the ProxyJump Host pattern covers a subnet wider than a /24, and a too-wide CIDR is refused" {
    run prep bridge --node pve1 --bridge vmbr9 --bridge-cidr 192.0.2.1/23
    echo "$output"; [ "$status" -eq 0 ]
    net=${BR[5]%.*}; net=${net%.*}   # a.b, built from the CIDR (a literal a.b.c reads as a pin)
    [[ "$output" == *"Host $net.2.* $net.3.*"* ]]
    run prep bridge --node pve1 --bridge vmbr8 --bridge-cidr 192.0.2.1/8
    [ "$status" -eq 1 ]; [[ "$output" == *"a lab subnet is /16 to /30"* ]]
}

@test "bridge refuses an existing bridge with a physical port and writes nothing" {
    run prep bridge "${BR[@]}" --bridge vmbr0
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  bridge vmbr0 has physical port(s) eno1"* ]]
    [ ! -e "$ROOT/etc/network/interfaces.d/vmbr0" ]
    run changes; [ "$status" -ne 0 ]
}

@test "bridge leaves an existing host-only bridge alone; a missing address is a WARN" {
    hostonly vmbr9
    run prep bridge "${BR[@]}"
    echo "$output"; [ "$status" -eq 0 ]
    [[ "$output" == *"exists with no physical port (host-only) — not changed"* ]]
    rm "$S/br-vmbr9"
    run prep bridge "${BR[@]}"
    [ "$status" -eq 2 ]; [[ "$output" == *"WARN  vmbr9 does not carry 192.0.2.1/24"* ]]
    [[ "$output" == *"ifdown vmbr9 && ifup vmbr9"*"never ifreload -a"* ]]
    run changes; [ "$status" -ne 0 ]
}

@test "bridge refuses a subnet that overlaps the host's, either way round, and passes one that does not" {
    # the host's address inside the new subnet
    ADDR_TAKEN=192.0.2.5/24 run prep bridge "${BR[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"overlaps what this host already uses: 192.0.2.5/24 (address on vmbr0)"* ]]
    # the new subnet nested inside a wider one of the host's, whose address is outside it (H1)
    ADDR_TAKEN=192.0.0.5/22 run prep bridge "${BR[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"overlaps what this host already uses: 192.0.0.5/22 (address on vmbr0)"* ]]
    # only a route or the gateway is in it
    ROUTES="192.0.2.128/25 dev wg0 scope link" run prep bridge "${BR[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"192.0.2.128/25 (route on wg0)"* ]]
    ADDR_TAKEN=198.51.100.21/22 ROUTES="default via 192.0.2.254 dev vmbr0" run prep bridge "${BR[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"192.0.2.254 (gateway)"* ]]
    [ ! -e "$ROOT/etc/network/interfaces.d/vmbr9" ]
    run changes; [ "$status" -ne 0 ]
    # apart from everything the host has: accepted
    ADDR_TAKEN=198.51.100.21/22 ROUTES=$'default via 198.51.100.1 dev vmbr0\n198.51.100.0/22 dev vmbr0 proto kernel scope link' \
        run prep bridge "${BR[@]}"
    echo "$output"; [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  192.0.2.1/24 overlaps none of this host's addresses, routes or gateways"* ]]
}

@test "bridge refuses an interfaces file that does not source interfaces.d" {
    printf 'auto lo\niface lo inet loopback\n' > "$ROOT/etc/network/interfaces"
    run prep bridge "${BR[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"does not source /etc/network/interfaces.d"* ]]
    [ ! -e "$ROOT/etc/network/interfaces.d/vmbr9" ]
    run changes; [ "$status" -ne 0 ]
}

@test "bridge FAILs when sshd forbids the forwarding ProxyJump needs, and changes nothing" {
    TCPFWD=no run prep bridge "${BR[@]}"
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  sshd AllowTcpForwarding is 'no'"* ]]
    [[ "$output" == *"nothing was changed"* ]]
    [[ "$output" != *"GATE:"* ]]
    [ ! -e "$ROOT/etc/network/interfaces.d/vmbr9" ]
    run changes; [ "$status" -ne 0 ]
}

@test "bridge stops at its gate when unattended without --yes" {
    KIT_YES=0 run prep bridge "${BR[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"needs a decision"* ]]
    [ ! -e "$ROOT/etc/network/interfaces.d/vmbr9" ]
    run changes; [ "$status" -ne 0 ]
}

# ── key ─────────────────────────────────────────────────────────────────────

@test "key installs the public key once, and a rerun changes nothing" {
    run prep key "${KY[@]}"
    echo "$output"; [ "$status" -eq 0 ]
    cmp "$PUB" "$ROOT/root/r770-e2e.pub"
    run prep key "${KY[@]}"
    [ "$status" -eq 0 ]; [[ "$output" == *"already holds this key — not changed"* ]]
}

@test "key never overwrites a different file and never takes a private key" {
    mkdir -p "$ROOT/root"; echo "ssh-ed25519 AAAAOTHER other@host" > "$ROOT/root/r770-e2e.pub"
    run prep key "${KY[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"exists and differs"* ]]
    grep -q OTHER "$ROOT/root/r770-e2e.pub"
    printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nxx\n' > "$PUB"
    run prep key "${KY[@]}" --sshkeys /root/other.pub
    [ "$status" -eq 1 ]; [[ "$output" == *"PRIVATE key"* ]]
    [ ! -e "$ROOT/root/other.pub" ]
}

# ── template ────────────────────────────────────────────────────────────────

@test "template builds a never-booted cloud-init template with a capture NIC and scsi9 free" {
    hostonly vmbr9
    run prep template "${TP[@]}"
    echo "$output"; [ "$status" -eq 0 ]
    grep -E '^qm (create|set|disk|template|start)' "$STUB_LOG" | cut -d' ' -f1-3 > "$BATS_TEST_TMPDIR/order"
    printf 'qm create 9000\nqm set 9000\nqm disk resize\nqm set 9000\nqm set 9000\nqm template 9000\n' | diff - "$BATS_TEST_TMPDIR/order"
    ! grep -q '^qm start' "$STUB_LOG"
    grep -q -- '--net0 virtio,bridge=vmbr9 --net1 virtio,bridge=vmbr9' "$STUB_LOG"
    grep -q -- '--scsi0 local-lvm:0,import-from=' "$STUB_LOG"
    grep -q -- '--scsi1 local-lvm:460,serial=r770e2edata' "$STUB_LOG"
    grep -q -- '--cicustom vendor=local:snippets/r770-e2e-vendor.yaml' "$STUB_LOG"
    ! grep -q -- 'scsi9\|ipconfig' "$STUB_LOG"
    [ -f "$SNIP" ]; head -1 "$SNIP" | grep -q '^#cloud-config$'
    [[ "$output" == *"PASS  scsi9 is free for the media disk"* ]]
    [[ "$output" == *"PASS  net1 (capture stand-in) has no ipconfig: no address"* ]]
    grep -q -- '--ciupgrade 0' "$STUB_LOG"
    [[ "$output" == *"PASS  cloud-init package upgrade is off: a clone never tries apt against the internet"* ]]
}

@test "template refuses a Proxmox that cannot turn cloud-init's package upgrade off" {
    hostonly vmbr9
    OLD_PVE=1 run prep template "${TP[@]}"
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"has no ciupgrade option"* ]]
    run changes; [ "$status" -ne 0 ]; [ ! -e "$SNIP" ]
}

@test "the vendor data is valid bash and lays out every mount the import preflight demands" {
    hostonly vmbr9
    run prep template "${TP[@]}"; [ "$status" -eq 0 ]
    # the layout script is the block scalar between 'content: |' and 'runcmd:', indented 6
    sed -n '/content: |/,/^runcmd:/p' "$SNIP" | sed '1d;$d' | sed 's/^      //' > "$BATS_TEST_TMPDIR/layout"
    bash -n "$BATS_TEST_TMPDIR/layout"
    lvs=$(sed -n 's/^LVS="\(.*\)"$/\1/p' "$BATS_TEST_DIRNAME/../scripts/r770-import-bundle.sh")
    [ -n "$lvs" ]
    for lv in $lvs; do grep -qE "^[a-z0-9]+ $lv [0-9]+$" "$BATS_TEST_TMPDIR/layout" || { echo "missing: $lv"; false; }; done
    total=$(awk '/^LAYOUT$/ { f = 0 } f && NF == 3 { t += $3 } /<<.LAYOUT/ { f = 1 } END { print t }' "$BATS_TEST_TMPDIR/layout")
    [ "$total" -gt 90 ]
    [ "$total" -le 100 ]
}

@test "template under the rehearsed data size is a WARN, not a refusal" {
    hostonly vmbr9
    run prep template "${TP[@]}" --data-size 200
    [ "$status" -eq 2 ]; [[ "$output" == *"WARN  --data-size 200 GB is under the rehearsed 460"* ]]
}

@test "template refuses a VMID that is taken, and one that is a VM it did not build" {
    hostonly vmbr9
    TAKEN=9000 run prep template "${TP[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"VMID 9000 is not free"* ]]
    printf 'name: someone-else\nscsi0: local-lvm:vm-9000-disk-0\n' > "$S/vm-9000.conf"
    run prep template "${TP[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"is not this script's template"* ]]
    run changes; [ "$status" -ne 0 ]
}

@test "template reports its own earlier template and changes nothing" {
    hostonly vmbr9
    printf 'ciupgrade: 0\ndescription: r770-e2e-template\nide2: local-lvm:vm-9000-cloudinit,media=cdrom\ntemplate: 1\n' > "$S/vm-9000.conf"
    run prep template "${TP[@]}"
    echo "$output"; [ "$status" -eq 0 ]
    [[ "$output" == *"already exists and is this script's"* ]]
    sed -i '/^ciupgrade:/d' "$S/vm-9000.conf"
    run prep template "${TP[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  template 9000 leaves cloud-init's package upgrade on"* ]]
    run changes; [ "$status" -ne 0 ]
}

@test "template refuses a bridge with a physical port, for net0 or the capture NIC" {
    hostonly vmbr9
    run prep template "${TP[@]}" --capture-bridge vmbr0
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  net1 (capture stand-in): bridge vmbr0 has physical port(s) eno1"* ]]
    run prep template "${TP[@]}" --bridge vmbr7
    [ "$status" -eq 1 ]; [[ "$output" == *"bridge vmbr7 does not exist"* ]]
    run changes; [ "$status" -ne 0 ]; [ ! -e "$SNIP" ]
}

@test "template refuses no snippets storage, a non-qcow2 image, and a foreign snippet" {
    hostonly vmbr9
    NO_SNIPPETS=1 run prep template "${TP[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"not active with content 'snippets'"* ]]
    RAW_IMAGE=1 run prep template "${TP[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"is not a qcow2 image"* ]]
    mkdir -p "$(dirname "$SNIP")"; echo "#cloud-config" > "$SNIP"
    run prep template "${TP[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"is not this script's vendor data — not overwritten"* ]]
    [ "$(cat "$SNIP")" = "#cloud-config" ]
    run changes; [ "$status" -ne 0 ]
}

@test "a failed import names the rollback and stops before the template is made" {
    hostonly vmbr9
    QM_RC=set:1 run prep template "${TP[@]}"
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"importing the image failed — rollback: qm destroy 9000 --purge 1"* ]]
    ! grep -q '^qm template' "$STUB_LOG"
}

# ── all ─────────────────────────────────────────────────────────────────────

@test "all --dry-run reads everything and changes nothing" {
    run prep all "${BR[@]}" "${KY[@]}" "${TP[@]}" --dry-run
    echo "$output"; [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN: ifup vmbr9"* && "$output" == *"DRY-RUN: qm create 9000"* && "$output" == *"DRY-RUN: qm template 9000"* ]]
    [[ "$output" == *"SKIP  net0 (management): bridge vmbr9 does not exist yet"* ]]
    [[ "$output" == *"SKIP  dry run: nothing was prepared"* ]]
    [[ "$output" != *"PASS  this host is prepared"* ]]
    run changes; [ "$status" -ne 0 ]
    [ ! -e "$ROOT/etc/network/interfaces.d/vmbr9" ]; [ ! -e "$ROOT/root/r770-e2e.pub" ]; [ ! -e "$SNIP" ]
}

@test "all prepares the bridge, the key and the template in one run" {
    run prep all "${BR[@]}" "${KY[@]}" "${TP[@]}"
    echo "$output"; [ "$status" -eq 0 ]
    [ -f "$ROOT/etc/network/interfaces.d/vmbr9" ]; [ -f "$ROOT/root/r770-e2e.pub" ]; [ -f "$SNIP" ]
    grep -q 'template: 1' "$S/vm-9000.conf"
    [[ "$output" == *"prepared for r770-proxmox-e2e.sh (--bridge vmbr9 --sshkeys /root/r770-e2e.pub --template-vmid 9000 --nameserver 192.0.2.1 --searchdomain <domain>)"* ]]
}

# ── staging-vm ──────────────────────────────────────────────────────────────
# The internet-connected staging host: a plain cloud-init VM on the bridge that
# carries the uplink (vmbr0 here, port eno1), left stopped. Never part of all.
stgkey() { mkdir -p "$ROOT/root"; cp "$PUB" "$ROOT/root/r770-e2e.pub"; }
without() {  # without <flag> — SV minus that flag and its value, into $args
    args=(); local skipnext=0 a
    for a in "${SV[@]}"; do
        if [ "$skipnext" = 1 ]; then skipnext=0; continue; fi
        [ "$a" = "$1" ] && { skipnext=1; continue; }
        args+=("$a")
    done
}

@test "staging-vm needs every value, takes none on trust, and refuses before anything runs" {
    stgkey
    for f in --vmid --storage --bridge --image --disk-size --memory --cores --guest-user --sshkeys --ip; do
        without "$f"
        run prep staging-vm "${args[@]}"
        [ "$status" -eq 1 ]; [[ "$output" == *"needs $f"* ]] || { echo "$f: $output"; false; }
    done
    run prep staging-vm "${SV[@]}" --ip 192.0.2.300/24
    [ "$status" -eq 1 ]; [[ "$output" == *"--ip"* ]]
    run prep staging-vm "${SV[@]}" --gw 192.0.2.1
    [ "$status" -eq 1 ]; [[ "$output" == *"--gw is for a static --ip"* ]]
    run prep staging-vm "${SV[@]}" --guest-user 'Root;x'
    [ "$status" -eq 1 ]; [[ "$output" == *"--guest-user"* ]]
    run prep staging-vm "${SV[@]}" --vmid 9x
    [ "$status" -eq 1 ]; [[ "$output" == *"--vmid"* ]]
    [ ! -s "$STUB_LOG" ]
}

@test "staging-vm creates a plain, stopped cloud-init VM on the uplink bridge, in order" {
    stgkey
    run prep staging-vm "${SV[@]}"
    echo "$output"; [ "$status" -eq 0 ]
    [[ "$output" == *"GATE: staging VM 9100"*"-- current --"*"-- proposed --"*"-- rollback --"*"qm destroy 9100 --purge 1"* ]]
    [[ "$output" == *"PASS  bridge vmbr0 carries physical port(s) eno1"* ]]
    grep -E '^qm (create|set|disk|template|start)' "$STUB_LOG" | cut -d' ' -f1-3 > "$BATS_TEST_TMPDIR/order"
    printf 'qm create 9100\nqm set 9100\nqm disk resize\nqm set 9100\n' | diff - "$BATS_TEST_TMPDIR/order"
    grep -q -- '--name r770-staging --description r770-staging-vm .*--memory 8192 .*--cores 4 .*--net0 virtio,bridge=vmbr0 ' "$STUB_LOG"
    grep -q -- 'qm disk resize 9100 scsi0 300G' "$STUB_LOG"
    grep -q -- '--ciuser stager --sshkeys /root/r770-e2e.pub --ipconfig0 ip=dhcp' "$STUB_LOG"
    ! grep -q -- '--net1\|serial=\|cicustom' "$STUB_LOG"
    [[ "$output" == *"PASS  VM 9100 exists and carries r770-staging-vm"* ]]
    [[ "$output" == *"harness/r770-staging-vm.sh start"*"staging/r770-staging-preflight.sh"* ]]
}

@test "staging-vm takes a static address with its gateway" {
    stgkey
    without --ip
    gw=192.0.2.1
    run prep staging-vm "${args[@]}" --ip 192.0.2.50/24 --gw "$gw"
    echo "$output"; [ "$status" -eq 0 ]
    grep -q -- "--ipconfig0 ip=192.0.2.50/24,gw=$gw" "$STUB_LOG"
}

@test "staging-vm --dry-run prints every command and changes nothing" {
    stgkey
    run prep staging-vm "${SV[@]}" --dry-run
    echo "$output"; [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN: qm create 9100"* && "$output" == *"DRY-RUN: qm disk resize 9100 scsi0 300G"* ]]
    run changes; [ "$status" -ne 0 ]
    [ ! -e "$S/vm-9100.conf" ]
}

@test "staging-vm stops at its gate when unattended without --yes" {
    stgkey
    KIT_YES=0 run prep staging-vm "${SV[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"needs a decision"* ]]
    run changes; [ "$status" -ne 0 ]
}

@test "staging-vm WARNs on a host-only bridge, a static address with no gateway, and a small disk" {
    stgkey; hostonly vmbr9
    without --bridge
    run prep staging-vm "${args[@]}" --bridge vmbr9
    [ "$status" -eq 2 ]; [[ "$output" == *"WARN  bridge vmbr9 has no physical port"*"air-gapped subnet"* ]]
    without --ip
    run prep staging-vm "${args[@]}" --ip 192.0.2.50/24 --vmid 9101
    [ "$status" -eq 2 ]; [[ "$output" == *"WARN  --ip 192.0.2.50/24 with no --gw"* ]]
    without --disk-size
    run prep staging-vm "${args[@]}" --disk-size 100 --vmid 9102
    [ "$status" -eq 2 ]; [[ "$output" == *"WARN  --disk-size 100 GB is under 200 GB"* ]]
}

@test "staging-vm refuses a taken or foreign VMID, an absent bridge, and a missing or private key" {
    run prep staging-vm "${SV[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"no such readable file on this host"* ]]
    stgkey
    TAKEN=9100 run prep staging-vm "${SV[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"VMID 9100 is not free"* ]]
    printf 'name: someone-else\n' > "$S/vm-9100.conf"
    run prep staging-vm "${SV[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"is not this script's staging VM"* ]]
    rm "$S/vm-9100.conf"
    without --bridge
    run prep staging-vm "${args[@]}" --bridge vmbr7
    [ "$status" -eq 1 ]; [[ "$output" == *"bridge vmbr7 does not exist"* ]]
    printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nxx\n' > "$ROOT/root/r770-e2e.pub"
    run prep staging-vm "${SV[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"PRIVATE key"* ]]
    run changes; [ "$status" -ne 0 ]
}

@test "staging-vm reports its own earlier VM and changes nothing" {
    stgkey
    printf 'description: r770-staging-vm\nipconfig0: ip=dhcp\n' > "$S/vm-9100.conf"
    run prep staging-vm "${SV[@]}"
    echo "$output"; [ "$status" -eq 0 ]
    [[ "$output" == *"already exists and is this script's staging VM"* ]]
    run changes; [ "$status" -ne 0 ]
}

@test "the template keeps its defaults now that staging-vm has none" {
    hostonly vmbr9
    run prep template "${TP[@]}" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"qm create 9000 --name r770-e2e-template "*"--memory 16384 "*"--cores 8 "* ]]
}
