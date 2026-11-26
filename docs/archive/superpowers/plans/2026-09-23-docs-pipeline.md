# Docs Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the analyst wiki build out of `r770-portal-deploy.sh docs` into its own independent pipeline, `scripts/r770-docs-deploy.sh`, with its own bundle-in prep and `full`, so the portal becomes purely the front door.

**Architecture:** A new bash script modelled step for step on `scripts/r770-gns3-deploy.sh`. It sources `scripts/lib/common.sh`, routes the shared prep steps (`preflight gate copy apt phone-home docker files`) to `scripts/r770-import-bundle.sh` through an `IMPORT_BUNDLE_CMD` seam, and adds its own `load` (docker load plus tag assertion) and `build` (mkdocs with `--network none`, then an atomic publish to `/srv/www/docs`). The portal keeps the `docs.lab` vhost, SAN and probe, and loses `docs`, `--bundle` and `--wiki`.

**Tech Stack:** bash, bats-core ≥ 1.10, shellcheck. There is no build step.

**Spec:** `docs/superpowers/specs/2026-09-23-docs-pipeline-design.md`

## Global Constraints

- `./tests/run.sh` must be green before every commit: shellcheck with **no exclusions** on `scripts/*.sh scripts/lib/*.sh tests/run.sh tests/helpers/*.bash`, plus every `tests/*.bats`. Baseline on this branch: 169/169 ok.
- Tests never touch the real host. Use `kit_test_env`/`kit_run` from `tests/helpers/stubs.bash` and `make_bundle`/`make_root` from `tests/helpers/fixtures.bash`. Every write goes under `$ROOT`, and the only versions allowed are the synthetic `0.0.0-fixture`.
- No version pins anywhere: image refs are read from `docker/monitoring-image-list.txt` via `image_ref_from_list` (`tests/no-pins.bats`).
- Every `docker run` carries `--network none` (`tests/no-internet.bats`).
- The exit contract is `0` done, `2` done with warnings, `1` refused or failed. Check lines use `PASS  `/`WARN  `/`FAIL  `/`SKIP  `.
- The `--help` header runs from line 3 to the first non-`#` line and is printed by `usage_from_header 3`. `tests/lint.bats` checks that the whole header is printed.
- `docker/monitoring-images.tar.gz` and `docker/monitoring-image-list.txt` keep their names, because the bundle verifier hardcodes them.
- Nothing under `staging/` is edited, and `docs/wiki/` (build-repo content) is not edited.
- Every commit message ends with:
  ```
  Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01NA7yRJiVMCwNVKPai6qjCA
  ```
- Work happens on branch `docs-pipeline`, which already exists and holds the spec commit.

## File map

| File | Change | Responsibility |
|---|---|---|
| `scripts/r770-docs-deploy.sh` | create (Task 1), extend (Task 2) | the docs pipeline: `load` `assert-tags` `build` `status` `full` |
| `tests/docs-deploy.bats` | create (Task 1), extend (Task 2) | the new script's suite |
| `tests/references.bats` | modify (Task 2) | full-step resolution covers the third pipeline |
| `.claude/settings.json` | modify (Task 1) | `allow` entry for the new script |
| `scripts/r770-portal-deploy.sh` | modify (Task 3) | drop `docs`, `--bundle`, `--wiki` |
| `tests/portal-deploy.bats` | modify (Task 3) | drop the docs tests, add a rejection test |
| `README.md`, `CLAUDE.md`, `tests/README.md`, `docs/deployment-runbook.md`, `docs/rollback.md`, `docs/kit-sync.md`, `docs/CODEMAPS/{architecture,stages,dependencies}.md` | modify (Task 4) | three pipelines, and the wiki is built by the docs pipeline |

---

### Task 1: `r770-docs-deploy.sh` with `load`, `assert-tags`, `build`, `status`

**Files:**
- Create: `scripts/r770-docs-deploy.sh` (mode 0755)
- Create: `tests/docs-deploy.bats`
- Modify: `.claude/settings.json` (the `allow` list, after the `r770-gns3-deploy.sh` entry)

**Interfaces:**
- Consumes (from `scripts/lib/common.sh`, unchanged): `kit_init`, `die`, `pass`, `note`, `banner`, `footer`, `run`, `p`, `need_root`, `common_flag`, `usage_from_header`, `bundle_dir`, `assert_image_tags`, `image_ref_from_list`, and the globals `DRY`, `FORCE`, `KIT_DIR`, `KIT_CONFIG_DIR`.
- Produces (used by Task 2): the functions `cmd_load`, `cmd_assert_tags`, `cmd_build` and `cmd_status`, which return 0 or exit per the contract; the globals `BUNDLE`, `WIKI`, `WWW="/srv/www"`, `LIST_REL`, `TAR_REL`; and, in the test file, the helpers `docs()` and `stub_docker()` and the variable `MKDOCS`.

- [ ] **Step 1: Write the failing suite**

Create `tests/docs-deploy.bats`:

```bash
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
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bats tests/docs-deploy.bats`
Expected: every test fails (`not ok`), because `scripts/r770-docs-deploy.sh` doesn't exist yet (exit 127).

- [ ] **Step 3: Write the script**

Create `scripts/r770-docs-deploy.sh`:

```bash
#!/usr/bin/env bash
#
# r770-docs-deploy.sh — the analyst wiki, built offline with the bundle's own
# mkdocs image and published to /srv/www/docs, where the front door's docs.lab
# vhost (r770-portal-deploy.sh) serves it.
#
#   r770-docs-deploy.sh <subcommand> [--bundle <dir>] [options]
#
#   load         docker load the bundle's docker/monitoring-images.tar.gz,
#                then assert every tag in docker/monitoring-image-list.txt
#   assert-tags  the tag check alone (docker load lies by omission)
#   build        mkdocs build of the wiki with the bundled image, --network
#                none, published atomically to /srv/www/docs
#   status       what is in place (read-only)
#
#   --bundle <dir>   the bundle (load, assert-tags, build; optional for status)
#   --wiki <dir>     wiki source (build; default: the kit's docs/wiki)
#   --yes / --non-interactive / --dry-run / --force   as everywhere in the kit
#
#   0  done · 2  done with warnings · 1  refused or failed
#
# The monitoring-* names outlived the monitoring stack: the bundle's verifier
# checks that list/tarball pair by exactly those filenames, and it now carries
# only mkdocs-material. Serving is not this script's job — docs.lab is the
# portal's vhost, and it serves whatever build last published.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

BUNDLE=""; WIKI=""
WWW="/srv/www"
LIST_REL="docker/monitoring-image-list.txt"
TAR_REL="docker/monitoring-images.tar.gz"
usage() { usage_from_header 3; exit 0; }

# ── load / assert-tags ──────────────────────────────────────────────────────
cmd_assert_tags() {
    local b; b=$(bundle_dir "$BUNDLE") || exit 1
    assert_image_tags "$b/$LIST_REL" || die "image(s) missing after load — the tarball is incomplete or the load failed"
}
cmd_load() {
    command -v docker >/dev/null 2>&1 || die "docker is not installed — run 'r770-import-bundle.sh docker' first"
    local b tar; b=$(bundle_dir "$BUNDLE") || exit 1
    if [ "$FORCE" != "1" ] && assert_image_tags "$b/$LIST_REL" >/dev/null 2>&1; then
        echo "$LIST_REL: every tag already present — load skipped (--force to redo)"
        return 0
    fi
    tar="$b/$TAR_REL"
    [ -s "$tar" ] || die "no $TAR_REL under $b"
    echo "loading $tar ..."
    run docker load -i "$tar" || die "docker load failed"
    [ "$DRY" = "1" ] || cmd_assert_tags
}

# ── build ────────────────────────────────────────────────────────────────────
# publish_site <built-site-dir> — swap it in as $WWW/docs without ever leaving
# docs.lab empty: stage beside the live tree, then two renames. Returns
# non-zero, reason on stderr, with the previous site still (or again) live.
publish_site() {
    local src=$1 www live new prev
    www="$(p "$WWW")"; live="$www/docs"; new="$www/docs.new"; prev="$www/docs.prev"
    run rm -rf "$new" "$prev" || { echo "could not clear a stale $WWW/docs.new or $WWW/docs.prev" >&2; return 1; }
    run mkdir -p "$www" || { echo "could not create $WWW" >&2; return 1; }
    run cp -a "$src" "$new" || { rm -rf "$new"; echo "copy into $WWW/docs.new failed — the previous site is still live" >&2; return 1; }
    if [ -e "$live" ]; then
        run mv "$live" "$prev" || { rm -rf "$new"; echo "could not move the live site aside — it is still live" >&2; return 1; }
    fi
    if ! run mv "$new" "$live"; then
        [ -e "$prev" ] && mv "$prev" "$live"
        echo "could not move the new site into place — the previous site was restored" >&2
        return 1
    fi
    run rm -rf "$prev"
    return 0
}

cmd_build() {
    banner "build — analyst wiki, built offline"
    need_root
    local b wiki img tmp
    b=$(bundle_dir "$BUNDLE") || exit 1
    wiki="${WIKI:-$KIT_DIR/docs/wiki}"
    [ -f "$wiki/index.md" ] || die "no wiki at $wiki (index.md missing) — pass --wiki <dir>"
    img=$(image_ref_from_list "$b/$LIST_REL" mkdocs-material) || exit 1
    tmp=$(mktemp -d)
    run cp -a "$wiki" "$tmp/docs"
    run install -m 0644 "$KIT_CONFIG_DIR/docs/mkdocs.yml" "$tmp/mkdocs.yml"
    # --network none: the build can want fonts and plugins; on an air gap it must not even try.
    run docker run --rm --network none -v "$tmp:/docs" "$img" build || { rm -rf "$tmp"; die "mkdocs build failed — is $img loaded? (run 'load' first)"; }
    if [ "$DRY" != "1" ]; then
        [ -f "$tmp/site/index.html" ] || { rm -rf "$tmp"; die "mkdocs produced no site/index.html"; }
        publish_site "$tmp/site" || { rm -rf "$tmp"; die "publish failed — see above"; }
        pass "wiki built into $WWW/docs ($(find "$(p "$WWW/docs")" -name '*.html' | wc -l) pages)"
    fi
    rm -rf "$tmp"
    footer "build"
}

# ── status ───────────────────────────────────────────────────────────────────
cmd_status() {
    banner "docs status"
    local live b img state
    live="$(p "$WWW/docs")"
    if [ -f "$live/index.html" ]; then
        printf '%-24s %s\n' "site" "$WWW/docs ($(find "$live" -name '*.html' | wc -l) pages, built $(date -r "$live/index.html" '+%F %T'))"
    else
        printf '%-24s %s\n' "site" "absent — run build"
    fi
    if [ -n "$BUNDLE" ] && b=$(bundle_dir "$BUNDLE") && img=$(image_ref_from_list "$b/$LIST_REL" mkdocs-material); then
        state="not loaded — run load"
        if docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -qxF "$img"; then state="loaded"; fi
        printf '%-24s %s (%s)\n' "build image" "$img" "$state"
    else
        printf '%-24s %s\n' "build image" "unknown — pass --bundle <dir> to check"
    fi
    if [ -e "$(p /etc/nginx/sites-enabled)/docs.lab.conf" ]; then
        printf '%-24s %s\n' "docs.lab vhost" "enabled"
    else
        printf '%-24s %s\n' "docs.lab vhost" "not enabled — serve the site with r770-portal-deploy.sh (ca cert htpasswd nginx)"
    fi
    return 0
}

SUB="${1:-}"; [ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
    case "$1" in
        --bundle)  BUNDLE="${2:-}"; shift ;;
        --wiki)    WIKI="${2:-}"; shift ;;
        -h|--help) usage ;;
        *)         common_flag "$1" || die "unknown option: $1 (try --help)" ;;
    esac
    shift
done
kit_init "r770-docs-deploy"
case "$SUB" in
    load)        cmd_load ;;
    assert-tags) cmd_assert_tags ;;
    build)       cmd_build ;;
    status)      cmd_status ;;
    -h|--help|help|"") usage ;;
    *)           die "unknown subcommand: $SUB (try --help)" ;;
esac
```

Then run `chmod 0755 scripts/r770-docs-deploy.sh`.

- [ ] **Step 4: Add the settings entry**

In `.claude/settings.json`, add this line directly after `"Bash(./scripts/r770-gns3-deploy.sh:*)",`:

```json
      "Bash(./scripts/r770-docs-deploy.sh:*)",
```

- [ ] **Step 5: Run the suite, then the whole gate**

Run: `bats tests/docs-deploy.bats`
Expected: 15 tests, all `ok`.

Run: `./tests/run.sh`
Expected: all `ok`. `lint.bats` now covers the new script (shellcheck, `--help` printing through the final header line, executable), and `references.bats` resolves the name in `settings.json`. If shellcheck flags anything, fix the code; never add a `# shellcheck disable`.

- [ ] **Step 6: Commit**

```bash
git add scripts/r770-docs-deploy.sh tests/docs-deploy.bats .claude/settings.json
git commit -m "Add r770-docs-deploy.sh: load, assert-tags, build with an atomic publish, status

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01NA7yRJiVMCwNVKPai6qjCA"
```

---

### Task 2: `full` for the docs pipeline

**Files:**
- Modify: `scripts/r770-docs-deploy.sh` (header, globals, a new `cmd_full`, argument parsing, dispatch)
- Modify: `tests/docs-deploy.bats` (append a `full` section)
- Modify: `tests/references.bats:38-58`

**Interfaces:**
- Consumes: `cmd_load`, `cmd_build`, `BUNDLE` from Task 1; `run_step`, `step_index` and `WARNED_STEPS` semantics from `common.sh`. `run_step` runs its command in a subshell and handles 0/2/1 exactly as it does for GNS3.
- Produces: `STEPS=(preflight gate copy apt phone-home docker files load build)`, the `IMPORT_BUNDLE_CMD` env seam, and `local_bundle()`.

- [ ] **Step 1: Append the failing tests**

Append to `tests/docs-deploy.bats`:

```bash
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
```

- [ ] **Step 2: Extend the references test so it fails**

In `tests/references.bats`, replace the test starting at line 38:

```bash
@test "every full step of both pipelines resolves to a subcommand that exists" {
    # No outer orchestrator: r770-malcolm-deploy.sh full and r770-gns3-deploy.sh
    # full each hold their own STEPS array. The shared prefix
    # (preflight gate copy apt phone-home docker files) must be a subcommand
    # of r770-import-bundle.sh; every other step must be a cmd_<step> function
    # defined in the pipeline's own script.
    for s in scripts/r770-malcolm-deploy.sh scripts/r770-gns3-deploy.sh; do
```

with:

```bash
@test "every full step of every pipeline resolves to a subcommand that exists" {
    # No outer orchestrator: r770-malcolm-deploy.sh, r770-gns3-deploy.sh and
    # r770-docs-deploy.sh full each hold their own STEPS array. The shared
    # prefix (preflight gate copy apt phone-home docker files) must be a
    # subcommand of r770-import-bundle.sh; every other step must be a
    # cmd_<step> function defined in the pipeline's own script.
    for s in scripts/r770-malcolm-deploy.sh scripts/r770-gns3-deploy.sh scripts/r770-docs-deploy.sh; do
```

Leave the rest of that test body unchanged.

- [ ] **Step 3: Run the tests to confirm they fail**

Run: `bats tests/docs-deploy.bats --filter 'full'`
Expected: 8 `not ok`, each with `unknown subcommand: full`.

Run: `bats tests/references.bats --filter 'every full step'`
Expected: `not ok`, with `no STEPS array in scripts/r770-docs-deploy.sh`.

- [ ] **Step 4: Implement `full`**

In `scripts/r770-docs-deploy.sh`, make these four edits.

(a) In the header, replace:

```bash
#   status       what is in place (read-only)
#
#   --bundle <dir>   the bundle (load, assert-tags, build; optional for status)
#   --wiki <dir>     wiki source (build; default: the kit's docs/wiki)
```

with:

```bash
#   status       what is in place (read-only)
#   full         the whole docs pipeline, in order, stopping at the first step
#                that refuses: preflight gate copy apt phone-home docker files
#                load build (see --from/--to/--only)
#
#   --bundle <dir>          the bundle (on the media for preflight/gate/copy
#                           under `full`, local after; optional for status)
#   --media <mnt>           mountpoint of the transfer media, for `full`'s
#                           gate/copy steps (gate mounts, copy unmounts)
#   --device <dev>          block device to mount read-only at --media, for
#                           `full`'s gate step — a DISCOVERED name, never a
#                           guess
#   --from STEP / --to STEP restrict `full` to a slice of its steps
#   --only STEP             sugar for --from STEP --to STEP
#   --wiki <dir>            wiki source (build; default: the kit's docs/wiki)
```

(b) Replace the globals block:

```bash
BUNDLE=""; WIKI=""
WWW="/srv/www"
LIST_REL="docker/monitoring-image-list.txt"
TAR_REL="docker/monitoring-images.tar.gz"
usage() { usage_from_header 3; exit 0; }
```

with:

```bash
BUNDLE=""; WIKI=""
MEDIA=""; DEVICE=""; FROM=""; TO=""; ONLY=""
WWW="/srv/www"
LIST_REL="docker/monitoring-image-list.txt"
TAR_REL="docker/monitoring-images.tar.gz"
STEPS=(preflight gate copy apt phone-home docker files load build)
# test seam: lets a suite stub out every call this script makes to
# r770-import-bundle.sh under `full`, and record what was called.
IMPORT_BUNDLE_CMD="${IMPORT_BUNDLE_CMD:-$KIT_DIR/scripts/r770-import-bundle.sh}"
usage() { usage_from_header 3; exit 0; }
local_bundle() {  # after copy, the bundle lives under /srv/bundles
    local l; l="$(p /srv/bundles)/$(basename "$BUNDLE")"
    if [ -d "$l" ]; then printf '%s' "$l"; else printf '%s' "$BUNDLE"; fi
}
```

(c) Insert this block directly above the line `SUB="${1:-}"; [ $# -gt 0 ] && shift`:

```bash
# ── full ─────────────────────────────────────────────────────────────────────
# The whole docs pipeline, in order, stopping at the first step that refuses.
# Independent of the Malcolm and GNS3 pipelines: it brings its own bundle in
# from the media, and the shared prep steps are idempotent, so running it
# after either of them costs only gate's re-verification.
cmd_full() {
    [ -n "$BUNDLE" ] || die "--bundle <dir> is required for full (try --help)"
    local first last i step
    first=0; last=$(( ${#STEPS[@]} - 1 ))
    [ -z "$FROM" ] || first=$(step_index STEPS "$FROM") || die "unknown step: $FROM (see --help)"
    [ -z "$TO" ]   || last=$(step_index STEPS "$TO")    || die "unknown step: $TO (see --help)"
    [ "$first" -le "$last" ] || die "--from $FROM comes after --to $TO"
    # Resolve the local copy BEFORE the loop: a resumed run (--from past copy)
    # never executes the copy) arm, so BUNDLE would otherwise still point at
    # the (already unmounted) media path. local_bundle() falls back to the raw
    # path when the copy hasn't landed yet, so this is safe on a fresh run too.
    BUNDLE="$(local_bundle)"
    echo "bundle: $BUNDLE"; [ -n "$MEDIA" ] && echo "media: $MEDIA${DEVICE:+ ($DEVICE)}"
    echo "steps: ${STEPS[*]:$first:$((last - first + 1))}"
    WARNED_STEPS=""
    for i in $(seq "$first" "$last"); do
        step="${STEPS[$i]}"
        banner "$(( i + 1 ))/${#STEPS[@]}  $step"
        case "$step" in
            preflight) run_step "$step" "$IMPORT_BUNDLE_CMD" preflight --bundle "$BUNDLE" ;;
            gate)
                if [ -n "$DEVICE" ]; then run_step "$step" "$IMPORT_BUNDLE_CMD" gate --bundle "$BUNDLE" --media "$MEDIA" --device "$DEVICE"
                else run_step "$step" "$IMPORT_BUNDLE_CMD" gate --bundle "$BUNDLE"; fi ;;
            copy)
                if [ -n "$MEDIA" ]; then run_step "$step" "$IMPORT_BUNDLE_CMD" copy --bundle "$BUNDLE" --media "$MEDIA"
                else run_step "$step" "$IMPORT_BUNDLE_CMD" copy --bundle "$BUNDLE"; fi
                BUNDLE="$(local_bundle)" ;;   # now the copy has landed, so this always resolves
            apt|phone-home|docker|files) run_step "$step" "$IMPORT_BUNDLE_CMD" "$step" --bundle "$(local_bundle)" ;;
            load)  run_step "$step" cmd_load ;;
            build) run_step "$step" cmd_build ;;
        esac
    done
    echo
    if [ -n "$WARNED_STEPS" ]; then
        echo "DEPLOYED WITH WARNINGS — steps:$WARNED_STEPS. Disposition each in the cycle log; evidence under ${KIT_EVIDENCE_DIR:-./r770-evidence}"
        exit 2
    fi
    echo "DEPLOYED — every step clean; evidence under ${KIT_EVIDENCE_DIR:-./r770-evidence}"
    exit 0
}

```

(d) Replace the argument parsing and dispatch (everything from `SUB="${1:-}"` to the end of the file) with:

```bash
SUB="${1:-}"; [ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
    case "$1" in
        --bundle)  BUNDLE="${2:-}"; shift ;;
        --wiki)    WIKI="${2:-}"; shift ;;
        --media)   MEDIA="${2:-}"; shift ;;
        --device)  DEVICE="${2:-}"; shift ;;
        --from)    FROM="${2:-}"; shift ;;
        --to)      TO="${2:-}"; shift ;;
        --only)    ONLY="${2:-}"; shift ;;
        -h|--help) usage ;;
        *)         common_flag "$1" || die "unknown option: $1 (try --help)" ;;
    esac
    shift
done
[ -n "$ONLY" ] && { FROM="$ONLY"; TO="$ONLY"; }
kit_init "r770-docs-deploy"
case "$SUB" in
    load)        cmd_load ;;
    assert-tags) cmd_assert_tags ;;
    build)       cmd_build ;;
    status)      cmd_status ;;
    full)        cmd_full ;;
    -h|--help|help|"") usage ;;
    *)           die "unknown subcommand: $SUB (try --help)" ;;
esac
```

- [ ] **Step 5: Run the tests to confirm they pass**

Run: `bats tests/docs-deploy.bats`
Expected: 23 tests, all `ok`.

Run: `./tests/run.sh`
Expected: all `ok`, including `references.bats`'s "every full step of every pipeline…".

- [ ] **Step 6: Commit**

```bash
git add scripts/r770-docs-deploy.sh tests/docs-deploy.bats tests/references.bats
git commit -m "Give the docs pipeline its own full: shared bundle-in prep, then load and build

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01NA7yRJiVMCwNVKPai6qjCA"
```

---

### Task 3: Remove `docs` from the portal

**Files:**
- Modify: `scripts/r770-portal-deploy.sh` (header lines 3-18, line 40, `cmd_docs` at 173-197, parser at 214-223, dispatch at 225-234)
- Modify: `tests/portal-deploy.bats` (header comment lines 1-5, the docker stub in `setup()` lines 35-37, the two `docs` tests at 140-160)

**Interfaces:**
- Consumes: nothing new. From here on, the wiki is built only by `scripts/r770-docs-deploy.sh build`.
- Produces: a portal that rejects `docs` ("unknown subcommand: docs") and `--bundle`/`--wiki` ("unknown option").

- [ ] **Step 1: Write the failing rejection test and remove the moved tests**

In `tests/portal-deploy.bats`:

(a) Replace lines 1-5:

```bash
#!/usr/bin/env bats
#
# The portal is where a wrong file mode, a missing SAN or a bad reload takes
# every service off the air at once. The suite pins the SAN list, the file
# modes, the -t-before-reload order, the gate, and the offline docs build.
```

with:

```bash
#!/usr/bin/env bats
#
# The portal is where a wrong file mode, a missing SAN or a bad reload takes
# every service off the air at once. The suite pins the SAN list, the file
# modes, the -t-before-reload order and the gate. The wiki it serves at
# docs.lab is built elsewhere (tests/docs-deploy.bats).
```

(b) In `setup()`, delete these three lines, which were the docs build's docker stub:

```bash
    stub docker 'echo "docker $*" >> "$STUB_LOG"
for a in "$@"; do case "$a" in *:/docs) d="${a%%:/docs}"; mkdir -p "$d/site"; echo "<html>built</html>" > "$d/site/index.html";; esac; done
exit 0'
```

(c) Delete both tests: `@test "docs loads the mkdocs image before building, with --network none"` and `@test "docs refuses a bundle whose list has no mkdocs image"`. In their place, add:

```bash
@test "docs is no longer a portal subcommand, and the portal takes no --bundle or --wiki" {
    run portal docs
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown subcommand: docs"* ]]
    run portal status --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown option: --bundle"* ]]
    run portal status --wiki /tmp
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown option: --wiki"* ]]
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `bats tests/portal-deploy.bats --filter 'no longer a portal subcommand'`
Expected: `not ok`. `portal docs` still runs `cmd_docs`, which dies on the missing bundle with a different message.

- [ ] **Step 3: Strip `docs` from the portal script**

In `scripts/r770-portal-deploy.sh`:

(a) Replace header lines 3-5:

```bash
# r770-portal-deploy.sh — the nginx front door: an internal CA generated ON
# the gapped box, one three-SAN certificate, the .lab vhosts and the analyst
# wiki built offline.
```

with:

```bash
# r770-portal-deploy.sh — the nginx front door: an internal CA generated ON
# the gapped box, one three-SAN certificate and the .lab vhosts. The analyst
# wiki it serves at docs.lab is built by r770-docs-deploy.sh.
```

(b) Change line 7 from `#   r770-portal-deploy.sh <subcommand> [--bundle <dir>] [options]` to `#   r770-portal-deploy.sh <subcommand> [options]`.

(c) Delete these two header lines, and only these two. The `#` line above `--wiki` stays, because it separates the subcommands from the options:

```bash
#   docs        analyst wiki built with the bundled mkdocs image, --network none
```

```bash
#   --wiki <dir>     wiki source (docs; default: the kit's docs/wiki)
```

The header should then read `... --print-sans  print the SAN list and exit (tests and docs read it)`, then `#`, then `#   EASYRSA_BIN ...`.

(d) Delete line 40: `BUNDLE=""; WIKI=""`.

(e) Delete the whole `cmd_docs() { ... }` function (lines 173-197) and the blank line after it.

(f) In the option parser, delete these two lines:

```bash
        --bundle)  BUNDLE="${2:-}"; shift ;;
        --wiki)    WIKI="${2:-}"; shift ;;
```

(g) In the dispatch, delete `    docs)     cmd_docs ;;`.

- [ ] **Step 4: Run the tests to confirm they pass**

Run: `bats tests/portal-deploy.bats`
Expected: all `ok`.

Run: `grep -n 'BUNDLE\|WIKI\|mkdocs\|cmd_docs' scripts/r770-portal-deploy.sh`
Expected: no output.

Run: `./tests/run.sh`
Expected: all `ok`. `references.bats`'s "every config file is installed" test still passes for `config/docs/mkdocs.yml`, because `scripts/r770-docs-deploy.sh` references `docs/mkdocs.yml`.

- [ ] **Step 5: Commit**

```bash
git add scripts/r770-portal-deploy.sh tests/portal-deploy.bats
git commit -m "Retire the portal's docs step: the wiki is built by r770-docs-deploy.sh, the portal only serves it

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01NA7yRJiVMCwNVKPai6qjCA"
```

---

### Task 4: Docs sweep — three pipelines, wiki owned by the docs pipeline

**Files:** `README.md`, `CLAUDE.md`, `tests/README.md`, `docs/deployment-runbook.md`, `docs/rollback.md`, `docs/kit-sync.md`, `docs/CODEMAPS/architecture.md`, `docs/CODEMAPS/stages.md`, `docs/CODEMAPS/dependencies.md`

**Interfaces:** documentation only. `tests/references.bats` requires every backticked `scripts/…`, `config/…`, `docs/…`, `tests/…` or `staging/…` path named in these files to exist.

- [ ] **Step 1: Confirm what's stale**

Run: `grep -rn 'portal-deploy.sh docs\|portal-deploy docs\|nginx docs`\|two independent\|two pipelines\|either `full`\|both pipelines\|an `ask` entry' README.md CLAUDE.md tests/README.md docs/*.md docs/CODEMAPS/`
Expected: hits in every file listed above. Each one is fixed below.

- [ ] **Step 2: `README.md`**

(a) Replace the front-door paragraph and code block:

````markdown
Once Malcolm is up, the optional front door (one certificate, the three `.lab`
vhosts, the offline analyst wiki) is a separate, explicit sequence:

```bash
sudo ./scripts/r770-portal-deploy.sh ca
sudo ./scripts/r770-portal-deploy.sh cert
sudo ./scripts/r770-portal-deploy.sh htpasswd   # needs Malcolm's auth step already run
sudo ./scripts/r770-portal-deploy.sh nginx
sudo ./scripts/r770-portal-deploy.sh docs --bundle /srv/bundles/bundle-YYYYMMDD
```
````

with:

````markdown
The offline analyst wiki is a third, equally independent pipeline, built with
the bundle's own mkdocs image and published to `/srv/www/docs`:

```bash
sudo ./scripts/r770-docs-deploy.sh full \
    --bundle /mnt/bundle/bundle-YYYYMMDD \
    --media /mnt/bundle --device /dev/<discovered>
# later, to rebuild just the wiki from the copied bundle:
sudo ./scripts/r770-docs-deploy.sh full --bundle /srv/bundles/bundle-YYYYMMDD --only build
```

Once Malcolm is up, the optional front door (one certificate, the three `.lab`
vhosts, `docs.lab` serving whatever the docs pipeline last published) is a
separate, explicit sequence:

```bash
sudo ./scripts/r770-portal-deploy.sh ca
sudo ./scripts/r770-portal-deploy.sh cert
sudo ./scripts/r770-portal-deploy.sh htpasswd   # needs Malcolm's auth step already run
sudo ./scripts/r770-portal-deploy.sh nginx
```
````

(b) In the "What's here" table, add this row after the `scripts/r770-gns3-deploy.sh` row:

```markdown
| `scripts/r770-docs-deploy.sh` | The analyst wiki: `full` runs its own bundle-in prep, then load/assert-tags for the mkdocs image, then `build` (`--network none`) with an atomic publish to `/srv/www/docs` — a failed build never leaves `docs.lab` empty |
```

(c) In the `scripts/r770-portal-deploy.sh` row, replace `vhosts (`nginx -t` before reload, probe after), analyst wiki built offline |` with `vhosts (`nginx -t` before reload, probe after); serves the wiki the docs pipeline built |`.

(d) In the `scripts/r770-import-bundle.sh` row, replace `Malcolm and GNS3 each load their own` with `Malcolm, GNS3 and docs each load their own`.

(e) In the `docs/wiki/` row, replace `built into `docs.lab` on the R770` with `built by `scripts/r770-docs-deploy.sh` and served at `docs.lab` on the R770`.

(f) In the `docs/CODEMAPS/` row, replace `the two pipelines plus the front door` with `the three pipelines plus the front door`.

(g) In the `docs/deployment-runbook.md` row, replace `the Malcolm pipeline, the GNS3 pipeline, and the optional front door` with `the Malcolm, GNS3 and docs pipelines, and the optional front door`.

(h) In the `.claude/settings.json` row, replace `every deploy script asks` with `every kit script is allowed by name`.

(i) Search the README's earlier text above the Malcolm/GNS3 code block for "two" (for example "two independent pipelines") and change it to three, naming `r770-docs-deploy.sh`. Check with `grep -n 'two' README.md` and edit only the sentences about pipelines.

- [ ] **Step 3: `CLAUDE.md`**

(a) In the Commands block, add after the GNS3 `--dry-run` line pair:

```bash
sudo ./scripts/r770-docs-deploy.sh full \
    --bundle <dir> --media <mnt> --device /dev/<discovered> --dry-run # the analyst wiki's pipeline, same contract, independent of both
```

(b) In "Two hosts, enforced.", replace `two independent pipelines plus an optional` with `three independent pipelines plus an optional`.

(c) Replace the whole bullet beginning `- **Two independent pipelines, no orchestrator.**` (through `either `full`.`) with:

```markdown
- **Three independent pipelines, no orchestrator.** There is no
  `r770-deploy.sh` any more — it was deleted once each service could stand
  up its own pipeline. `scripts/r770-malcolm-deploy.sh full`,
  `scripts/r770-gns3-deploy.sh full` and `scripts/r770-docs-deploy.sh full`
  (the analyst wiki, built offline and published to `/srv/www/docs`) each
  run their own bundle-in prep (preflight, gate, copy, apt, phone-home,
  docker, files — the shared logic lives in `scripts/r770-import-bundle.sh`)
  before their own service-specific steps; run them in any order — the
  shared prep steps are idempotent, so a later `full` just reports "already
  done". The optional front door, `scripts/r770-portal-deploy.sh`
  (`ca cert htpasswd nginx`), is a separate, explicit sequence run after
  Malcolm is up; it serves `docs.lab` but does not build it, and it is not
  part of any `full`.
```

(d) In "Working on the kit itself", replace `and an `ask` entry in `.claude/settings.json`.` with `and an `allow` entry in `.claude/settings.json` beside its siblings.`

- [ ] **Step 4: `tests/README.md`**

(a) Add this row after the `gns3-deploy.bats` row:

```markdown
| `docs-deploy.bats` | load and the tag assertion, `--network none`, the atomic publish (a failed build leaves the live site; stale `docs.new`/`docs.prev` cleared), image-list refusals, `full` slicing and the warn contract |
```

(b) In the `portal-deploy.bats` row, replace `probe verdicts, offline docs build |` with `probe verdicts, `docs` retired |`.

(c) In the `references.bats` row, replace `every runner stage resolves` with `every pipeline's `full` step resolves`.

- [ ] **Step 5: `docs/deployment-runbook.md`**

(a) In the intro, replace the paragraph beginning `Malcolm and GNS3 are **two independent pipelines**` (through `offline analyst wiki) is a separate, explicit sequence.`) with:

```markdown
Malcolm, GNS3 and the offline analyst wiki are **three independent
pipelines**, each its own `... full` entry point in its own script — there
is no outer orchestrator. Run them in any order, or back to back on the same
box: the bundle-prep steps they share (`preflight gate copy apt phone-home
docker files`) are all idempotent, so a later pipeline's copy of them reports
"already done" and moves on (see `docs/CODEMAPS/architecture.md`). Once
Malcolm is up, an optional **front door** (one certificate, the three `.lab`
vhosts) is a separate, explicit sequence; it serves the wiki the docs
pipeline published at `docs.lab`.
```

(b) Rename `## The short path: two commands` to `## The short path: one command per pipeline`. In its code block, add after the GNS3 command:

```bash

sudo ./scripts/r770-docs-deploy.sh full --bundle /mnt/bundle/bundle-YYYYMMDD \
    --media /mnt/bundle --device /dev/<discovered>
```

In the paragraph after it, replace `are the same two pipelines one step at a time` with `are the same three pipelines one step at a time`.

(c) Insert a new section directly above `## Front door (optional, after Malcolm)`:

````markdown
## Docs procedure

Steps D1–D4 (`preflight` `gate` `copy` `apt` `phone-home` `docker` `files`)
are identical to Malcolm's M1–M7 above, against the same
`r770-import-bundle.sh`, and are idempotent — if another pipeline has
already run on this box, the docs pipeline's copy of them reports "already
done" and `full` moves straight on. What follows is docs-specific.

### Step D5 — load

```bash
sudo ./scripts/r770-docs-deploy.sh load --bundle /srv/bundles/bundle-YYYYMMDD
```

`docker load` of `docker/monitoring-images.tar.gz`, then **every tag asserted
against `docker/monitoring-image-list.txt`** (the names predate the cut of the
monitoring stack; the pair now carries only the mkdocs-material build image).
Skipped, and safe to rerun, once every tag is already present.

### Step D6 — build

```bash
sudo ./scripts/r770-docs-deploy.sh build --bundle /srv/bundles/bundle-YYYYMMDD
```

The kit's `docs/wiki` (or `--wiki <dir>`) built with the bundled image under
`--network none`, then published to `/srv/www/docs` by staging beside the live
tree and swapping it in with two renames. A failed build, or a failed copy,
leaves the previous site live; a `docs.new` or `docs.prev` left by an
interrupted run is cleared by the next `build`. To rebuild after the wiki
source changes: `r770-docs-deploy.sh full --bundle <local bundle> --only build`.

### Docs — validate note

`r770-docs-deploy.sh status` shows the page count, the build time, whether
the image is loaded (with `--bundle`) and whether `docs.lab` is being served.
Once the front door is up, `r770-validate.sh --area portal` covers `docs.lab`.

---

````

(d) In the front-door section, replace `The front door is the internal CA, one three-SAN certificate, the `.lab`
vhosts and the offline analyst wiki — a separate, explicit sequence, never
part of either `full`.` with `The front door is the internal CA, one three-SAN certificate and the `.lab`
vhosts — a separate, explicit sequence, never part of any `full`. It serves
`docs.lab` from whatever the docs pipeline last published; before the first
`build`, `docs.lab` answers 401 (auth), then 404.`

(e) Delete the code-block line `sudo ./scripts/r770-portal-deploy.sh docs --bundle /srv/bundles/bundle-YYYYMMDD   # wiki built with the bundled mkdocs image, --network none`.

- [ ] **Step 6: `docs/rollback.md`**

(a) In the `load (malcolm, gns3)` row, change the stage cell to `load (malcolm, gns3, docs)`.

(b) In the `portal` row, delete `, `/srv/www/docs`` from the "What changed" cell.

(c) Add a row directly after the `portal` row:

```markdown
| docs | `/srv/www/docs` (the built site) | the previous site survives a failed `build` (staged in `/srv/www/docs.new`, swapped by rename) | `rm -rf /srv/www/docs` — `docs.lab` then answers 404 behind auth | — |
```

- [ ] **Step 7: `docs/kit-sync.md`, `docs/CODEMAPS/dependencies.md`**

(a) In `docs/kit-sync.md`, change `(`docs.lab`, built by `scripts/r770-portal-deploy.sh docs`)` to `(`docs.lab`, built by `scripts/r770-docs-deploy.sh build`)`.

(b) In `docs/CODEMAPS/dependencies.md`, change the "Loaded by" cell of the `docker/monitoring-image-list.txt` row from `` `r770-portal-deploy.sh docs` (self-load; the list keeps... `` to `` `r770-docs-deploy.sh load` (the list keeps... ``, keeping the rest of the cell's text.

- [ ] **Step 8: `docs/CODEMAPS/architecture.md`**

(a) In the top diagram, replace:

```
  staging/r770-offline-fetch.sh  ──┐            scripts/r770-gns3-deploy.sh full
    (the one pin owner)            │            two independent pipelines, no
  staging/r770-build-bundle.sh     │            outer orchestrator
```

with:

```
  staging/r770-offline-fetch.sh  ──┐            scripts/r770-gns3-deploy.sh full
    (the one pin owner)            │            scripts/r770-docs-deploy.sh full
  staging/r770-build-bundle.sh     │            three independent pipelines,
                                   │            no outer orchestrator
```

(b) In the "Three layers" diagram, replace:

```
r770-malcolm-deploy.sh full     r770-gns3-deploy.sh full     (independent; each
  │ own STEPS array               │ own STEPS array           brings its own
  │ run_step()/step_index()       │ run_step()/step_index()   bundle in from
  ▼                               ▼                           the media)
```

with:

```
r770-malcolm-deploy.sh full   r770-gns3-deploy.sh full   r770-docs-deploy.sh full
  │ own STEPS array             │ own STEPS array          │ own STEPS array
  │ run_step()/step_index()     │ run_step()/step_index()  │ run_step()/step_index()
  ▼                             ▼                          ▼
                 (independent; each brings its own bundle in from the media)
```

(c) Rename the heading `## Two independent `full` pipelines, one shared prep` to `## Three independent `full` pipelines, one shared prep`. In the paragraph below it, change `` `r770-malcolm-deploy.sh full` and `r770-gns3-deploy.sh full` each hold their `` to `` `r770-malcolm-deploy.sh full`, `r770-gns3-deploy.sh full` and `r770-docs-deploy.sh full` each hold their ``, change `Both begin with` to `All three begin with`, change `running one pipeline's `full` after the other has` to `running one pipeline's `full` after another has`, and change `once per pipeline instead of once total` so the sentence stays true for three pipelines. Reread the paragraph afterwards to check that it still reads correctly.

(d) Replace the front-door paragraph `The front door (`r770-portal-deploy.sh`: `ca cert htpasswd nginx docs`) is
never part of either `full`` with `The front door (`r770-portal-deploy.sh`: `ca cert htpasswd nginx`) is
never part of any `full``, and at the end of that paragraph add: ` It serves `docs.lab` but no longer builds it — `r770-docs-deploy.sh build` does.`

- [ ] **Step 9: `docs/CODEMAPS/stages.md`**

(a) Replace the intro sentence `` `r770-malcolm-deploy.sh full` and
`r770-gns3-deploy.sh full` are two independent entry points `` with `` `r770-malcolm-deploy.sh full`,
`r770-gns3-deploy.sh full` and `r770-docs-deploy.sh full` are three independent entry points ``.

(b) Add a row after the GNS3 row of the pipeline table:

```markdown
| Docs | `scripts/r770-docs-deploy.sh` | `preflight` `gate` `copy` `apt` 🔒 `phone-home` 🔒 `docker` 🔒 `files` `load` `build` | `assert-tags`, `status` |
```

(c) In the Front door row, replace `` run by hand as `ca` `cert` `htpasswd` `nginx` 🔒 `docs`, in that order `` with `` run by hand as `ca` `cert` `htpasswd` `nginx` 🔒, in that order ``.

(d) Change `Malcolm and GNS3 each load and tag-assert their own tarball.` to `Malcolm, GNS3 and docs each load and tag-assert their own tarball.`, and change `## Subcommands NOT in either `full`` to `## Subcommands NOT in any `full``.

(e) In the extras table, add after the `gns3` row: `| docs | `assert-tags` `status` | the tag check alone / read-only |`. Change the portal row's first cell to `` `ca` `cert` `htpasswd` `nginx` ``.

(f) In the config table, change `` | `config/docs/mkdocs.yml` | `portal-deploy docs` | `` to `` | `config/docs/mkdocs.yml` | `docs-deploy build` | ``.

- [ ] **Step 10: Verify that nothing stale remains, then run the gate**

Run: `grep -rn 'portal-deploy.sh docs\|portal-deploy docs\|nginx docs`\|htpasswd nginx docs\|either `full`\|two independent\|an `ask` entry' README.md CLAUDE.md tests/README.md docs/*.md docs/CODEMAPS/`
Expected: no output. If anything is left, it's a sentence Steps 2-9 missed. Fix it in the same way.

Run: `./tests/run.sh`
Expected: all `ok`, and `references.bats` finds every newly named path (`scripts/r770-docs-deploy.sh`, `tests/docs-deploy.bats`).

- [ ] **Step 11: Commit**

```bash
git add README.md CLAUDE.md tests/README.md docs/deployment-runbook.md docs/rollback.md docs/kit-sync.md docs/CODEMAPS/
git commit -m "Document the docs pipeline: three independent pipelines, the portal serves docs.lab but no longer builds it

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01NA7yRJiVMCwNVKPai6qjCA"
```
