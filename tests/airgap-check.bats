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

@test "an air-gapped host passes, with the unbuilt phases SKIPPED by name" {
    run airgap
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  apt: every index target is file:"* ]]
    [[ "$output" == *"PASS  snapd not installed"* ]]
    [[ "$output" == *"SKIP  dnsmasq: not installed (Phase 5 not built)"* ]]
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
