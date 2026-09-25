#!/usr/bin/env bash
#
# r770-malcolm-deploy.sh — stand Malcolm up from the bundle, offline, in the
# order the staging rehearsal of 2026-09-12 proved and with every trap it hit
# encoded as a refusal.
#
#   r770-malcolm-deploy.sh <subcommand> [--bundle <dir>] [options]
#
#   load          docker load the Malcolm tarball, then assert every tag
#   assert-tags   the tag check alone (docker load lies by omission)
#   unpack        unzip the bundled installer into /opt/malcolm
#   configure     render the kit's config template, replay it through the
#                 installer (--import-malcolm-config-file), then rebind
#   secrets       generate the admin password file once (never printed)
#   auth          Malcolm's auth_setup, unattended, hashes generated on the box
#   rebind        publish nginx-proxy on 127.0.0.1:8443 instead of 0.0.0.0:443
#   start         Malcolm's own ./scripts/start, then wait for health
#   stop          Malcolm's own ./scripts/stop
#   status        what is in place
#   inventory     what saved objects Dashboards holds NOW, read-only — the
#                 only honest source for what this Malcolm actually ships
#   dashboards    install the kit's saved objects, then assert every id back
#   arkime-views  install the kit's Arkime views, then read every one back
#   full          the whole Malcolm pipeline, in order, stopping at the first
#                 step that refuses: preflight gate copy apt phone-home
#                 docker files load unpack configure secrets auth rebind
#                 start (see --from/--to/--only)
#
#   --bundle <dir>             the bundle (on the media for preflight/gate/copy
#                              under `full`, local after)
#   --media <mnt>              mountpoint of the transfer media, for `full`'s
#                              gate/copy steps (gate mounts, copy unmounts)
#   --device <dev>             block device to mount read-only at --media, for
#                              `full`'s gate step — a DISCOVERED name, never a
#                              guess
#   --from STEP / --to STEP    restrict `full` to a slice of its steps
#   --only STEP                sugar for --from STEP --to STEP
#   --arkime-free-space-g N    let Arkime delete oldest raw PCAP below N GB free
#                              (Phase 10 sets this from measured feed rates;
#                              default: no automatic deletion)
#   --index-pattern <id|title> which Dashboards index pattern the saved objects
#                              attach to. Needed only when the stack carries
#                              more than one: the kit refuses to pick for you,
#                              it does not guess (run `inventory` to see them)
#   --capture-ifs "<if ...>"   live capture (Arkime + Zeek) on these interfaces,
#                              for configure (and full). Each must exist and
#                              carry no address: discovered names, never
#                              guessed -- on staging, the lab mirror
#                              lab-mirror0 (r770-gns3-deploy.sh labnet first).
#                              Without it, live capture stays off.
#   --yes / --non-interactive / --dry-run / --force   as everywhere in the kit
#
#   MALCOLM_HOME        /opt/malcolm        MALCOLM_ADMIN_USER   analyst
#   MALCOLM_WAIT_SECS   600                 MALCOLM_OS_MEM_G / MALCOLM_LS_MEM_M
#                                           override the heaps computed from free -g
#
#   0  done · 2  done with warnings · 1  refused or failed
#
# Rehearsal lessons this encodes: install.py needs root and --non-interactive
# (--defaults alone opens a TUI and waits); auth_setup is mandatory before
# start or compose refuses on missing bind sources; a compose override file is
# ignored (control.py passes -f), so the port rebind is an assert-then-sed
# re-applied after every installer run; start with Malcolm's own script, never
# raw `docker compose up`; the installer needs python3-ruamel.yaml and
# python3-dotenv from the bundle's apt/.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

BUNDLE=""; FREE_G=""; IDX=""; OSD_NETRC=""
CAPTURE_IFS=""; CAPTURE_SET=0
MEDIA=""; DEVICE=""; FROM=""; TO=""; ONLY=""
MALCOLM_HOME="${MALCOLM_HOME:-/opt/malcolm}"
ADMIN_USER="${MALCOLM_ADMIN_USER:-analyst}"
WAIT_SECS="${MALCOLM_WAIT_SECS:-600}"
AUTH_FLAGS=(--auth-noninteractive --auth-method --auth-admin-username --auth-admin-password-openssl
            --auth-admin-password-htpasswd --auth-generate-webcerts --auth-generate-fwcerts
            --auth-generate-netbox-passwords --auth-generate-valkey-password
            --auth-generate-postgres-password --auth-generate-opensearch-internal-creds
            --auth-generate-keycloak-db-password)
INSTALL_FLAGS=(--non-interactive --skip-splash --configure --import-malcolm-config-file --export-malcolm-config-file)
REBIND_FROM='^    - 0.0.0.0:443:443/tcp$'
REBIND_TO='    - 127.0.0.1:8443:443/tcp'
SECRET="/etc/lab/secrets/malcolm-admin.pw"
STEPS=(preflight gate copy apt phone-home docker files load unpack configure secrets auth rebind start)
# test seam: lets a suite stub out every call this script makes to
# r770-import-bundle.sh under `full`, and record what was called.
IMPORT_BUNDLE_CMD="${IMPORT_BUNDLE_CMD:-$KIT_DIR/scripts/r770-import-bundle.sh}"

usage() { usage_from_header 3; exit 0; }
home()      { p "$MALCOLM_HOME"; }
installer() { printf '%s/scripts/install.py' "$(home)"; }
stack()     { printf '%s/malcolm' "$(home)"; }
compose()   { printf '%s/docker-compose.yml' "$(stack)"; }
local_bundle() {  # after copy, the bundle lives under /srv/bundles
    local l; l="$(p /srv/bundles)/$(basename "$BUNDLE")"
    if [ -d "$l" ]; then printf '%s' "$l"; else printf '%s' "$BUNDLE"; fi
}

# ── load / assert-tags (behaviour-identical to the build repo's script) ─────
cmd_assert_tags() {
    local b; b=$(bundle_dir "$BUNDLE") || exit 1
    assert_image_tags "$b/malcolm/image-list.txt" || die "image(s) missing after load — the tarball is incomplete or the load failed"
}
cmd_load() {
    local b tar; b=$(bundle_dir "$BUNDLE") || exit 1
    tar=$(find "$b/malcolm" -maxdepth 1 -name 'malcolm-images-*.tar.gz' | head -1)
    [ -n "$tar" ] || die "no malcolm-images-*.tar.gz under $b/malcolm"
    echo "loading $tar ..."
    run docker load -i "$tar" || die "docker load failed"
    [ "$DRY" = "1" ] || cmd_assert_tags
}

# ── unpack ───────────────────────────────────────────────────────────────────
cmd_unpack() {
    banner "unpack the bundled installer"
    need_root
    local b zip; b=$(bundle_dir "$BUNDLE") || exit 1
    # Both were missing from the first bundle and would have failed on the
    # R770 after the media crossed the gap, costing a full cycle.
    require_pkg python3-ruamel.yaml python3-dotenv
    zip=$(glob_one "$b/malcolm" 'malcolm-*-docker_install.zip') || exit 1
    if [ -f "$(installer)" ] && [ "$FORCE" != "1" ]; then
        pass "installer already unpacked at $(installer) (--force to redo)"
    else
        run mkdir -p "$(home)"
        run unzip -o -q "$zip" -d "$(home)" || die "unzip failed — is unzip installed from the bundle's apt/?"
        if [ "$DRY" = "1" ] || [ -f "$(installer)" ]; then
            pass "installer unpacked: $(installer)"
        else
            fail "unzip finished but $(installer) is not there — the zip's layout is not the one this kit expects; read BUNDLE_NOTES.md"
        fi
    fi
    footer "unpack"
}

# ── configure ────────────────────────────────────────────────────────────────

# capture_json — check --capture-ifs and print it as a JSON list ("[]" when
# not given). Each name must look like an interface, exist, carry no address
# (rule 8), and appear once. Interfaces are given, never guessed.
capture_json() {
    local i seen=" " json="" n=0 ifs=()
    [ "$CAPTURE_SET" = "1" ] || { printf '[]'; return 0; }
    read -ra ifs <<< "$CAPTURE_IFS"
    for i in "${ifs[@]}"; do
        [[ "$i" =~ ^[A-Za-z0-9._-]{1,15}$ ]] || die "--capture-ifs: '$i' is not an interface name"
        case "$seen" in *" $i "*) die "--capture-ifs names $i twice" ;; esac
        seen="$seen$i "
        if [ ! -e "$(p /sys/class/net)/$i" ]; then
            case "$i" in
                lab-*) die "capture interface $i does not exist — create the lab network first: r770-gns3-deploy.sh labnet" ;;
                *)     die "capture interface $i does not exist — capture interfaces come from discovery (ip -br link), never guessed" ;;
            esac
        fi
        [ -z "$(ip -o addr show dev "$i" 2>/dev/null)" ] || die "capture interface $i carries an address — capture interfaces never get one (rule 8)"
        json="$json${json:+, }\"$i\""
        n=$((n + 1))
    done
    [ "$n" -gt 0 ] || die "--capture-ifs was given but names no interface"
    printf '[%s]' "$json"
}

# pcap_ifaces_of <config.json> — the pcapIface list, on one line, whether the
# file writes it on one line or one element per line.
pcap_ifaces_of() {
    awk '/"pcapIface"/ { f = 1 } f { printf "%s", $0; if (/]/) exit }' "$1" \
        | sed -e 's/.*"pcapIface"[[:space:]]*:[[:space:]]*\(\[[^]]*\]\).*/\1/' \
              -e 's/\[[[:space:]]*/[/' -e 's/[[:space:]]*\]/]/' -e 's/,[[:space:]]*/, /g'
}
# live_kept <exported> <iface...> — the installer rewrites what it imports;
# prove its export still says live capture is on, on every given interface.
# Whitespace-tolerant, and pcapIface is read by pcap_ifaces_of.
live_kept() {
    local x=$1 k i lst missing=0; shift
    if [ ! -f "$x" ]; then
        fail "the installer wrote no exported config at $x — live capture is unconfirmed; read its output above"
        return 0
    fi
    for k in captureLiveNetworkTraffic liveArkime liveZeek; do
        grep -qE "\"$k\"[[:space:]]*:[[:space:]]*true" "$x" && continue
        fail "the installer did not keep \"$k\": true — live capture will not start; read $x"
        missing=1
    done
    lst=$(pcap_ifaces_of "$x")
    for i in "$@"; do
        [[ "$lst" == *"\"$i\""* ]] && continue
        fail "the installer did not keep \"pcapIface\" with $i — live capture will not start on it; read $x"
        missing=1
    done
    [ "$missing" -eq 1 ] || pass "the installer kept live capture on $* (captureLiveNetworkTraffic, liveArkime, liveZeek, pcapIface)"
}
malcolm_version_from_zip() {  # numeric components lose their leading zeros, as the installer's own export writes them
    local name=$1 v part out=""
    v=${name#malcolm-}; v=${v%-docker_install.zip}
    for part in ${v//./ }; do
        [[ $part =~ ^[0-9]+$ ]] && part=$((10#$part))   # numeric components lose leading zeros
        out="${out:+$out.}$part"
    done
    [ -n "$out" ] || die "cannot derive a version from '$name'"
    printf '%s' "$out"
}
heap_sizes() {  # prints "<os-g> <ls-m>" from the host's memory, unless overridden
    local total os ls
    total=$(free -g | awk '/^Mem:/{print $2}')
    [ -n "$total" ] || total=8
    os=$(( total * 3 / 16 ))                  # buildout §8: 24 GB on 128 GB
    [ "$os" -lt 2 ]  && os=2
    [ "$os" -gt 31 ] && os=31                 # never above 31g: compressed oops
    ls=$(( os * 1024 / 6 ))
    [ "$ls" -lt 2500 ] && ls=2500
    printf '%s %s' "${MALCOLM_OS_MEM_G:-$os}" "${MALCOLM_LS_MEM_M:-$ls}"
}
cmd_configure() {
    banner "configure — replay the kit's config through the installer"
    need_root
    local b zip ver os ls rendered exported manage free ifaces live
    b=$(bundle_dir "$BUNDLE") || exit 1
    [ -f "$(installer)" ] || die "$(installer) not found — run unpack first"
    require_pkg python3-ruamel.yaml python3-dotenv
    help_has_flags python3 "$(installer)" -- "${INSTALL_FLAGS[@]}"
    zip=$(glob_one "$b/malcolm" 'malcolm-*-docker_install.zip') || exit 1
    ver=$(malcolm_version_from_zip "$(basename "$zip")")
    read -r os ls <<< "$(heap_sizes)"
    if [ -n "$FREE_G" ]; then manage=true; free="$FREE_G"; else manage=false; free='<MALCOLM_CONFIG_NONE>'; fi
    ifaces=$(capture_json) || exit 1
    if [ "$ifaces" = "[]" ]; then live=false; else live=true; fi
    rendered="$(home)/malcolm-config.rendered.json"
    exported="$(home)/malcolm-config.exported.json"
    note "version from the bundled installer's filename: $ver"
    note "heaps from this host: OpenSearch ${os}g, Logstash ${ls}m (override: MALCOLM_OS_MEM_G / MALCOLM_LS_MEM_M)"
    note "PCAP -> /data/pcap/raw, indexes -> /data/index, Suricata off, no feed pulls; Arkime PCAP management: $manage"
    if [ "$live" = "true" ]; then note "live capture on: $CAPTURE_IFS (Arkime + Zeek; Suricata stays off)"; else note "live capture off (no --capture-ifs)"; fi
    run mkdir -p "$(home)"
    render "$KIT_CONFIG_DIR/malcolm/malcolm-config.json.template" "$rendered" \
        "PCAP_NODE_NAME=$(hostname -s)" "OS_MEMORY=${os}g" "LS_MEMORY=${ls}m" \
        "ARKIME_MANAGE_PCAP=$manage" "ARKIME_FREE_SPACE_G=$free" "MALCOLM_VER=$ver" \
        "PCAP_IFACE=$ifaces" "CAPTURE_LIVE=$live" "LIVE_ARKIME=$live" "LIVE_ZEEK=$live"
    run python3 "$(installer)" --non-interactive --skip-splash --configure \
        --import-malcolm-config-file "$rendered" --export-malcolm-config-file "$exported" \
        || die "the installer failed — its output above is the evidence; nothing else was changed"
    if [ "$DRY" != "1" ]; then
        [ -f "$(compose)" ] || die "the installer did not produce $(compose) — read its output"
        pass "installer configured $(stack); exported config at $exported"
        if [ "$live" = "true" ]; then local ifl; read -ra ifl <<< "$CAPTURE_IFS"; live_kept "$exported" "${ifl[@]}"; fi
        if [ -d "$(stack)/pcap/upload" ]; then
            if run chown 1000:1000 "$(stack)/pcap/upload"; then pass "pcap/upload owned by 1000:1000 (the drop-off the rehearsal measured)"; fi
        fi
    fi
    do_rebind
    footer "configure"
}

# ── secrets / auth ───────────────────────────────────────────────────────────
cmd_secrets() { banner "secrets"; need_root; secret_file "$(p "$SECRET")"; pass "admin credential location: $SECRET"; footer "secrets"; }

cmd_auth() {
    banner "auth — Malcolm's auth_setup, unattended"
    need_root
    local b setup pw h_ssl h_ht img
    b=$(bundle_dir "$BUNDLE") || exit 1
    setup="$(stack)/scripts/auth_setup"
    [ -x "$setup" ] || die "$setup not found — run configure first (the installer extracts the stack)"
    if [ -s "$(stack)/nginx/htpasswd" ] && [ "$FORCE" != "1" ]; then
        pass "auth material already present ($(stack)/nginx/htpasswd); --force regenerates certs and keystores too"
        footer "auth"
    fi
    help_has_flags "$setup" -- "${AUTH_FLAGS[@]}"
    pw=$(secret_read "$(p "$SECRET")") || exit 1
    img=$(image_ref_from_list "$b/malcolm/image-list.txt" nginx-proxy) || exit 1
    if [ "$DRY" = "1" ]; then
        echo "DRY-RUN: openssl passwd -1 <admin password>"
        echo "DRY-RUN: docker run --rm --network none --entrypoint sh $img -c 'htpasswd -bnBC 10 \"\" <admin password>'"
        echo "DRY-RUN: (cd $(stack) && ./scripts/auth_setup ${AUTH_FLAGS[*]} ...)"
        footer "auth"
    fi
    h_ssl=$(openssl passwd -1 "$pw") || die "openssl passwd failed"
    # bcrypt from the bundled nginx-proxy image: the only htpasswd guaranteed
    # on the box, and the tag comes from the bundle's list, never from here.
    echo "+ docker run --rm --network none --entrypoint sh $img -c 'htpasswd -bnBC 10 ...'   (credential passed by environment, not shown)"
    h_ht=$(docker run --rm --network none -e PW="$pw" --entrypoint sh "$img" \
             -c 'htpasswd -bnBC 10 "" "$PW"' | tr -d ':\n') || die "htpasswd via $img failed — are the Malcolm images loaded?"
    [ -n "$h_ht" ] || die "empty bcrypt hash from $img"
    echo "+ (cd $(stack) && ./scripts/auth_setup --auth-noninteractive --auth-method basic --auth-admin-username $ADMIN_USER --auth-admin-password-openssl <hash> --auth-admin-password-htpasswd <hash> --auth-generate-...)"
    ( cd "$(stack)" && ./scripts/auth_setup --auth-noninteractive --auth-method basic \
        --auth-admin-username "$ADMIN_USER" \
        --auth-admin-password-openssl "$h_ssl" --auth-admin-password-htpasswd "$h_ht" \
        --auth-generate-webcerts --auth-generate-fwcerts \
        --auth-generate-netbox-passwords --auth-generate-valkey-password \
        --auth-generate-postgres-password --auth-generate-opensearch-internal-creds \
        --auth-generate-keycloak-db-password ) || die "auth_setup failed — see its output above"
    if [ -s "$(stack)/nginx/htpasswd" ]; then
        pass "auth material generated (htpasswd, web/forward certs, keystores); admin user '$ADMIN_USER'"
    else
        fail "auth_setup returned success but $(stack)/nginx/htpasswd is absent — compose will refuse to start"
    fi
    footer "auth"
}

# ── rebind ───────────────────────────────────────────────────────────────────
do_rebind() {
    local c; c=$(compose)
    [ -f "$c" ] || die "$c not found — run configure first"
    if [ "$(grep -cF -- "$REBIND_TO" "$c")" -eq 1 ] && ! grep -qE -- "$REBIND_FROM" "$c"; then
        pass "nginx-proxy already bound to 127.0.0.1:8443 in $(basename "$c")"
        return 0
    fi
    assert_edit "$c" "$REBIND_FROM" 1
    if [ "$DRY" = "1" ]; then
        echo "DRY-RUN: sed -i 's|$REBIND_FROM|$REBIND_TO|' $c"
        return 0
    fi
    sed -i "s|${REBIND_FROM}|${REBIND_TO}|" "$c"
    [ "$(grep -cF -- "$REBIND_TO" "$c")" -eq 1 ] || die "rebind edit did not take in $c"
    pass "nginx-proxy publish rewritten: 0.0.0.0:443 -> 127.0.0.1:8443 (the front door owns 443)"
}
cmd_rebind() { banner "rebind"; need_root; do_rebind; footer "rebind"; }

# ── start / stop / status ────────────────────────────────────────────────────
cmd_start() {
    banner "start — Malcolm's own start script, then wait for health"
    need_root
    local s; s="$(stack)/scripts/start"
    [ -x "$s" ] || die "$s not found — run configure first"
    [ -s "$(stack)/nginx/htpasswd" ] || die "no auth material — run auth first (compose would refuse: bind sources missing)"
    grep -qE -- "$REBIND_FROM" "$(compose)" && die "compose still publishes 0.0.0.0:443 — run rebind first (it must follow every installer run)"
    run bash -c "cd '$(stack)' && ./scripts/start" || die "Malcolm's start script failed — see above"
    [ "$DRY" = "1" ] && footer "start"

    local waited=0 step=15 out notready total
    [ "$WAIT_SECS" -lt "$step" ] && step="$WAIT_SECS"
    while :; do
        out=$(cd "$(stack)" 2>/dev/null && docker compose ps --format '{{.Service}} {{.State}} {{.Health}}' 2>/dev/null; true)
        total=$(printf '%s\n' "$out" | grep -c . || true)
        notready=$(printf '%s\n' "$out" | grep -vE ' running (healthy)?$' | grep -c . || true)
        if [ "$total" -gt 0 ] && [ "$notready" -eq 0 ]; then
            pass "all $total services running/healthy after ${waited}s"
            break
        fi
        if [ "$waited" -ge "$WAIT_SECS" ]; then
            printf '%s\n' "$out" | sed 's/^/      /'
            fail "$notready of $total services not ready after ${WAIT_SECS}s — arkime and logstash are the last to go healthy (~6 min on the rehearsal VM); rerun start to keep waiting, or read 'docker compose logs'"
            break
        fi
        sleep "$step"; waited=$((waited + step))
    done
    local ss_out; ss_out=$(ss -ltn 2>/dev/null || true)
    if printf '%s\n' "$ss_out" | grep -q '127\.0\.0\.1:8443 '; then pass "nginx-proxy listening on 127.0.0.1:8443"; else fail "nothing listening on 127.0.0.1:8443"; fi
    if printf '%s\n' "$ss_out" | grep -qE '(0\.0\.0\.0|\*):443 '; then
        warn "something listens on 0.0.0.0:443 — expected only once the front door's nginx is up; if this is Malcolm, the rebind did not take"
    else
        pass "nothing on 0.0.0.0:443 from Malcolm"
    fi
    footer "start"
}
cmd_stop() {
    banner "stop"; need_root
    local s; s="$(stack)/scripts/stop"
    [ -x "$s" ] || die "$s not found"
    if run bash -c "cd '$(stack)' && ./scripts/stop"; then pass "stopped"; else fail "stop script failed"; fi
    footer "stop"
}
cmd_status() {
    banner "malcolm status"
    local inst=absent st=absent
    [ -f "$(installer)" ] && inst=present
    [ -f "$(compose)" ] && st="$(stack)"
    printf '%-28s %s\n' "installer" "$inst"
    printf '%-28s %s\n' "stack" "$st"
    if [ -f "$(compose)" ]; then
        if grep -qF -- "$REBIND_TO" "$(compose)"; then printf '%-28s %s\n' "nginx-proxy bind" "127.0.0.1:8443 (rebound)"; else printf '%-28s %s\n' "nginx-proxy bind" "NOT rebound"; fi
    fi
    printf '%-28s %s\n' "auth material" "$([ -s "$(stack)/nginx/htpasswd" ] && echo present || echo absent)"
    local rc live="off" label=""
    rc="$(home)/malcolm-config.exported.json"   # what the installer kept
    if [ ! -f "$rc" ]; then rc="$(home)/malcolm-config.rendered.json"; label=" (rendered, not yet confirmed)"; fi
    if [ -f "$rc" ]; then
        if grep -qE '"captureLiveNetworkTraffic"[[:space:]]*:[[:space:]]*true' "$rc"; then
            live="on $(pcap_ifaces_of "$rc")"
        fi
        printf '%-28s %s\n' "live capture" "$live$label"
    fi
    printf '%-28s %s\n' "admin credential" "$([ -s "$(p "$SECRET")" ] && echo "present at $SECRET" || echo absent)"
    if command -v docker >/dev/null 2>&1 && [ -f "$(compose)" ]; then
        ( cd "$(stack)" && docker compose ps --format '{{.Service}} {{.State}} {{.Health}}' 2>/dev/null | sed 's/^/    /' ) || true
    fi
    return 0
}

# ── dashboards and arkime views ──────────────────────────────────────────────
# Everything below reaches the stack through the rebound proxy on
# 127.0.0.1:8443 — the entry point `rebind` guarantees, and the only one the
# air gap admits. The admin credential never reaches argv or the transcript:
# curl reads it from a 0600 netrc that lives only for the length of the run.
# There is no jq on this box, so every response is read with sed and grep, and
# any shape this kit was not written for is a refusal, never a guess.
osd_cleanup() {
    if [ -n "$OSD_NETRC" ]; then rm -f "$OSD_NETRC"; fi
    OSD_NETRC=""
}
osd_auth_file() {
    local pw
    pw=$(secret_read "$(p "$SECRET")") || exit 1
    OSD_NETRC=$(mktemp) || die "mktemp failed"
    chmod 600 "$OSD_NETRC"
    printf 'machine 127.0.0.1 login %s password %s\n' "$ADMIN_USER" "$pw" > "$OSD_NETRC"
    trap osd_cleanup EXIT
}
osd_api() {  # osd_api <method> <path> [extra args...]
    local m=$1 path=$2; shift 2
    curl -sS -k --max-time 60 --netrc-file "$OSD_NETRC" -X "$m" -H 'osd-xsrf: true' "https://127.0.0.1:8443/dashboards${path}" "$@"
}
arkime_api() {  # arkime_api <method> <path> [extra args...]
    local m=$1 path=$2; shift 2
    curl -sS -k --max-time 60 --netrc-file "$OSD_NETRC" -X "$m" -H 'Content-Type: application/json' "https://127.0.0.1:8443/arkime${path}" "$@"
}
# osd_reachable — a named SKIP beats a wall of curl errors when the stack is
# simply not up yet.
osd_reachable() { osd_api GET "/api/status" --fail >/dev/null 2>&1; }

# osd_objects <find-query> — "<type> <id> <title>" per line. Each object is put
# on a line of its own first; that is as much JSON as bash should ever parse.
osd_objects() {
    local q=$1
    # `|| [ -n "$line" ]`: an API response has no trailing newline, and a plain
    # `while read` drops its last line — which would report an empty stack.
    osd_api GET "/api/saved_objects/_find?${q}" | sed 's/},{/}\n{/g' | while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in *'"type":"'*) ;; *) continue ;; esac
        local id type title
        id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
        type=$(printf '%s' "$line" | sed -n 's/.*"type":"\([^"]*\)".*/\1/p')
        title=$(printf '%s' "$line" | sed -n 's/.*"title":"\([^"]*\)".*/\1/p')
        [ -n "$id" ] || continue
        printf '%s %s %s\n' "${type:-unknown}" "$id" "${title:-<untitled>}"
    done
}

# resolve_index_pattern — the id the kit's saved objects attach to. Given
# --index-pattern it takes that (by id or by title); given nothing it accepts
# exactly one and refuses to choose between several. Zero and many are both
# refusals, as in image_ref_from_list: the kit never picks for the operator.
resolve_index_pattern() {
    local all hits n
    all=$(osd_objects 'type=index-pattern&per_page=1000&fields=title')
    n=$(printf '%s' "$all" | grep -c . || true)
    [ "$n" -gt 0 ] || die "Dashboards holds no index pattern — Malcolm has not finished its first-run import yet, or this is not the stack you think it is"
    if [ -n "$IDX" ]; then
        hits=$(printf '%s\n' "$all" | awk -v want="$IDX" '{ t=$0; sub(/^[^ ]+ [^ ]+ /,"",t); if ($2==want || t==want) print $2 }')
        [ -n "$hits" ] || die "no index pattern with id or title '$IDX' — run 'inventory' to see what this stack carries"
        printf '%s\n' "$hits" | head -1
        return 0
    fi
    if [ "$n" -ne 1 ]; then
        printf '%s\n' "$all" | sed 's/^/      /' >&2
        die "${n} index patterns on this stack — name one with --index-pattern <id|title>; the kit does not choose for you"
    fi
    printf '%s\n' "$all" | awk '{print $2}'
}

# assert_saved_objects <ndjson> — every object the file declares is really
# there afterwards. The import API reports success for a partial import exactly
# as it reports a whole one, which is the lie `docker load` also tells.
assert_saved_objects() {
    local f=$1 bn line id type missing=0 total=0
    bn=$(basename "$f")
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        id=$(printf '%s' "$line" | sed -n 's/^{"id":"\([^"]*\)","type":"\([^"]*\)".*/\1/p')
        type=$(printf '%s' "$line" | sed -n 's/^{"id":"\([^"]*\)","type":"\([^"]*\)".*/\2/p')
        if [ -z "$id" ] || [ -z "$type" ]; then
            die "refusing to verify ${bn}: a line does not begin {\"id\":...,\"type\":...} — the file's shape is not the one this check was written for"
        fi
        total=$((total + 1))
        if osd_api GET "/api/saved_objects/${type}/${id}" | grep -qF "\"id\":\"${id}\""; then
            echo "ok      ${type}/${id}"
        else
            echo "MISSING ${type}/${id}"
            missing=$((missing + 1))
        fi
    done < "$f"
    [ "$total" -gt 0 ] || die "no saved objects declared in $f"
    if [ "$missing" -gt 0 ]; then
        fail "${missing} of ${total} object(s) absent after import — the import reported success but did not land them"
        return 1
    fi
    pass "all ${total} saved object(s) present"
}

cmd_inventory() {
    banner "inventory — what this Dashboards holds now"
    need_root
    osd_auth_file
    if ! osd_reachable; then
        skip "Dashboards did not answer on 127.0.0.1:8443 — start the stack first; nothing was read or changed"
        footer "inventory"
    fi
    local all n t
    all=$(osd_objects 'type=index-pattern&type=search&type=visualization&type=dashboard&per_page=1000&fields=title')
    n=$(printf '%s' "$all" | grep -c . || true)
    if [ "$n" -eq 0 ]; then
        fail "Dashboards answered but reported no saved objects at all"
        footer "inventory"
    fi
    for t in index-pattern search visualization dashboard; do
        banner "$t"
        printf '%s\n' "$all" | awk -v k="$t" '$1 == k { id=$2; $1=""; $2=""; sub(/^  /,""); printf "      %-46s %s\n", id, $0 }'
    done
    pass "${n} saved object(s) listed — this transcript is the inventory"
    footer "inventory"
}

cmd_dashboards() {
    banner "dashboards — install the kit's saved objects"
    need_root
    local dir tpl rendered idx base
    dir="$KIT_CONFIG_DIR/malcolm/dashboards"
    [ -d "$dir" ] || die "no dashboards directory at $dir"
    if [ "$DRY" = "1" ]; then
        for tpl in "$dir"/*.ndjson.template; do
            [ -e "$tpl" ] || die "no *.ndjson.template under $dir"
            echo "DRY-RUN: render $(basename "$tpl"), import it, then assert every id it declares"
        done
        footer "dashboards"
    fi
    osd_auth_file
    if ! osd_reachable; then
        skip "Dashboards did not answer on 127.0.0.1:8443 — start the stack first; nothing was changed"
        footer "dashboards"
    fi
    idx=$(resolve_index_pattern) || exit 1
    note "index pattern: $idx"
    for tpl in "$dir"/*.ndjson.template; do
        [ -e "$tpl" ] || die "no *.ndjson.template under $dir"
        base=$(basename "${tpl%.template}")
        rendered="$(home)/$base"
        render "$tpl" "$rendered" "NETWORK_INDEX_PATTERN_ID=$idx"
        echo "+ POST /api/saved_objects/_import?overwrite=true   ($base)"
        osd_api POST "/api/saved_objects/_import?overwrite=true" -F "file=@${rendered}" > "${rendered}.result" \
            || die "the import call failed — ${rendered}.result holds what came back"
        grep -q '"success":true' "${rendered}.result" \
            || die "import did not report success for ${base} — read ${rendered}.result"
        assert_saved_objects "$rendered" || true
    done
    footer "dashboards"
}

cmd_arkime_views() {
    banner "arkime-views — install the kit's Arkime views"
    need_root
    local dir f bn line name vexpr listed total=0 missing=0
    dir="$KIT_CONFIG_DIR/malcolm/arkime-views"
    [ -d "$dir" ] || die "no arkime views directory at $dir"
    if [ "$DRY" = "1" ]; then
        for f in "$dir"/*.views; do
            [ -e "$f" ] || die "no *.views under $dir"
            echo "DRY-RUN: post each view in $(basename "$f"), then read them all back"
        done
        footer "arkime-views"
    fi
    osd_auth_file
    arkime_api GET "/api/user/views" --fail >/dev/null 2>&1 \
        || die "Arkime did not answer GET /api/user/views on 127.0.0.1:8443 — the stack is down, or this Arkime's view API moved; read the bundle's BUNDLE_NOTES.md before changing the kit"
    for f in "$dir"/*.views; do
        [ -e "$f" ] || die "no *.views under $dir"
        bn=$(basename "$f")
        while IFS= read -r line; do
            case "$line" in ''|'#'*) continue ;; esac
            case "$line" in *'|'*) ;; *) die "refusing ${bn}: '$line' is not <name>|<expression>" ;; esac
            name=${line%%|*}; vexpr=${line#*|}
            if [ -z "$name" ] || [ -z "$vexpr" ]; then
                die "refusing ${bn}: '$line' has an empty name or expression"
            fi
            case "${name}${vexpr}" in *'"'*|*\\*) die "refusing ${bn}: '${name}' carries a quote or backslash, which this format cannot encode without a JSON writer" ;; esac
            total=$((total + 1))
            echo "+ POST /api/user/views   (${name})"
            arkime_api POST "/api/user/views" -d "$(printf '{"name":"%s","expression":"%s"}' "$name" "$vexpr")" >/dev/null 2>&1 || true
        done < "$f"
    done
    listed=$(arkime_api GET "/api/user/views" 2>/dev/null || true)
    for f in "$dir"/*.views; do
        while IFS= read -r line; do
            case "$line" in ''|'#'*) continue ;; esac
            case "$line" in *'|'*) ;; *) continue ;; esac
            name=${line%%|*}
            if printf '%s' "$listed" | grep -qF "\"${name}\""; then
                echo "ok      ${name}"
            else
                echo "MISSING ${name}"
                missing=$((missing + 1))
            fi
        done < "$f"
    done
    if [ "$missing" -gt 0 ]; then
        fail "${missing} of ${total} view(s) absent after the call — Arkime accepted the post but did not store them"
    else
        pass "all ${total} view(s) present"
    fi
    footer "arkime-views"
}

# ── full ─────────────────────────────────────────────────────────────────────
# The whole Malcolm pipeline, in order, stopping at the first step that
# refuses. Independent of r770-gns3-deploy.sh's own `full` and of the retired
# r770-deploy.sh, whose child()/stage_index() this script's run_step/step_index
# (scripts/lib/common.sh) grew out of: this script now brings its own bundle
# in from the media rather than being handed an already-copied one by an
# outer orchestrator.
cmd_full() {
    [ -n "$BUNDLE" ] || die "--bundle <dir> is required for full (try --help)"
    local first last i step
    first=0; last=$(( ${#STEPS[@]} - 1 ))
    [ -z "$FROM" ] || first=$(step_index STEPS "$FROM") || die "unknown step: $FROM (see --help)"
    [ -z "$TO" ]   || last=$(step_index STEPS "$TO")    || die "unknown step: $TO (see --help)"
    [ "$first" -le "$last" ] || die "--from $FROM comes after --to $TO"
    # Resolve the local copy BEFORE the loop, not only inside the copy) arm
    # below: a resumed run (--from past copy) never executes that arm, so
    # BUNDLE would otherwise still point at --bundle's original media path
    # (already unmounted) for every in-process step. local_bundle() falls
    # back to the raw path when the copy hasn't landed yet, so this is safe
    # on a fresh run too.
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
            load)      run_step "$step" cmd_load ;;
            unpack)    run_step "$step" cmd_unpack ;;
            configure) run_step "$step" cmd_configure ;;
            secrets)   run_step "$step" cmd_secrets ;;
            auth)      run_step "$step" cmd_auth ;;
            rebind)    run_step "$step" cmd_rebind ;;
            start)     run_step "$step" cmd_start ;;
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

# ── dispatch ─────────────────────────────────────────────────────────────────
SUB="${1:-}"; [ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
    case "$1" in
        --bundle)              BUNDLE="${2:-}"; shift ;;
        --media)               MEDIA="${2:-}"; shift ;;
        --device)              DEVICE="${2:-}"; shift ;;
        --from)                FROM="${2:-}"; shift ;;
        --to)                  TO="${2:-}"; shift ;;
        --only)                ONLY="${2:-}"; shift ;;
        --arkime-free-space-g) FREE_G="${2:-}"; shift ;;
        --index-pattern)       IDX="${2:-}"; shift ;;
        --capture-ifs)         CAPTURE_IFS="${2:-}"; CAPTURE_SET=1; shift ;;
        -h|--help)             usage ;;
        *)
            if common_flag "$1"; then :
            elif [ -z "$BUNDLE" ] && [ -d "$1" ]; then BUNDLE="$1"   # bare <bundle-dir>, as the build repo's script took it
            else die "unknown option: $1 (try --help)"
            fi ;;
    esac
    shift
done
[ -n "$ONLY" ] && { FROM="$ONLY"; TO="$ONLY"; }
kit_init "r770-malcolm-deploy"
case "$SUB" in
    load)        cmd_load ;;
    assert-tags) cmd_assert_tags ;;
    unpack)      cmd_unpack ;;
    configure)   cmd_configure ;;
    secrets)     cmd_secrets ;;
    auth)        cmd_auth ;;
    rebind)      cmd_rebind ;;
    start)       cmd_start ;;
    stop)        cmd_stop ;;
    full)        cmd_full ;;
    status)      cmd_status ;;
    inventory)    cmd_inventory ;;
    dashboards)   cmd_dashboards ;;
    arkime-views) cmd_arkime_views ;;
    -h|--help|help|"") usage ;;
    *)           die "unknown subcommand: $SUB (try --help)" ;;
esac
