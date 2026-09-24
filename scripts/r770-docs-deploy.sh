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
