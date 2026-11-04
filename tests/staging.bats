#!/usr/bin/env bats
#
# staging/ carries the build repo's four bundle-building scripts BYTE FOR
# BYTE. Their behaviour is tested in the build repo; what this suite proves
# is identity (the provenance hashes), that they still run as a set from this
# directory, and that the R770 side never calls them.

load helpers/fixtures

setup() { cd "$BATS_TEST_DIRNAME/.."; }

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

# a simlab-build-shaped checkout: --pack now embeds a git archive of that
# repo's scripts/, config/, docs/analyst-wiki/, scenarios/ and images/ as the bundle's site/
fake_build_repo() {
    local r="$BATS_TEST_TMPDIR/simlab-build"
    mkdir -p "$r/scripts" "$r/config" "$r/docs/analyst-wiki" "$r/scenarios" "$r/images"
    echo '#!/bin/sh' > "$r/scripts/r770-offline-fetch.sh"
    echo 'x' > "$r/scenarios/x.conf"; echo 'x' > "$r/images/x"
    echo 'x' > "$r/config/x.conf"; echo '# wiki' > "$r/docs/analyst-wiki/index.md"
    git -C "$r" init -q && git -C "$r" add -A && git -C "$r" -c user.email=t@t -c user.name=t commit -qm fixture
    printf '%s' "$r"
}

@test "--pack refuses the kit's own tree: site/ must come from a simlab-build checkout, never from this kit" {
    run ./staging/r770-build-bundle.sh --pack
    [ "$status" -ne 0 ]
    [[ "$output" == *"docs/analyst-wiki"* ]]
}

@test "--pack emits a valid self-extracting builder carrying all four scripts" {
    BUILD_PACK_ROOT=$(fake_build_repo) run ./staging/r770-build-bundle.sh --pack
    [ "$status" -eq 0 ]
    printf '%s' "$output" > "$BATS_TEST_TMPDIR/packed.sh"
    for s in r770-build-bundle.sh r770-staging-preflight.sh r770-offline-fetch.sh r770-bundle.sh; do
        grep -q "$s" "$BATS_TEST_TMPDIR/packed.sh"
    done
    run bash -n "$BATS_TEST_TMPDIR/packed.sh"
    [ "$status" -eq 0 ]
}

# a fixture bundle as the fetch leaves it: the real verifier in the root and
# kit/ carrying what the verifier requires. There is no site/: the fetch no
# longer has that stage.
real_bundle() {
    local B="$1" f
    make_bundle "$B"; stage_manual "$B"
    rm "$B/r770-bundle.sh" "$B/MANIFEST.sha256"          # the fixture's stub verifier and fake manifest
    cp staging/r770-bundle.sh "$B/"                       # what the fetch does: the verifier travels in the root
    for f in $(sed -n 's/^KIT_REQUIRED_FILES=(\(.*\))$/\1/p' staging/r770-bundle.sh); do
        mkdir -p "$B/kit/$(dirname "$f")"; echo '#!/bin/sh' > "$B/kit/$f"
    done
    [ -s "$B/kit/scripts/r770-install.sh" ]
}

@test "the verifier round-trips a bundle with kit/ and no site/: manifest, then verify --strict PASS" {
    B="$BATS_TEST_TMPDIR/bundle-fixture"
    real_bundle "$B"
    run ./staging/r770-bundle.sh manifest "$B"
    echo "$output"
    [ "$status" -eq 0 ]
    run ./staging/r770-bundle.sh verify "$B" --strict
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RESULT: PASS"* ]]
    [[ "$output" != *"site/"* ]]
}

@test "an older bundle that still carries site/ verifies: nothing asks about it, the manifest covers it" {
    B="$BATS_TEST_TMPDIR/bundle-fixture"
    real_bundle "$B"
    mkdir -p "$B/site/scripts"; echo '#!/bin/sh' > "$B/site/scripts/anything.sh"
    run ./staging/r770-bundle.sh manifest "$B"
    [ "$status" -eq 0 ]
    run ./staging/r770-bundle.sh verify "$B" --strict
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RESULT: PASS"* ]]
}

@test "a bundle without kit/ still fails the strict gate" {
    B="$BATS_TEST_TMPDIR/bundle-fixture"
    real_bundle "$B"
    rm -rf "$B/kit"
    run ./staging/r770-bundle.sh manifest "$B"
    [ "$status" -eq 0 ]
    run ./staging/r770-bundle.sh verify "$B" --strict
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"kit/ is missing"* ]]
}

@test "a packed builder left in the tree is gitignored (base64 hides the pins from the guard)" {
    run env GIT_CONFIG_GLOBAL=/dev/null git -c core.excludesFile=/dev/null check-ignore -q r770-bundle-builder.sh
    [ "$status" -eq 0 ]
}

@test "the fetch's --list runs from this kit's tree and names no site or labimages stage" {
    BUNDLE_DIR="$BATS_TEST_TMPDIR/b" run ./staging/r770-offline-fetch.sh --list
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"  kit "* ]]
    [[ "$output" != *"site"* ]]
    [[ "$output" != *"labimages"* ]]
}

@test "the fetch's --dry-run plans no lab image build, and the old stage names are unknown" {
    BUNDLE_DIR="$BATS_TEST_TMPDIR/b" run ./staging/r770-offline-fetch.sh --dry-run
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" != *"lab-images"* ]]
    for s in site labimages; do
        run ./staging/r770-offline-fetch.sh --only "$s" --dry-run
        [ "$status" -eq 1 ]
        [[ "$output" == *"unknown stage '$s'"* ]]
    done
}

@test "the fetch's help names no SITE_ variable" {
    run ./staging/r770-offline-fetch.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" != *"SITE_"* ]]
}
