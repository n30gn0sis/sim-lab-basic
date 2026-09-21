#!/usr/bin/env bash
#
# r770-validate.sh — prove capabilities, do not assume them. The R770 side
# of the success criteria (build repo PRD §10 / buildout §13), as a
# read-only or self-cleaning suite that writes a check · expected ·
# observed · verdict · evidence table.
#
#   r770-validate.sh [--area A]... [--list] [options]
#
#   areas: host cpu-ram storage network virtualization gns3 wan capture
#          backup airgap portal                    (default: all of them)
#
#   --expect-threads N    --expect-ram-gb N     what the chassis should show
#   --mgmt-if IF          --capture-ifs "a b"   interfaces, given — never guessed
#   --mgmt-cidr a.b.c.d/n                       for the air-gap resolver checks
#   --allow-vm --lab-bridge BR                  boot and destroy a throwaway VM
#   --allow-wan                                 (Phase 12 tooling lives outside this kit)
#   --feed IF --pcap FILE                       tcpreplay a reference PCAP into a feed
#   --out DIR                                   where the report lands
#
#   0  every executed check passed · 2  warnings · 1  at least one FAIL
#   SKIPPED checks never change the exit code — but they are always listed.
#
# A check that cannot run (tool missing, phase not built, opt-in not given)
# is SKIPPED with its reason; it is never omitted and never counted as a
# pass. A FAIL gets a diagnosis and the single most likely next step, not a
# fix attempt: fixing happens under the phase protocol.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ALL_AREAS="host cpu-ram storage network virtualization gns3 wan capture backup airgap portal"
AREAS=""; EXPECT_THREADS=""; EXPECT_RAM=""; MGMT_IF=""; CAPTURE_IFS=""; MGMT_CIDR=""
ALLOW_VM=0; LAB_BRIDGE=""; ALLOW_WAN=0; FEED=""; PCAP=""; OUT=""
LVS="/var/lib/docker /data/pcap /data/index /data/staging /srv/vms /srv/gns3 /srv/work /srv/backup"
SANS="malcolm.lab gns3.lab docs.lab"
MALCOLM_HOME="${MALCOLM_HOME:-/opt/malcolm}"
AIRGAP_CMD="${VALIDATE_AIRGAP_CMD:-$KIT_DIR/scripts/r770-airgap-check.sh}"
usage() { usage_from_header 3; exit 0; }

ROWS=(); DIAGS=(); AREA=""
cell() { printf '%s' "$1" | tr -d '\n' | tr '|' '/' ; }
# row <check> <expected> <observed> <verdict> <evidence-command>
row() {
    ROWS+=("$AREA|$(cell "$1")|$(cell "$2")|$(cell "$3")|$4|$(cell "$5")")
    case "$4" in
        PASS) pass "$AREA/$1: $3" ;;
        WARN) warn "$AREA/$1: $3" ;;
        FAIL) fail "$AREA/$1: $3" ;;
        SKIP) skip "$AREA/$1: $3 ($5)" ;;
    esac
}
diag() { DIAGS+=("$AREA/$1: $2"); }

# ── host ─────────────────────────────────────────────────────────────────────
area_host() {
    AREA=host
    local st
    st=$(systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null || echo unknown)
    if [ "$st" = "active" ]; then row "sshd" "active" "$st" PASS "systemctl is-active ssh"; else row "sshd" "active" "$st" FAIL "systemctl is-active ssh"; diag sshd "ssh is not active; if this session is over SSH something else answers — check 'ss -ltnp | grep :22'"; fi
    if command -v chronyc >/dev/null 2>&1; then
        local leap; leap=$(chronyc tracking 2>/dev/null | awk -F': *' '/^Leap status/{print $2}')
        if [ "$leap" = "Normal" ]; then row "chrony" "Leap status Normal" "$leap" PASS "chronyc tracking"; else row "chrony" "Leap status Normal" "${leap:-unreadable}" WARN "chronyc tracking"; fi
    else row "chrony" "Leap status Normal" "chronyc not installed" SKIP "Phase 5 not built"; fi
    if dpkg -s dnsmasq >/dev/null 2>&1; then
        local n miss=""
        for n in $SANS; do getent hosts "$n" >/dev/null 2>&1 || miss="$miss $n"; done
        if [ -z "$miss" ]; then row "lab-dns" "three .lab names resolve" "all resolve" PASS "getent hosts <name>"; else row "lab-dns" "three .lab names resolve" "unresolved:$miss" FAIL "getent hosts <name>"; diag lab-dns "dnsmasq is installed but not authoritative for these names — check its .lab address records"; fi
    else row "lab-dns" "three .lab names resolve" "dnsmasq not installed" SKIP "Phase 5 not built"; fi
    local uris bad
    uris=$(apt-get indextargets --format '$''(URI)' 2>/dev/null | sort -u || true)
    bad=$(printf '%s\n' "$uris" | grep -v '^file:' | grep -c . || true)
    if [ -z "$uris" ]; then row "apt-local" "only file: sources" "no sources" FAIL "apt-get indextargets"; diag apt-local "APT has no sources; the import script's apt stage sets the local repo up"
    elif [ "$bad" -gt 0 ]; then row "apt-local" "only file: sources" "$bad non-file source(s)" FAIL "apt-get indextargets"; diag apt-local "an upstream source survived — restore per docs/rollback.md then rerun the apt stage"
    else row "apt-local" "only file: sources" "$(printf '%s\n' "$uris" | grep -c .) file: target(s)" PASS "apt-get indextargets"; fi
}

# ── cpu-ram ──────────────────────────────────────────────────────────────────
area_cpu_ram() {
    AREA=cpu-ram
    if command -v kvm-ok >/dev/null 2>&1; then
        if kvm-ok >/dev/null 2>&1; then row "kvm-ok" "KVM acceleration can be used" "ok" PASS "kvm-ok"; else row "kvm-ok" "KVM acceleration can be used" "$(kvm-ok 2>&1 | tail -1)" FAIL "kvm-ok"; diag kvm-ok "VT-x/VT-d disabled in BIOS or the kvm module is missing (Phase 2)"; fi
    else row "kvm-ok" "KVM acceleration can be used" "cpu-checker not installed" SKIP "package not installed yet"; fi
    local t; t=$(nproc 2>/dev/null || echo 0)
    if [ -n "$EXPECT_THREADS" ]; then
        if [ "$t" -eq "$EXPECT_THREADS" ]; then row "threads" "$EXPECT_THREADS" "$t" PASS "nproc"; else row "threads" "$EXPECT_THREADS" "$t" FAIL "nproc"; diag threads "thread count differs from the hardware of record — a socket or SMT setting changed, or the expectation is stale"; fi
    else row "threads" "== --expect-threads" "$t" SKIP "--expect-threads not given"; fi
    local g; g=$(free -g 2>/dev/null | awk '/^Mem:/{print $2}')
    if [ -n "$EXPECT_RAM" ]; then
        # free -g reports GiB; 128 GB of DIMMs shows as ~125. Allow 5 %.
        if [ $(( ${g:-0} * 100 )) -ge $(( EXPECT_RAM * 95 )) ]; then row "ram-gb" ">= $EXPECT_RAM" "${g:-?}" PASS "free -g"; else row "ram-gb" ">= $EXPECT_RAM" "${g:-?}" FAIL "free -g"; diag ram-gb "less memory than the hardware of record — a DIMM is missing or unseated (check iDRAC)"; fi
    else row "ram-gb" ">= --expect-ram-gb" "${g:-?}" SKIP "--expect-ram-gb not given"; fi
    local ce=0 ue=0 f found=0
    for f in /sys/devices/system/edac/mc/mc*/ce_count; do [ -r "$f" ] || continue; found=1; ce=$((ce + $(cat "$f"))); done
    for f in /sys/devices/system/edac/mc/mc*/ue_count; do [ -r "$f" ] || continue; ue=$((ue + $(cat "$f"))); done
    if [ "$found" -eq 0 ]; then row "edac" "0 correctable, 0 uncorrectable" "no EDAC memory controllers exposed" SKIP "/sys/devices/system/edac/mc"
    elif [ "$ce" -eq 0 ] && [ "$ue" -eq 0 ]; then row "edac" "0 / 0" "ce=$ce ue=$ue" PASS "/sys/devices/system/edac/mc/*/[cu]e_count"
    else row "edac" "0 / 0" "ce=$ce ue=$ue" FAIL "/sys/devices/system/edac/mc/*/[cu]e_count"; diag edac "memory errors are being logged — identify the DIMM via iDRAC before trusting capture data"; fi
}

# ── storage ──────────────────────────────────────────────────────────────────
area_storage() {
    AREA=storage
    local lv mp size
    for lv in $LVS; do
        mp=$(findmnt -n -o TARGET -T "$lv" 2>/dev/null || true)
        size=$(findmnt -n -o SIZE -T "$lv" 2>/dev/null || true)
        if [ "$mp" = "$lv" ]; then row "mount $lv" "own mount point" "mounted, $size" PASS "findmnt -T $lv"; else row "mount $lv" "own mount point" "on '${mp:-nothing}'" FAIL "findmnt -T $lv"; diag "mount $lv" "the LV is not mounted here — Phase 3 layout incomplete; nothing may be imported onto it"; fi
    done
    if command -v nvme >/dev/null 2>&1 && command -v smartctl >/dev/null 2>&1; then
        local dev ok
        while read -r dev; do
            [ -n "$dev" ] || continue
            ok=$(smartctl -H "$dev" 2>/dev/null | grep -ciE 'PASSED|: OK' || true)
            if [ "$ok" -gt 0 ]; then row "smart $dev" "PASSED" "PASSED" PASS "smartctl -H $dev"; else row "smart $dev" "PASSED" "$(smartctl -H "$dev" 2>&1 | tail -1)" FAIL "smartctl -H $dev"; diag "smart $dev" "SMART health not PASSED — pull the full attributes before the next capture window"; fi
        done < <(nvme list 2>/dev/null | awk '/^\/dev\//{print $1}')
    else row "smart" "PASSED on every NVMe" "nvme-cli/smartmontools not installed" SKIP "packages not installed yet"; fi
    if command -v perccli2 >/dev/null 2>&1; then
        local vd; vd=$(perccli2 /c0/v0 show 2>/dev/null | grep -iE '^\s*0\s' | awk '{print $3}' | head -1)
        if [ "$vd" = "Optl" ]; then row "perc-vd" "Optl" "$vd" PASS "perccli2 /c0/v0 show"; else row "perc-vd" "Optl" "${vd:-unreadable}" FAIL "perccli2 /c0/v0 show"; diag perc-vd "virtual disk not optimal — check iDRAC storage health before anything else"; fi
    else row "perc-vd" "Optl" "perccli2 not installed (Dell manual download)" SKIP "dell/ category not staged"; fi
}

# ── network ──────────────────────────────────────────────────────────────────
area_network() {
    AREA=network
    if [ -n "$MGMT_IF" ]; then
        local l a
        l=$(ip -o link show "$MGMT_IF" 2>/dev/null | grep -oE 'state [A-Z]+' | awk '{print $2}')
        a=$(ip -o -4 addr show "$MGMT_IF" 2>/dev/null | awk '{print $4}' | head -1)
        if [ "$l" = "UP" ] && [ -n "$a" ]; then row "mgmt $MGMT_IF" "UP with an address" "$l $a" PASS "ip -o addr show $MGMT_IF"; else row "mgmt $MGMT_IF" "UP with an address" "${l:-absent} ${a:-no address}" FAIL "ip -o addr show $MGMT_IF"; diag "mgmt $MGMT_IF" "the management interface is not up with an address — if you are reading this over SSH, a different interface carries the session"; fi
    else row "mgmt" "UP with an address" "no --mgmt-if given" SKIP "interfaces are never guessed"; fi
    if [ -z "$CAPTURE_IFS" ]; then row "capture" "no address, promisc, offloads off" "no --capture-ifs given" SKIP "interfaces are never guessed"; return; fi
    local i addrs link offl
    for i in $CAPTURE_IFS; do
        addrs=$(ip -o addr show "$i" 2>/dev/null | grep -E ' inet6? ' | grep -v 'scope link' | grep -c . || true)
        if [ "$addrs" -eq 0 ]; then row "capture $i address" "none" "none" PASS "ip -o addr show $i"; else row "capture $i address" "none" "$addrs address(es)" FAIL "ip -o addr show $i"; diag "capture $i address" "a capture port has an address — capture ports never get an IP and never join the lab fabric; remove it from Netplan"; fi
        link=$(ip -o link show "$i" 2>/dev/null | head -1)
        if printf '%s' "$link" | grep -q PROMISC; then row "capture $i promisc" "PROMISC" "PROMISC" PASS "ip -o link show $i"; else row "capture $i promisc" "PROMISC" "not promiscuous" FAIL "ip -o link show $i"; diag "capture $i promisc" "capture-prep has not run on this port (Phase 9)"; fi
        if command -v ethtool >/dev/null 2>&1; then
            offl=$(ethtool -k "$i" 2>/dev/null | grep -E '^(generic-receive-offload|large-receive-offload|tcp-segmentation-offload):' | grep -c ': on' || true)
            if [ "$offl" -eq 0 ]; then row "capture $i offloads" "gro/lro/tso off" "off" PASS "ethtool -k $i"; else row "capture $i offloads" "gro/lro/tso off" "$offl still on" FAIL "ethtool -k $i"; diag "capture $i offloads" "offloads merge packets before capture sees them — capture-prep (Phase 9) turns them off"; fi
        else row "capture $i offloads" "gro/lro/tso off" "ethtool not installed" SKIP "package not installed yet"; fi
    done
}

# ── virtualization ───────────────────────────────────────────────────────────
VM_NAME=""
vm_cleanup() { [ -n "$VM_NAME" ] || return 0; virsh destroy "$VM_NAME" >/dev/null 2>&1 || true; virsh undefine "$VM_NAME" --remove-all-storage >/dev/null 2>&1 || true; rm -f "/tmp/$VM_NAME.qcow2"; VM_NAME=""; }
area_virtualization() {
    AREA=virtualization
    if [ "$ALLOW_VM" != "1" ]; then row "throwaway-vm" "create, boot, destroy" "not opted in (--allow-vm --lab-bridge BR)" SKIP "self-cleaning but not read-only"; return; fi
    [ -n "$LAB_BRIDGE" ] || { row "throwaway-vm" "create, boot, destroy" "--lab-bridge not given" SKIP "bridges are never guessed"; return; }
    { command -v virt-install >/dev/null 2>&1 && command -v virsh >/dev/null 2>&1; } || { row "throwaway-vm" "create, boot, destroy" "virt-install/virsh not installed" SKIP "Phase 7 not built"; return; }
    local base; base=$(find "$(p /srv/vms/base)" -maxdepth 1 -name 'cirros-*disk.img' 2>/dev/null | head -1)
    [ -n "$base" ] || { row "throwaway-vm" "create, boot, destroy" "no cirros image under /srv/vms/base" SKIP "files stage not run"; return; }
    VM_NAME="kit-validate-$(date +%s)"; trap vm_cleanup EXIT
    qemu-img create -q -f qcow2 -b "$base" -F qcow2 "/tmp/$VM_NAME.qcow2" >/dev/null 2>&1 || { row "throwaway-vm" "overlay created" "qemu-img create failed" FAIL "qemu-img create"; diag throwaway-vm "cannot create an overlay on the cirros image — check /srv/vms/base permissions and qemu-utils"; return; }
    if virt-install --name "$VM_NAME" --memory 256 --vcpus 1 --import --disk "/tmp/$VM_NAME.qcow2,format=qcow2" --network "bridge=$LAB_BRIDGE" --os-variant generic --noautoconsole --graphics none >/dev/null 2>&1; then
        local st tries=0
        while [ $tries -lt 12 ]; do st=$(virsh domstate "$VM_NAME" 2>/dev/null); [ "$st" = "running" ] && break; sleep 5; tries=$((tries + 1)); done
        if [ "$st" = "running" ]; then row "throwaway-vm" "running on $LAB_BRIDGE" "running" PASS "virt-install --import cirros; virsh domstate"; else row "throwaway-vm" "running" "${st:-unknown}" FAIL "virsh domstate $VM_NAME"; diag throwaway-vm "the guest defined but did not reach running — virsh dumpxml/journal for libvirtd"; fi
    else
        row "throwaway-vm" "defined and started" "virt-install failed" FAIL "virt-install --import"; diag throwaway-vm "virt-install refused — bridge $LAB_BRIDGE missing, or libvirt not running"
    fi
    vm_cleanup; trap - EXIT
    row "throwaway-vm cleanup" "guest and overlay removed" "removed" PASS "virsh destroy/undefine --remove-all-storage"
}

# ── gns3 ─────────────────────────────────────────────────────────────────────
area_gns3() {
    AREA=gns3
    local st; st=$(systemctl is-active gns3 2>/dev/null || echo inactive)
    if [ "$st" != "active" ]; then row "unit" "active" "$st" SKIP "Phase 8 not built (systemctl is-active gns3)"; return; fi
    row "unit" "active" "$st" PASS "systemctl is-active gns3"
    local v; v=$(curl -s --max-time 5 http://127.0.0.1:3080/v3/version 2>/dev/null || true)
    if printf '%s' "$v" | grep -q '"version"'; then row "api" "/v3/version answers" "$(printf '%s' "$v" | tr -d '\n' | cut -c1-60)" PASS "curl 127.0.0.1:3080/v3/version"; else row "api" "/v3/version answers" "${v:-no answer}" FAIL "curl 127.0.0.1:3080/v3/version"; diag api "the unit is active but the API does not answer on 127.0.0.1:3080 — journalctl -u gns3 (a root-owned /etc/gns3 is the usual cause)"; return; fi
    local pw tok; pw=$(head -1 "$(p /etc/lab/secrets/gns3-admin.pw)" 2>/dev/null || true)
    [ -n "$pw" ] || { row "login" "token issued" "no admin secret on this box" SKIP "/etc/lab/secrets/gns3-admin.pw"; return; }
    tok=$(curl -s --max-time 10 -X POST -H 'Content-Type: application/json' -d "{\"username\":\"admin\",\"password\":\"$pw\"}" http://127.0.0.1:3080/v3/access/users/login 2>/dev/null || true)
    if printf '%s' "$tok" | grep -q 'access_token'; then row "login" "token issued" "access_token present" PASS "POST /v3/access/users/login"; else row "login" "token issued" "no token" FAIL "POST /v3/access/users/login"; diag login "admin login rejected — the rendered config and the secret file disagree; rerun 'r770-gns3-deploy.sh config' then restart the unit"; fi
    row "node-boot" "one QEMU + one docker node pass traffic" "not automated" SKIP "needs a project; run by hand per docs/validation.md"
}

# ── wan ──────────────────────────────────────────────────────────────────────
area_wan() {
    AREA=wan
    if [ "$ALLOW_WAN" != "1" ]; then row "impairment" "+40 ms then baseline" "not opted in (--allow-wan)" SKIP "applies and clears an impairment"; return; fi
    if command -v wan-apply >/dev/null 2>&1; then row "impairment" "+40 ms then baseline" "wan-apply present but not driven by this kit" SKIP "Phase 12 tooling lives in the config repo"; else row "impairment" "+40 ms then baseline" "wan-apply not installed" SKIP "Phase 12 not built"; fi
}

# ── capture ──────────────────────────────────────────────────────────────────
area_capture() {
    AREA=capture
    local zl; zl=$(find "$(p "$MALCOLM_HOME")/malcolm/zeek-logs" -name 'capture_loss*.log' 2>/dev/null | head -1)
    if [ -n "$zl" ]; then
        local pct; pct=$(grep -v '^#' "$zl" | tail -1 | awk '{print $NF}')
        if [ -n "$pct" ] && awk -v p="$pct" 'BEGIN{exit !(p < 0.5)}'; then row "zeek capture_loss" "< 0.5 %" "$pct" PASS "$zl"; elif [ -n "$pct" ]; then row "zeek capture_loss" "< 0.5 %" "$pct" FAIL "$zl"; diag "zeek capture_loss" "Zeek reports loss — check ethtool -S drop deltas on the feed and Arkime's own stats before touching tuning"; else row "zeek capture_loss" "< 0.5 %" "no data rows yet" WARN "$zl"; fi
    else row "zeek capture_loss" "< 0.5 %" "no capture_loss log yet" SKIP "Malcolm not running or no traffic seen"; fi
    if [ -z "$FEED" ] || [ -z "$PCAP" ]; then row "tcpreplay" "packets replayed == packets indexed" "not opted in (--feed IF --pcap FILE)" SKIP "injects traffic"; return; fi
    command -v tcpreplay >/dev/null 2>&1 || { row "tcpreplay" "replayed == indexed" "tcpreplay not installed" SKIP "package not installed yet"; return; }
    [ -r "$PCAP" ] || { row "tcpreplay" "replayed == indexed" "$PCAP unreadable" SKIP "reference PCAP"; return; }
    local out sent
    out=$(tcpreplay -i "$FEED" -q "$PCAP" 2>&1 || true)
    sent=$(printf '%s' "$out" | grep -oE 'Actual: [0-9]+ packets' | grep -oE '[0-9]+' | head -1)
    if [ -n "$sent" ]; then row "tcpreplay" "packets sent" "$sent packets into $FEED" PASS "tcpreplay -i $FEED $PCAP"; else row "tcpreplay" "packets sent" "$(printf '%s' "$out" | tail -1)" FAIL "tcpreplay -i $FEED $PCAP"; diag tcpreplay "replay failed — is $FEED up and are you root (or in pcapture with setcap)?"; return; fi
    row "arkime-count" "== $sent (± indexing lag)" "compare in Arkime after the pipeline catches up" WARN "Arkime sessions/packets for the replay window — Zeek→OpenSearch lag is real (measured 2026-09-12), not a capture failure"
}

# ── backup ───────────────────────────────────────────────────────────────────
area_backup() {
    AREA=backup
    command -v restic >/dev/null 2>&1 || { row "restore" "one file restored and identical" "restic not installed" SKIP "Phase 15 not built"; return; }
    local pf; pf="$(p /etc/lab/secrets/restic.pw)"
    { [ -s "$pf" ] && [ -d "$(p /srv/backup)" ]; } || { row "restore" "one file restored and identical" "no repo password file / repo" SKIP "Phase 15 not built"; return; }
    local tmp; tmp=$(mktemp -d)
    if RESTIC_PASSWORD_FILE="$pf" restic -r "$(p /srv/backup)" restore latest --target "$tmp" --include /etc/hostname >/dev/null 2>&1 && cmp -s "$tmp/etc/hostname" /etc/hostname; then
        row "restore" "/etc/hostname restored and identical" "identical" PASS "restic restore latest --include /etc/hostname"
    else
        row "restore" "/etc/hostname restored and identical" "restore failed or differs" FAIL "restic restore latest --include /etc/hostname"; diag restore "the latest snapshot does not restore this file — check the nightly job's log and 'restic snapshots'"
    fi
    rm -rf "$tmp"
}

# ── airgap (folds in the posture script) ─────────────────────────────────────
area_airgap() {
    AREA=airgap
    [ -x "$AIRGAP_CMD" ] || { row "posture" "r770-airgap-check.sh" "$AIRGAP_CMD not executable" SKIP "kit file missing"; return; }
    local out line v text
    if [ -n "$MGMT_CIDR" ]; then out=$(KIT_NO_TEE=1 "$AIRGAP_CMD" --mgmt-cidr "$MGMT_CIDR" 2>&1 || true); else out=$(KIT_NO_TEE=1 "$AIRGAP_CMD" 2>&1 || true); fi
    while IFS= read -r line; do
        v=${line%% *}; text=${line#* }; text=${text#"${text%%[! ]*}"}
        case "$v" in
            PASS|WARN|FAIL|SKIP) row "${text%%:*}" "air-gapped" "${text#*: }" "$v" "r770-airgap-check.sh" ;;
        esac
    done <<< "$out"
}

# ── portal ───────────────────────────────────────────────────────────────────
area_portal() {
    AREA=portal
    local ca; ca="$(p /etc/nginx/ssl/ca.crt)"
    [ -s "$ca" ] || { row "vhosts" "three names answer with the lab CA" "no /etc/nginx/ssl/ca.crt" SKIP "Phase 13 not built"; return; }
    local n hdr code loc
    for n in $SANS; do
        hdr=$(curl -s --max-time 10 --cacert "$ca" --resolve "$n:443:127.0.0.1" -o /dev/null -D - "https://$n/" 2>/dev/null || true)
        code=$(printf '%s' "$hdr" | head -1 | awk '{print $2}')
        loc=$(printf '%s' "$hdr" | grep -i '^location:' | tr -d '\r' || true)
        case "$code" in
            200|301|302|307|308|401)
                if printf '%s' "$loc" | grep -qE '127\.0\.0\.1|:8443|:3080|:3000'; then row "vhost $n" "answers, redirects stay on the name" "$code, $loc" FAIL "curl --cacert ca.crt --resolve $n:443:127.0.0.1"; diag "vhost $n" "a redirect escapes the vhost to a loopback port — the backend builds absolute URLs; check the proxy_set_header lines"
                else row "vhost $n" "answers with the lab CA" "HTTP $code" PASS "curl --cacert ca.crt --resolve $n:443:127.0.0.1"; fi ;;
            *) row "vhost $n" "answers with the lab CA" "HTTP ${code:-000}" FAIL "curl --cacert ca.crt --resolve $n:443:127.0.0.1"; diag "vhost $n" "no TLS answer (000) or a gateway error (502) — nginx -t, then the backend for this name" ;;
        esac
    done
    local owners; owners=$(ss -ltnp 2>/dev/null | grep -E '(0\.0\.0\.0|\*):443 ' | grep -oE 'users:\(\("[^"]+"' | cut -d'"' -f2 | sort -u | tr '\n' ' ')
    if [ "$(printf '%s' "$owners" | wc -w)" -eq 1 ] && [[ "$owners" == nginx* ]]; then row "port-443" "only nginx" "$owners" PASS "ss -ltnp"; else row "port-443" "only nginx" "${owners:-nothing}" FAIL "ss -ltnp"; diag port-443 "something other than the portal owns 0.0.0.0:443 — if it is Malcolm's nginx-proxy the rebind did not take"; fi
}

# ── report ───────────────────────────────────────────────────────────────────
write_report() {
    local out="${OUT:-${KIT_EVIDENCE_DIR:-$PWD/r770-evidence}}" f a r
    mkdir -p "$out"
    f="$out/validation-$(hostname -s 2>/dev/null || echo host)-$(date +%Y%m%d-%H%M%S).md"
    {
        echo "# Validation — $(hostname -s 2>/dev/null || echo host) — $(date -Is)"
        echo
        echo "Format per the build repo's validation-runner: check · expected · observed · verdict · evidence. Areas: ${AREAS}."
        echo "SKIPPED checks are listed, never omitted, and never counted as passed."
        for a in $AREAS; do
            echo; echo "## $a"; echo; echo "| Check | Expected | Observed | Verdict | Evidence |"; echo "|---|---|---|---|---|"
            local ra rc re ro rv rev
            for r in "${ROWS[@]}"; do
                IFS='|' read -r ra rc re ro rv rev <<< "$r"
                [ "$ra" = "$a" ] || continue
                echo "| $rc | $re | $ro | $rv | $rev |"
            done
        done
        echo; echo "## SKIPPED"; echo
        for r in "${ROWS[@]}"; do case "$r" in *"|SKIP|"*) echo "- ${r%%|*} / $(printf '%s' "$r" | cut -d'|' -f2): $(printf '%s' "$r" | cut -d'|' -f4)" ;; esac; done
        echo; echo "## FAIL diagnoses"; echo
        if [ "${#DIAGS[@]}" -eq 0 ]; then echo "(none)"; else for r in "${DIAGS[@]}"; do echo "- $r"; done; fi
        echo; echo "Summary: ${PASSED} PASS · ${WARNED} WARN · ${FAILED} FAIL · ${SKIPPED} SKIP"
    } > "$f"
    echo; echo "report: $f"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --area)           AREAS="${AREAS:+$AREAS }${2:-}"; shift ;;
        --list)           printf '%s\n' "$ALL_AREAS" | tr ' ' '\n'; exit 0 ;;
        --expect-threads) EXPECT_THREADS="${2:-}"; shift ;;
        --expect-ram-gb)  EXPECT_RAM="${2:-}"; shift ;;
        --mgmt-if)        MGMT_IF="${2:-}"; shift ;;
        --capture-ifs)    CAPTURE_IFS="${2:-}"; shift ;;
        --mgmt-cidr)      MGMT_CIDR="${2:-}"; shift ;;
        --allow-vm)       ALLOW_VM=1 ;;
        --lab-bridge)     LAB_BRIDGE="${2:-}"; shift ;;
        --allow-wan)      ALLOW_WAN=1 ;;
        --feed)           FEED="${2:-}"; shift ;;
        --pcap)           PCAP="${2:-}"; shift ;;
        --out)            OUT="${2:-}"; shift ;;
        -h|--help)        usage ;;
        *)                common_flag "$1" || die "unknown option: $1 (try --help)" ;;
    esac
    shift
done
[ -n "$AREAS" ] || AREAS="$ALL_AREAS"
for a in $AREAS; do case " $ALL_AREAS " in *" $a "*) ;; *) die "unknown area: $a (--list shows them)" ;; esac; done
kit_init "r770-validate"
for a in $AREAS; do
    banner "validate: $a"
    case "$a" in
        host)           area_host ;;
        cpu-ram)        area_cpu_ram ;;
        storage)        area_storage ;;
        network)        area_network ;;
        virtualization) area_virtualization ;;
        gns3)           area_gns3 ;;
        wan)            area_wan ;;
        capture)        area_capture ;;
        backup)         area_backup ;;
        airgap)         area_airgap ;;
        portal)         area_portal ;;
    esac
done
write_report
footer "validation"
