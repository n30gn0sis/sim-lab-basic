#!/usr/bin/env bats
# r770-capture-ports.sh: physical capture ports made silent, promiscuous and
# offload-free, gated, with every refusal before any write.
load helpers/fixtures
load helpers/stubs

setup() {
    kit_test_env
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-capture-ports.sh"
    make_root "$ROOT"
    S="$ROOT/sys/class/net"
    mkdir -p "$S/ens2f0/device" "$S/ens2f1/device" "$S/eno1/device" "$S/lab_mirror0" "$S/dummy0" "$ROOT/etc/systemd/network"
    echo 0x1103 > "$S/ens2f0/flags"; echo 0x1103 > "$S/ens2f1/flags"
    export ROOT KIT_YES=1
    stub systemctl 'echo "systemctl $*" >> "$STUB_LOG"; [ "$*" = "is-active systemd-networkd" ] && echo active; exit 0'
    stub_log networkctl
    stub ip 'echo "ip $*" >> "$STUB_LOG"
case "$*" in
  "-o addr show dev eno1")   echo "2: eno1    inet 192.168.4.78/24 brd 192.168.4.255 scope global eno1" ;;
  "route show default")      echo "default via 192.168.4.1 dev eno1 proto static" ;;
esac
exit 0'
    stub ethtool 'echo "ethtool $*" >> "$STUB_LOG"; [ "$1" = -k ] && printf "tcp-segmentation-offload: off\ngeneric-receive-offload: off\nlarge-receive-offload: off [fixed]\n"; exit 0'
}
cap() { kit_run "$SCRIPT" "$@"; }
netf() { echo "$ROOT/etc/systemd/network/05-capture-$1.network"; }

@test "apply needs --capture-ifs; nothing is guessed" {
    run cap apply
    [ "$status" -eq 1 ]; [[ "$output" == *"--capture-ifs"* ]]
}

@test "apply is gated: unattended without --yes writes nothing" {
    unset KIT_YES
    run cap apply --capture-ifs ens2f0 --non-interactive
    echo "$output"
    [ "$status" -eq 1 ]
    [ ! -e "$(netf ens2f0)" ]
    ! grep -q '^systemctl enable' "$STUB_LOG"
}

@test "apply renders one .network per port, enables the offload unit, reloads, applies offloads now, and proves the port" {
    run cap apply --capture-ifs "ens2f0 ens2f1"
    echo "$output"
    [ "$status" -eq 0 ]
    for i in ens2f0 ens2f1; do
        grep -qx "Name=$i" "$(netf "$i")"
        grep -qx 'Promiscuous=yes' "$(netf "$i")"
        grep -qx 'LinkLocalAddressing=no' "$(netf "$i")"
        grep -qx "systemctl enable r770-capture-offloads@$i.service" "$STUB_LOG"
        grep -qx "ethtool -K $i tso off gso off gro off lro off" "$STUB_LOG"
        [[ "$output" == *"PASS  $i: no address, no master, promiscuous, offloads off"* ]]
    done
    [ -f "$ROOT/etc/systemd/system/r770-capture-offloads@.service" ]
    grep -qx 'networkctl reload' "$STUB_LOG"
    [ ! -e "$ROOT/etc/systemd/network/05-capture-ens2f0.link" ]     # never a .link for a physical port
}

@test "apply passes lab_mirror0 over: labnet owns it" {
    run cap apply --capture-ifs "lab_mirror0 ens2f0"
    echo "$output"
    [ "$status" -eq 0 ]
    [ ! -e "$(netf lab_mirror0)" ]
    [[ "$output" == *"lab_mirror0"*"labnet"* ]]
    [ -e "$(netf ens2f0)" ]
}

@test "apply with only lab_mirror0 has nothing to do and changes nothing" {
    run cap apply --capture-ifs lab_mirror0
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  no physical capture port"* ]]
    ! grep -q '^networkctl' "$STUB_LOG"
}

@test "apply refuses, before any write: a missing port, a non-physical one, the default route's port, a port with an address, a port with a master" {
    run cap apply --capture-ifs ens9
    [ "$status" -eq 1 ]; [[ "$output" == *"ens9 does not exist"* ]]
    run cap apply --capture-ifs dummy0
    [ "$status" -eq 1 ]; [[ "$output" == *"dummy0 is not a physical"* ]]
    run cap apply --capture-ifs eno1
    [ "$status" -eq 1 ]; [[ "$output" == *"eno1"*"default route"* ]]
    stub ip 'case "$*" in "-o addr show dev ens2f0") echo "3: ens2f0    inet 10.0.0.5/24 scope global ens2f0" ;; esac; exit 0'
    run cap apply --capture-ifs ens2f0
    [ "$status" -eq 1 ]; [[ "$output" == *"ens2f0 carries an address"* ]]
    stub ip 'exit 0'
    ln -s ../br0 "$S/ens2f1/master"
    run cap apply --capture-ifs "ens2f0 ens2f1"
    [ "$status" -eq 1 ]; [[ "$output" == *"ens2f1 has a master"* ]]
    [ ! -e "$(netf ens2f0)" ]                                       # one bad port stops all of them
}

@test "apply refuses when systemd-networkd is not active" {
    stub systemctl 'echo inactive; exit 3'
    run cap apply --capture-ifs ens2f0
    [ "$status" -eq 1 ]; [[ "$output" == *"systemd-networkd"* ]]
    [ ! -e "$(netf ens2f0)" ]
}

@test "apply is idempotent: files in place means no gate and no reload" {
    cap apply --capture-ifs ens2f0 >/dev/null
    : > "$STUB_LOG"; unset KIT_YES
    run cap apply --capture-ifs ens2f0 --non-interactive
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already in place"* ]]
    ! grep -q '^networkctl reload' "$STUB_LOG"
}

@test "apply FAILs a port that is still not promiscuous or still has offloads on" {
    echo 0x1003 > "$S/ens2f0/flags"
    run cap apply --capture-ifs ens2f0
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  ens2f0: not promiscuous"* ]]
    echo 0x1103 > "$S/ens2f0/flags"
    stub ethtool '[ "$1" = -k ] && printf "tcp-segmentation-offload: on\ngeneric-receive-offload: off\n"; exit 0'
    run cap apply --capture-ifs ens2f0 --force
    [ "$status" -eq 1 ]; [[ "$output" == *"FAIL  ens2f0: 1 offload(s) still on"* ]]
}

@test "apply --dry-run prints the file and writes nothing" {
    run cap apply --capture-ifs ens2f0 --dry-run
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Name=ens2f0"* ]]
    [ ! -e "$(netf ens2f0)" ]
}

@test "status is read-only and reports each port" {
    run cap status --capture-ifs ens2f0
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ens2f0"* ]]
    ! grep -qE '^(networkctl reload|systemctl enable|ethtool -K)' "$STUB_LOG"
}
