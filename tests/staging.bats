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

# ── the preflight's room checks ─────────────────────────────────────────────
# Run under the stubbed PATH: docker, df and the host probes answer from knobs,
# egress is skipped, and nothing reaches a real engine. STORE_* describe the
# image store, BUNDLE_* the bundle directory's filesystem (df -Pk, in KiB).
preflight_env() {
    load helpers/stubs
    kit_test_env
    export PF_STORE="$BATS_TEST_TMPDIR/store"; mkdir -p "$PF_STORE"
    export PF_BUNDLE="$BATS_TEST_TMPDIR/bundle"; mkdir -p "$PF_BUNDLE"
    printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$BATS_TEST_TMPDIR/os-release"
    stub docker '
case "$*" in
    --version)                            echo "Docker version 0.0.0-fixture" ;;
    "info --format {{.DockerRootDir}}")   echo "${STORE_ROOT-$PF_STORE}" ;;
    "info --format {{.OperatingSystem}}") echo "${ENGINE_OS:-Ubuntu 24.04 LTS}" ;;
    info)                                 exit 0 ;;
esac'
    stub df '
if [ "${!#}" = "$PF_STORE" ]; then k=${STORE_K:-209715200}; m=${STORE_MNT:-/var/lib/docker}
else k=${BUNDLE_K:-209715200}; m=${BUNDLE_MNT:-/}; fi
printf "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x 1 1 %s 1%% %s\n" "$k" "$m"'
    stub systemd-detect-virt 'echo kvm'
    stub curl 'exit 0'; stub pigz 'exit 0'
}
preflight() {
    PREFLIGHT_OS_RELEASE="$BATS_TEST_TMPDIR/os-release" PREFLIGHT_BUNDLE_DIR="$PF_BUNDLE" \
        PREFLIGHT_SKIP_EGRESS=1 kit_run ./staging/r770-staging-preflight.sh
}

@test "preflight: an image store on its own filesystem with too little room is a refusal" {
    preflight_env
    STORE_K=$((20 * 1024 * 1024)) run preflight
    echo "$output"; [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  only 20 GB free on docker's image store $PF_STORE (/var/lib/docker) — need at least 60 GB"* ]]
    [[ "$output" == *"PASS  200 GB free on $PF_BUNDLE"* ]]
}

@test "preflight: an image store on its own filesystem with room passes, and one sharing the bundle's is covered once" {
    preflight_env
    run preflight
    echo "$output"; [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  200 GB free on docker's image store $PF_STORE (/var/lib/docker; need 60)"* ]]
    STORE_MNT=/ STORE_K=1 run preflight
    echo "$output"; [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  docker's image store $PF_STORE shares $PF_BUNDLE's filesystem (/) — the room above covers both"* ]]
}

@test "preflight: a store it cannot see (Docker Desktop, a path not on this host) is a WARN naming where to look, never a PASS" {
    preflight_env
    ENGINE_OS="Docker Desktop" run preflight
    echo "$output"; [ "$status" -eq 2 ]
    [[ "$output" == *"WARN  docker's image store ($PF_STORE, Docker Desktop) is not on this host's filesystem"*"Disk image location"* ]]
    ! grep -q '^PASS .*image store' <<< "$output"
    STORE_ROOT="$BATS_TEST_TMPDIR/not-here" run preflight
    [ "$status" -eq 2 ]; [[ "$output" == *"WARN  docker's image store ($BATS_TEST_TMPDIR/not-here, Ubuntu 24.04 LTS) is not on this host's filesystem"* ]]
    STORE_ROOT="" run preflight
    [ "$status" -eq 2 ]; [[ "$output" == *"WARN  cannot ask docker where it keeps images"* ]]
}
