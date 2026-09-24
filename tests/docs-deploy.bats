#!/usr/bin/env bats
#
# The analyst wiki's own pipeline. The build must never reach a network, never
# leave docs.lab serving nothing, and never take `docker load`'s word that the
# image arrived.

load helpers/fixtures
load helpers/stubs

MKDOCS=docker.io/squidfunk/mkdocs-material:latest

setup() {
    kit_test_env
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-docs-deploy.sh"
    BUNDLE="$BATS_TEST_TMPDIR/bundle-fixture"
    make_bundle "$BUNDLE"
    make_root "$ROOT"
    export ROOT
    unset DOCKER_RUN_RC
}

docs() { kit_run "$SCRIPT" "$@"; }

# stub_docker — `docker image ls` reports the fixture's mkdocs image only once
# `docker load` has "loaded" it (or from the start with PRELOADED=1);
# `docker run ... <dir>:/docs <img> build` writes a two-page site into
# <dir>/site, or exits $DOCKER_RUN_RC when that is set non-zero.
stub_docker() {
    echo "$MKDOCS" > "$BATS_TEST_TMPDIR/would-be-present.txt"
    if [ "${PRELOADED:-0}" = "1" ]; then
        cp "$BATS_TEST_TMPDIR/would-be-present.txt" "$BATS_TEST_TMPDIR/present.txt"
    else
        : > "$BATS_TEST_TMPDIR/present.txt"
    fi
    stub docker 'echo "docker $*" >> "$STUB_LOG"
case "$1" in
  image) [ "$2" = ls ] && cat "$BATS_TEST_TMPDIR/present.txt" 2>/dev/null ;;
  load)  cp "$BATS_TEST_TMPDIR/would-be-present.txt" "$BATS_TEST_TMPDIR/present.txt" ;;
  run)   [ "${DOCKER_RUN_RC:-0}" = 0 ] || exit "$DOCKER_RUN_RC"
         for a in "$@"; do case "$a" in *:/docs) d="${a%%:/docs}"; mkdir -p "$d/site/guide"
             echo "<html>built</html>" > "$d/site/index.html"; echo "<html>guide</html>" > "$d/site/guide/index.html";; esac; done ;;
esac
exit 0'
}

# ── load / assert-tags ─────────────────────────────────────────────────────

@test "assert-tags passes when the mkdocs image is present" {
    PRELOADED=1 stub_docker
    run docs assert-tags --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok      $MKDOCS"* ]]
}

@test "assert-tags FAILS naming the missing image" {
    stub_docker
    run docs assert-tags --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MISSING $MKDOCS"* ]]
}

@test "load runs docker load on the bundle's tarball, asserts the tags, and a second load is skipped" {
    stub_docker
    run docs load --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q "^docker load -i $BUNDLE/docker/monitoring-images.tar.gz" "$STUB_LOG"
    [[ "$output" == *"all images present"* ]]
    : > "$STUB_LOG"
    run docs load --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    ! grep -q '^docker load' "$STUB_LOG"
    [[ "$output" == *"load skipped"* ]]
}

@test "load refuses when docker is not installed" {
    run docs load --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"docker is not installed"* ]]
}

@test "load refuses a bundle without the tarball" {
    stub_docker
    rm "$BUNDLE/docker/monitoring-images.tar.gz"
    run docs load --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no docker/monitoring-images.tar.gz"* ]]
    ! grep -q '^docker load' "$STUB_LOG"
}

# ── build ──────────────────────────────────────────────────────────────────

@test "build runs mkdocs with --network none and publishes /srv/www/docs" {
    PRELOADED=1 stub_docker
    run docs build --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q "^docker run --rm --network none -v .*:/docs $MKDOCS build" "$STUB_LOG"
    [ "$(cat "$ROOT/srv/www/docs/index.html")" = "<html>built</html>" ]
    [[ "$output" == *"PASS  wiki built into /srv/www/docs (2 pages)"* ]]
    [ ! -e "$ROOT/srv/www/docs.new" ]
    [ ! -e "$ROOT/srv/www/docs.prev" ]
}

@test "build replaces the whole previous site rather than overlaying it" {
    PRELOADED=1 stub_docker
    mkdir -p "$ROOT/srv/www/docs"
    echo "<html>old</html>" > "$ROOT/srv/www/docs/index.html"
    echo "<html>retired</html>" > "$ROOT/srv/www/docs/retired.html"
    run docs build --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(cat "$ROOT/srv/www/docs/index.html")" = "<html>built</html>" ]
    [ ! -e "$ROOT/srv/www/docs/retired.html" ]
    [ ! -e "$ROOT/srv/www/docs.new" ]
    [ ! -e "$ROOT/srv/www/docs.prev" ]
}

@test "a failed build leaves the live site untouched" {
    PRELOADED=1 stub_docker
    export DOCKER_RUN_RC=1
    mkdir -p "$ROOT/srv/www/docs"
    echo "<html>old</html>" > "$ROOT/srv/www/docs/index.html"
    run docs build --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"mkdocs build failed"* ]]
    [ "$(cat "$ROOT/srv/www/docs/index.html")" = "<html>old</html>" ]
    [ ! -e "$ROOT/srv/www/docs.new" ]
}

@test "build clears a stale docs.new and docs.prev left by an interrupted run" {
    PRELOADED=1 stub_docker
    mkdir -p "$ROOT/srv/www/docs.new" "$ROOT/srv/www/docs.prev"
    touch "$ROOT/srv/www/docs.new/half-copied.html" "$ROOT/srv/www/docs.prev/old.html"
    run docs build --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [ ! -e "$ROOT/srv/www/docs.new" ]
    [ ! -e "$ROOT/srv/www/docs.prev" ]
    [ "$(cat "$ROOT/srv/www/docs/index.html")" = "<html>built</html>" ]
}

@test "build refuses a bundle whose list has no mkdocs image" {
    PRELOADED=1 stub_docker
    printf 'docker.io/library/busybox:0.0.0-fixture\n' > "$BUNDLE/docker/monitoring-image-list.txt"
    run docs build --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no image named 'mkdocs-material'"* ]]
    ! grep -q '^docker run' "$STUB_LOG"
}

@test "build refuses a list with two mkdocs images rather than choose one" {
    PRELOADED=1 stub_docker
    printf 'docker.io/squidfunk/mkdocs-material:0.0.0-fixture\nghcr.io/other/mkdocs-material:0.0.0-fixture\n' \
        > "$BUNDLE/docker/monitoring-image-list.txt"
    run docs build --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"2 images named 'mkdocs-material'"* ]]
    ! grep -q '^docker run' "$STUB_LOG"
}

@test "build refuses a --wiki directory with no index.md" {
    PRELOADED=1 stub_docker
    mkdir -p "$BATS_TEST_TMPDIR/empty-wiki"
    run docs build --bundle "$BUNDLE" --wiki "$BATS_TEST_TMPDIR/empty-wiki"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"index.md missing"* ]]
    ! grep -q '^docker run' "$STUB_LOG"
}

@test "build --dry-run prints the mkdocs run and writes nothing under /srv/www" {
    PRELOADED=1 stub_docker
    run docs build --bundle "$BUNDLE" --dry-run
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN: docker run --rm --network none"* ]]
    ! grep -q '^docker run' "$STUB_LOG"
    [ ! -e "$ROOT/srv/www/docs" ]
}

# ── status ─────────────────────────────────────────────────────────────────

@test "status on a bare box reports no site, no image check, docs.lab not served" {
    run docs status
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"absent — run build"* ]]
    [[ "$output" == *"pass --bundle <dir> to check"* ]]
    [[ "$output" == *"not enabled — serve the site with r770-portal-deploy.sh"* ]]
}

@test "status after a build reports the pages, the loaded image and the enabled vhost" {
    PRELOADED=1 stub_docker
    run docs build --bundle "$BUNDLE"
    [ "$status" -eq 0 ]
    mkdir -p "$ROOT/etc/nginx/sites-enabled"
    touch "$ROOT/etc/nginx/sites-enabled/docs.lab.conf"
    run docs status --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/srv/www/docs (2 pages, built "* ]]
    [[ "$output" == *"$MKDOCS (loaded)"* ]]
    [[ "$output" != *"not enabled"* ]]
}

# ── full ──────────────────────────────────────────────────────────────────

# stub_import_bundle — a fake r770-import-bundle.sh that records "<subcommand>
# <argv...>" to $IMPORT_LOG and exits per IMPORT_RC_<SUBCOMMAND> (default 0).
stub_import_bundle() {
    cat > "$BATS_TEST_TMPDIR/import-bundle-stub.sh" <<'STUB'
#!/usr/bin/env bash
echo "import-bundle $*" >> "$IMPORT_LOG"
sub="$1"
var="IMPORT_RC_$(printf '%s' "$sub" | tr 'a-z-' 'A-Z_')"
exit "${!var:-0}"
STUB
    chmod +x "$BATS_TEST_TMPDIR/import-bundle-stub.sh"
    export IMPORT_BUNDLE_CMD="$BATS_TEST_TMPDIR/import-bundle-stub.sh"
    export IMPORT_LOG="$BATS_TEST_TMPDIR/import-bundle.log"
    : > "$IMPORT_LOG"
}

@test "full runs preflight through build in order: r770-import-bundle.sh for the shared steps, load before build" {
    stub_import_bundle
    stub_docker
    run docs full --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(awk '{print $2}' "$IMPORT_LOG" | paste -sd' ')" = "preflight gate copy apt phone-home docker files" ]
    grep -q "^import-bundle preflight --bundle $BUNDLE\$" "$IMPORT_LOG"
    grep -q "^import-bundle gate --bundle $BUNDLE\$" "$IMPORT_LOG"
    grep -q "^import-bundle copy --bundle $BUNDLE\$" "$IMPORT_LOG"
    l=$(grep -n '^docker load' "$STUB_LOG" | cut -d: -f1)
    r=$(grep -n '^docker run' "$STUB_LOG" | cut -d: -f1)
    [ -n "$l" ] && [ -n "$r" ] && [ "$l" -lt "$r" ]
    [ -f "$ROOT/srv/www/docs/index.html" ]
    [[ "$output" == *"DEPLOYED — every step clean"* ]]
}

@test "full with --media/--device passes them to the gate step only, and --media alone to copy" {
    stub_import_bundle
    run docs full --bundle "$BUNDLE" --media /mnt/usb --device /dev/fixture0 --only gate
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q "^import-bundle gate --bundle $BUNDLE --media /mnt/usb --device /dev/fixture0\$" "$IMPORT_LOG"

    : > "$IMPORT_LOG"
    run docs full --bundle "$BUNDLE" --media /mnt/usb --only copy
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q "^import-bundle copy --bundle $BUNDLE --media /mnt/usb\$" "$IMPORT_LOG"
}

@test "full --only build rebuilds the wiki alone: no shared steps, no load" {
    stub_import_bundle
    PRELOADED=1 stub_docker
    run docs full --bundle "$BUNDLE" --only build
    echo "$output"
    [ "$status" -eq 0 ]
    [ ! -s "$IMPORT_LOG" ]
    ! grep -q '^docker load' "$STUB_LOG"
    grep -q '^docker run --rm --network none' "$STUB_LOG"
    [[ "$output" == *"DEPLOYED — every step clean"* ]]
}

@test "full --from/--to slices to a contiguous range of steps" {
    stub_import_bundle
    run docs full --bundle "$BUNDLE" --from apt --to files
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(awk '{print $2}' "$IMPORT_LOG" | paste -sd' ')" = "apt phone-home docker files" ]
    ! grep -q '^docker' "$STUB_LOG"
}

@test "full refuses when --from comes after --to, and names both" {
    run docs full --bundle "$BUNDLE" --from build --to apt
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"--from build"* ]]
    [[ "$output" == *"--to apt"* ]]
}

@test "full refuses naming an unknown --from/--to step" {
    run docs full --bundle "$BUNDLE" --from bogus
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown step: bogus"* ]]
}

@test "full refuses without --bundle" {
    run docs full
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"--bundle <dir> is required for full"* ]]
}

@test "full stops after a step that warns without --yes, and finishes exit 2 once the warning is accepted" {
    stub_import_bundle
    export IMPORT_RC_APT=2
    unset KIT_YES
    run docs full --bundle "$BUNDLE" --only apt
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"warned and this run is non-interactive"* ]]

    export KIT_YES=1
    : > "$IMPORT_LOG"
    run docs full --bundle "$BUNDLE" --only apt
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"accepted via --yes"* ]]
    [[ "$output" == *"DEPLOYED WITH WARNINGS"* ]]
    [[ "$output" == *"steps: apt"* ]]
}
