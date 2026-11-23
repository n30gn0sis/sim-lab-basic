#!/usr/bin/env bats
#
# The posture check must say "no" and "couldn't tell" differently. The
# rehearsal's air-gap simulator once reported OPEN while blocking because an
# error was swallowed as absence; every case here is a false-pass it must
# not produce.

load helpers/fixtures
load helpers/stubs

setup() {
    kit_test_env
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-airgap-check.sh"
    make_root "$ROOT"
    rm -f "$ROOT/etc/apt/sources.list.d/ubuntu.list"
    echo 'deb [trusted=yes] file:/srv/repo/apt ./' > "$ROOT/etc/apt/sources.list.d/r770-local.list"
    printf 'nameserver 127.0.0.1\n' > "$ROOT/etc/resolv.conf"
    # an air-gapped host, as stubs
    stub apt-get 'case "$1" in indextargets) echo "file:/srv/repo/apt/./Packages";; esac'
    stub dpkg 'case "$*" in "-s snapd") exit 1;; "-s dnsmasq") exit 1;; *) exit 0;; esac'
    stub systemctl 'echo disabled'
    stub docker 'case "$*" in *Mirrors*) echo "[]";; *Proxy*) echo;; "ps -q") ;; esac; exit 0'
    unset PIP_INDEX_URL PIP_EXTRA_INDEX_URL
}

airgap() { kit_run "$SCRIPT" "$@"; }

@test "an air-gapped host passes, with the missing prerequisites SKIPPED by name" {
    run airgap
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  apt: every index target is file:"* ]]
    [[ "$output" == *"PASS  snapd not installed"* ]]
    [[ "$output" == *"SKIP  dnsmasq: not installed — .lab authority and no-resolv cannot be checked"* ]]
    [[ "$output" == *"SKIP  resolv.conf: no --mgmt-cidr given"* ]]
    [[ "$output" == *"READY —"* ]]
}

@test "an upstream APT source is a FAIL that names it" {
    stub apt-get 'echo "file:/srv/repo/apt/./Packages"; echo "https://archive.ubuntu.com/ubuntu/dists/noble/InRelease"'
    run airgap
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  apt: source(s) beyond the local repo: https://archive.ubuntu.com"* ]]
}

@test "no APT sources at all is a FAIL, not a pass (nothing to reach is not the same as local-only)" {
    stub apt-get 'exit 0'
    run airgap
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  apt: no index targets at all"* ]]
}

@test "snapd installed is a FAIL" {
    stub dpkg 'case "$*" in "-s snapd") exit 0;; *) exit 1;; esac'
    run airgap
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  snapd is installed"* ]]
}

@test "a docker registry mirror or daemon proxy is a FAIL; docker absent is a SKIP" {
    stub docker 'case "$*" in *Mirrors*) echo "[https://mirror.example]";; *Proxy*) echo;; esac; exit 0'
    run airgap
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  docker: registry mirrors configured"* ]]
    unstub docker
    run airgap
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  docker: not installed"* ]]
}

@test "a phone-home timer left enabled is a WARN (exit 2)" {
    stub systemctl 'case "$*" in *apt-daily.timer*) echo enabled;; *) echo disabled;; esac'
    run airgap
    [ "$status" -eq 2 ]
    [[ "$output" == *"WARN  unit apt-daily.timer is enabled"* ]]
}

@test "dnsmasq without no-resolv, or with an upstream server=, is a FAIL" {
    stub dpkg 'case "$*" in "-s dnsmasq") exit 0;; *) exit 1;; esac'
    printf 'server=8.8.8.8\n' > "$ROOT/etc/dnsmasq.conf"
    run airgap
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  dnsmasq: no-resolv not set"* ]]
    [[ "$output" == *"FAIL  dnsmasq: upstream forwarder(s): server=8.8.8.8"* ]]
    printf 'no-resolv\nserver=/lab/127.0.0.1\n' > "$ROOT/etc/dnsmasq.conf"
    run airgap
    [ "$status" -eq 0 ]
}

@test "resolvers are judged only against a given --mgmt-cidr, and an outside one FAILs" {
    printf 'nameserver 10.10.10.1\nnameserver 1.1.1.1\n' > "$ROOT/etc/resolv.conf"
    run airgap
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  resolv.conf: no --mgmt-cidr given"* ]]
    run airgap --mgmt-cidr 10.10.10.0/24
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"resolver 1.1.1.1 is outside"* ]]
    [[ "$output" == *"FAIL  resolv.conf: 1 of 2 resolver(s) point outside the lab"* ]]
    printf 'nameserver 10.10.10.1\n' > "$ROOT/etc/resolv.conf"
    run airgap --mgmt-cidr 10.10.10.0/24
    [ "$status" -eq 0 ]
}

@test "a pip index in the environment is a FAIL" {
    export PIP_INDEX_URL=https://pypi.example/simple
    run airgap
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  pip: PIP_INDEX_URL"* ]]
}

@test "a malformed --mgmt-cidr is rejected" {
    run airgap --mgmt-cidr 10.10.10.0
    [ "$status" -eq 1 ]
}

# default_route <ipv4-line> [operstate] [ipv6-line] — the kernel's default
# routes, and the operstate of eth0 under $ROOT (documentation addresses only)
default_route() {
    stub ip "case \"\$*\" in \"-o -4 route show default\") echo \"$1\";; \"-o -6 route show default\") echo \"${3:-}\";; esac; exit 0"
    mkdir -p "$ROOT/sys/class/net/eth0"; echo "${2:-up}" > "$ROOT/sys/class/net/eth0/operstate"
}

@test "routes: no default route PASSes; without ip the route SKIPs rather than passes" {
    stub ip 'exit 0'
    run airgap
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  routes: no default route"* ]]
    unstub ip
    run airgap
    echo "$output"
    [[ "$output" == *"SKIP  routes: ip not found"* ]]
}

@test "routes: a live default route outside --mgmt-cidr is a FAIL; without --mgmt-cidr it is SKIPPED, never guessed" {
    default_route "default via 203.0.113.1 dev eth0 proto dhcp metric 100"
    run airgap --mgmt-cidr 198.51.100.0/24
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  routes: default via 203.0.113.1 dev eth0 is live and outside 198.51.100.0/24"* ]]
    run airgap
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  routes: default via 203.0.113.1 dev eth0 is live and no --mgmt-cidr"* ]]
}

@test "routes: a gateway inside --mgmt-cidr PASSes and says whose policy it is" {
    default_route "default via 198.51.100.1 dev eth0 proto static"
    run airgap --mgmt-cidr 198.51.100.0/24
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  routes: default via 198.51.100.1 dev eth0, a gateway inside 198.51.100.0/24"* ]]
}

@test "routes: a default route on a downed link is a WARN — the gap is physical only" {
    default_route "default via 203.0.113.1 dev eth0 proto dhcp linkdown"
    run airgap --mgmt-cidr 198.51.100.0/24
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"WARN  routes: default via 203.0.113.1 dev eth0, link down"* ]]
    default_route "default via 203.0.113.1 dev eth0 proto dhcp" down
    run airgap --mgmt-cidr 198.51.100.0/24
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"WARN  routes: default via 203.0.113.1 dev eth0, link down"* ]]
}

@test "routes: an unreachable, blackhole or prohibit default is good posture and PASSes" {
    for t in unreachable blackhole prohibit; do
        default_route "$t default proto static metric 1024"
        run airgap --mgmt-cidr 198.51.100.0/24
        echo "$output"
        [ "$status" -eq 0 ]
        [[ "$output" == *"PASS  routes: $t default — the kernel drops off-lab traffic itself"* ]]
    done
}

@test "routes: a live IPv6 default (a router advertisement's link-local gateway) is a FAIL that says IPv6" {
    default_route "" up "default via fe80::1 dev eth0 proto ra metric 1024 expires 1799sec pref medium"
    run airgap --mgmt-cidr 198.51.100.0/24
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  routes: IPv6 default via fe80::1 dev eth0 is live"*"IPv6AcceptRA=no"* ]]
    [[ "$output" != *"outside 198.51.100.0/24"* ]]
}
