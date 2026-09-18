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

@test "every script's --help prints its whole header and no shell code" {
    # The end of the usage text is FOUND, never declared. A hardcoded last
    # line silently truncates --help the moment a line is added above it,
    # which it did: four scripts shipped a help that stopped mid-sentence,
    # and r770-deploy.sh printed `set -uo pipefail` as its closing line.
    for f in scripts/r770-*.sh; do
        run bash "$f" --help
        [ "$status" -eq 0 ] || { echo "$f: --help exited $status"; false; }
        [[ "$output" != *"set -uo pipefail"* ]] || { echo "$f: --help leaks shell code"; false; }
        last=$(awk 'NR >= 3 && $0 !~ /^#/ { print NR - 1; exit }' "$f")
        want=$(sed -n "${last}p" "$f" | sed 's/^# \{0,1\}//')
        [[ "$output" == *"$want"* ]] || { echo "$f: --help truncated; missing final header line: $want"; false; }
    done
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
