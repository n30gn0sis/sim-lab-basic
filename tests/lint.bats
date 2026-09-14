#!/usr/bin/env bats
#
# Lint gate. Every script in this kit was written under the gate, so all of
# them must be shellcheck-clean at default severity with NO exclusions. There
# is no legacy list here and there must never be one.

setup() { cd "$BATS_TEST_DIRNAME/.."; }

@test "every kit script is shellcheck-clean with no exclusions" {
    run shellcheck -x scripts/*.sh scripts/lib/*.sh tests/run.sh
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "the test helpers are shellcheck-clean" {
    run shellcheck -s bash tests/helpers/*.bash
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "every shell script parses" {
    for f in scripts/*.sh scripts/lib/*.sh tests/run.sh; do
        run bash -n "$f"
        echo "$f: $output"
        [ "$status" -eq 0 ]
    done
}

@test "every kit script is executable" {
    for f in scripts/*.sh tests/run.sh; do
        [ -x "$f" ] || { echo "not executable: $f"; false; }
    done
}
