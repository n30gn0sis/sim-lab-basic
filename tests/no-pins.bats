#!/usr/bin/env bats
#
# The kit carries NO version pins outside their one owner. That owner is
# staging/r770-offline-fetch.sh -- the build repo's fetch script, carried
# byte-identical (tests/staging.bats) with its pin block -- exactly as the
# build repo's OWNERS.md says. Everywhere else a pin would be a copy nothing
# updates on the next bump, which is the drift that registry was written to
# stop. Fixtures use 0.0.0-fixture, IPs are not versions, and the clean build
# image `ubuntu:24.04` the preflight names is a decision of record, not a pin.

setup() { cd "$BATS_TEST_DIRNAME/.."; }

OWNER='staging/r770-offline-fetch.sh'
EXCL=(--exclude-dir=.git --exclude-dir=r770-evidence --exclude=r770-offline-fetch.sh --exclude=PROVENANCE.txt)

# tokens <regex> — every match across the tracked tree minus the owner, one per line
tokens() {
    grep -rhoE "$1" "${EXCL[@]}" . | sort -u
}

@test "the pin owner exists and is the only file allowed to carry the pin block" {
    grep -q '# ── pins: review each refresh cycle' "$OWNER"
    run grep -rl 'pins: review each refresh cycle' --exclude-dir=.git --exclude-dir=tests .
    [ "$output" = "./$OWNER" ]
}

@test "no three-part version number anywhere (IPs and 0.0.0-fixture excepted)" {
    bad=""
    while read -r t; do
        [ -n "$t" ] || continue
        case "$t" in
            *.*.*.*) continue ;;                         # dotted quad: an address
            *fixture*) continue ;;                       # synthetic
        esac
        bad="$bad $t"
    done < <(tokens '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)*([-.][a-z]+)?')
    echo "pins found:$bad"
    [ -z "$bad" ]
}

@test "no vX.Y-style tag anywhere (TLS protocol names and fixtures excepted)" {
    bad=""
    while read -r t; do
        [ -n "$t" ] || continue
        case "$t" in
            TLSv*|*fixture*) continue ;;
        esac
        bad="$bad $t"
    done < <(tokens '[A-Za-z]*v[0-9]+\.[0-9]+(\.[0-9]+)?(-[a-z]+)?')
    echo "tags found:$bad"
    [ -z "$bad" ]
}

@test "no file names a Malcolm artifact by version" {
    run grep -rnE 'malcolm-[0-9]' "${EXCL[@]}" --exclude-dir=tests .
    echo "$output"
    [ "$status" -ne 0 ]
}

@test "no image reference carries a literal numeric tag" {
    # repo/name:1.2 or name:v1 forms; registry:2 is a floating major, allowed by name
    run grep -rnE '[a-z0-9./-]+/[a-z0-9-]+:v?[0-9]+\.[0-9]+' "${EXCL[@]}" --exclude-dir=tests .
    echo "$output"
    out=$(printf '%s\n' "$output" | grep -v fixture | grep -v 'library/ubuntu:24\.04' || true)
    [ -z "$out" ]
}
