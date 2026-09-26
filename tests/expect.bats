#!/usr/bin/env bats
#
# scripts/lib/expect.sh: one expect.txt row into the Arkime expression and the
# Dashboards (KQL) query that find it, and the refusals that keep a guess out
# of both. Pure functions: no stubs needed beyond the kit's PATH.

load helpers/stubs

setup() {
    kit_test_env
    LIB="$BATS_TEST_DIRNAME/../scripts/lib"
}

# x <snippet> — run a snippet with common.sh and expect.sh sourced
x() { kit_run bash -c "set -uo pipefail; . '$LIB/common.sh'; . '$LIB/expect.sh'; $1"; }

@test "a tcp row with a port: the port matches either side, in both languages" {
    run x 'expect_arkime tcp 179 10.204.0.0/24 10.204.0.0/24'
    [ "$output" = 'ip.protocol == tcp && port == 179 && ((ip.src == 10.204.0.0/24 && ip.dst == 10.204.0.0/24) || (ip.src == 10.204.0.0/24 && ip.dst == 10.204.0.0/24 && packets.dst > 0))' ]
    run x 'expect_kql tcp 179 10.204.0.0/24 10.204.0.0/24'
    [ "$output" = 'network.transport:tcp and (source.port:179 or destination.port:179) and ((source.ip:"10.204.0.0/24" and destination.ip:"10.204.0.0/24") or (source.ip:"10.204.0.0/24" and destination.ip:"10.204.0.0/24" and destination.packets > 0))' ]
}

@test "icmp and udp are matched by name; a row with no port has no port clause; either orientation counts" {
    run x 'expect_arkime icmp "" 10.205.0.10/32 10.205.0.20/32'
    [ "$output" = 'ip.protocol == icmp && ((ip.src == 10.205.0.10/32 && ip.dst == 10.205.0.20/32) || (ip.src == 10.205.0.20/32 && ip.dst == 10.205.0.10/32 && packets.dst > 0))' ]
    run x 'expect_kql udp 500 10.202.0.1/32 10.202.0.2/32'
    [ "$output" = 'network.transport:udp and (source.port:500 or destination.port:500) and ((source.ip:"10.202.0.1/32" and destination.ip:"10.202.0.2/32") or (source.ip:"10.202.0.2/32" and destination.ip:"10.202.0.1/32" and destination.packets > 0))' ]
}

@test "esp, ah and ospf are matched by IANA protocol number, in both languages" {
    for pair in esp:50 ah:51 ospf:89; do
        p=${pair%%:*}; num=${pair#*:}
        run x "expect_arkime $p '' 10.0.0.1/32 10.0.0.2/32"
        [ "$output" = "ip.protocol == $num && ((ip.src == 10.0.0.1/32 && ip.dst == 10.0.0.2/32) || (ip.src == 10.0.0.2/32 && ip.dst == 10.0.0.1/32 && packets.dst > 0))" ]
        run x "expect_kql $p '' 10.0.0.1/32 10.0.0.2/32"
        [ "$output" = "network.iana_number:$num and ((source.ip:\"10.0.0.1/32\" and destination.ip:\"10.0.0.2/32\") or (source.ip:\"10.0.0.2/32\" and destination.ip:\"10.0.0.1/32\" and destination.packets > 0))" ]
    done
}

@test "labels are <proto>[/<port>] <src> -> <dst>" {
    run x 'expect_label udp 500 10.202.0.1/32 10.202.0.2/32'
    [ "$output" = 'udp/500 10.202.0.1/32 -> 10.202.0.2/32' ]
    run x 'expect_label esp "" 10.201.0.1/32 10.201.0.2/32'
    [ "$output" = 'esp 10.201.0.1/32 -> 10.201.0.2/32' ]
}

@test "expect_rows numbers data lines only, keeps an empty port, and reads a last line with no newline" {
    d="$BATS_TEST_TMPDIR/s"; mkdir -p "$d"
    printf '# a comment\n\nesp||10.0.0.1/32|10.0.0.2/32\n# mid\ntcp|80|10.0.0.1/32|10.0.0.2/32' > "$d/expect.txt"
    run x "expect_rows '$d'"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = '1|esp||10.0.0.1/32|10.0.0.2/32' ]
    [ "${lines[1]}" = '2|tcp|80|10.0.0.1/32|10.0.0.2/32' ]
}

@test "expect_rows dies naming the directory when there is no expect.txt" {
    run x "expect_rows '$BATS_TEST_TMPDIR/none'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no expect.txt in $BATS_TEST_TMPDIR/none"* ]]
}

@test "expect_problem is empty for a good row and names each kind of bad one" {
    run x 'expect_problem tcp 179 10.204.0.0/24 10.204.0.0/24'
    [ -z "$output" ]
    run x 'expect_problem sctp "" 10.0.0.1/32 10.0.0.2/32'
    [[ "$output" == "unknown protocol 'sctp' (known: tcp udp icmp esp ah ospf)" ]]
    run x 'expect_problem ospf 89 10.0.0.1/32 10.0.0.2/32'
    [[ "$output" == "ospf carries no port (got 89)" ]]
    for bad in 0 70000 http; do
        run x "expect_problem tcp $bad 10.0.0.1/32 10.0.0.2/32"
        [[ "$output" == "port '$bad' is not 1-65535" ]]
    done
    for bad in 10.0.0.1 300.0.0.1/32 10.0.0.0/33 host; do
        run x "expect_problem tcp 80 $bad 10.0.0.2/32"
        [[ "$output" == "src '$bad' is not an IPv4 CIDR" ]]
    done
    run x 'expect_problem tcp 80 10.0.0.1/32 10.0.0.0/33'
    [[ "$output" == "dst '10.0.0.0/33' is not an IPv4 CIDR" ]]
}
