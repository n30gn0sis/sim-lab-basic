#!/usr/bin/env bats
#
# The shared library is the one place every seam lives, so its contract is
# tested once, here: KIT_ROOT redirection, dry-run, gates, rendering,
# assert-then-edit, image-list handling, and the rule that the verifier is
# the bundle's own copy.

load helpers/fixtures
load helpers/stubs

setup() {
    kit_test_env
    LIB="$BATS_TEST_DIRNAME/../scripts/lib/common.sh"
    BUNDLE="$BATS_TEST_TMPDIR/bundle-fixture"
    make_bundle "$BUNDLE"
    make_root "$ROOT"
}

# lib <bash snippet> — run a snippet with the library sourced, under the
# replacement PATH, in a fresh shell (so die/exit are observable).
lib() { kit_run bash -c "set -uo pipefail; . '$LIB'; kit_init test; $1"; }

@test "p() prefixes every absolute path with KIT_ROOT" {
    run lib 'p /etc/apt/sources.list'
    [ "$output" = "$ROOT/etc/apt/sources.list" ]
}

@test "run() executes normally and prints the command" {
    run lib 'run touch "$(p /srv/marker)"'
    echo "$output"
    [ "$status" -eq 0 ]
    [ -e "$ROOT/srv/marker" ]
    [[ "$output" == *"+ touch"* ]]
}

@test "run() under KIT_DRY_RUN=1 prints and does NOT execute" {
    export KIT_DRY_RUN=1
    run lib 'run touch "$(p /srv/marker)"'
    echo "$output"
    [ "$status" -eq 0 ]
    [ ! -e "$ROOT/srv/marker" ]
    [[ "$output" == *"DRY-RUN:"* ]]
}

@test "gate() refuses a non-interactive run that has not said --yes" {
    unset KIT_YES
    run lib 'cur() { echo now; }; pro() { echo later; }; gate "thing" cur pro "undo it"; echo REACHED'
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" != *"REACHED"* ]]
    [[ "$output" == *"non-interactive"* ]]
}

@test "gate() with --yes proceeds after printing current, proposed and rollback" {
    run lib 'cur() { echo NOW-STATE; }; pro() { echo LATER-STATE; }; gate "thing" cur pro "UNDO-TEXT"; echo REACHED'
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"-- current --"*"NOW-STATE"*"-- proposed --"*"LATER-STATE"*"-- rollback --"*"UNDO-TEXT"*"REACHED"* ]]
}

@test "render() fills every token and refuses when one survives" {
    printf 'ip=__MGMT_IP__ name=__NAME__\n' > "$BATS_TEST_TMPDIR/t.tpl"
    run lib "render '$BATS_TEST_TMPDIR/t.tpl' '$ROOT/out.txt' MGMT_IP=10.0.0.1 NAME=r770"
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(cat "$ROOT/out.txt")" = "ip=10.0.0.1 name=r770" ]

    run lib "render '$BATS_TEST_TMPDIR/t.tpl' '$ROOT/out2.txt' MGMT_IP=10.0.0.1"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"__NAME__"* ]]
    [ ! -e "$ROOT/out2.txt" ]
}

@test "render() survives values containing sed metacharacters" {
    printf 'pw=__PW__\n' > "$BATS_TEST_TMPDIR/t.tpl"
    run lib "render '$BATS_TEST_TMPDIR/t.tpl' '$ROOT/out.txt' 'PW=a|b&c/d'"
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(cat "$ROOT/out.txt")" = 'pw=a|b&c/d' ]
}

@test "assert_edit() refuses a file whose shape is not the one expected" {
    printf 'a\nb\nb\n' > "$ROOT/f"
    run lib "assert_edit '$ROOT/f' '^b$' 1"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"found 2"* ]]
    run lib "assert_edit '$ROOT/f' '^a$' 1"
    [ "$status" -eq 0 ]
}

@test "assert_image_tags() never reports success for a missing list" {
    stub docker 'exit 0'
    run lib "assert_image_tags '$BUNDLE/malcolm/no-such-list.txt'"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" != *"all images present"* ]]
}

@test "assert_image_tags() names the missing tag and fails" {
    stub docker 'if [ "$1" = image ] && [ "$2" = ls ]; then echo ghcr.io/idaholab/malcolm/arkime:0.0.0-fixture; fi; exit 0'
    run lib "assert_image_tags '$BUNDLE/malcolm/image-list.txt'"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MISSING ghcr.io/idaholab/malcolm/nginx-proxy:0.0.0-fixture"* ]]
    [[ "$output" != *"all images present"* ]]
}

@test "image_ref_from_list() finds by repository name regardless of position" {
    run lib "image_ref_from_list '$BUNDLE/malcolm/image-list.txt' arkime"
    [ "$output" = "ghcr.io/idaholab/malcolm/arkime:0.0.0-fixture" ]
    run lib "image_ref_from_list '$BUNDLE/malcolm/image-list.txt' nginx-proxy"
    [ "$output" = "ghcr.io/idaholab/malcolm/nginx-proxy:0.0.0-fixture" ]
}

@test "image_ref_from_list() dies on zero or two matches" {
    run lib "image_ref_from_list '$BUNDLE/malcolm/image-list.txt' loki"
    echo "$output"
    [ "$status" -eq 1 ]
    printf 'a/x:1-fixture\nb/x:2-fixture\n' > "$BATS_TEST_TMPDIR/dup.txt"
    run lib "image_ref_from_list '$BATS_TEST_TMPDIR/dup.txt' x"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"2 images"* ]]
}

@test "bundle_verify() runs the verifier that travels IN the bundle, and reports its RESULT line" {
    export FIXTURE_VERIFY_LOG="$BATS_TEST_TMPDIR/verify.log"
    run lib "bundle_verify '$BUNDLE'"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q "^r770-bundle.sh verify $BUNDLE" "$FIXTURE_VERIFY_LOG"
    [[ "$output" == *"verifier exit 0: RESULT: PASS"* ]]
    [[ "$output" != *"sha256sum -c"* ]]
}

@test "bundle_verify() passes the verifier's exit code through untouched" {
    export FIXTURE_VERIFY_RC=2
    run lib "bundle_verify '$BUNDLE'"
    [ "$status" -eq 2 ]
    export FIXTURE_VERIFY_RC=1
    run lib "bundle_verify '$BUNDLE'"
    [ "$status" -eq 1 ]
}

@test "bundle_dir() rejects a directory with no verifier in its root" {
    rm "$BUNDLE/r770-bundle.sh"
    run lib "bundle_dir '$BUNDLE'"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"r770-bundle.sh"* ]]
}

@test "secret_file() generates once, never prints the value, and is idempotent" {
    run lib "secret_file '$ROOT/etc/lab/secrets/x.pw'"
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "$ROOT/etc/lab/secrets/x.pw")" = "600" ]
    [ "$(stat -c %a "$ROOT/etc/lab/secrets")" = "700" ]
    v=$(head -1 "$ROOT/etc/lab/secrets/x.pw")
    [ "${#v}" -eq 32 ]
    [[ "$output" != *"$v"* ]]
    run lib "secret_file '$ROOT/etc/lab/secrets/x.pw'"
    [[ "$output" == *"secret present"* ]]
    [ "$(head -1 "$ROOT/etc/lab/secrets/x.pw")" = "$v" ]
}

@test "help_has_flags() dies naming the flag the bundled tool no longer advertises" {
    stub tool 'echo "usage: tool [--alpha] [--beta]"'
    run lib "help_has_flags tool -- --alpha --beta"
    [ "$status" -eq 0 ]
    run lib "help_has_flags tool -- --alpha --gamma"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"--gamma"* ]]
    [[ "$output" == *"BUNDLE_NOTES.md"* ]]
}

@test "footer() maps counters to the 0/2/1 contract" {
    run lib 'pass a; footer'
    [ "$status" -eq 0 ]; [[ "$output" == *"READY —"* ]]
    run lib 'pass a; warn b; footer'
    [ "$status" -eq 2 ]; [[ "$output" == *"READY WITH WARNINGS"* ]]
    run lib 'warn b; fail c; footer'
    [ "$status" -eq 1 ]; [[ "$output" == *"NOT READY"* ]]
}

@test "bridge_physical_ports() follows lower devices: a VLAN and a bond over physical NICs count, a veth does not" {
    s="$ROOT/sys/class/net"
    mkdir -p "$s/br-x/bridge" "$s/br-x/brif" "$s/eno1/device" "$s/eno2/device" \
             "$s/eno1.100" "$s/bond0" "$s/veth0" "$s/loopa" "$s/loopb"
    ln -s ../eno1 "$s/eno1.100/lower_eno1"
    ln -s ../eno2 "$s/bond0/lower_eno2"
    ln -s ../loopb "$s/loopa/lower_loopb"      # a lower-device cycle must terminate
    ln -s ../loopa "$s/loopb/lower_loopa"
    touch "$s/br-x/brif/eno1.100" "$s/br-x/brif/bond0" "$s/br-x/brif/veth0" "$s/br-x/brif/loopa"
    run lib 'bridge_physical_ports br-x'
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$output" = "bond0 eno1.100" ]
    run lib 'bridge_physical_ports br-none'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
