#!/usr/bin/env bats
#
# staging/ carries the build repo's four bundle-building scripts BYTE FOR
# BYTE. Their behaviour is tested in the build repo; what this suite proves
# is identity (the provenance hashes), that they still run as a set from this
# directory, and that the R770 side never calls them.

load helpers/fixtures

setup() { cd "$BATS_TEST_DIRNAME/.."; }

@test "every carried file matches the hash recorded in PROVENANCE.txt" {
    n=0
    while read -r sum name; do
        [ -n "$name" ] || continue
        n=$((n + 1))
        have=$(sha256sum "staging/$name" | cut -d' ' -f1)
        [ "$have" = "$sum" ] || { echo "staging/$name differs from its recorded hash — resync from the build repo, never edit here (docs/kit-sync.md)"; false; }
    done < <(grep -E '^[0-9a-f]{64}  ' staging/PROVENANCE.txt)
    [ "$n" -eq 4 ]
    grep -qE '^commit: [0-9a-f]{40}$' staging/PROVENANCE.txt
}

@test "the four scripts are executable and nothing else executable lives beside them" {
    for f in r770-staging-preflight.sh r770-offline-fetch.sh r770-build-bundle.sh r770-bundle.sh; do
        [ -x "staging/$f" ] || { echo "missing or not executable: staging/$f"; false; }
    done
    run find staging -maxdepth 1 -name '*.sh' -printf '%f\n'
    [ "$(printf '%s\n' "$output" | sort | tr '\n' ' ')" = "r770-build-bundle.sh r770-bundle.sh r770-offline-fetch.sh r770-staging-preflight.sh " ]
}

@test "the one-command builder prints its usage from this directory" {
    run ./staging/r770-build-bundle.sh --help
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"one command, one verified bundle"* ]]
}

@test "--pack emits a valid self-extracting builder carrying all four scripts" {
    run ./staging/r770-build-bundle.sh --pack
    [ "$status" -eq 0 ]
    printf '%s' "$output" > "$BATS_TEST_TMPDIR/packed.sh"
    for s in r770-build-bundle.sh r770-staging-preflight.sh r770-offline-fetch.sh r770-bundle.sh; do
        grep -q "$s" "$BATS_TEST_TMPDIR/packed.sh"
    done
    run bash -n "$BATS_TEST_TMPDIR/packed.sh"
    [ "$status" -eq 0 ]
}

@test "the carried verifier still round-trips a fixture bundle: manifest, then verify PASS" {
    B="$BATS_TEST_TMPDIR/bundle-fixture"
    make_bundle "$B"; stage_manual "$B"
    rm "$B/r770-bundle.sh" "$B/MANIFEST.sha256"          # the fixture's stub verifier and fake manifest
    cp staging/r770-bundle.sh "$B/"                       # what the fetch does: the verifier travels in the root
    run ./staging/r770-bundle.sh manifest "$B"
    echo "$output"
    [ "$status" -eq 0 ]
    run ./staging/r770-bundle.sh verify "$B"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RESULT: PASS"* ]]
}

@test "a packed builder left in the tree is gitignored (base64 hides the pins from the guard)" {
    run env GIT_CONFIG_GLOBAL=/dev/null git -c core.excludesFile=/dev/null check-ignore -q r770-bundle-builder.sh
    [ "$status" -eq 0 ]
}
