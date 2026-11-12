#!/usr/bin/env bats
#
# staging/ is the kit's own bundle pipeline: preflight, fetch, the one-command
# builder and the verifier. What this suite proves: they run as a set from this
# directory, the fetch ships the kit as its one tree, --pack carries only
# themselves and the kit, and the verifier gates a bundle as the fetch leaves it.
# tests/no-legacy-manifest.bats proves the R770 side never calls them.

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

# a kit-shaped checkout: what KIT_SRC_ROOT names when --pack embeds the kit
fake_kit() {
    local r="$BATS_TEST_TMPDIR/kit"
    mkdir -p "$r/scripts/lib" "$r/config" "$r/scenarios" "$r/docs"
    echo '#!/bin/sh' > "$r/scripts/r770-install.sh"; echo '#!/bin/sh' > "$r/scripts/lib/common.sh"
    echo 'x' > "$r/config/x.conf"; echo 'x' > "$r/scenarios/x.conf"; echo '# doc' > "$r/docs/index.md"
    git -C "$r" init -q && git -C "$r" add -A && git -C "$r" -c user.email=t@t -c user.name=t commit -qm fixture
    printf '%s' "$r"
}

# payload_list <packed builder> -- the file names inside its base64 payload
payload_list() {
    sed -n "/^base64 -d <<'R770_PAYLOAD'/,/^R770_PAYLOAD$/p" "$1" | sed '1d;$d' | base64 -d | tar tz
}

@test "--pack with a kit checkout emits a valid builder: the four scripts and kit.tar, no site/" {
    KIT_SRC_ROOT=$(fake_kit) run ./staging/r770-build-bundle.sh --pack
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" > "$BATS_TEST_TMPDIR/packed.sh"
    run bash -n "$BATS_TEST_TMPDIR/packed.sh"
    [ "$status" -eq 0 ]
    run payload_list "$BATS_TEST_TMPDIR/packed.sh"
    echo "$output"
    [ "$status" -eq 0 ]
    for f in r770-build-bundle.sh r770-staging-preflight.sh r770-offline-fetch.sh r770-bundle.sh kit.tar; do
        [[ $'\n'"$output"$'\n' == *$'\n'"$f"$'\n'* ]] || { echo "payload lacks $f"; false; }
    done
    [[ "$output" != *"site"* ]]
    grep -q '^export KIT_ARCHIVE=' "$BATS_TEST_TMPDIR/packed.sh"
    run grep -c 'SITE_' "$BATS_TEST_TMPDIR/packed.sh"
    [ "$output" = "0" ]
}

@test "--pack refuses without KIT_SRC_ROOT: a pack with no kit cannot build a gated bundle" {
    run env -u KIT_SRC_ROOT ./staging/r770-build-bundle.sh --pack
    [ "$status" -eq 1 ]
    [[ "$output" == *"KIT_SRC_ROOT"* ]]
    [[ "$output" != *"R770_PAYLOAD"* ]]
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

@test "the fetch asks the GNS3 registry for the Alpine definition under its current name" {
    # The registry renamed the definition; the old name is a 404 and one WARN,
    # which fails the builder's strict gate (rehearsal 2026-11-10).
    run grep -E '^[[:space:]]+vyos .* alpine-linux-virt ' staging/r770-offline-fetch.sh
    [ "$status" -eq 0 ]
    run grep -E '(^|[[:space:]])alpine-linux([[:space:]]|$)' staging/r770-offline-fetch.sh
    [ "$status" -ne 0 ]
}

@test "the fetch's help names no SITE_ variable" {
    run ./staging/r770-offline-fetch.sh --help
    [ "$status" -eq 0 ]
    [[ "$output" != *"SITE_"* ]]
}

@test "A8: the fetch stages no definition whose image the bundle cannot carry" {
    defs=$(sed -n '/^GNS3A_DEFS=(/,/^)/p' staging/r770-offline-fetch.sh)
    [ -n "$defs" ]
    for d in cisco-iosv cisco-iosvl2 cisco-asav fortigate pan-vm-fw; do
        if grep -qw -- "$d" <<< "$defs"; then echo "still listed: $d"; false; fi
    done
    for d in vyos mikrotik-chr opnsense frr alpine-linux-virt tinycore-linux openwrt; do
        grep -qw -- "$d" <<< "$defs" || { echo "lost: $d"; false; }
    done
}
