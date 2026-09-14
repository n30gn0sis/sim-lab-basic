#!/usr/bin/env bats
#
# Lint gate. Every script written for this kit must be shellcheck-clean at
# default severity with NO exclusions. The one exception is carried, not
# written: staging/r770-offline-fetch.sh is the build repo's fetch script,
# byte-identical to its source (tests/staging.bats), and it keeps the
# exclusion list the build repo accepted for it. No other file may use it.

LEGACY_EXCLUDE="SC2015,SC2012,SC2010,SC1091"   # build repo's tests/README.md explains each

setup() { cd "$BATS_TEST_DIRNAME/.."; }

@test "every kit script is shellcheck-clean with no exclusions" {
    run shellcheck -x scripts/*.sh scripts/lib/*.sh tests/run.sh
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "the carried staging scripts lint: three clean, the fetch script with its accepted list only" {
    run shellcheck staging/r770-staging-preflight.sh staging/r770-build-bundle.sh staging/r770-bundle.sh
    echo "$output"
    [ "$status" -eq 0 ]
    run shellcheck -e "$LEGACY_EXCLUDE" staging/r770-offline-fetch.sh
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "the test helpers are shellcheck-clean" {
    run shellcheck -s bash tests/helpers/*.bash
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "every shell script parses" {
    for f in scripts/*.sh scripts/lib/*.sh staging/*.sh tests/run.sh; do
        run bash -n "$f"
        echo "$f: $output"
        [ "$status" -eq 0 ]
    done
}

@test "every kit script is executable" {
    for f in scripts/*.sh staging/*.sh tests/run.sh; do
        [ -x "$f" ] || { echo "not executable: $f"; false; }
    done
}
