#!/usr/bin/env bash
#
# r770-import-bundle.sh — bring a verified supply bundle onto the air-gapped
# R770 and put its payload where the rest of the kit expects it.
#
#   r770-import-bundle.sh <subcommand> --bundle <dir> [options]
#
#   preflight    is this host ready to receive a bundle? (mounts, tools, room)
#   gate         run the verifier THAT TRAVELS IN THE BUNDLE; refuse on FAIL
#   copy         cp -a to /srv/bundles/, verify again from the copy, unmount
#   apt          local flat repo at /srv/repo/apt, sources rewritten   (GATED)
#   phone-home   unattended-upgrades, snapd, motd-news neutralised      (GATED)
#   docker       docker-ce from the local repo, daemon asserted         (GATED)
#   images       docker load every list/payload pair, assert every tag
#   files        VM images, GNS3 definitions/appliances, enrichment, docs
#   status       what has landed so far
#
#   --bundle <dir>     the bundle (on the media for gate/copy; local after)
#   --media <mnt>      mountpoint of the transfer media (gate mounts, copy unmounts)
#   --device <dev>     block device to mount read-only at --media — a DISCOVERED
#                      name (lsblk), never a guess; the script will not pick one
#   --yes              accept every gate (also KIT_YES=1)
#   --non-interactive  never prompt; a gate without --yes refuses
#   --dry-run          print every command instead of executing (KIT_DRY_RUN=1)
#   --force            redo a step its stamp says is done
#
#   0  done · 2  done with warnings to disposition · 1  refused or failed
#
# Nothing here reaches the internet. The verifier is the bundle's own copy of
# r770-bundle.sh (covered by its manifest); this kit ships no verifier and
# never gates on a hand-rolled checksum.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

LVS="/var/lib/docker /data/pcap /data/index /data/staging /srv/vms /srv/gns3 /srv/work /srv/backup"
PAIRS=(
    "malcolm/image-list.txt|malcolm/malcolm-images-*.tar.gz"
    "docker/monitoring-image-list.txt|docker/monitoring-images.tar.gz"
    "gns3/docker-nodes/image-list.txt|gns3/docker-nodes/gns3-node-images.tar.gz"
)
PHONE_HOME_UNITS="unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer ua-timer.timer motd-news.timer fwupd-refresh.timer"
DOCKER_PKGS="docker-ce docker-ce-cli containerd.io docker-compose-plugin"

BUNDLE=""; MEDIA=""; DEVICE=""
usage() { usage_from_header 3 30; exit 0; }

# ── preflight ────────────────────────────────────────────────────────────────
cmd_preflight() {
    banner "import preflight"
    if [ -z "$ROOT" ] && [ "$(id -u)" -ne 0 ]; then
        fail "not root — every stage after gate writes to the host; run with sudo"
    else
        pass "running as root (or under a test root)"
    fi

    # Every logical volume in the storage layout must be mounted BEFORE anything
    # is imported: `docker load` into an unmounted /var/lib/docker writes onto
    # the root filesystem and fills it (install runbook Part 2).
    local lv mp
    for lv in $LVS; do
        mp=$(findmnt -n -o TARGET -T "$lv" 2>/dev/null || true)
        if [ "$mp" = "$lv" ]; then
            pass "$lv is its own mount point"
        else
            fail "$lv is NOT a mount point (it is on '${mp:-nothing}') — imports would land on the wrong filesystem; mount the LV first (Phase 3)"
        fi
    done

    local t
    for t in tar gzip findmnt python3; do
        if command -v "$t" >/dev/null 2>&1; then pass "tool present: $t"; else fail "tool missing: $t"; fi
    done
    for t in docker unzip; do
        if command -v "$t" >/dev/null 2>&1; then pass "tool present: $t"; else warn "tool not yet present: $t — it is installed from the bundle's apt/ by a later stage"; fi
    done

    if [ -n "$BUNDLE" ] && [ -d "$BUNDLE" ]; then
        local need avail
        need=$(du -sk "$BUNDLE" 2>/dev/null | cut -f1)
        avail=$(df -Pk "$(p /srv)" 2>/dev/null | tail -1 | awk '{print $4}')
        if [ -n "$need" ] && [ -n "$avail" ] && [ "$avail" -gt "$need" ]; then
            pass "room for the copy: $((need / 1024)) MB needed, $((avail / 1024)) MB free under /srv"
        else
            fail "not enough room under /srv for the bundle copy (need ${need:-?} KB, have ${avail:-?} KB)"
        fi
    fi

    local prev
    prev=$(find "$(p /srv/bundles)" -maxdepth 1 -mindepth 1 -type d -name 'bundle-*' 2>/dev/null | sort | tail -1)
    if [ -n "$prev" ]; then
        pass "previous bundle present — the rollback: $prev"
    else
        warn "no previous bundle under /srv/bundles — this import has no bundle to roll back to (first cycle?)"
    fi
    footer "import preflight"
}

# ── gate ─────────────────────────────────────────────────────────────────────
cmd_gate() {
    banner "gate — the verifier that travels in the bundle"
    if [ -n "$DEVICE" ]; then
        [ -n "$MEDIA" ] || die "--device needs --media <mountpoint>"
        if findmnt -n "$MEDIA" >/dev/null 2>&1; then
            note "$MEDIA already mounted"
        else
            run mkdir -p "$MEDIA"
            run mount -o ro "$DEVICE" "$MEDIA" || die "could not mount $DEVICE read-only at $MEDIA"
            pass "mounted $DEVICE read-only at $MEDIA — a bundle that fails the gate must not be writable by the box that rejected it"
        fi
    fi
    local b rc=0
    b=$(bundle_dir "$BUNDLE") || exit 1
    bundle_verify "$b" || rc=$?
    echo
    echo "Exit 0 PASS · 2 PASS WITH WARNINGS (disposition each before importing) · 1 FAIL, do not import"
    case "$rc" in
        0) pass "bundle verified clean: $b" ;;
        2)
            warn "bundle verified WITH WARNINGS — each needs a written disposition in the cycle log"
            if [ "${KIT_YES:-0}" = "1" ]; then
                note "accepted via --yes; record the dispositions in the cycle log"
            elif [ "${KIT_NON_INTERACTIVE:-0}" = "1" ]; then
                fail "warnings need a decision and this run is non-interactive — rerun with --yes once dispositioned"
            else
                local a
                read -r -p "Import despite the warnings? [y/N] " a
                case "$a" in [yY]*) ;; *) fail "stopped at the gate by the operator" ;; esac
            fi ;;
        *) fail "the bundle FAILED verification — do not import; the media is suspect, re-cut on staging" ;;
    esac
    note "site AV/content scan of the media: confirm it was done per policy before proceeding (the kit cannot check this)"
    footer "gate"
}

# ── copy ─────────────────────────────────────────────────────────────────────
cmd_copy() {
    banner "copy to local storage"
    need_root
    local b name dest rc=0
    b=$(bundle_dir "$BUNDLE") || exit 1
    name=$(basename "$b")
    dest="$(p /srv/bundles)/$name"
    if [ -d "$dest" ] && stamped "copied.$name" && [ "$FORCE" != "1" ]; then
        pass "already copied: $dest (stamp present; --force to redo)"
    else
        run mkdir -p "$(p /srv/bundles)"
        run cp -a "$b" "$(p /srv/bundles)/" || die "copy failed — check space under /srv/bundles"
        if [ "$DRY" != "1" ]; then
            # Verifying after the copy catches a truncated or bit-flipped transfer.
            bundle_verify "$dest" || rc=$?
            case "$rc" in
                0) pass "copy verified clean at $dest" ;;
                2) warn "copy verified with warnings at $dest (same warnings as the media, presumably — compare)" ;;
                *) fail "the COPY failed verification — the transfer corrupted it; remove $dest and copy again" ;;
            esac
        fi
        [ "$FAILED" -eq 0 ] && stamp "copied.$name"
    fi
    if [ -n "$MEDIA" ] && findmnt -n "$MEDIA" >/dev/null 2>&1; then
        if run umount "$MEDIA"; then pass "unmounted $MEDIA"; else warn "could not unmount $MEDIA — unmount it by hand before removing the media"; fi
    fi
    note "next stages use --bundle $dest"
    footer "copy"
}

# ── apt ──────────────────────────────────────────────────────────────────────
apt_current() {
    echo "sources.list:"; sed 's/^/    /' "$(p /etc/apt/sources.list)" 2>/dev/null || echo "    (absent)"
    echo "sources.list.d/:"
    find "$(p /etc/apt/sources.list.d)" -maxdepth 1 -type f -printf '    %f\n' 2>/dev/null || echo "    (absent)"
    local f
    for f in "$(p /etc/apt/sources.list.d)"/*; do [ -f "$f" ] && sed "s|^|    $(basename "$f"): |" "$f"; done
    return 0
}
apt_proposed() {
    echo "sources.list:             (emptied)"
    echo "sources.list.d/:          moved aside to sources.list.d.upstream/"
    echo "sources.list.d/r770-local.list:"
    echo "    deb [trusted=yes] file:/srv/repo/apt ./"
    echo "then: apt-get update — must contact file:/srv/repo/apt and nothing else"
}
cmd_apt() {
    banner "apt — point the box at the local repo"
    need_root
    local b repo bak
    b=$(bundle_dir "$BUNDLE") || exit 1
    [ -s "$b/apt/Packages.gz" ] || die "$b/apt/Packages.gz is missing — the flat-repo index must be present; this bundle's apt/ is unusable"
    repo="$(p /srv/repo/apt)"
    run mkdir -p "$(p /srv/repo)"
    if [ -d "$repo" ] && [ "$FORCE" != "1" ] && cmp -s "$b/apt/Packages.gz" "$repo/Packages.gz"; then
        pass "local repo already holds this bundle's apt/ (Packages.gz identical)"
    else
        run rm -rf "$repo"
        run cp -a "$b/apt" "$repo" || die "could not copy apt/ into place"
        pass "apt/ copied to /srv/repo/apt ($(find "$repo" -name '*.deb' 2>/dev/null | wc -l) debs)"
    fi

    bak="$(p /root)/apt-sources-$(date +%F).tar.gz"
    run mkdir -p "$(p /root)"
    run tar czf "$bak" --ignore-failed-read -C "${ROOT:-/}" etc/apt/sources.list etc/apt/sources.list.d 2>/dev/null || true
    [ "$DRY" = "1" ] || [ -s "$bak" ] || die "could not write the sources backup $bak — refusing to touch APT without a rollback"
    pass "sources backed up to $bak"

    gate "rewrite APT sources to the local repo only" apt_current apt_proposed \
        "tar xzf $bak -C / && apt-get update      (restores sources.list and sources.list.d/)"

    local sld; sld="$(p /etc/apt/sources.list.d)"
    if [ -d "$sld" ] && [ "$(find "$sld" -maxdepth 1 -type f ! -name r770-local.list 2>/dev/null | wc -l)" -gt 0 ]; then
        if [ -d "$sld.upstream" ]; then
            run mkdir -p "$sld.upstream"
            local f; for f in "$sld"/*; do [ -f "$f" ] && [ "$(basename "$f")" != r770-local.list ] && run mv "$f" "$sld.upstream/"; done
        else
            run mv "$sld" "$sld.upstream"
        fi
    fi
    run mkdir -p "$sld"
    if [ "$DRY" = "1" ]; then
        echo "DRY-RUN: empty $(p /etc/apt/sources.list); write $sld/r770-local.list"
    else
        : > "$(p /etc/apt/sources.list)"
        echo 'deb [trusted=yes] file:/srv/repo/apt ./' > "$sld/r770-local.list"
    fi
    pass "sources rewritten: only file:/srv/repo/apt remains"

    local out rc=0 bad
    out=$(run apt-get update 2>&1) || rc=$?
    printf '%s\n' "$out" | sed 's/^/      /'
    bad=$(printf '%s\n' "$out" | grep -E '^(Get|Hit|Ign|Err):' | grep -v 'file:' || true)
    if [ "$DRY" = "1" ]; then
        note "dry run: apt-get update not executed"
    elif [ -n "$bad" ] || [ "$rc" -ne 0 ]; then
        fail "apt-get update reached something other than the local repo (or failed, rc=$rc):"
        printf '%s\n' "$bad" | sed 's/^/      /'
        note "restoring the previous sources from $bak"
        rm -rf "$sld"; tar xzf "$bak" -C "${ROOT:-/}" 2>/dev/null || true
        footer "apt"
    else
        pass "apt-get update contacted only file:/srv/repo/apt"
    fi
    footer "apt"
}

# ── phone-home ───────────────────────────────────────────────────────────────
ph_current() {
    local u
    for u in $PHONE_HOME_UNITS; do printf '    %-30s %s\n' "$u" "$(systemctl is-enabled "$u" 2>/dev/null || echo 'not-found')"; done
    printf '    %-30s %s\n' "snapd" "$(dpkg -s snapd >/dev/null 2>&1 && echo installed || echo absent)"
    printf '    %-30s %s\n' "motd-news" "$(grep -h '^ENABLED=' "$(p /etc/default/motd-news)" 2>/dev/null || echo 'no file')"
}
ph_proposed() {
    echo "    every unit above: systemctl disable --now"
    echo "    snapd: apt-get purge (nothing in this build needs snaps; the daemon phones home)"
    echo "    /etc/default/motd-news: ENABLED=0; /etc/update-motd.d/*: chmod -x"
    echo "    updates then arrive ONLY by bundle — the accepted cost of the air gap"
}
cmd_phone_home() {
    banner "phone-home — neutralise everything that would try the internet"
    need_root
    gate "disable phone-home paths" ph_current ph_proposed \
        "systemctl enable --now <unit> for any unit you want back; snapd comes back only from a bundle that carries the deb"
    local u
    for u in $PHONE_HOME_UNITS; do
        if run systemctl disable --now "$u" >/dev/null 2>&1; then
            pass "disabled $u"
        else
            note "$u: not present or already disabled"
        fi
    done
    if dpkg -s snapd >/dev/null 2>&1; then
        if run apt-get purge -y snapd; then pass "snapd purged"; else fail "snapd purge failed"; fi
    else
        pass "snapd not installed"
    fi
    local mn; mn="$(p /etc/default/motd-news)"
    if [ -f "$mn" ]; then
        if [ "$DRY" = "1" ]; then echo "DRY-RUN: set ENABLED=0 in $mn"; else sed -i 's/^ENABLED=.*/ENABLED=0/' "$mn"; fi
        pass "motd-news disabled"
    fi
    local d; d="$(p /etc/update-motd.d)"
    if [ -d "$d" ]; then
        run chmod -x "$d"/* 2>/dev/null || true
        pass "update-motd.d scripts made non-executable"
    fi
    footer "phone-home"
}

# ── docker ───────────────────────────────────────────────────────────────────
dk_current() {
    printf '    docker-ce: %s\n' "$(dpkg -s docker-ce 2>/dev/null | awk '/^Version:/{print $2}' || true)"
    echo "    candidate from the local repo:"
    apt-cache policy docker-ce 2>/dev/null | sed 's/^/      /' || echo "      (apt-cache unavailable)"
}
dk_proposed() {
    echo "    apt-get install -y $DOCKER_PKGS      (from file:/srv/repo/apt only)"
    echo "    systemctl enable --now docker"
    echo "    assert: data root /var/lib/docker on its own LV; no registry mirrors; no proxy"
}
cmd_docker() {
    banner "docker — engine from the bundle"
    need_root
    gate "install Docker Engine from the local repo" dk_current dk_proposed \
        "apt-get purge -y $DOCKER_PKGS"
    # shellcheck disable=SC2086
    run apt-get install -y $DOCKER_PKGS || die "apt-get install failed — the debs come from the bundle's apt/; check the apt stage"
    run systemctl enable --now docker || die "docker.service did not start"
    [ "$DRY" = "1" ] && { note "dry run: daemon assertions skipped"; footer "docker"; }

    local root mp mirrors proxy
    root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
    if [ "$root" = "/var/lib/docker" ]; then
        mp=$(findmnt -n -o TARGET -T /var/lib/docker 2>/dev/null || true)
        if [ "$mp" = "/var/lib/docker" ]; then
            pass "docker data root is /var/lib/docker on its own mount"
        else
            fail "docker data root /var/lib/docker is not a mount point (on '${mp:-?}') — image loads would fill the root filesystem"
        fi
    else
        fail "docker data root is '${root:-unknown}', expected /var/lib/docker"
    fi
    mirrors=$(docker info --format '{{.RegistryConfig.Mirrors}}' 2>/dev/null || true)
    if [ "$mirrors" = "[]" ]; then pass "no registry mirrors configured"; else fail "registry mirrors configured: ${mirrors:-?} — there is no registry to reach"; fi
    proxy=$(docker info --format '{{.HTTPProxy}}{{.HTTPSProxy}}' 2>/dev/null || true)
    if [ -z "$proxy" ]; then pass "no proxy configured in the daemon"; else fail "daemon proxy configured: $proxy — remove the drop-in; nothing should try to leave"; fi
    pass "docker $(docker info --format '{{.ServerVersion}}' 2>/dev/null || echo '?') responding"
    footer "docker"
}

# ── images ───────────────────────────────────────────────────────────────────
cmd_images() {
    banner "images — load every list/payload pair and assert every tag"
    need_root
    command -v docker >/dev/null 2>&1 || die "docker is not installed — run the docker stage first"
    local b pair list payload tar
    b=$(bundle_dir "$BUNDLE") || exit 1
    for pair in "${PAIRS[@]}"; do
        list="${pair%%|*}"; payload="${pair#*|}"
        tar=""
        for tar in "$b"/$payload; do [ -s "$tar" ] || tar=""; break; done
        if [ ! -s "$b/$list" ] && [ -z "$tar" ]; then
            note "$list: category not in this bundle"
            continue
        fi
        [ -s "$b/$list" ] || { fail "$payload present but $list missing — cannot verify the loaded tags"; continue; }
        [ -n "$tar" ] || { fail "$list present but $payload missing — this bundle cannot import that category"; continue; }
        if [ "$FORCE" != "1" ] && assert_image_tags "$b/$list" >/dev/null 2>&1; then
            pass "$list: every tag already present — load skipped"
            continue
        fi
        run docker load -i "$tar" || { fail "docker load failed for $tar"; continue; }
        [ "$DRY" = "1" ] && continue
        # `docker load` reports success even when the resulting tag set is
        # incomplete: assert against the list that travelled with the tarball.
        if assert_image_tags "$b/$list"; then
            pass "$list: every tag present after load"
        else
            fail "$list: tag(s) missing after load — the tarball is incomplete; re-cut, do not patch by hand"
        fi
    done
    footer "images"
}

# ── files ────────────────────────────────────────────────────────────────────
copy_into() {  # copy_into <src-glob-dir> <dest> [stamp]
    local src=$1 dest=$2 tag=${3:-}
    if [ -n "$tag" ] && stamped "$tag" && [ "$FORCE" != "1" ]; then
        pass "$dest: already in place (stamp $tag)"
        return 0
    fi
    run mkdir -p "$dest"
    local f n=0
    for f in "$src"/*; do
        [ -e "$f" ] || continue
        run cp -a "$f" "$dest/" && n=$((n + 1))
    done
    pass "$dest: $n item(s) copied from $(basename "$src")/"
    [ -n "$tag" ] && stamp "$tag"
    return 0
}

cmd_files() {
    banner "files — payload into place"
    need_root
    local b name
    b=$(bundle_dir "$BUNDLE") || exit 1
    name=$(basename "$b")

    # VM base images
    if [ -d "$b/images" ]; then
        copy_into "$b/images" "$(p /srv/vms/base)" "files.$name.images"
        if command -v qemu-img >/dev/null 2>&1 && [ "$DRY" != "1" ]; then
            local img
            for img in "$(p /srv/vms/base)"/*.img "$(p /srv/vms/base)"/*.qcow2; do
                [ -e "$img" ] && { note "$(basename "$img"): $(qemu-img info "$img" 2>&1 | grep -E '^(file format|virtual size)' | tr '\n' ' ')"; }
            done
        else
            note "qemu-img not available yet — image formats will be confirmed after Phase 7"
        fi
    fi

    # GNS3 definitions and appliance images
    if [ -d "$b/gns3/definitions" ]; then
        copy_into "$b/gns3/definitions" "$(p /srv/gns3/appliances)" "files.$name.definitions"
    fi
    if [ -d "$b/gns3/appliances" ]; then
        local imgdir ckdir f n=0
        imgdir="$(p /srv/gns3/images)"; ckdir="$imgdir/checksums"
        run mkdir -p "$imgdir" "$ckdir"
        for f in "$b/gns3/appliances"/*; do
            [ -f "$f" ] || continue
            case "$(basename "$f")" in
                README.txt) continue ;;
                *.sha256|*.minisig|*.sig|*.asc|*.sha) run cp -a "$f" "$ckdir/" ;;
                *) run cp -a "$f" "$imgdir/" && n=$((n + 1)) ;;
            esac
        done
        if [ "$n" -gt 0 ]; then
            pass "gns3 appliance images: $n file(s) into /srv/gns3/images (checksums beside them in checksums/)"
        else
            warn "gns3/appliances/ holds no images beyond README.txt — licensed appliances were not staged"
        fi
        # A definition whose image was never staged shows in the GUI and fails at boot.
        local def key hit
        [ "$DRY" = "1" ] && note "dry run: definition-vs-image check skipped"
        for def in "$b/gns3/definitions"/*.gns3a; do
            [ "$DRY" = "1" ] && break
            [ -e "$def" ] || continue
            key=$(basename "$def" .gns3a); hit=0
            local part
            for part in ${key//-/ }; do
                [ "${#part}" -ge 3 ] || continue
                if find "$imgdir" -maxdepth 1 -iname "*${part}*" 2>/dev/null | grep -q .; then hit=1; fi
            done
            [ "$hit" -eq 1 ] || warn "definition without image: $key — it will appear in GNS3 and fail at boot until its image is staged"
        done
    fi

    # Enrichment data (Suricata rules staged, not active; GeoIP descoped)
    if [ -d "$b/enrichment" ]; then
        local ed; ed="$(p /opt/enrichment)"
        copy_into "$b/enrichment" "$ed" "files.$name.enrichment"
        if [ -s "$ed/emerging.rules.tar.gz" ]; then
            run mkdir -p "$ed/rules"
            run tar xzf "$ed/emerging.rules.tar.gz" -C "$ed/rules" && pass "ET rules extracted to /opt/enrichment/rules (staged only — Suricata is disabled by decision)"
        fi
    fi

    # Docs mirrors — best-effort by design; reading material only
    if [ -d "$b/docs" ]; then
        local dd; dd="$(p /srv/docs)"
        copy_into "$b/docs" "$dd" "files.$name.docs"
        local t
        for t in "$dd"/*.tar.gz; do
            [ -e "$t" ] || continue
            run tar xzf "$t" -C "$dd" && note "extracted $(basename "$t")"
        done
    fi

    note "the GNS3 wheelhouse stays in the bundle; r770-gns3-deploy.sh venv reads it from $b/gns3/wheelhouse"
    footer "files"
}

# ── status ───────────────────────────────────────────────────────────────────
cmd_status() {
    banner "import status"
    local d
    for d in "$(p /srv/bundles)"/bundle-*; do [ -d "$d" ] && echo "bundle on box: $d"; done
    echo "stamps:"; find "$(p /srv/bundles/.kit-stamps)" -maxdepth 1 -type f -printf '    %f\n' 2>/dev/null || echo "    (none)"
    echo "apt sources.list.d: $(find "$(p /etc/apt/sources.list.d)" -maxdepth 1 -type f -printf '%f ' 2>/dev/null)"
    if command -v docker >/dev/null 2>&1; then
        echo "docker root: $(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo '(daemon not responding)')"
        echo "images loaded: $(docker image ls -q 2>/dev/null | wc -l)"
    else
        echo "docker: not installed"
    fi
    [ -n "$BUNDLE" ] && [ -d "$BUNDLE" ] && for pair in "${PAIRS[@]}"; do
        [ -s "$BUNDLE/${pair%%|*}" ] && { assert_image_tags "$BUNDLE/${pair%%|*}" | tail -1; }
    done
    return 0
}

# ── dispatch ─────────────────────────────────────────────────────────────────
SUB="${1:-}"; [ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
    case "$1" in
        --bundle)  BUNDLE="${2:-}"; shift ;;
        --media)   MEDIA="${2:-}";  shift ;;
        --device)  DEVICE="${2:-}"; shift ;;
        -h|--help) usage ;;
        *)         common_flag "$1" || die "unknown option: $1 (try --help)" ;;
    esac
    shift
done
kit_init "r770-import-bundle"
case "$SUB" in
    preflight)  cmd_preflight ;;
    gate)       cmd_gate ;;
    copy)       cmd_copy ;;
    apt)        cmd_apt ;;
    phone-home) cmd_phone_home ;;
    docker)     cmd_docker ;;
    images)     cmd_images ;;
    files)      cmd_files ;;
    status)     cmd_status ;;
    -h|--help|help|"") usage ;;
    *)          die "unknown subcommand: $SUB (try --help)" ;;
esac
