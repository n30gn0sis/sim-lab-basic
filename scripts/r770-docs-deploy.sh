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
# publish_site <built-site-dir> — swap it in as $WWW/docs: stage beside the
# live tree, then two renames. A failure at any point leaves the previous
# site live (a failed build never leaves docs.lab empty); the swap window
# between the two renames is brief but real. Returns non-zero, reason on
# stderr, with the previous site still (or again) live.
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
    run cp -a "$wiki" "$tmp/docs" || { rm -rf "$tmp"; die "wiki copy into $tmp/docs failed — the wiki may be partially staged"; }
    run install -m 0644 "$KIT_CONFIG_DIR/docs/mkdocs.yml" "$tmp/mkdocs.yml" || { rm -rf "$tmp"; die "could not install mkdocs.yml into $tmp"; }
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
        if docker_loaded_images | grep -qxF "$(image_norm "$img")"; then state="loaded"; fi
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
