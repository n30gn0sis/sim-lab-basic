#!/usr/bin/env bats
#
# The runner's value is ORDER and REFUSAL, so that is what these test. Every
# child is a stub that records the stage it was called for; the suite
# imports nothing, reaches no daemon, deploys nothing.

load helpers/stubs

setup() {
    kit_test_env
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-deploy.sh"
    ORDER="$BATS_TEST_TMPDIR/order.log"; : > "$ORDER"
    export DEPLOY_ORDER_LOG="$ORDER"
    BUNDLE="$BATS_TEST_TMPDIR/media/bundle-fixture"; mkdir -p "$BUNDLE"
    for st in preflight gate copy apt phone-home docker images files gns3 malcolm portal monitoring validate airgap; do child "$st" 0; done
}

# child <stage> <exit> — records "<stage> <subcommand> <args>" and exits <exit>
child() {
    local var="DEPLOY_$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')_CMD"
    printf '#!/usr/bin/env bash\necho "$DEPLOY_STAGE $*" >> "$DEPLOY_ORDER_LOG"\n[ -n "${KIT_YES:-}" ] && echo "yes-seen" >> "$DEPLOY_ORDER_LOG.env"\nexit %s\n' "$2" > "$BIN/child-$1"
    chmod +x "$BIN/child-$1"
    export "$var=$BIN/child-$1"
}
order() { cut -d' ' -f1 "$ORDER" | uniq | tr '\n' ' '; }
deploy() { kit_run "$SCRIPT" --bundle "$BUNDLE" --mgmt-ip 10.10.10.31 "$@"; }

@test "--list prints the thirteen stages in order" {
    run kit_run "$SCRIPT" --list
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | tr '\n' ' ')" = "preflight gate copy apt phone-home docker images files gns3 malcolm portal monitoring validate" ]
}

@test "the happy path runs every stage, in order, and exits 0" {
    run deploy
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(order)" = "preflight gate copy apt phone-home docker images files gns3 malcolm portal monitoring validate " ]
    [[ "$output" == *"DEPLOYED — every stage clean"* ]]
}

@test "each stage calls the subcommands it is documented to, with the bundle" {
    run deploy
    grep -q "^gate gate --bundle $BUNDLE" "$ORDER"
    grep -q "^malcolm load --bundle" "$ORDER"; grep -q "^malcolm unpack --bundle" "$ORDER"; grep -q "^malcolm configure --bundle" "$ORDER"
    grep -q "^malcolm secrets$" "$ORDER"; grep -q "^malcolm auth --bundle" "$ORDER"; grep -q "^malcolm rebind$" "$ORDER"; grep -q "^malcolm start$" "$ORDER"
    grep -q "^gns3 venv --bundle" "$ORDER"; grep -q "^gns3 service$" "$ORDER"
    grep -q "^portal nginx$" "$ORDER"; grep -q "^portal portal --mgmt-ip 10.10.10.31" "$ORDER"; grep -q "^portal docs --bundle" "$ORDER"
    grep -q "^monitoring env --bundle" "$ORDER"; grep -q "^monitoring up$" "$ORDER"
    grep -q "^validate --area airgap" "$ORDER"
    m=$(grep -n '^malcolm start' "$ORDER" | cut -d: -f1); r=$(grep -n '^malcolm rebind' "$ORDER" | cut -d: -f1); a=$(grep -n '^malcolm auth' "$ORDER" | cut -d: -f1)
    [ "$a" -lt "$r" ] && [ "$r" -lt "$m" ]
}

@test "a failed gate stops BEFORE anything is copied" {
    child gate 1
    run deploy
    echo "$output"
    [ "$status" -eq 1 ]
    [ "$(order)" = "preflight gate " ]
    [[ "$output" == *"--from gate"* ]]
}

@test "a stage that warns stops an unattended run that has not accepted the warnings" {
    child gate 2
    unset KIT_YES
    run deploy --non-interactive
    echo "$output"
    [ "$status" -ne 0 ]
    [ "$(order)" = "preflight gate " ]
}

@test "warnings accepted with --yes are carried to the end as exit 2, never laundered" {
    child gate 2
    run deploy --yes
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"DEPLOYED WITH WARNINGS — stages: gate"* ]]
    [ "$(order)" = "preflight gate copy apt phone-home docker images files gns3 malcolm portal monitoring validate " ]
}

@test "--from skips the earlier stages and --only runs exactly one" {
    run deploy --from apt
    [ "$(order)" = "apt phone-home docker images files gns3 malcolm portal monitoring validate " ]
    : > "$ORDER"
    run deploy --only malcolm
    [ "$(order)" = "malcolm " ]
    : > "$ORDER"
    run deploy --from gns3 --to portal
    [ "$(order)" = "gns3 malcolm portal " ]
}

@test "--yes reaches the gated children through the environment" {
    run deploy --yes --only apt
    [ "$status" -eq 0 ]
    grep -q yes-seen "$ORDER.env"
}

@test "after copy, later stages use the bundle under /srv/bundles" {
    mkdir -p "$ROOT/srv/bundles/bundle-fixture"
    run deploy --only apt
    grep -q "^apt apt --bundle $ROOT/srv/bundles/bundle-fixture" "$ORDER"
}

@test "the portal stage refuses without --mgmt-ip rather than guessing" {
    run kit_run "$SCRIPT" --bundle "$BUNDLE" --only portal
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"--mgmt-ip"* ]]
}

@test "an unknown option, stage or a missing --bundle is rejected" {
    run kit_run "$SCRIPT" --bundle "$BUNDLE" --wat;      [ "$status" -eq 1 ]
    run kit_run "$SCRIPT" --bundle "$BUNDLE" --from nope; [ "$status" -eq 1 ]
    run kit_run "$SCRIPT";                                [ "$status" -eq 1 ]
}
