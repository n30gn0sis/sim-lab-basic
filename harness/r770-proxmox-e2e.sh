#!/usr/bin/env bash
#
# r770-proxmox-e2e.sh — the lab, end to end, on a throwaway Proxmox VM: full-
# clone a prepared Ubuntu 24.04 cloud-init template, install the bundle on it
# with the kit's own installer, prove it, then destroy the clone. Runs on the
# OPERATOR'S machine; every change to the hypervisor is one `qm` command sent
# over ssh, the channel harness/r770-staging-vm.sh uses. No API token.
#
#   r770-proxmox-e2e.sh provision --pve H --node N --template-vmid T --vmid V
#                       --storage S --bridge B --guest-ip CIDR --guest-user U
#                       --sshkeys PVE-PATH --media-size GB [--guest-gw IP]
#                       [--boot-wait SECONDS]                      (GATED: clone)
#   r770-proxmox-e2e.sh deploy    --pve H --vmid V --guest-ip CIDR --guest-user U
#                       --bundle DIR --install-conf FILE --media-mnt PATH
#   r770-proxmox-e2e.sh verify    --pve H --vmid V --guest-ip CIDR --guest-user U
#                       [--mgmt-peer IP]
#   r770-proxmox-e2e.sh teardown  --pve H --vmid V                  (GATED: destroy)
#   r770-proxmox-e2e.sh all       every flag above; teardown is ALWAYS attempted
#
#   --pve H            the hypervisor's ssh host (key login; never a password)
#   --node N           the node name `hostname` prints there; checked, so a
#                      cluster member reached by mistake is refused
#   --template-vmid T  the prepared template (must carry `template: 1` and a
#                      cloud-init drive); it is read, never changed
#   --vmid V           the clone's id; refused if the cluster already has it
#   --storage S        where the full clone and its media disk are written
#   --bridge B         net0's bridge; must have no physical port (host-only)
#   --guest-ip CIDR    the clone's static address on B, set by cloud-init
#   --guest-gw IP      optional, and wrong for an air-gapped run: no gateway
#                      means no default route
#   --guest-user U     cloud-init's user; key login, passwordless sudo
#   --sshkeys PATH     a public key file ON THE PROXMOX HOST, for that user
#   --media-size GB    the media disk added to the clone (the stand-in USB)
#   --bundle DIR       the bundle on this machine, pushed onto the media disk
#   --install-conf F   install.conf for the TEMPLATE's hardware: CAPTURE_IFS,
#                      LAB_BRIDGE, MGMT_IF, MGMT_CIDR (from `r770-install.sh
#                      discover` on one clone); BUNDLE, MEDIA and DEVICE must
#                      be empty: this script fills them from what it discovers
#   --media-mnt PATH   where the media is mounted in the guest
#   --mgmt-peer IP     passed to r770-validate.sh's mgmt reachability check
#   --boot-wait SECS   how long provision waits for ssh (default 600)
#   --yes / --non-interactive / --dry-run   as everywhere in the kit
#
#   0  done · 2  done with warnings · 1  refused or failed
#
# Ownership: provision writes a run id to a marker file in the evidence
# directory BEFORE it clones, and `qm clone` itself stamps the description
# r770-e2e-run=<id> as it creates the VM (the tag r770-e2e follows, informative).
# deploy, verify and teardown refuse a VM whose description is not exactly the
# marker's run id: a VM this script did not create is never deployed to and
# never destroyed, whatever --vmid says. `all` tears down only the clone its
# OWN run id names, never an earlier run's leftover: that takes an explicit,
# gated `teardown`. Volumes no config references are reported, never deleted.
# The media disk is found in the guest by the serial provision gave it.
# Evidence from the guest is pulled back before anything is destroyed.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib/common.sh"

PVE=""; NODE=""; TEMPLATE=""; VMID=""; STORAGE=""; BRIDGE=""; GUEST_IP=""; GUEST_GW=""
GUEST_USER=""; SSHKEYS=""; MEDIA_SIZE=""; BUNDLE=""; INSTALL_CONF=""; MEDIA_MNT=""
MGMT_PEER=""; BOOT_WAIT=600; RUN_ID=""; GUEST=""
TAG="r770-e2e"
MEDIA_SERIAL="r770e2emedia"     # the media disk's serial: how the guest finds it
MEDIA_SLOT="scsi9"              # the clone's media disk slot; refused if the template uses it
MEDIA_LABEL="R770E2E"
GUEST_EVIDENCE="/var/tmp/r770-e2e-evidence"
VERIFY_OUT="/var/tmp/r770-e2e-verify"        # r770-validate.sh --out, as agreed for #2
GUEST_CONF="/etc/lab/install.conf"
PLANNED=0                       # all --dry-run: the VM is never created, so nothing of it is read
STATE_DIR="${KIT_EVIDENCE_DIR:-$PWD/r770-evidence}"
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

pve()     { ssh -o BatchMode=yes -o ConnectTimeout=10 "$PVE" "$@"; }          # reads
pve_run() { run ssh -o BatchMode=yes -o ConnectTimeout=10 "$PVE" "$@"; }      # changes; honours --dry-run
known_hosts() { printf '%s/r770-proxmox-e2e-%s-%s.known_hosts' "$STATE_DIR" "$PVE" "$VMID"; }
# The guest: a fresh clone has a fresh host key on a reused address, so each
# clone gets its own known_hosts file, never the operator's.
KH=""
guest_init() { KH=$(known_hosts); GUEST="${GUEST_USER}@${GUEST_IP%/*}"; }
guest() {
    ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 \
        -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$KH" "$GUEST" "$@"
}
guest_run() {
    run ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 \
        -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$KH" "$GUEST" "$@"
}
marker() { printf '%s/r770-proxmox-e2e-%s-%s.run' "$STATE_DIR" "$PVE" "$VMID"; }

# ── ownership ───────────────────────────────────────────────────────────────
# owned — 0 when VM $VMID is the one this machine's provision created: the
# marker holds a run id, and the VM's live description is exactly
# r770-e2e-run=<that id> — set by `qm clone` itself, in the same command that
# creates the VM, so no clone can exist without it. The tag, set afterwards
# by `qm set`, is informative only: a clone whose `qm set` failed is still
# ours to remove. A template is never ours. Dies naming what is missing.
RUN_ID_RE='^[0-9]{14}-[0-9]+$'
owned() {
    local m id cfg
    if [ "$PLANNED" = "1" ]; then note "dry-run of all: VM $VMID is not created, so its ownership is not read"; return 0; fi
    m=$(marker)
    [ -s "$m" ] || die "no run marker for VM $VMID on $PVE ($m) — this machine did not provision it; refusing to touch it"
    id=$(head -1 "$m")
    [[ "$id" =~ $RUN_ID_RE ]] || die "the run marker $m does not hold a run id — refusing to touch VM $VMID"
    cfg=$(pve qm config "$VMID" --current 2>/dev/null) || cfg=""
    [ -n "$cfg" ] || die "cannot read VM $VMID's config on $PVE — does it still exist? (marker: $m)"
    printf '%s\n' "$cfg" | grep -q '^template: 1' && die "VM $VMID is a template — refusing to touch it"
    # Proxmox may print the '=' of a description percent-encoded
    printf '%s\n' "$cfg" | grep -qE "^description: r770-e2e-run(=|%3D)${id}\$" \
        || die "VM $VMID's description is not exactly r770-e2e-run=$id (this machine's run id) — refusing to touch it"
    if printf '%s\n' "$cfg" | grep -qE "^tags:(.*[ ;,])?${TAG}([ ;,]|$)"; then
        pass "VM $VMID is this run's clone (run id $id, tag $TAG)"
    else
        warn "VM $VMID is this run's clone (run id $id) but lacks the tag $TAG — its qm set did not complete"
    fi
}

# bridge_phys <bridge> — on the hypervisor: print the bridge's physical ports
# (a port with a sysfs device link, or one whose VLAN/bond lowers have one),
# NOBRIDGE when the bridge does not exist. Same rule as bridge_physical_ports().
bridge_phys() {
    pve bash -s -- "$1" <<'EOF'
br=$1; sys=/sys/class/net
[ -d "$sys/$br/bridge" ] || { echo NOBRIDGE; exit 0; }
phys() { local n=$1 d=${2:-0} l; [ "$d" -le 8 ] || return 1; [ -e "$sys/$n/device" ] && return 0
         for l in "$sys/$n"/lower_*; do [ -e "$l" ] || continue; phys "${l##*/lower_}" $((d + 1)) && return 0; done; return 1; }
for p in "$sys/$br"/brif/*; do [ -e "$p" ] || continue; phys "${p##*/}" && echo "${p##*/}"; done
exit 0
EOF
}
check_bridge() {  # check_bridge <bridge> <what> — FAIL unless host-only
    local out
    out=$(bridge_phys "$1") || { fail "$2: could not inspect bridge $1 on $PVE"; return 1; }
    if [ "$out" = "NOBRIDGE" ]; then fail "$2: bridge $1 does not exist on $PVE"; return 1; fi
    if [ -n "$out" ]; then fail "$2: bridge $1 has physical port(s) $(printf '%s' "$out" | tr '\n' ' ')— not host-only, the clone would not be air-gapped"; return 1; fi
    pass "$2: bridge $1 has no physical port (host-only)"
}
# bridge_isolation <bridge> — on the hypervisor: "<forwarding> <disable_ipv6>", the
# second "none" when the host has no IPv6 at all. Read on every run: the kernel resets
# a bridge's forwarding whenever net.ipv4.ip_forward changes (a daemon starting, say),
# so what r770-proxmox-prep.sh proved at ifup may not hold today.
bridge_isolation() {
    pve bash -s -- isolation "$1" <<'EOF'
br=$2
v4=$(cat "/proc/sys/net/ipv4/conf/$br/forwarding" 2>/dev/null) || v4="?"
f6=/proc/sys/net/ipv6/conf/$br/disable_ipv6
if [ -e "$f6" ]; then v6=$(cat "$f6" 2>/dev/null) || v6="?"; else v6=none; fi
echo "${v4:-?} ${v6:-?}"
EOF
}
check_isolation() {  # check_isolation <bridge> <what> — FAIL unless the bridge forwards nothing off the host
    local out v4 v6
    out=$(bridge_isolation "$1") || { fail "$2: could not read bridge $1's forwarding on $PVE"; return 1; }
    read -r v4 v6 <<< "$out"
    case "$v4" in
        0) ;;
        1) fail "$2: bridge $1 forwards IPv4 on $PVE (net.ipv4.conf.$1.forwarding=1) — a clone could be routed off the host; rerun r770-proxmox-prep.sh bridge on $NODE (or sysctl -w net/ipv4/conf/$1/forwarding=0 there)"; return 1 ;;
        *) fail "$2: cannot read net.ipv4.conf.$1.forwarding on $PVE — the clone's isolation is not proven"; return 1 ;;
    esac
    case "$v6" in
        1|none) ;;
        *) fail "$2: bridge $1 has IPv6 on (net.ipv6.conf.$1.disable_ipv6=$v6) — a clone could be routed off the host over IPv6; rerun r770-proxmox-prep.sh bridge on $NODE (or sysctl -w net/ipv6/conf/$1/disable_ipv6=1 there)"; return 1 ;;
    esac
    pass "$2: bridge $1 does not forward (IPv4 forwarding 0, IPv6 ${v6/1/off})"
}

# ── provision ───────────────────────────────────────────────────────────────
TPL_CFG=""
pv_current() {
    printf 'template %s on %s:\n' "$TEMPLATE" "$NODE"
    printf '%s\n' "$TPL_CFG" | grep -E '^(name|template|memory|cores|scsihw|net[0-9]+|(scsi|virtio|sata|ide)[0-9]+):' | sed 's/^/  /'
    printf 'VMID %s: free on the cluster\n' "$VMID"
}
ipconfig() { printf 'ip=%s%s' "$GUEST_IP" "${GUEST_GW:+,gw=$GUEST_GW}"; }
pv_proposed() {
    echo "qm clone $TEMPLATE $VMID --full 1 --name r770-e2e-$VMID --description r770-e2e-run=$RUN_ID --storage $STORAGE"
    echo "qm set $VMID --tags $TAG --net0 virtio,bridge=$BRIDGE --ipconfig0 $(ipconfig) --ciuser $GUEST_USER --sshkeys $SSHKEYS --$MEDIA_SLOT $STORAGE:$MEDIA_SIZE,serial=$MEDIA_SERIAL"
    echo "qm start $VMID   (after every NIC's bridge is proven host-only)"
}
cmd_provision() {
    local host out vols nets b ci_rc deadline
    banner "provision — full clone of template $TEMPLATE as VM $VMID"
    host=$(pve hostname 2>/dev/null) || die "cannot reach $PVE over ssh (key login, BatchMode)"
    [ "$host" = "$NODE" ] || die "$PVE is node '$host', not '$NODE' — refusing to act on a node you did not name"
    pass "$PVE is node $NODE"
    TPL_CFG=$(pve qm config "$TEMPLATE" 2>/dev/null) || TPL_CFG=""
    [ -n "$TPL_CFG" ] || die "cannot read template $TEMPLATE on $NODE — does it exist? (qm list)"
    printf '%s\n' "$TPL_CFG" | grep -q '^template: 1' || die "VM $TEMPLATE is not a template (no 'template: 1') — a full clone is only taken from a template"
    printf '%s\n' "$TPL_CFG" | grep -q 'cloudinit' || die "template $TEMPLATE has no cloud-init drive — the clone's user, key and address could not be set"
    printf '%s\n' "$TPL_CFG" | grep -q "^${MEDIA_SLOT}:" && die "template $TEMPLATE already uses $MEDIA_SLOT, the slot the media disk takes"
    pass "template $TEMPLATE: template, cloud-init drive, $MEDIA_SLOT free"
    out=$(pve pvesh get /cluster/nextid --vmid "$VMID" 2>&1) || true
    [ "$(printf '%s' "$out" | tr -d '"[:space:]')" = "$VMID" ] \
        || die "VMID $VMID is not free on the cluster — refusing to clone over it (pvesh said: $(printf '%s' "$out" | head -1))"
    pass "VMID $VMID is free on the cluster"
    pve pvesm status --storage "$STORAGE" >/dev/null 2>&1 || die "storage '$STORAGE' is not active on $NODE (pvesm status)"
    pass "storage $STORAGE is active"
    vols=$(pve pvesm list "$STORAGE" --vmid "$VMID" 2>&1)         || die "cannot list storage $STORAGE's volumes on $PVE (pvesm list failed: $(printf '%s' "$vols" | head -1)) — refusing to clone without knowing what VMID $VMID already owns there"
    out=$(printf '%s
' "$vols" | awk 'NR > 1 && NF { print $1 }')
    [ -z "$out" ] || die "storage $STORAGE already holds volume(s) of VMID $VMID ($(printf '%s' "$out" | tr '\n' ' ')) — not this run's; refusing to clone beside them"
    pass "storage $STORAGE holds no volume of VMID $VMID"
    pve test -r "$SSHKEYS" || die "$SSHKEYS is not a readable file on $PVE — --sshkeys is a path on the Proxmox host"
    pass "public key file $SSHKEYS is readable on $PVE"
    check_bridge "$BRIDGE" "--bridge" || footer "provision"
    check_isolation "$BRIDGE" "--bridge" || footer "provision"

    # all passes its own RUN_ID down, so it can tell its clone from an earlier run's
    [ -n "$RUN_ID" ] || RUN_ID="$(date +%Y%m%d%H%M%S)-$RANDOM$RANDOM"
    gate "full clone of template $TEMPLATE as VM $VMID" pv_current pv_proposed \
        "r770-proxmox-e2e.sh teardown --pve $PVE --vmid $VMID — stops and destroys only this clone and its disks (run id $RUN_ID); template $TEMPLATE is never changed"
    if [ "$DRY" != "1" ]; then
        mkdir -p "$STATE_DIR"
        # BEFORE the clone: `qm clone` stamps the run id into the description as
        # it creates the VM, so whatever is left after a failure or a Ctrl-C is
        # still recognisably ours. Line 2: the storage, for teardown's leftover check.
        printf '%s\n%s\n' "$RUN_ID" "$STORAGE" > "$(marker)"
        rm -f "$(known_hosts)"                  # a new clone has a new host key on the same address
    fi
    pve_run qm clone "$TEMPLATE" "$VMID" --full 1 --name "r770-e2e-$VMID" \
        --description "r770-e2e-run=$RUN_ID" --storage "$STORAGE" \
        || die "qm clone failed — read the line above; if a VM $VMID was left, run: teardown --pve $PVE --vmid $VMID"
    pve_run qm set "$VMID" --tags "$TAG" --net0 "virtio,bridge=$BRIDGE" --ipconfig0 "$(ipconfig)" \
        --ciuser "$GUEST_USER" --sshkeys "$SSHKEYS" "--$MEDIA_SLOT" "$STORAGE:$MEDIA_SIZE,serial=$MEDIA_SERIAL" \
        || die "qm set failed — VM $VMID is left stopped; remove it with: teardown --pve $PVE --vmid $VMID (its run id is in its description)"
    if [ "$DRY" = "1" ]; then
        pve_run qm start "$VMID"
        note "DRY-RUN: every NIC's bridge would be proven host-only before the start, then ssh awaited for ${BOOT_WAIT}s and cloud-init's end"
        footer "provision"
    fi
    pass "VM $VMID cloned and configured"

    nets=$(pve qm config "$VMID" --current | sed -nE 's/^net[0-9]+:.*bridge=([^,]+).*/\1/p' | sort -u)
    [ -n "$nets" ] || { fail "could not read VM $VMID's NICs — not starting it"; footer "provision"; }
    for b in $nets; do
        [[ "$b" =~ ^[A-Za-z][A-Za-z0-9_.-]{0,14}$ ]] || { fail "VM $VMID has a bridge name '$b' this script will not send through a shell"; continue; }
        check_bridge "$b" "VM $VMID NIC" && check_isolation "$b" "VM $VMID NIC"
    done
    [ "$FAILED" -eq 0 ] || { note "VM $VMID is NOT started; remove it with teardown"; footer "provision"; }

    pve_run qm start "$VMID" || die "qm start failed — run teardown"
    pass "VM $VMID started"
    guest_init
    deadline=$((SECONDS + BOOT_WAIT))
    until guest true 2>/dev/null; do
        if [ "$SECONDS" -ge "$deadline" ]; then fail "guest $GUEST did not answer ssh within ${BOOT_WAIT}s"; footer "provision"; fi
        sleep 5
    done
    pass "guest answers on $GUEST"
    ci_rc=0; guest cloud-init status --wait >/dev/null 2>&1 || ci_rc=$?
    case "$ci_rc" in
        0) pass "cloud-init finished" ;;
        2) warn "cloud-init finished with recoverable errors — read 'cloud-init status --long' in the guest" ;;
        *) fail "cloud-init did not finish cleanly (exit $ci_rc)" ;;
    esac
    footer "provision"
}

# ── deploy ──────────────────────────────────────────────────────────────────
# collect <name> <guest-dir> — pull a guest directory back as a tarball; never fatal.
collect() {
    local dest
    if [ "$DRY" = "1" ]; then note "DRY-RUN: $2 would be pulled back from the guest"; return 0; fi
    mkdir -p "$STATE_DIR"
    dest="$STATE_DIR/r770-proxmox-e2e-$VMID-$1-$(date +%Y%m%d-%H%M%S).tar"
    if guest "sudo tar -C $(dirname "$2") -cf - $(basename "$2")" > "$dest" 2>/dev/null && [ -s "$dest" ]; then
        note "guest evidence: $dest"
    else
        rm -f "$dest"; warn "could not pull $2 back from the guest — its evidence stays in the VM until teardown"
    fi
}

CONF_BODY=""
read_install_conf() {  # the operator's file, minus comments; BUNDLE/MEDIA/DEVICE must be empty
    local line key val
    [ -f "$INSTALL_CONF" ] || die "--install-conf $INSTALL_CONF: no such file"
    while IFS= read -r line || [ -n "$line" ]; do
        line=${line%$'\r'}
        case "$line" in ''|'#'*) continue ;; esac
        key=${line%%=*}; val=${line#*=}
        [[ "$key" =~ ^[A-Z_]+$ ]] || die "--install-conf: '$line' is not KEY=value"
        case "$key" in
            BUNDLE|MEDIA|DEVICE)
                [ -z "$val" ] || die "--install-conf sets $key — leave BUNDLE, MEDIA and DEVICE empty: this script fills them from the clone" ;;
            *) CONF_BODY+="$line"$'\n' ;;
        esac
    done < "$INSTALL_CONF"
}

cmd_deploy() {
    local b name kb dev size fsrc=0 fstype label inst rc
    banner "deploy — the bundle onto VM $VMID's media disk, then the kit's installer"
    b=$(bundle_dir "$BUNDLE") || exit 1
    name=$(basename "$b")
    read_install_conf
    pass "bundle $name and install.conf read"
    owned
    guest_init
    inst="$MEDIA_MNT/$name/kit/scripts/r770-install.sh"
    if [ "$PLANNED" = "1" ]; then
        note "DRY-RUN: find the disk with serial $MEDIA_SERIAL (lsblk), mkfs.ext4 -L $MEDIA_LABEL it, stream $name onto it, remount it read-only at $MEDIA_MNT"
        note "DRY-RUN: write $GUEST_CONF (the operator's keys + BUNDLE=$MEDIA_MNT/$name MEDIA=$MEDIA_MNT DEVICE=<that disk>)"
        note "DRY-RUN: sudo $inst plan, then sudo $inst run --yes; pull $GUEST_EVIDENCE back"
        footer "deploy"
    fi

    dev=$(guest lsblk -dnpo NAME,SERIAL 2>/dev/null | awk -v s="$MEDIA_SERIAL" '$2 == s { print $1 }')
    [ "$(printf '%s' "$dev" | grep -c .)" -eq 1 ] \
        || die "the guest does not show exactly one disk with serial $MEDIA_SERIAL (found: '${dev}') — was it provisioned by this script?"
    [[ "$dev" =~ ^/dev/[a-z0-9]+$ ]] || die "the media disk's name '$dev' is not a plain /dev/<name>"
    pass "media disk: $dev (serial $MEDIA_SERIAL)"
    kb=$(du -sk "$b" | awk '{ print $1 }')
    size=$(guest lsblk -bdno SIZE "$dev" 2>/dev/null | tr -d '[:space:]')
    [[ "$size" =~ ^[0-9]+$ ]] || die "cannot read the size of $dev in the guest"
    [ "$size" -ge $((kb * 1024 * 11 / 10)) ] || die "$dev is $((size / 1048576)) MiB; the bundle needs $((kb * 11 / 10 / 1024)) MiB with 10% room — provision with a larger --media-size"
    # blkid -p exits 2 when the disk holds no recognisable filesystem at all
    fstype=$(guest sudo blkid -p -o value -s TYPE "$dev" 2>/dev/null) || fsrc=$?
    label=""; [ -n "$fstype" ] && label=$(guest sudo blkid -p -o value -s LABEL "$dev" 2>/dev/null)

    if guest sudo test -e "$MEDIA_MNT/$name/.r770-e2e-pushed" 2>/dev/null; then
        pass "the bundle is already on the media (marker present) — not pushed again"
    else
        if [ "$fstype" = "ext4" ] && [ "$label" = "$MEDIA_LABEL" ]; then
            note "$dev already carries $MEDIA_LABEL — pushing into it"
        elif [ "$fsrc" = "2" ] && [ -z "$fstype" ]; then
            guest_run sudo mkfs.ext4 -q -L "$MEDIA_LABEL" "$dev" || die "mkfs on $dev failed"
        else
            die "$dev holds a filesystem that is not this script's ($MEDIA_LABEL) — refusing to format it"
        fi
        guest_run sudo umount "$MEDIA_MNT" 2>/dev/null || true
        guest_run sudo mkdir -p "$MEDIA_MNT" || die "cannot create $MEDIA_MNT in the guest"
        guest_run sudo mount "$dev" "$MEDIA_MNT" || die "cannot mount $dev at $MEDIA_MNT"
        if [ "$DRY" = "1" ]; then
            echo "DRY-RUN: tar -C $(dirname "$b") -cf - $name | ssh $GUEST sudo tar -C $MEDIA_MNT -xf -"
        else
            echo "+ tar -C $(dirname "$b") -cf - $name | ssh $GUEST sudo tar -C $MEDIA_MNT -xf -"
            tar -C "$(dirname "$b")" -cf - "$name" | guest "sudo tar -C $MEDIA_MNT -xf -" \
                || die "pushing the bundle failed — rerun deploy; the copy restarts"
        fi
        guest_run sudo touch "$MEDIA_MNT/$name/.r770-e2e-pushed" || die "cannot mark the push done"
        pass "bundle $name pushed onto $dev"
    fi
    guest_run sudo umount "$MEDIA_MNT" 2>/dev/null || true
    guest_run sudo mount -o ro "$dev" "$MEDIA_MNT" || die "cannot mount $dev read-only at $MEDIA_MNT"

    guest_run sudo mkdir -p /etc/lab || die "cannot create /etc/lab in the guest"
    if [ "$DRY" = "1" ]; then
        echo "DRY-RUN: write $GUEST_CONF in the guest: the operator's keys + BUNDLE=$MEDIA_MNT/$name MEDIA=$MEDIA_MNT DEVICE=$dev"
    else
        printf '%sBUNDLE=%s\nMEDIA=%s\nDEVICE=%s\n' "$CONF_BODY" "$MEDIA_MNT/$name" "$MEDIA_MNT" "$dev" \
            | guest "sudo tee $GUEST_CONF >/dev/null" || die "cannot write $GUEST_CONF in the guest"
        pass "$GUEST_CONF written (BUNDLE, MEDIA, DEVICE from the clone)"
    fi

    rc=0; guest_run sudo env "KIT_EVIDENCE_DIR=$GUEST_EVIDENCE" "$inst" plan --conf "$GUEST_CONF" --non-interactive || rc=$?
    if [ "$DRY" = "1" ]; then
        guest_run sudo env "KIT_EVIDENCE_DIR=$GUEST_EVIDENCE" "$inst" run --yes --conf "$GUEST_CONF"
        collect deploy "$GUEST_EVIDENCE"; footer "deploy"
    fi
    case "$rc" in
        0) pass "installer plan: READY" ;;
        2) warn "installer plan: READY WITH WARNINGS — expected on a first install (no Docker yet, no previous bundle)" ;;
        *) fail "installer plan refused (exit $rc) — nothing was installed"; collect deploy "$GUEST_EVIDENCE"; footer "deploy" ;;
    esac
    rc=0; guest_run sudo env "KIT_EVIDENCE_DIR=$GUEST_EVIDENCE" "$inst" run --yes --conf "$GUEST_CONF" || rc=$?
    case "$rc" in
        0) pass "installer run: INSTALLED" ;;
        2) warn "installer run finished with warnings — never INSTALLED; read its summary" ;;
        *) fail "installer run stopped (exit $rc) — its summary names the step; rerun in the guest with --from <step>" ;;
    esac
    collect deploy "$GUEST_EVIDENCE"
    footer "deploy"
}

# ── verify ──────────────────────────────────────────────────────────────────
conf_val() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | tail -1 | tr -d '\r' | sed 's/^"\(.*\)"$/\1/'; }
cmd_verify() {
    local conf cap br mif mcidr bundle validate rc args
    banner "verify — r770-validate.sh in VM $VMID"
    owned
    guest_init
    if [ "$PLANNED" = "1" ]; then
        note "DRY-RUN: read $GUEST_CONF in the guest, then sudo /srv/bundles/<bundle>/kit/scripts/r770-validate.sh --area host --area network --area portal --area airgap --mgmt-if <MGMT_IF> --mgmt-cidr <MGMT_CIDR> --capture-ifs <CAPTURE_IFS> --lab-bridge <LAB_BRIDGE>${MGMT_PEER:+ --mgmt-peer $MGMT_PEER} --out $VERIFY_OUT --non-interactive"
        footer "verify"
    fi
    conf=$(guest sudo cat "$GUEST_CONF" 2>/dev/null) || conf=""
    [ -n "$conf" ] || die "cannot read $GUEST_CONF in the guest — run deploy first"
    cap=$(conf_val "$conf" CAPTURE_IFS); br=$(conf_val "$conf" LAB_BRIDGE)
    mif=$(conf_val "$conf" MGMT_IF); mcidr=$(conf_val "$conf" MGMT_CIDR); bundle=$(conf_val "$conf" BUNDLE)
    valid "CAPTURE_IFS" "$cap" '^[A-Za-z0-9_.-]+( [A-Za-z0-9_.-]+)*$'
    valid "LAB_BRIDGE" "$br" '^[A-Za-z0-9_.-]+$'
    valid "MGMT_IF" "$mif" '^[A-Za-z0-9_.-]+$'
    valid "MGMT_CIDR" "$mcidr" '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'
    valid "BUNDLE" "$bundle" '^/[A-Za-z0-9_./-]+$'
    { [ -n "$cap" ] && [ -n "$br" ] && [ -n "$mif" ] && [ -n "$mcidr" ] && [ -n "$bundle" ]; } \
        || die "$GUEST_CONF lacks one of CAPTURE_IFS LAB_BRIDGE MGMT_IF MGMT_CIDR BUNDLE"
    validate="/srv/bundles/$(basename "$bundle")/kit/scripts/r770-validate.sh"
    # --capture-ifs travels through the guest's shell: single-quoted so its spaces stay one argument
    args=(--area host --area network --area portal --area airgap --mgmt-if "$mif" --mgmt-cidr "$mcidr"
          --capture-ifs "'$cap'" --lab-bridge "$br")
    if [ -n "$MGMT_PEER" ]; then
        # a bundle cut before --mgmt-peer existed would die on it as an unknown option
        if guest "$validate" --help 2>/dev/null | grep -q -- '--mgmt-peer'; then args+=(--mgmt-peer "$MGMT_PEER")
        else skip "mgmt reachability: this bundle's r770-validate.sh predates --mgmt-peer — not checked"; fi
    fi
    rc=0; guest_run sudo env "KIT_EVIDENCE_DIR=$GUEST_EVIDENCE" "$validate" "${args[@]}" --out "$VERIFY_OUT" --non-interactive || rc=$?
    if [ "$DRY" = "1" ]; then collect verify "$VERIFY_OUT"; footer "verify"; fi
    case "$rc" in
        0) pass "r770-validate.sh: every executed check passed" ;;
        2) warn "r770-validate.sh: warnings — read its report" ;;
        *) if [ -n "$(guest sudo find "$VERIFY_OUT" -name '*.md' 2>/dev/null)" ]; then
               fail "r770-validate.sh: at least one FAIL (exit $rc) — read its report"
           else
               fail "r770-validate.sh did not run (exit $rc, no report under $VERIFY_OUT) — see its output above"
           fi ;;
    esac
    collect verify "$VERIFY_OUT"
    collect verify-logs "$GUEST_EVIDENCE"
    footer "verify"
}

# ── teardown ────────────────────────────────────────────────────────────────
TD_CFG=""; TD_STATE=""
td_current() {
    printf 'VM %s on %s is %s\n' "$VMID" "$PVE" "${TD_STATE:-(not read: dry-run of all)}"
    printf '%s\n' "$TD_CFG" | grep -E '^(name|tags|description|net[0-9]+|(scsi|virtio|sata|ide)[0-9]+):' | sed 's/^/  /'
}
td_proposed() {
    echo "qm stop $VMID          (hard stop: the clone is disposable)"
    echo "qm destroy $VMID --purge 1 --destroy-unreferenced-disks 0   (only the disks its config references)"
}
cmd_teardown() {
    local storage="" left vols
    banner "teardown — VM $VMID"
    owned
    [ "$PLANNED" = "1" ] || storage=$(sed -n 2p "$(marker)")
    [[ "$storage" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]] || storage=""
    if [ "$PLANNED" != "1" ]; then
        TD_CFG=$(pve qm config "$VMID" --current 2>/dev/null)
        TD_STATE=$(pve qm status "$VMID" 2>/dev/null | awk '/^status:/ { print $2 }')
    fi
    gate "destroy VM $VMID and its disks" td_current td_proposed \
        "none — the clone and its disks are gone. The template is untouched; provision again to recreate"
    if [ "$TD_STATE" != "stopped" ]; then pve_run qm stop "$VMID" || die "qm stop failed — VM $VMID is left as it was"; fi
    pve_run qm destroy "$VMID" --purge 1 --destroy-unreferenced-disks 0 || die "qm destroy failed — read the line above; VM $VMID may be locked"
    if [ "$DRY" = "1" ]; then note "DRY-RUN: VM $VMID would be destroyed"; footer "teardown"; fi
    if pve qm status "$VMID" >/dev/null 2>&1; then
        fail "VM $VMID still exists after qm destroy"
    else
        pass "VM $VMID no longer exists on $PVE"
        # volumes no config referenced (a qm set that died mid-allocation) are
        # never deleted blind: they are named, for the operator to judge
        if [ -n "$storage" ]; then
            if ! vols=$(pve pvesm list "$storage" --vmid "$VMID" 2>&1); then
                fail "could not list storage $storage after the destroy (pvesm list failed: $(printf '%s' "$vols" | head -1)) — leftover volumes of VMID $VMID are unproven; check by hand"
            else
                left=$(printf '%s
' "$vols" | awk 'NR > 1 && NF { print $1 }')
                if [ -n "$left" ]; then warn "storage $storage still holds volume(s) of VMID $VMID: $(printf '%s' "$left" | tr '
' ' ' | sed 's/ $//') — not removed; check them, then pvesm free each"
                else pass "storage $storage holds no volume of VMID $VMID"; fi
            fi
        fi
        rm -f "$(marker)" "$(known_hosts)"
    fi
    footer "teardown"
}

# ── all ─────────────────────────────────────────────────────────────────────
TORN=0
phase() {  # phase <name> — run cmd_<name> in a subshell (its footer exits there); report its verdict
    local rc=0
    # the subshell starts its own tally: its footer judges this phase alone
    ( PASSED=0; WARNED=0; FAILED=0; SKIPPED=0; "cmd_$1" ) || rc=$?
    case "$rc" in
        0) pass "phase $1" ;;
        2) warn "phase $1 finished with warnings" ;;
        *) fail "phase $1 refused or failed (exit $rc)" ;;
    esac
    return "$rc"
}
all_teardown() {
    [ "$TORN" = "1" ] && return 0
    TORN=1
    trap '' INT TERM   # a second Ctrl-C must not leave the clone half destroyed
    # Only the clone THIS invocation made: the marker must hold this run's id.
    # A marker left by an earlier run is never acted on here — removing that
    # clone is an explicit, gated `teardown` of its own.
    if [ "$PLANNED" = "1" ] || [ "$(head -1 "$(marker)" 2>/dev/null)" = "$RUN_ID" ]; then
        phase teardown || true
    else
        skip "phase teardown: this run cloned nothing (no marker with run id $RUN_ID), so there is nothing of this run's to destroy"
    fi
}
cmd_all() {
    local rc
    if [ "${KIT_NON_INTERACTIVE:-0}" = "1" ] && [ "${KIT_YES:-0}" != "1" ]; then
        die "all is unattended here but has no --yes: teardown could not pass its gate, so the clone would be left behind — rerun with --yes"
    fi
    [ "$DRY" = "1" ] && PLANNED=1
    RUN_ID="$(date +%Y%m%d%H%M%S)-$RANDOM$RANDOM"   # provision stamps this one; teardown acts only on it
    trap 'all_teardown' EXIT
    trap 'echo; echo "interrupted — tearing VM $VMID down before exiting"; all_teardown; exit 1' INT TERM
    rc=0; phase provision || rc=$?
    if [ "$rc" != "1" ]; then rc=0; phase deploy || rc=$?; else skip "phase deploy: provision did not finish"; fi
    if [ "$rc" != "1" ]; then phase verify || true; else skip "phase verify: deploy did not finish"; fi
    all_teardown
    footer "all"
}

SUB="${1:-}"; [ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)        usage ;;
        --pve)            PVE="${2:-}"; shift ;;
        --node)           NODE="${2:-}"; shift ;;
        --template-vmid)  TEMPLATE="${2:-}"; shift ;;
        --vmid)           VMID="${2:-}"; shift ;;
        --storage)        STORAGE="${2:-}"; shift ;;
        --bridge)         BRIDGE="${2:-}"; shift ;;
        --guest-ip)       GUEST_IP="${2:-}"; shift ;;
        --guest-gw)       GUEST_GW="${2:-}"; shift ;;
        --guest-user)     GUEST_USER="${2:-}"; shift ;;
        --sshkeys)        SSHKEYS="${2:-}"; shift ;;
        --media-size)     MEDIA_SIZE="${2:-}"; shift ;;
        --bundle)         BUNDLE="${2:-}"; shift ;;
        --install-conf)   INSTALL_CONF="${2:-}"; shift ;;
        --media-mnt)      MEDIA_MNT="${2:-}"; shift ;;
        --mgmt-peer)      MGMT_PEER="${2:-}"; shift ;;
        --boot-wait)      BOOT_WAIT="${2:-}"; shift ;;
        -*)               common_flag "$1" || die "unknown option: $1 (try --help)" ;;
        *)                die "unexpected argument: $1 (try --help)" ;;
    esac
    shift
done
case "$SUB" in -h|--help|help|"") usage ;; esac
SELF="r770-proxmox-e2e"
# These regexes are the shell-safety guarantee for every value interpolated into
# a remote command: loosening one needs the remote quoting re-audited.
valid --pve "$PVE" '^[A-Za-z0-9][A-Za-z0-9._-]*$'
valid --node "$NODE" '^[A-Za-z0-9][A-Za-z0-9.-]*$'
valid --template-vmid "$TEMPLATE" '^[1-9][0-9]{2,8}$'
valid --vmid "$VMID" '^[1-9][0-9]{2,8}$'
valid --storage "$STORAGE" '^[A-Za-z][A-Za-z0-9_-]*$'
valid --bridge "$BRIDGE" '^[A-Za-z][A-Za-z0-9_.-]{0,14}$'
valid --guest-ip "$GUEST_IP" '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'; valid_ipv4 --guest-ip "$GUEST_IP"
valid --guest-gw "$GUEST_GW" '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; valid_ipv4 --guest-gw "$GUEST_GW"
valid --mgmt-peer "$MGMT_PEER" '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; valid_ipv4 --mgmt-peer "$MGMT_PEER"
valid --guest-user "$GUEST_USER" '^[a-z_][a-z0-9_-]{0,31}$'
valid --sshkeys "$SSHKEYS" '^/[A-Za-z0-9._/-]+$'
valid --media-size "$MEDIA_SIZE" '^[1-9][0-9]{0,4}$'
valid --media-mnt "$MEDIA_MNT" '^/[A-Za-z0-9._/-]+$'
valid --boot-wait "$BOOT_WAIT" '^[0-9]+$'
[ -n "$TEMPLATE" ] && [ "$TEMPLATE" = "$VMID" ] && die "--vmid and --template-vmid are the same — the template is never a clone target"
case "$SUB" in provision|deploy|verify|teardown|all) ;; *) die "unknown subcommand: $SUB (try --help)" ;; esac
need_arg --pve "$PVE"; need_arg --vmid "$VMID"
case "$SUB" in provision|all)
    need_arg --node "$NODE"; need_arg --template-vmid "$TEMPLATE"; need_arg --storage "$STORAGE"
    need_arg --bridge "$BRIDGE"; need_arg --sshkeys "$SSHKEYS"; need_arg --media-size "$MEDIA_SIZE" ;; esac
case "$SUB" in provision|deploy|verify|all) need_arg --guest-ip "$GUEST_IP"; need_arg --guest-user "$GUEST_USER" ;; esac
case "$SUB" in deploy|all) need_arg --bundle "$BUNDLE"; need_arg --install-conf "$INSTALL_CONF"; need_arg --media-mnt "$MEDIA_MNT" ;; esac
kit_init "r770-proxmox-e2e"
"cmd_$SUB"
