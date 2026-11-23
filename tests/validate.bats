#!/usr/bin/env bats
#
# The validation suite's contract: every check produces a row; a check that
# cannot run is SKIPPED with a reason and still appears; interfaces are never
# discovered; a FAIL carries a diagnosis and drives the exit code; indexing
# lag is a WARN, not a capture failure.

load helpers/fixtures
load helpers/stubs

setup() {
    kit_test_env
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-validate.sh"
    make_root "$ROOT"
    export OUT="$BATS_TEST_TMPDIR/out"
    stub systemctl 'case "$*" in "is-active ssh") echo active;; "is-active gns3") echo inactive;; *) echo inactive;; esac'
    stub apt-get 'echo "file:/srv/repo/apt/./Packages"'
    stub dpkg 'exit 1'
    stub findmnt 'case "$1 $2" in "-n -o") [ "$3" = TARGET ] && echo "$5" || echo 100G;; esac'
    stub nproc 'echo 64'
    stub free 'echo "Mem: 125 4 121"'
    stub curl 'echo'
    stub ss 'echo'
    stub ip 'echo'
    export VALIDATE_AIRGAP_CMD="$BIN/airgap-stub"
    stub airgap-stub 'echo "PASS  apt: every index target is file: (1 target(s))"; echo "SKIP  dnsmasq: not installed — .lab authority and no-resolv cannot be checked"; exit 0'
}

validate() { kit_run "$SCRIPT" --out "$OUT" "$@"; }
report() { cat "$OUT"/validation-*.md; }

@test "--list prints every area" {
    run validate --list
    [ "$status" -eq 0 ]
    for a in host cpu-ram storage network virtualization gns3 wan capture backup airgap portal; do
        [[ "$output" == *"$a"* ]]
    done
}

@test "checks that cannot run are SKIPPED with a reason, present in the report, and do not change the exit code" {
    run validate --area host --area cpu-ram --area gns3 --area wan --area backup --area portal
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  host/chrony: chronyc not installed (needs chrony)"* ]]
    [[ "$output" == *"SKIP  cpu-ram/threads: 64 (--expect-threads not given)"* ]]
    [[ "$output" == *"SKIP  gns3/unit: inactive (needs the gns3 unit: r770-gns3-deploy.sh service)"* ]]
    [[ "$output" == *"SKIP  wan/impairment: not opted in"* ]]
    [[ "$output" == *"SKIP  backup/restore: restic not installed (needs restic)"* ]]
    [[ "$output" == *"SKIP  portal/vhosts: no /etc/nginx/ssl/ca.crt (needs the lab CA: r770-portal-deploy.sh ca)"* ]]
    run report
    [[ "$output" == *"## SKIPPED"* ]]
    [[ "$output" == *"- gns3 / unit"* ]]
    [[ "$output" == *"| chrony | Leap status Normal | chronyc not installed | SKIP | needs chrony |"* ]]
}

@test "an opted-in wan area SKIPs as not automated, pointing at r770-wan.sh" {
    run validate --area wan --allow-wan
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  wan/impairment: not automated by this suite (impair with r770-wan.sh and measure by hand)"* ]]
}

@test "the report has one five-column row per check and a summary" {
    run validate --area host --area cpu-ram
    [ "$status" -eq 0 ]
    checks=$(printf '%s\n' "$output" | grep -cE '^(PASS|WARN|FAIL|SKIP)  (host|cpu-ram)/')
    rows=$(grep -cE '^\| [^|]+ \| [^|]+ \| [^|]+ \| (PASS|WARN|FAIL|SKIP) \| [^|]+ \|$' "$OUT"/validation-*.md)
    echo "checks=$checks rows=$rows"
    [ "$checks" -eq "$rows" ]
    grep -q '^Summary: ' "$OUT"/validation-*.md
}

@test "sshd: a listening ssh.socket PASSes while ssh.service waits for its first connection (Ubuntu 24.04)" {
    # The 2026-10-06 EC2 rehearsal: nobody had SSH'd in since boot, so the
    # service was inactive behind an active socket. Like the real systemctl,
    # the stub exits non-zero for a unit that is not active.
    stub systemctl 'case "$*" in "is-active ssh.socket") echo active;; "is-active ssh"|"is-active sshd") echo inactive; exit 3;; *) echo inactive; exit 3;; esac'
    run validate --area host
    echo "$output"
    [[ "$output" == *"PASS  host/sshd: ssh.socket active"* ]]
    [[ "$output" != *"FAIL  host/sshd"* ]]
}

@test "sshd: no service and no socket is a FAIL with one value and a diagnosis" {
    stub systemctl 'echo inactive; exit 3'
    run validate --area host
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  host/sshd: inactive"* ]]
    # one systemctl answer, not "inactive" from ssh then another from sshd
    [ "$(grep -c 'host/sshd' <<<"$output")" -eq 1 ]
    [[ "$output" != *"FAIL  host/sshd: inactive"$'\n'"inactive"* ]]
    run report
    [[ "$output" == *"host/sshd: ssh is not active"* ]]
}

@test "a FAIL drives exit 1 and carries a diagnosis" {
    stub apt-get 'echo "https://archive.ubuntu.com/ubuntu/dists/noble/InRelease"'
    run validate --area host
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  host/apt-local"* ]]
    run report
    [[ "$output" == *"## FAIL diagnoses"* ]]
    [[ "$output" == *"host/apt-local: an upstream source survived"* ]]
}

@test "hardware expectations are arguments: threads and RAM pass against what is given" {
    run validate --area cpu-ram --expect-threads 64 --expect-ram-gb 128
    echo "$output"
    [[ "$output" == *"PASS  cpu-ram/threads: 64"* ]]
    [[ "$output" == *"PASS  cpu-ram/ram-gb: 125"* ]]
    run validate --area cpu-ram --expect-threads 32
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  cpu-ram/threads: 64"* ]]
}

@test "capture interfaces are never discovered: without --capture-ifs the area SKIPs" {
    run validate --area network
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  network/capture: no --capture-ifs given"* ]]
    [[ "$output" == *"SKIP  network/mgmt: no --mgmt-if given"* ]]
}

@test "a capture port carrying an address is a FAIL with the rule in its diagnosis" {
    stub ip 'case "$*" in *"addr show cap0"*) echo "2: cap0 inet 10.0.0.9/24 scope global cap0";; *"link show cap0"*) echo "2: cap0: <BROADCAST,PROMISC,UP>";; *) echo;; esac'
    run validate --area network --capture-ifs "cap0"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  network/capture cap0 address: 1 address(es)"* ]]
    [[ "$output" == *"PASS  network/capture cap0 promisc"* ]]
    run report
    [[ "$output" == *"capture ports never get an IP"* ]]
}

@test "zeek capture_loss is SKIPPED naming the cause when Malcolm's live Zeek has its stats off" {
    mkdir -p "$ROOT/opt/malcolm/malcolm/config" "$ROOT/opt/malcolm/malcolm/zeek-logs/live"
    printf 'ZEEK_LIVE_CAPTURE=true\nZEEK_DISABLE_STATS=true\n' > "$ROOT/opt/malcolm/malcolm/config/zeek-live.env"
    run validate --area capture
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  capture/zeek capture_loss: stats off (ZEEK_DISABLE_STATS=true in config/zeek-live.env) (r770-malcolm-deploy.sh configure --capture-ifs ... turns them on)"* ]]
    printf 'ZEEK_LIVE_CAPTURE=true\nZEEK_DISABLE_STATS=\n' > "$ROOT/opt/malcolm/malcolm/config/zeek-live.env"
    run validate --area capture
    [[ "$output" == *"SKIP  capture/zeek capture_loss: no capture_loss log yet (Malcolm not running or no traffic seen)"* ]]
    printf '#fields\tts\tts_delta\tpeer\tgaps\tacks\tpercent_lost\n1\t900\tzeek\t0\t100\t0.0\n' > "$ROOT/opt/malcolm/malcolm/zeek-logs/live/capture_loss.log"
    run validate --area capture
    [[ "$output" == *"PASS  capture/zeek capture_loss: 0.0"* ]]
}

@test "zeek capture_loss reads the newest log, rotated .gz included, and judges the worst worker" {
    z="$ROOT/opt/malcolm/malcolm/zeek-logs/live"
    mkdir -p "$z/logs/2026-01-01" "$z/spool/logger-1"
    printf '#fields\tts\tts_delta\tpeer\tgaps\tacks\tpercent_lost\n1\t60\tworker-1-1\t0\t100\t0.0\n' > "$z/spool/logger-1/capture_loss.log"
    touch -d '2 hours ago' "$z/spool/logger-1/capture_loss.log"
    printf '#fields\tts\tts_delta\tpeer\tgaps\tacks\tpercent_lost\n2\t60\tworker-1-2\t9\t100\t0.9\n2\t60\tworker-1-1\t0\t100\t0.0\n#close\t2026-01-01-01-00-00\n' \
        | gzip > "$z/logs/2026-01-01/capture_loss.00:00:00-01:00:00.log.gz"
    run validate --area capture
    echo "$output"
    [[ "$output" == *"FAIL  capture/zeek capture_loss: 0.9"* ]]
    run report
    [[ "$output" == *"capture_loss.00:00:00-01:00:00.log.gz"* ]]
}

@test "zeek capture_loss judges only the latest interval: an old spike in the same file no longer fails it" {
    z="$ROOT/opt/malcolm/malcolm/zeek-logs/live/spool/logger-1"
    mkdir -p "$z"
    printf '#fields\tts\tts_delta\tpeer\tgaps\tacks\tpercent_lost\n' > "$z/capture_loss.log"
    printf '1000.000002\t60.0\tworker-1-1\t9\t100\t0.9\n1000.000001\t60.0\tworker-1-2\t0\t100\t0.0\n' >> "$z/capture_loss.log"
    printf '1060.000002\t60.0\tworker-1-1\t0\t100\t0.0\n1060.000001\t60.0\tworker-1-2\t0\t100\t0.1\n' >> "$z/capture_loss.log"
    run validate --area capture
    echo "$output"
    [[ "$output" == *"PASS  capture/zeek capture_loss: 0.1"* ]]
}

@test "a replay is opt-in, and the Arkime comparison is a WARN (indexing lag), not a FAIL" {
    run validate --area capture
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  capture/tcpreplay: not opted in (--feed IF --pcap FILE) (injects traffic)"* ]]
    stub tcpreplay 'echo "Actual: 1234 packets (100000 bytes) sent in 0.5 seconds"'
    echo pcap > "$BATS_TEST_TMPDIR/ref.pcap"
    run validate --area capture --feed cap0 --pcap "$BATS_TEST_TMPDIR/ref.pcap"
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"PASS  capture/tcpreplay: 1234 packets into cap0"* ]]
    [[ "$output" == *"WARN  capture/arkime-count"* ]]
}

@test "the airgap area folds the posture script's rows in, under its own verdicts" {
    run validate --area airgap
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  airgap/apt: every index target is file:"* ]]
    [[ "$output" == *"SKIP  airgap/dnsmasq: not installed — .lab authority"* ]]
    stub airgap-stub 'echo "FAIL  snapd is installed — it phones home"; exit 1'
    run validate --area airgap
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  airgap/snapd is installed"* ]]
}

@test "an unknown area is rejected" {
    run validate --area frobnicate
    [ "$status" -eq 1 ]
}

# fake_lab_sys [ageing] [physical-port] [multicast_snooping] [operstate] —
# br-lab with lab-mon0 as a port whose veth peer is lab_mirror0 (ifindex 21
# <-> iflink 21), under $ROOT
fake_lab_sys() {
    local s="$ROOT/sys/class/net"
    mkdir -p "$s/br-lab/bridge" "$s/br-lab/brif" "$s/lab-mon0" "$s/lab_mirror0" "$s/lab-tap0"
    echo "${1:-0}" > "$s/br-lab/bridge/ageing_time"
    echo "${3:-0}" > "$s/br-lab/bridge/multicast_snooping"
    echo "${4:-up}" > "$s/br-lab/operstate"
    touch "$s/br-lab/brif/lab-mon0" "$s/br-lab/brif/lab-tap0"
    echo 21 > "$s/lab-mon0/ifindex"; echo 22 > "$s/lab-mon0/iflink"
    echo 22 > "$s/lab_mirror0/ifindex"; echo 21 > "$s/lab_mirror0/iflink"
    echo 30 > "$s/lab-tap0/ifindex"; echo 30 > "$s/lab-tap0/iflink"
    if [ -n "${2:-}" ]; then mkdir -p "$s/$2/device"; touch "$s/br-lab/brif/$2"; echo 40 > "$s/$2/ifindex"; echo 40 > "$s/$2/iflink"; fi
}

@test "the lab bridge is never guessed: without --lab-bridge its rows SKIP" {
    run validate --area network
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  network/lab-bridge: no --lab-bridge given"* ]]
}

@test "a correct lab bridge PASSes hub mode, no physical port, and the mirror wiring" {
    fake_lab_sys
    stub ip 'case "$*" in *"link show lab_mirror0"*) echo "22: lab_mirror0@lab-mon0: <BROADCAST,NOARP,PROMISC,UP>";; esac; exit 0'
    run validate --area network --lab-bridge br-lab --capture-ifs lab_mirror0
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  network/lab-bridge br-lab operstate: up"* ]]
    [[ "$output" == *"PASS  network/lab-bridge br-lab hub"* ]]
    [[ "$output" == *"PASS  network/lab-bridge br-lab multicast snooping"* ]]
    [[ "$output" == *"PASS  network/lab-bridge br-lab physical ports"* ]]
    [[ "$output" == *"PASS  network/lab-bridge br-lab mirror"* ]]
    [[ "$output" == *"PASS  network/lab-mirror lab_mirror0 address"* ]]
}

@test "a lab bridge that learns MACs, or holds a physical port, is a FAIL with a diagnosis" {
    fake_lab_sys 30000 eno1
    stub ip 'case "$*" in *"link show lab_mirror0"*) echo "22: lab_mirror0@lab-mon0: <PROMISC,UP>";; esac; exit 0'
    run validate --area network --lab-bridge br-lab --capture-ifs lab_mirror0
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  network/lab-bridge br-lab hub: ageing_time 30000"* ]]
    [[ "$output" == *"FAIL  network/lab-bridge br-lab physical ports: eno1"* ]]
    run report
    [[ "$output" == *"never touches a physical port"* ]]
}

@test "a mirror capture end with a link-local address is a FAIL; no capture interface fed by the bridge is a FAIL" {
    fake_lab_sys
    stub ip 'case "$*" in *"addr show lab_mirror0"*) echo "22: lab_mirror0    inet6 fe80::1/64 scope link";; *"link show lab_mirror0"*) echo "22: lab_mirror0: <PROMISC,UP>";; esac; exit 0'
    run validate --area network --lab-bridge br-lab --capture-ifs lab_mirror0
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  network/lab-mirror lab_mirror0 address: 1 address(es)"* ]]
    mkdir -p "$ROOT/sys/class/net/cap9"; echo 50 > "$ROOT/sys/class/net/cap9/iflink"
    run validate --area network --lab-bridge br-lab --capture-ifs cap9
    echo "$output"
    [[ "$output" == *"FAIL  network/lab-bridge br-lab mirror: no --capture-ifs interface is fed by a port of br-lab"* ]]
}

@test "a lab bridge that snoops multicast is a FAIL with a diagnosis (F7)" {
    fake_lab_sys 0 "" 1
    stub ip 'case "$*" in *"link show lab_mirror0"*) echo "22: lab_mirror0@lab-mon0: <PROMISC,UP>";; esac; exit 0'
    run validate --area network --lab-bridge br-lab --capture-ifs lab_mirror0
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  network/lab-bridge br-lab multicast snooping: multicast_snooping 1"* ]]
    run report
    [[ "$output" == *"MulticastSnooping=no"* ]]
}

@test "--lab-bridge naming a bridge that does not exist is a FAIL pointing at labnet (F12)" {
    run validate --area network --lab-bridge br-nope
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  network/lab-bridge br-nope: absent or not a bridge"* ]]
    run report
    [[ "$output" == *"r770-gns3-deploy.sh labnet creates it"* ]]
}

@test "capture offloads on the mirror end PASS when off and FAIL when on (F3)" {
    fake_lab_sys
    stub ip 'case "$*" in *"link show lab_mirror0"*) echo "22: lab_mirror0@lab-mon0: <PROMISC,UP>";; esac; exit 0'
    stub ethtool 'printf "tcp-segmentation-offload: %s\ngeneric-receive-offload: %s\nlarge-receive-offload: off [fixed]\n" "${OFFL:-off}" "${OFFL:-off}"'
    run validate --area network --lab-bridge br-lab --capture-ifs lab_mirror0
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  network/capture lab_mirror0 offloads: off"* ]]
    OFFL=on run validate --area network --lab-bridge br-lab --capture-ifs lab_mirror0
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  network/capture lab_mirror0 offloads: 2 still on"* ]]
}

@test "a capture interface enslaved to a bridge is a FAIL (rule 8); one with no master PASSes (F9)" {
    fake_lab_sys
    stub ip 'case "$*" in *"link show"*) echo "3: x: <PROMISC,UP>";; esac; exit 0'
    mkdir -p "$ROOT/sys/class/net/cap0"
    run validate --area network --capture-ifs "lab_mirror0 cap0"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  network/capture lab_mirror0 master: none"* ]]
    [[ "$output" == *"PASS  network/capture cap0 master: none"* ]]
    ln -s ../br-lab "$ROOT/sys/class/net/cap0/master"
    run validate --area network --capture-ifs "lab_mirror0 cap0"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  network/capture cap0 master: br-lab"* ]]
    run report
    [[ "$output" == *"never bridged to the lab fabric"* ]]
}

@test "the mirror's capture end enslaved to the lab bridge is a FAIL by name, never counted as fed (rule 8)" {
    fake_lab_sys
    stub ip 'case "$*" in *"link show lab_mirror0"*) echo "22: lab_mirror0@lab-mon0: <PROMISC,UP>";; esac; exit 0'
    touch "$ROOT/sys/class/net/br-lab/brif/lab_mirror0"
    ln -s ../br-lab "$ROOT/sys/class/net/lab_mirror0/master"
    run validate --area network --lab-bridge br-lab --capture-ifs lab_mirror0
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  network/lab-mirror lab_mirror0 bridge port: a port of br-lab"* ]]
    [[ "$output" == *"FAIL  network/lab-bridge br-lab mirror: no --capture-ifs interface is fed by a port of br-lab"* ]]
    [[ "$output" == *"FAIL  network/capture lab_mirror0 master: br-lab"* ]]
    [[ "$output" != *"PASS  network/lab-bridge br-lab mirror"* ]]
    run report
    [[ "$output" == *"fed BY br-lab through lab-mon0"* ]]
}

@test "a lab bridge that exists but is not up is a FAIL naming the mirror pair" {
    fake_lab_sys 0 "" 0 down
    stub ip 'case "$*" in *"link show lab_mirror0"*) echo "22: lab_mirror0@lab-mon0: <PROMISC>";; esac; exit 0'
    run validate --area network --lab-bridge br-lab --capture-ifs lab_mirror0
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  network/lab-bridge br-lab operstate: down"* ]]
    run report
    [[ "$output" == *"networkctl status br-lab lab-mon0 lab_mirror0"* ]]
}

# mgmt_ip <route-dev> — ip as seen from a box whose mgmt interface is mgmt0
# (198.51.100.10/24; documentation addresses only), routing the peer via <route-dev>
mgmt_ip() {
    stub ip "case \"\$*\" in
        *\"route get\"*) echo \"198.51.100.1 dev ${1:-mgmt0} src 198.51.100.10 uid 0\";;
        *\"link show mgmt0\"*) echo \"2: mgmt0: <BROADCAST,UP> mtu 1500 state UP\";;
        *\"-4 addr show mgmt0\"*) echo \"2: mgmt0    inet 198.51.100.10/24 brd 198.51.100.255 scope global mgmt0\";;
    esac; exit 0"
}

@test "mgmt reachability is never guessed: without --mgmt-peer, or without --mgmt-if, it SKIPs" {
    run validate --area network
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  network/mgmt-peer: no --mgmt-peer given (peers are never guessed)"* ]]
    run validate --area network --mgmt-peer 198.51.100.1
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  network/mgmt-peer 198.51.100.1: no --mgmt-if given"* ]]
}

@test "mgmt reachability PASSes when the route leaves by --mgmt-if and the peer answers 3/3" {
    mgmt_ip mgmt0
    stub ping 'echo "3 packets transmitted, 3 received, 0% packet loss, time 2003ms"'
    run validate --area network --mgmt-if mgmt0 --mgmt-peer 198.51.100.1
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  network/mgmt mgmt0: UP 198.51.100.10/24"* ]]
    [[ "$output" == *"PASS  network/mgmt-peer 198.51.100.1 route: dev mgmt0"* ]]
    [[ "$output" == *"PASS  network/mgmt-peer 198.51.100.1 answers: 3/3"* ]]
}

@test "a route to the mgmt peer out of another interface is a FAIL, and no ping is sent" {
    mgmt_ip eth9
    stub_log ping
    run validate --area network --mgmt-if mgmt0 --mgmt-peer 198.51.100.1
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  network/mgmt-peer 198.51.100.1 route: dev eth9"* ]]
    ! grep -q '^ping ' "$STUB_LOG"
    run report
    [[ "$output" == *"ip route get 198.51.100.1"* ]]
}

@test "a mgmt peer that loses some replies is a WARN; one that answers none is a FAIL pointing at ARP" {
    mgmt_ip mgmt0
    stub ping 'echo "3 packets transmitted, 2 received, 33% packet loss"'
    run validate --area network --mgmt-if mgmt0 --mgmt-peer 198.51.100.1
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"WARN  network/mgmt-peer 198.51.100.1 answers: 2/3"* ]]
    stub ping 'echo "3 packets transmitted, 0 received, 100% packet loss"; exit 1'
    run validate --area network --mgmt-if mgmt0 --mgmt-peer 198.51.100.1
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  network/mgmt-peer 198.51.100.1 answers: 0/3"* ]]
    run report
    [[ "$output" == *"ip neigh show dev mgmt0"* ]]
}

@test "--mgmt-peer that is not an address is refused before anything runs" {
    for bad in '-f' 'abc' '198.51.100.1.5' 'dead.beef'; do
        run validate --area network --mgmt-if mgmt0 --mgmt-peer "$bad"
        echo "$output"
        [ "$status" -eq 1 ]
        [[ "$output" == *"--mgmt-peer must be an IPv4 or IPv6 address"* ]]
    done
    mgmt_ip mgmt0
    stub ping 'echo "3 packets transmitted, 3 received"'
    run validate --area network --mgmt-if mgmt0 --mgmt-peer 2001:db8::1
    echo "$output"
    [[ "$output" == *"network/mgmt-peer 2001:db8::1 route"* ]]
}

# portal_box <getent-body> <curl-code-for-a-resolved-request> — the lab CA in
# place, the box owning 198.51.100.10, every vhost answering 200 on loopback
portal_box() {
    mkdir -p "$ROOT/etc/nginx/ssl"; echo fixture > "$ROOT/etc/nginx/ssl/ca.crt"
    stub getent "$1"
    stub ip 'case "$*" in "-o addr show") echo "1: lo    inet 127.0.0.1/8 scope host lo"; echo "2: mgmt0    inet 198.51.100.10/24 scope global mgmt0";; esac; exit 0'
    stub curl "case \"\$*\" in *--resolve*) printf 'HTTP/1.1 200 OK\r\n\r\n';; *) printf '%s' '$2';; esac"
    stub ss 'echo "LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:((\"nginx\",pid=1,fd=6))"'
}

@test "each .lab name answers through the portal at the address DNS gives it" {
    portal_box 'echo "198.51.100.10   $2"' 200
    run validate --area portal
    echo "$output"
    [ "$status" -eq 0 ]
    for n in malcolm.lab gns3.lab docs.lab; do
        [[ "$output" == *"PASS  portal/vhost $n: HTTP 200"* ]]
        [[ "$output" == *"PASS  portal/vhost $n via DNS: HTTP 200 at 198.51.100.10"* ]]
    done
}

@test "a .lab name resolving off-box is a FAIL; one answering on loopback only is a FAIL; an unresolved one SKIPs to host/lab-dns" {
    portal_box 'echo "203.0.113.7   $2"' 200
    run validate --area portal
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  portal/vhost docs.lab via DNS: 203.0.113.7, not on this box"* ]]
    portal_box 'echo "198.51.100.10   $2"' 000
    run validate --area portal
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  portal/vhost gns3.lab via DNS: HTTP 000 at 198.51.100.10"* ]]
    run report
    [[ "$output" == *"nginx listens on loopback only"* ]]
    portal_box 'exit 2' 200
    run validate --area portal
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  portal/vhost malcolm.lab via DNS: does not resolve (host/lab-dns proves resolution)"* ]]
}

@test "host/lab-dns: the three .lab names resolve; a missing one is a FAIL by name; without dnsmasq it SKIPs" {
    stub dpkg 'exit 0'
    stub getent 'echo "198.51.100.10   $2"'
    run validate --area host
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  host/lab-dns: all resolve"* ]]
    stub getent 'case "$2" in gns3.lab) exit 2;; *) echo "198.51.100.10   $2";; esac'
    run validate --area host
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  host/lab-dns: unresolved: gns3.lab"* ]]
    run report
    [[ "$output" == *"not authoritative for these names"* ]]
    stub dpkg 'exit 1'
    run validate --area host
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  host/lab-dns: dnsmasq not installed"* ]]
}

@test "the airgap area folds in the route verdict under its own name" {
    stub airgap-stub 'echo "FAIL  routes: default via 203.0.113.1 dev eth0 is live and outside 198.51.100.0/24 — a path to the outside is open"; exit 1'
    run validate --area airgap --mgmt-cidr 198.51.100.0/24
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  airgap/routes: default via 203.0.113.1 dev eth0 is live"* ]]
}

@test "a .lab name resolving to loopback SKIPs its via-DNS row: the loopback row already proves that path" {
    portal_box 'echo "127.0.0.1   $2"' 200
    run validate --area portal
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  portal/vhost docs.lab via DNS: 127.0.0.1, loopback"* ]]
}
