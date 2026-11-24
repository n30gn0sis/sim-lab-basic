#!/usr/bin/env bats
# harness/r770-proxmox-e2e.sh: clone, deploy, verify, destroy — with ssh
# stubbed for both the hypervisor and the guest. No test reaches a Proxmox host,
# a VM or a guest; every VM below is a few files under $BATS_TEST_TMPDIR.
load helpers/stubs
load helpers/fixtures

setup() {
    kit_test_env
    SCRIPT="$BATS_TEST_DIRNAME/../harness/r770-proxmox-e2e.sh"
    export S="$BATS_TEST_TMPDIR/pve"; mkdir -p "$S"
    printf 'name: ubuntu-2404-tpl\ntemplate: 1\nmemory: 32768\nnet0: virtio=BC:24:11:00:00:01,bridge=vmbr9\nide2: local-lvm:vm-9000-cloudinit,media=cdrom\nscsi0: local-lvm:base-9000-disk-0,size=200G\n' > "$S/template.conf"
    printf 'vmbr9:\nvmbr8:\nvmbr0:eno1\n' > "$S/bridges"     # bridge:physical ports
    # ssh: the first non-option argument is the target — "pve" is the hypervisor,
    # anything else the guest. Knobs: TAKEN (a VMID the cluster has), PVE_NODE,
    # STORAGE_RC, KEY_RC, DESTROY_KEEPS, GUEST_RC, CI_RC, PLAN_RC, RUN_RC,
    # VALIDATE_RC, FOREIGN_FS.
    stub ssh '
echo "ssh $*" >> "$STUB_LOG"
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
tgt=$1; shift; cmd="$*"
if [ "$tgt" = pve ]; then
    case "$cmd" in
        hostname)                     echo "${PVE_NODE:-pve1}" ;;
        "qm config 9000"*)            cat "$S/template.conf" ;;
        "qm config 9771"*)            [ -f "$S/vm.conf" ] || exit 2; cat "$S/vm.conf" ;;
        "pvesh get /cluster/nextid --vmid "*)
                                      id=${cmd##* }
                                      if [ -f "$S/vm.conf" ] || [ "$id" = "${TAKEN:-}" ]; then echo "400 Parameter verification failed. vmid: VM $id already exists" >&2; exit 2; fi
                                      echo "$id" ;;
        "pvesm status --storage "*)   exit "${STORAGE_RC:-0}" ;;
        "pvesm list "*)               [ "${PVESM_LIST_RC:-0}" = 0 ] || { echo "storage does not exist" >&2; exit "$PVESM_LIST_RC"; }
                                      echo "Volid Format Type Size VMID"
                                      [ "${ORPHAN:-0}" = 1 ] && echo "local-lvm:vm-9771-disk-7 raw images 1073741824 9771"
                                      exit 0 ;;
        "test -r "*)                  exit "${KEY_RC:-0}" ;;
        "bash -s -- isolation "*)     cat > /dev/null; echo "${ISO:-0 1}"; exit 0 ;;   # forwarding, disable_ipv6
        "bash -s -- "*)               cat > /dev/null; br=${cmd##* }
                                      line=$(grep "^$br:" "$S/bridges") || { echo NOBRIDGE; exit 0; }
                                      printf "%s" "${line#*:}" | tr " " "\n"; exit 0 ;;
        "qm clone "*)                 prev=""; desc=""; for a in "$@"; do [ "$prev" = --description ] && desc=$a; prev=$a; done
                                      grep -E "^(memory|net[0-9]+|ide2):" "$S/template.conf" > "$S/vm.conf"
                                      printf "name: r770-e2e-9771\ndescription: %s\n" "$desc" >> "$S/vm.conf"
                                      echo stopped > "$S/state" ;;
        "qm set "*)                   [ "${QMSET_RC:-0}" = 0 ] || exit "$QMSET_RC"
                                      prev=""; for a in "$@"; do
                                          case "$prev" in
                                              --tags) echo "tags: $a" >> "$S/vm.conf" ;;
                                              --net0) sed -i "s|^net0: .*|net0: $a|" "$S/vm.conf" ;;
                                          esac; prev=$a; done ;;
        "qm start "*)                 echo running > "$S/state" ;;
        "qm status 9771")             [ -f "$S/vm.conf" ] || exit 2; echo "status: $(cat "$S/state")" ;;
        "qm stop "*)                  echo stopped > "$S/state" ;;
        "qm destroy "*)               [ "${DESTROY_KEEPS:-0}" = 1 ] || rm -f "$S/vm.conf" ;;
    esac
    exit 0
fi
case "$cmd" in
    true)                                     exit "${GUEST_RC:-0}" ;;
    "cloud-init status --wait")               exit "${CI_RC:-0}" ;;
    "lsblk -dnpo NAME,SERIAL")                printf "/dev/sda \n/dev/sdb r770e2emedia\n" ;;
    "lsblk -bdno SIZE /dev/sdb")              echo 214748364800 ;;
    "sudo blkid -p -o value -s TYPE /dev/sdb")
                                              [ "${FOREIGN_FS:-0}" = 1 ] && { echo xfs; exit 0; }
                                              [ -f "$S/fs" ] || exit 2; echo ext4 ;;
    "sudo blkid -p -o value -s LABEL /dev/sdb") [ -f "$S/fs" ] && echo R770E2E ;;
    "sudo test -e "*)                         [ -f "$S/pushed" ]; exit $? ;;
    "sudo mkfs.ext4 "*)                       touch "$S/fs" ;;
    "sudo tar -C /mnt/r770-media -xf -")      cat > "$S/bundle.tar" ;;
    "sudo touch "*".r770-e2e-pushed")         touch "$S/pushed" ;;
    "sudo tee /etc/lab/install.conf >/dev/null") cat > "$S/install.conf" ;;
    "sudo cat /etc/lab/install.conf")         cat "$S/install.conf" ;;
    *"r770-install.sh plan "*)                exit "${PLAN_RC:-0}" ;;
    *"r770-install.sh run --yes "*)           exit "${RUN_RC:-0}" ;;
    *"r770-validate.sh --help")               echo "--mgmt-if IF"; [ "${OLD_VALIDATE:-0}" = 1 ] || echo "--mgmt-peer IP" ;;
    *"r770-validate.sh "*)                    exit "${VALIDATE_RC:-0}" ;;
    "sudo find /var/tmp/r770-e2e-verify -name *.md") [ "${NO_REPORT:-0}" = 1 ] || echo /var/tmp/r770-e2e-evidence/verify/validation-x.md ;;
    "sudo tar -C /var/tmp -cf - r770-e2e-"*)  echo "guest evidence" ;;
esac
exit 0'
    stub sleep 'exit 0'
    BUNDLE="$BATS_TEST_TMPDIR/media/bundle-fixture"; make_bundle "$BUNDLE"
    CONF="$BATS_TEST_TMPDIR/install.conf"
    printf '# from discover on a clone\nCAPTURE_IFS="lab_mirror0 ens20"\nLAB_BRIDGE=br-lab\nMGMT_IF=ens18\nMGMT_CIDR=192.0.2.0/24\nBUNDLE=\nMEDIA=\nDEVICE=\n' > "$CONF"
    MARKER="$KIT_EVIDENCE_DIR/r770-proxmox-e2e-pve-9771.run"
    PV=(--pve pve --node pve1 --template-vmid 9000 --vmid 9771 --storage local-lvm --bridge vmbr9
        --guest-ip 192.0.2.10/24 --guest-user lab --sshkeys /root/e2e.pub --media-size 200 --boot-wait 0
        --nameserver 192.0.2.1 --searchdomain lab)
    GU=(--pve pve --vmid 9771 --guest-ip 192.0.2.10/24 --guest-user lab)
    DP=("${GU[@]}" --bundle "$BUNDLE" --install-conf "$CONF" --media-mnt /mnt/r770-media)
    cd "$BATS_TEST_TMPDIR"
}
e2e() { kit_run "$SCRIPT" "$@"; }
# own_vm — a clone this machine provisioned: marker + matching tag and description
own_vm() {
    mkdir -p "$KIT_EVIDENCE_DIR"; echo "20261120150000-4242" > "$MARKER"
    printf 'name: r770-e2e-9771\nnet0: virtio=BC:24:11:00:00:09,bridge=vmbr9\ntags: r770-e2e\ndescription: r770-e2e-run=20261120150000-4242\n' > "$S/vm.conf"
    echo "${1:-running}" > "$S/state"
}
changed() { grep -E 'pve qm (clone|set|start|stop|destroy) ' "$STUB_LOG"; }

# ── refusals before anything is sent ────────────────────────────────────────

@test "a missing or malformed value is refused before any ssh" {
    run e2e teardown --vmid 9771
    [ "$status" -eq 1 ]; [[ "$output" == *"needs --pve"* ]]
    run e2e provision "${PV[@]}" --vmid '9771;reboot'
    [ "$status" -eq 1 ]; [[ "$output" == *"--vmid"* ]]
    run e2e provision "${PV[@]}" --guest-ip 192.0.2.300/24
    [ "$status" -eq 1 ]; [[ "$output" == *"--guest-ip"* ]]
    run e2e provision "${PV[@]}" --sshkeys 'key; rm -rf /'
    [ "$status" -eq 1 ]; [[ "$output" == *"--sshkeys"* ]]
    run e2e provision "${PV[@]}" --vmid 9000
    [ "$status" -eq 1 ]; [[ "$output" == *"template is never a clone target"* ]]
    for f in --node --template-vmid --storage --bridge --sshkeys --media-size --nameserver --searchdomain; do
        args=(); skipnext=0
        for a in "${PV[@]}"; do
            if [ "$skipnext" = 1 ]; then skipnext=0; continue; fi
            [ "$a" = "$f" ] && { skipnext=1; continue; }
            args+=("$a")
        done
        run e2e provision "${args[@]}"
        [ "$status" -eq 1 ]; [[ "$output" == *"needs $f"* ]]
    done
    run e2e deploy "${GU[@]}" --bundle "$BUNDLE" --media-mnt /mnt/r770-media
    [ "$status" -eq 1 ]; [[ "$output" == *"needs --install-conf"* ]]
    ! grep -q '^ssh' "$STUB_LOG"
}

@test "the clone's resolver is the operator's: off the guest's subnet without --guest-gw, or malformed, is refused before any ssh" {
    # an unset nameserver/searchdomain makes Proxmox copy the HOST's resolv.conf into the clone
    run e2e provision "${PV[@]}" --nameserver 198.51.100.1
    [ "$status" -eq 1 ]; [[ "$output" == *"--nameserver 198.51.100.1 is not on --guest-ip 192.0.2.10/24"* ]]
    # a /32 guest has no neighbour: only its own address or loopback is on its subnet
    run e2e provision "${PV[@]}" --guest-ip 192.0.2.10/32
    [ "$status" -eq 1 ]; [[ "$output" == *"--nameserver 192.0.2.1 is not on --guest-ip 192.0.2.10/32"* ]]
    # the unspecified address is no resolver, with or without a gateway
    for gw in "" "--guest-gw 192.0.2.254"; do
        # shellcheck disable=SC2086
        run e2e provision "${PV[@]}" --nameserver 0.0.0.0 $gw
        [ "$status" -eq 1 ]; [[ "$output" == *"--nameserver 0.0.0.0 is the unspecified address"* ]]
    done
    run e2e provision "${PV[@]}" --nameserver '192.0.2.1;reboot'
    [ "$status" -eq 1 ]; [[ "$output" == *"--nameserver"* ]]
    run e2e provision "${PV[@]}" --nameserver 192.0.2.256
    [ "$status" -eq 1 ]; [[ "$output" == *"--nameserver"* ]]
    for d in 'lab;reboot' '-lab' 'lab.' 'la b' 'a..b'; do
        run e2e provision "${PV[@]}" --searchdomain "$d"
        [ "$status" -eq 1 ]; [[ "$output" == *"--searchdomain"* ]]
    done
    ! grep -q '^ssh' "$STUB_LOG"
}

@test "provision passes --nameserver and --searchdomain to qm set: loopback, and an off-subnet one when --guest-gw routes to it" {
    run e2e provision "${PV[@]}" --nameserver 127.0.0.1 --searchdomain e2e.lab
    echo "$output"; [ "$status" -eq 0 ]
    grep -q -- '--ipconfig0 ip=192.0.2.10/24 --nameserver 127.0.0.1 --searchdomain e2e.lab --ciuser lab ' "$STUB_LOG"
    rm -f "$S/vm.conf"
    run e2e provision "${PV[@]}" --guest-gw 192.0.2.254 --nameserver 198.51.100.53
    echo "$output"; [ "$status" -eq 0 ]
    grep -q -- '--ipconfig0 ip=192.0.2.10/24,gw=192.0.2.254 --nameserver 198.51.100.53 --searchdomain lab ' "$STUB_LOG"
}

@test "the help prints the whole header" {
    run e2e --help
    [ "$status" -eq 0 ]; [[ "$output" == *"provision"* && "$output" == *"Evidence from the guest is pulled back"* ]]
}

# ── provision ───────────────────────────────────────────────────────────────

@test "provision refuses a VMID the cluster already has, and clones nothing" {
    TAKEN=9771 run e2e provision "${PV[@]}"
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"VMID 9771 is not free"*"already exists"* ]]
    run changed; [ "$status" -ne 0 ]
    [ ! -e "$MARKER" ]
}

@test "provision refuses the wrong node, a non-template, a template without cloud-init, an inactive storage, an unreadable key" {
    PVE_NODE=pve2 run e2e provision "${PV[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"is node 'pve2', not 'pve1'"* ]]
    sed -i '/^template:/d' "$S/template.conf"
    run e2e provision "${PV[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"is not a template"* ]]
    echo 'template: 1' >> "$S/template.conf"; sed -i '/cloudinit/d' "$S/template.conf"
    run e2e provision "${PV[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"no cloud-init drive"* ]]
    echo 'ide2: local-lvm:vm-9000-cloudinit,media=cdrom' >> "$S/template.conf"
    STORAGE_RC=1 run e2e provision "${PV[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"storage 'local-lvm' is not active"* ]]
    KEY_RC=1 run e2e provision "${PV[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"not a readable file on pve"* ]]
    echo 'scsi9: local-lvm:vm-9000-disk-9,size=1G' >> "$S/template.conf"
    run e2e provision "${PV[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"already uses scsi9"* ]]
    run changed; [ "$status" -ne 0 ]
}

@test "provision refuses a --bridge with a physical port, or one that does not exist" {
    run e2e provision "${PV[@]}" --bridge vmbr0
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  "*"vmbr0 has physical port(s) eno1"* ]]
    run e2e provision "${PV[@]}" --bridge vmbr7
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  "*"vmbr7 does not exist"* ]]
    run changed; [ "$status" -ne 0 ]
}

@test "provision re-reads the bridge's isolation and refuses forwarding, IPv6, or an unreadable value before cloning" {
    ISO="1 1" run e2e provision "${PV[@]}"
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  --bridge: bridge vmbr9 forwards IPv4 on pve (net.ipv4.conf.vmbr9.forwarding=1)"*"r770-proxmox-prep.sh bridge"* ]]
    ISO="0 0" run e2e provision "${PV[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  --bridge: bridge vmbr9 has IPv6 on (net.ipv6.conf.vmbr9.disable_ipv6=0)"* ]]
    ISO="? 1" run e2e provision "${PV[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  --bridge: cannot read net.ipv4.conf.vmbr9.forwarding on pve"* ]]
    run changed; [ "$status" -ne 0 ]
    [ ! -e "$MARKER" ]
    ISO="0 none" run e2e provision "${PV[@]}" --dry-run   # no IPv6 on the host at all is fine
    echo "$output"; [ "$status" -eq 0 ]; [[ "$output" == *"PASS  --bridge: bridge vmbr9 does not forward"* ]]
}

@test "the clone is gated: unattended without --yes, the gate is shown and nothing is cloned" {
    KIT_YES=0 run e2e provision "${PV[@]}"
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"GATE: full clone of template 9000 as VM 9771"* ]]
    [[ "$output" == *"-- current --"*"name: ubuntu-2404-tpl"*"-- proposed --"*"qm clone 9000 9771 --full 1"*"-- rollback --"*"teardown --pve pve --vmid 9771"* ]]
    [[ "$output" == *"-- proposed --"*"qm set 9771 "*"--ipconfig0 ip=192.0.2.10/24 --nameserver 192.0.2.1 --searchdomain lab "*"-- rollback --"* ]]
    run changed; [ "$status" -ne 0 ]
    [ ! -e "$MARKER" ]
}

@test "provision with --yes: marker first, full clone stamped with tag and run id, media disk by serial, bridges proven, then start" {
    run e2e provision "${PV[@]}"
    echo "$output"; [ "$status" -eq 0 ]
    id=$(cat "$MARKER")
    grep -q "pve qm clone 9000 9771 --full 1 --name r770-e2e-9771 --description r770-e2e-run=$id --storage local-lvm$" "$STUB_LOG"
    grep -q 'pve qm set 9771 --tags r770-e2e --net0 virtio,bridge=vmbr9 --ipconfig0 ip=192.0.2.10/24 --nameserver 192.0.2.1 --searchdomain lab --ciuser lab --sshkeys /root/e2e.pub --scsi9 local-lvm:200,serial=r770e2emedia$' "$STUB_LOG"
    seq=$(grep -oE 'qm (clone|set|start)|bash -s -- (isolation )?vmbr9' "$STUB_LOG" | tr '\n' ' ')
    [ "$seq" = "bash -s -- vmbr9 bash -s -- isolation vmbr9 qm clone qm set bash -s -- vmbr9 bash -s -- isolation vmbr9 qm start " ]
    [[ "$output" == *"PASS  --bridge: bridge vmbr9 does not forward"* ]]
    [[ "$output" == *"PASS  guest answers on lab@192.0.2.10"* && "$output" == *"PASS  cloud-init finished"* ]]
}

@test "provision does not start a clone whose template NIC sits on a bridge with a physical port" {
    echo 'net1: virtio=BC:24:11:00:00:02,bridge=vmbr0' >> "$S/template.conf"
    run e2e provision "${PV[@]}"
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  VM 9771 NIC: bridge vmbr0 has physical port(s) eno1"* && "$output" == *"NOT started"* ]]
    ! grep -q 'pve qm start' "$STUB_LOG"
    [ -s "$MARKER" ]   # the clone exists and is still this run's to tear down
}

@test "provision with --guest-gw adds the gateway; a guest that never answers is a FAIL" {
    GUEST_RC=255 run e2e provision "${PV[@]}" --guest-gw 192.0.2.1
    echo "$output"; [ "$status" -eq 1 ]
    grep -q -- '--ipconfig0 ip=192.0.2.10/24,gw=192.0.2.1 ' "$STUB_LOG"
    [[ "$output" == *"FAIL  guest lab@192.0.2.10 did not answer ssh within 0s"* ]]
}

@test "cloud-init: 2 is a WARN, anything else but 0 a FAIL" {
    CI_RC=2 run e2e provision "${PV[@]}"
    [ "$status" -eq 2 ]; [[ "$output" == *"WARN  cloud-init"* ]]
    rm -f "$S/vm.conf"
    CI_RC=1 run e2e provision "${PV[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  cloud-init did not finish cleanly"* ]]
}

@test "provision --dry-run reads, but clones, sets and starts nothing, and writes no marker" {
    run e2e provision "${PV[@]}" --dry-run
    echo "$output"; [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN: ssh"*"qm clone 9000 9771 --full 1"* && "$output" == *"DRY-RUN: ssh"*"qm start 9771"* ]]
    run changed; [ "$status" -ne 0 ]
    [ ! -e "$MARKER" ]
}

# ── ownership and teardown ──────────────────────────────────────────────────

@test "teardown refuses a VM this machine did not provision: no marker, another run id, a run id only as a substring, a template" {
    own_vm; rm -f "$MARKER"
    run e2e teardown --pve pve --vmid 9771
    [ "$status" -eq 1 ]; [[ "$output" == *"no run marker"* ]]
    own_vm; echo "20990101000000-1" > "$MARKER"
    run e2e teardown --pve pve --vmid 9771
    [ "$status" -eq 1 ]; [[ "$output" == *"is not exactly r770-e2e-run=20990101000000-1"* ]]
    own_vm; sed -i 's/^description: .*/description: r770-e2e-run=20261120150000-42420/' "$S/vm.conf"
    run e2e teardown --pve pve --vmid 9771
    [ "$status" -eq 1 ]; [[ "$output" == *"is not exactly"* ]]
    own_vm; sed -i 's/^description: .*/description: x r770-e2e-run=20261120150000-4242/' "$S/vm.conf"
    run e2e teardown --pve pve --vmid 9771
    [ "$status" -eq 1 ]; [[ "$output" == *"is not exactly"* ]]
    own_vm; echo 'template: 1' >> "$S/vm.conf"
    run e2e teardown --pve pve --vmid 9771
    [ "$status" -eq 1 ]; [[ "$output" == *"is a template"* ]]
    own_vm; echo 'not-a-run-id' > "$MARKER"
    run e2e teardown --pve pve --vmid 9771
    [ "$status" -eq 1 ]; [[ "$output" == *"does not hold a run id"* ]]
    run changed; [ "$status" -ne 0 ]
}

@test "a clone whose qm set failed is still removable: no tag is a WARN, the run id in its description decides" {
    QMSET_RC=5 run e2e provision "${PV[@]}"
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"qm set failed"*"teardown --pve pve --vmid 9771"* ]]
    ! grep -q '^tags:' "$S/vm.conf"
    run e2e teardown --pve pve --vmid 9771
    echo "$output"; [ "$status" -eq 2 ]
    [[ "$output" == *"WARN  VM 9771 is this run's clone"*"lacks the tag r770-e2e"* && "$output" == *"PASS  VM 9771 no longer exists"* ]]
    [ ! -e "$S/vm.conf" ]
}

@test "the description's '=' may come back percent-encoded" {
    own_vm; sed -i 's/^description: r770-e2e-run=/description: r770-e2e-run%3D/' "$S/vm.conf"
    run e2e teardown --pve pve --vmid 9771
    [ "$status" -eq 0 ]; [[ "$output" == *"PASS  VM 9771 no longer exists"* ]]
}

@test "pvesm list failing is never read as 'no volume': provision refuses, teardown FAILs the leftover check" {
    PVESM_LIST_RC=2 run e2e provision "${PV[@]}"
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"cannot list storage local-lvm's volumes"*"storage does not exist"* ]]
    [[ "$output" != *"holds no volume"* ]]
    run changed; [ "$status" -ne 0 ]
    own_vm; printf 'local-lvm
' >> "$MARKER"
    PVESM_LIST_RC=2 run e2e teardown --pve pve --vmid 9771
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  could not list storage local-lvm after the destroy"* && "$output" != *"holds no volume"* ]]
}

@test "provision refuses when the storage already holds a volume of that VMID; teardown names such leftovers and deletes none" {
    ORPHAN=1 run e2e provision "${PV[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"already holds volume(s) of VMID 9771 (local-lvm:vm-9771-disk-7"* ]]
    run changed; [ "$status" -ne 0 ]
    own_vm; printf 'local-lvm
' >> "$MARKER"
    ORPHAN=1 run e2e teardown --pve pve --vmid 9771
    echo "$output"; [ "$status" -eq 2 ]
    [[ "$output" == *"WARN  storage local-lvm still holds volume(s) of VMID 9771: local-lvm:vm-9771-disk-7 — not removed"* ]]
    ! grep -q 'pvesm free' "$STUB_LOG"
    run grep -c 'destroy-unreferenced-disks 1' "$STUB_LOG"; [ "$output" = 0 ]
}

@test "teardown is gated: unattended without --yes, nothing is stopped or destroyed" {
    own_vm
    KIT_YES=0 run e2e teardown --pve pve --vmid 9771
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"GATE: destroy VM 9771"*"-- current --"*"is running"*"tags: r770-e2e"*"-- proposed --"*"qm destroy 9771 --purge 1"*"-- rollback --"* ]]
    run changed; [ "$status" -ne 0 ]
}

@test "teardown --yes stops, destroys with --purge, proves the VM is gone, and clears the marker" {
    own_vm
    run e2e teardown --pve pve --vmid 9771
    echo "$output"; [ "$status" -eq 0 ]
    grep -q 'pve qm stop 9771$' "$STUB_LOG"
    grep -q 'pve qm destroy 9771 --purge 1 --destroy-unreferenced-disks 0$' "$STUB_LOG"
    [[ "$output" == *"PASS  VM 9771 no longer exists"* ]]
    [ ! -e "$MARKER" ]
}

@test "teardown FAILs when the VM is still there after qm destroy, and keeps the marker" {
    own_vm stopped
    DESTROY_KEEPS=1 run e2e teardown --pve pve --vmid 9771
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  VM 9771 still exists"* ]]
    ! grep -q 'pve qm stop' "$STUB_LOG"   # already stopped
    [ -s "$MARKER" ]
}

# ── deploy ──────────────────────────────────────────────────────────────────

@test "deploy refuses an install.conf that sets BUNDLE, MEDIA or DEVICE, and a VM that is not this run's" {
    own_vm
    sed -i 's|^DEVICE=$|DEVICE=/dev/sdz|' "$CONF"
    run e2e deploy "${DP[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"--install-conf sets DEVICE"* ]]
    sed -i 's|^DEVICE=.*|DEVICE=|' "$CONF"; rm -f "$MARKER"
    run e2e deploy "${DP[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"no run marker"* ]]
    ! grep -q 'lab@' "$STUB_LOG"
}

@test "deploy: the media disk found by serial, formatted, the bundle streamed on, remounted read-only, install.conf filled, plan then run" {
    own_vm
    run e2e deploy "${DP[@]}"
    echo "$output"; [ "$status" -eq 0 ]
    grep -q 'lab@192.0.2.10 sudo mkfs.ext4 -q -L R770E2E /dev/sdb$' "$STUB_LOG"
    tar -tf "$S/bundle.tar" | grep -q '^bundle-fixture/r770-bundle.sh$'
    grep -q 'lab@192.0.2.10 sudo mount -o ro /dev/sdb /mnt/r770-media$' "$STUB_LOG"
    grep -qx 'CAPTURE_IFS="lab_mirror0 ens20"' "$S/install.conf"
    grep -qx 'BUNDLE=/mnt/r770-media/bundle-fixture' "$S/install.conf"
    grep -qx 'MEDIA=/mnt/r770-media' "$S/install.conf"
    grep -qx 'DEVICE=/dev/sdb' "$S/install.conf"
    [ "$(grep -c '^DEVICE=' "$S/install.conf")" -eq 1 ]
    seq=$(grep -oE 'r770-install.sh (plan|run --yes)' "$STUB_LOG" | tr '\n' ' ')
    [ "$seq" = "r770-install.sh plan r770-install.sh run --yes " ]
    grep -q 'sudo env KIT_EVIDENCE_DIR=/var/tmp/r770-e2e-evidence /mnt/r770-media/bundle-fixture/kit/scripts/r770-install.sh run --yes --conf /etc/lab/install.conf' "$STUB_LOG"
    [[ "$output" == *"PASS  installer run: INSTALLED"* ]]
    ls "$KIT_EVIDENCE_DIR"/r770-proxmox-e2e-9771-deploy-*.tar
}

@test "deploy is re-entrant: a pushed bundle is not pushed or formatted again" {
    own_vm; touch "$S/fs" "$S/pushed"
    run e2e deploy "${DP[@]}"
    [ "$status" -eq 0 ]; [[ "$output" == *"already on the media"* ]]
    ! grep -qE 'mkfs|tar -C /mnt/r770-media -xf' "$STUB_LOG"
}

@test "deploy never formats a disk holding someone else's filesystem" {
    own_vm
    FOREIGN_FS=1 run e2e deploy "${DP[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"refusing to format it"* ]]
    ! grep -q 'mkfs' "$STUB_LOG"
}

@test "deploy: plan's first-install warnings are a WARN, a refusing plan stops before run, a failing run is a FAIL; evidence is pulled every time" {
    own_vm
    PLAN_RC=2 run e2e deploy "${DP[@]}"
    [ "$status" -eq 2 ]; [[ "$output" == *"WARN  installer plan: READY WITH WARNINGS"* ]]
    : > "$STUB_LOG"
    PLAN_RC=1 run e2e deploy "${DP[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  installer plan refused"* ]]
    ! grep -q 'r770-install.sh run' "$STUB_LOG"
    grep -q 'sudo tar -C /var/tmp -cf - r770-e2e-evidence' "$STUB_LOG"
    RUN_RC=1 run e2e deploy "${DP[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  installer run stopped"* ]]
}

# ── verify ──────────────────────────────────────────────────────────────────

@test "verify runs the installed bundle's r770-validate.sh with the interfaces read from the guest's install.conf" {
    own_vm
    printf 'CAPTURE_IFS="lab_mirror0 ens20"\nLAB_BRIDGE=br-lab\nMGMT_IF=ens18\nMGMT_CIDR=192.0.2.0/24\nBUNDLE=/mnt/r770-media/bundle-fixture\n' > "$S/install.conf"
    run e2e verify "${GU[@]}"
    echo "$output"; [ "$status" -eq 0 ]
    grep -qF "/srv/bundles/bundle-fixture/kit/scripts/r770-validate.sh --area host --area network --area portal --area airgap --mgmt-if ens18 --mgmt-cidr 192.0.2.0/24 --capture-ifs 'lab_mirror0 ens20' --lab-bridge br-lab --out /var/tmp/r770-e2e-verify --non-interactive" "$STUB_LOG"
    ! grep -q -- '--mgmt-peer' "$STUB_LOG"
    run e2e verify "${GU[@]}" --mgmt-peer 192.0.2.1
    grep -qF -- "--lab-bridge br-lab --mgmt-peer 192.0.2.1 --out" "$STUB_LOG"
    VALIDATE_RC=2 run e2e verify "${GU[@]}"
    [ "$status" -eq 2 ]
    VALIDATE_RC=1 run e2e verify "${GU[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  r770-validate.sh: at least one FAIL"* ]]
    VALIDATE_RC=1 NO_REPORT=1 run e2e verify "${GU[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  r770-validate.sh did not run"* ]]
}

@test "verify passes --mgmt-peer only when the bundle's validate lists it; an older one is a SKIP, never a pass" {
    own_vm
    printf 'CAPTURE_IFS="lab_mirror0 ens20"\nLAB_BRIDGE=br-lab\nMGMT_IF=ens18\nMGMT_CIDR=192.0.2.0/24\nBUNDLE=/mnt/r770-media/bundle-fixture\n' > "$S/install.conf"
    OLD_VALIDATE=1 run e2e verify "${GU[@]}" --mgmt-peer 192.0.2.1
    echo "$output"; [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  mgmt reachability: this bundle's r770-validate.sh predates --mgmt-peer"* ]]
    ! grep -q -- '--mgmt-peer 192.0.2.1' "$STUB_LOG"
}

@test "verify refuses a guest install.conf value that is not shell-safe, and one with a key missing" {
    own_vm
    printf 'CAPTURE_IFS="lab_mirror0;reboot"\nLAB_BRIDGE=br-lab\nMGMT_IF=ens18\nMGMT_CIDR=192.0.2.0/24\nBUNDLE=/mnt/r770-media/b\n' > "$S/install.conf"
    run e2e verify "${GU[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"CAPTURE_IFS"* ]]
    printf 'LAB_BRIDGE=br-lab\nMGMT_IF=ens18\nMGMT_CIDR=192.0.2.0/24\nBUNDLE=/mnt/r770-media/b\n' > "$S/install.conf"
    run e2e verify "${GU[@]}"
    [ "$status" -eq 1 ]; [[ "$output" == *"lacks one of"* ]]
    ! grep -q 'r770-validate.sh' "$STUB_LOG"
}

# ── all ─────────────────────────────────────────────────────────────────────

@test "all, clean: provision, deploy, verify, then teardown; the VM is gone and every phase PASSes" {
    run e2e all "${PV[@]}" --bundle "$BUNDLE" --install-conf "$CONF" --media-mnt /mnt/r770-media
    echo "$output"; [ "$status" -eq 0 ]
    for p in provision deploy verify teardown; do [[ "$output" == *"PASS  phase $p"* ]]; done
    seq=$(grep -oE 'qm (clone|start|destroy)|r770-install.sh run|r770-validate.sh' "$STUB_LOG" | tr '\n' ' ')
    [ "$seq" = "qm clone qm start r770-install.sh run r770-validate.sh qm destroy " ]
    [ ! -e "$S/vm.conf" ]; [ ! -e "$MARKER" ]
}

@test "all tears the clone down even when deploy fails, and verify is skipped" {
    RUN_RC=1 run e2e all "${PV[@]}" --bundle "$BUNDLE" --install-conf "$CONF" --media-mnt /mnt/r770-media
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  phase deploy"* && "$output" == *"SKIP  phase verify"* && "$output" == *"PASS  phase teardown"* ]]
    grep -q 'pve qm destroy 9771 --purge 1' "$STUB_LOG"
    [ ! -e "$S/vm.conf" ]
}

@test "all tears the clone down when provision fails after the clone (a NIC on a physical bridge)" {
    echo 'net1: virtio=BC:24:11:00:00:02,bridge=vmbr0' >> "$S/template.conf"
    run e2e all "${PV[@]}" --bundle "$BUNDLE" --install-conf "$CONF" --media-mnt /mnt/r770-media
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  phase provision"* && "$output" == *"SKIP  phase deploy"* && "$output" == *"PASS  phase teardown"* ]]
    [ ! -e "$S/vm.conf" ]
}

@test "all destroys nothing when provision refused before cloning: a VMID that already existed is left alone" {
    TAKEN=9771 run e2e all "${PV[@]}" --bundle "$BUNDLE" --install-conf "$CONF" --media-mnt /mnt/r770-media
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"SKIP  phase teardown: this run cloned nothing"* ]]
    run changed; [ "$status" -ne 0 ]
}

@test "all never tears down an earlier run's clone: a stale marker and a VMID that is not free mean nothing is stopped or destroyed" {
    own_vm      # an earlier run's clone, still up, with its marker on this machine
    run e2e all "${PV[@]}" --bundle "$BUNDLE" --install-conf "$CONF" --media-mnt /mnt/r770-media
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  phase provision"* && "$output" == *"SKIP  phase teardown: this run cloned nothing"* ]]
    run changed; [ "$status" -ne 0 ]
    [ -f "$S/vm.conf" ]; [ "$(head -1 "$MARKER")" = "20261120150000-4242" ]
}

@test "all refuses to start unattended without --yes: teardown could never pass its gate" {
    KIT_YES=0 run e2e all "${PV[@]}" --bundle "$BUNDLE" --install-conf "$CONF" --media-mnt /mnt/r770-media
    [ "$status" -eq 1 ]; [[ "$output" == *"teardown could not pass its gate"* ]]
    ! grep -q '^ssh' "$STUB_LOG"
}

@test "all --dry-run shows the clone and the destroy, changes nothing, reaches no guest, writes no marker" {
    run e2e all "${PV[@]}" --bundle "$BUNDLE" --install-conf "$CONF" --media-mnt /mnt/r770-media --dry-run
    echo "$output"; [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN: ssh"*"qm clone 9000 9771"* && "$output" == *"DRY-RUN: ssh"*"qm destroy 9771 --purge 1"* ]]
    [[ "$output" == *"r770-install.sh run --yes"* && "$output" == *"r770-validate.sh"* ]]
    run changed; [ "$status" -ne 0 ]
    ! grep -q 'lab@' "$STUB_LOG"
    [ ! -e "$MARKER" ]
}

@test "the only VM this script can destroy is its own --vmid, and it never touches the template or a container" {
    run grep -nE '(pve_run|pve|ssh) .*qm destroy' "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | grep -vc 'pve_run qm destroy "\$VMID" ')" -eq 0 ]
    run grep -nE 'pct |qm (set|destroy|rollback|delsnapshot) "?\$TEMPLATE|lvremove|zfs destroy' "$SCRIPT"
    [ "$status" -ne 0 ]
}
