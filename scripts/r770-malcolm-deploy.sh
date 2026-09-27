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
#                              lab_mirror0 (r770-gns3-deploy.sh labnet first).
#                              Without it, live capture stays off.
#   --yes / --non-interactive / --dry-run / --force   as everywhere in the kit
#
#   MALCOLM_HOME        /opt/malcolm        MALCOLM_ADMIN_USER   analyst
#   MALCOLM_WAIT_SECS   600                 MALCOLM_OS_MEM_G / MALCOLM_LS_MEM_M
#                                           override the heaps computed from free -g
#   SCENARIO_DIR        <kit>/scenarios
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
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/malcolm-api.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/malcolm-api.sh"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/expect.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/expect.sh"

BUNDLE=""; FREE_G=""; IDX=""
CAPTURE_IFS=""; CAPTURE_SET=0
MEDIA=""; DEVICE=""; FROM=""; TO=""; ONLY=""
MALCOLM_HOME="${MALCOLM_HOME:-/opt/malcolm}"
ADMIN_USER="$MALCOLM_API_USER"
WAIT_SECS="${MALCOLM_WAIT_SECS:-600}"
AUTH_FLAGS=(--auth-noninteractive --auth-method --auth-admin-username --auth-admin-password-openssl
            --auth-admin-password-htpasswd --auth-generate-webcerts --auth-generate-fwcerts
            --auth-generate-netbox-passwords --auth-generate-valkey-password
            --auth-generate-postgres-password --auth-generate-opensearch-internal-creds
            --auth-generate-keycloak-db-password)
INSTALL_FLAGS=(--non-interactive --skip-splash --configure --import-malcolm-config-file --export-malcolm-config-file)
REBIND_FROM='^    - 0.0.0.0:443:443/tcp$'
REBIND_TO='    - 127.0.0.1:8443:443/tcp'
SECRET="$MALCOLM_SECRET_FILE"
SCEN_DIR="${SCENARIO_DIR:-$KIT_DIR/scenarios}"   # the pack dashboards and arkime-views generate from
STEPS=(preflight gate copy apt phone-home docker files load unpack configure secrets auth rebind start)
# test seam: lets a suite stub out every call this script makes to
# r770-import-bundle.sh under `full`, and record what was called.
IMPORT_BUNDLE_CMD="${IMPORT_BUNDLE_CMD:-$KIT_DIR/scripts/r770-import-bundle.sh}"

usage() { usage_from_header 3; exit 0; }
home()      { p "$MALCOLM_HOME"; }
# The docker_install.zip puts install.py at its root, beside the stack tarball
# (measured on staging VM 9770, 2026-09-25) -- not under scripts/.
installer() { printf '%s/install.py' "$(home)"; }
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
        # Malcolm's pcap-capture runs `export $IFACE` for each capture interface,
        # so the name must be a shell identifier; netsniff dies at start on
        # anything else (measured on staging VM 9770, 2026-09-25).
        [[ "$i" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "$i cannot be a Malcolm capture interface — its pcap-capture container uses each name as a shell variable, so only letters, digits and _ work (no - or .)"
        case "$seen" in *" $i "*) die "--capture-ifs names $i twice" ;; esac
        seen="$seen$i "
        if [ ! -e "$(p /sys/class/net)/$i" ]; then
            case "$i" in
                lab_*) die "capture interface $i does not exist — create the lab network first: r770-gns3-deploy.sh labnet" ;;
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
    for k in captureLiveNetworkTraffic liveZeek; do
        grep -qE "\"$k\"[[:space:]]*:[[:space:]]*true" "$x" && continue
        fail "the installer did not keep \"$k\": true — live capture will not start; read $x"
        missing=1
    done
    # Arkime gets live packets either by capturing itself (liveArkime) or from
    # the PCAP a capture container writes (netsniff or tcpdump). The installer
    # picks: asked for liveArkime it kept netsniff instead (measured on staging
    # VM 9770, 2026-09-25). Any one path is enough; none means Arkime is blind.
    local via=""
    for k in liveArkime pcapNetSniff pcapTcpDump; do
        grep -qE "\"$k\"[[:space:]]*:[[:space:]]*true" "$x" && via="${via:+$via, }$k"
    done
    if [ -z "$via" ]; then
        fail "the installer kept no capture path into Arkime (liveArkime, pcapNetSniff, pcapTcpDump all off) — live packets will not reach Arkime; read $x"
        missing=1
    fi
    lst=$(pcap_ifaces_of "$x")
    for i in "$@"; do
        [[ "$lst" == *"\"$i\""* ]] && continue
        fail "the installer did not keep \"pcapIface\" with $i — live capture will not start on it; read $x"
        missing=1
    done
    [ "$missing" -eq 1 ] || pass "the installer kept live capture on $* (Zeek live; Arkime via $via)"
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
# track_esp — turn on Arkime's ESP (IP protocol 50) session tracking in
# config/arkime.env. Malcolm ships no knob for this; Arkime 5 reads
# ARKIME_<section>__<key> overrides from its env file, and both Arkime
# containers load config/arkime.env. The installer rewrites every
# config/*.env file on every configure run, so this is re-applied after each
# one, the same as do_rebind's compose edit. Measured on staging VM 9770,
# 2026-09-26: without it, Zeek's conn log has no ESP either, so no session
# from an ESP scenario existed at all; appending the line and cycling
# stop/start (which recreates the containers) fixed it.
track_esp() {
    local f old want='ARKIME_default__trackESP=true'
    f="$(stack)/config/arkime.env"
    if [ "$DRY" = "1" ]; then
        echo "DRY-RUN: set $want in $f"
        return 0
    fi
    if [ ! -f "$f" ]; then
        fail "$f is missing — the installer did not write it"
        return 0
    fi
    if grep -qxF "$want" "$f"; then
        pass "trackESP already on in $f"
        return 0
    fi
    old=$(sed -n 's/^ARKIME_default__trackESP=//p' "$f" | head -1)
    if [ -n "$old" ]; then
        sed -i "s|^ARKIME_default__trackESP=.*|$want|" "$f"
        pass "trackESP turned on in $f (was: $old)"
    else
        printf '%s\n' "$want" >> "$f"
        pass "trackESP turned on in $f — ESP (IP protocol 50) becomes an Arkime session"
    fi
}

cmd_configure() {
    banner "configure — replay the kit's config through the installer"
    need_root
    local b zip ver os ls rendered exported manage free ifaces live cdir cinst
    b=$(bundle_dir "$BUNDLE") || exit 1
    [ -f "$(installer)" ] || die "$(installer) not found — run unpack first"
    require_pkg python3-ruamel.yaml python3-dotenv
    # The zip-root installer extracts the stack and refuses once it exists
    # ("already exists, please specify a different installation path"); the
    # extracted stack carries its own scripts/install.py to reconfigure itself.
    # Each runs from its own directory (both measured on staging VM 9770).
    cdir=$(home); cinst=$(installer)
    if [ -f "$(stack)/scripts/install.py" ]; then
        cdir=$(stack); cinst="$(stack)/scripts/install.py"
        note "reconfiguring the extracted stack with its own installer ($cinst)"
    fi
    help_has_flags python3 "$cinst" -- "${INSTALL_FLAGS[@]}"
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
        "PCAP_IFACE=$ifaces" "CAPTURE_LIVE=$live" "LIVE_ARKIME=$live" "LIVE_ZEEK=$live" "CAPTURE_STATS=$live"
    # From its own directory: the zip-root installer looks for the stack
    # tarball in its working directory, and anywhere else fails on missing
    # .env.example templates (measured on staging VM 9770, 2026-09-25).
    ( cd "$cdir" && run python3 "$cinst" --non-interactive --skip-splash --configure \
        --import-malcolm-config-file "$rendered" --export-malcolm-config-file "$exported" ) \
        || die "the installer failed — its output above is the evidence; nothing else was changed"
    if [ "$DRY" != "1" ]; then
        [ -f "$(compose)" ] || die "the installer did not produce $(compose) — read its output"
        pass "installer configured $(stack); exported config at $exported"
        if [ "$live" = "true" ]; then local ifl; read -ra ifl <<< "$CAPTURE_IFS"; live_kept "$exported" "${ifl[@]}"; fi
        if [ -d "$(stack)/pcap/upload" ]; then
            if run chown 1000:1000 "$(stack)/pcap/upload"; then pass "pcap/upload owned by 1000:1000 (the drop-off the rehearsal measured)"; fi
        fi
    fi
    track_esp
    do_rebind
    own_stack
    footer "configure"
}

# ── secrets / auth ───────────────────────────────────────────────────────────
cmd_secrets() { banner "secrets"; need_root; secret_file "$(p "$SECRET")"; pass "admin credential location: $SECRET"; footer "secrets"; }

cmd_auth() {
    banner "auth — Malcolm's auth_setup, unattended"
    need_root
    local b setup pw h_ssl h_ht img user
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
    user=$(malcolm_owner) || exit 1; user=${user%% *}
    echo "+ (cd $(stack) && runuser -u $user -- ./scripts/auth_setup --auth-noninteractive --auth-method basic --auth-admin-username $ADMIN_USER --auth-admin-password-openssl <hash> --auth-admin-password-htpasswd <hash> --auth-generate-...)"
    ( cd "$(stack)" && runuser -u "$user" -- ./scripts/auth_setup --auth-noninteractive --auth-method basic \
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

# ── the stack's owner ────────────────────────────────────────────────────────
# Malcolm's control scripts (auth_setup, start, stop) refuse root. They run as
# the user the installer recorded in config/process.env (PUID/PGID, the sudo
# user it ran under), who must own the stack -- which the installer, run as
# root, leaves root-owned. Both measured on staging VM 9770, 2026-09-25.
# Discovered from the stack, never guessed.
malcolm_owner() {  # prints "<user> <uid> <gid>", or dies
    local env uid gid user
    env="$(stack)/config/process.env"
    [ -f "$env" ] || die "$env not found — run configure first"
    uid=$(sed -n 's/^PUID=//p' "$env" | head -1); gid=$(sed -n 's/^PGID=//p' "$env" | head -1)
    if ! [[ "$uid" =~ ^[0-9]+$ ]] || ! [[ "$gid" =~ ^[0-9]+$ ]]; then die "no numeric PUID/PGID in $env"; fi
    [ "$uid" -ne 0 ] || die "PUID is 0 in $env — Malcolm's control scripts refuse root; run configure with sudo from the operator's own account"
    user=$(getent passwd "$uid" | cut -d: -f1)
    [ -n "$user" ] || die "PUID $uid in $env is not a user on this host"
    printf '%s %s %s' "$user" "$uid" "$gid"
}
own_stack() {  # give the stack to its recorded owner (after every installer run and rebind)
    local o user uid gid
    if [ "$DRY" = "1" ] && [ ! -f "$(stack)/config/process.env" ]; then
        echo "DRY-RUN: chown -R <PUID>:<PGID from config/process.env> $(stack)"; return 0
    fi
    o=$(malcolm_owner) || exit 1
    read -r user uid gid <<< "$o"
    run chown -R "$uid:$gid" "$(stack)" || die "could not give $(stack) to $user"
    [ "$DRY" = "1" ] || pass "$(stack) owned by $user ($uid:$gid, from config/process.env) — Malcolm's control scripts run as this user"
    # Malcolm writes its indexes and PCAP as that user too, and those live on
    # root-owned mount points (Phase 3). The directories are the ones the
    # installer's exported config names -- read back, never restated.
    local x k d dirs=""
    x="$(home)/malcolm-config.exported.json"
    [ -f "$x" ] || return 0
    for k in indexDir pcapDir; do
        d=$(sed -n "s/.*\"$k\"[[:space:]]*:[[:space:]]*\"\(\/[^\"]*\)\".*/\1/p" "$x" | head -1)
        [ -n "$d" ] || continue
        run mkdir -p "$(p "$d")" || die "could not create $d"
        run chown -R "$uid:$gid" "$(p "$d")" || die "could not give $d to $user"
        dirs="$dirs $d"
    done
    [ "$DRY" = "1" ] || [ -z "$dirs" ] || pass "data dirs owned by $user:$dirs"
}
owner_for_docker() {  # the owner's name, once it is known to reach docker
    local o user
    o=$(malcolm_owner) || exit 1
    user=${o%% *}
    getent group docker | cut -d: -f4 | tr ',' '\n' | grep -qx "$user" \
        || die "$user is not in the docker group — Malcolm's scripts run as $user and drive docker compose (usermod -aG docker $user, then log in again)"
    printf '%s' "$user"
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
cmd_rebind() { banner "rebind"; need_root; do_rebind; own_stack; footer "rebind"; }

# ── start / stop / status ────────────────────────────────────────────────────
cmd_start() {
    banner "start — Malcolm's own start script, then wait for health"
    need_root
    local s; s="$(stack)/scripts/start"
    [ -x "$s" ] || die "$s not found — run configure first"
    [ -s "$(stack)/nginx/htpasswd" ] || die "no auth material — run auth first (compose would refuse: bind sources missing)"
    grep -qE -- "$REBIND_FROM" "$(compose)" && die "compose still publishes 0.0.0.0:443 — run rebind first (it must follow every installer run)"
    local user; user=$(owner_for_docker) || exit 1
    ( cd "$(stack)" && run runuser -u "$user" -- ./scripts/start ) || die "Malcolm's start script failed — see above"
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
    local user; user=$(owner_for_docker) || exit 1
    if ( cd "$(stack)" && run runuser -u "$user" -- ./scripts/stop ); then pass "stopped"; else fail "stop script failed"; fi
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
# The API helpers (osd_api, arkime_api, the netrc) are scripts/lib/malcolm-api.sh's.

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

# ── the scenario pack's objects, generated ──────────────────────────────────
# Each scenario's range lives once, in its scenario.conf; its flows once, in
# its expect.txt. The searches and views below are generated from them through
# scripts/lib/expect.sh — the same translator r770-scenario.sh check queries
# with — so nothing under config/ restates a range.

# pack_rows — the pack as lines the generators read, every row already through
# the translator's checks: "S|<name>|<range>" per scenario, then
# "R|<name>|<n>|<proto>|<port>|<src>|<dst>" per expect.txt row. Call it with a
# redirect, never in $() or a pipe: a refusal must stop the step, and it must
# stop it before anything is imported.
pack_rows() {
    local c d s range n proto port src dst why
    for c in "$SCEN_DIR"/*/scenario.conf; do
        [ -e "$c" ] || continue
        d=$(dirname "$c"); s=$(basename "$d")
        range=$(sed -n 's/^range=//p' "$c" | head -1)
        expect_cidr "$range" || die "refusing scenarios/$s/scenario.conf: range '$range' is not an IPv4 CIDR — nothing was imported"
        [ -f "$d/expect.txt" ] || die "refusing scenarios/$s: no expect.txt — nothing was imported"
        printf 'S|%s|%s\n' "$s" "$range"
        while IFS='|' read -r n proto port src dst; do
            why=$(expect_problem "$proto" "$port" "$src" "$dst")
            [ -z "$why" ] || die "refusing scenarios/$s/expect.txt row $n: $why — nothing was imported"
            printf 'R|%s|%s|%s|%s|%s|%s\n' "$s" "$n" "$proto" "$port" "$src" "$dst"
        done < <(expect_rows "$d")
    done
}

# scenario_spec <pack-file> — "<range|row><TAB><id><TAB><title><TAB><description><TAB><kql>" per search
scenario_spec() {
    local kind a b c d e f
    while IFS='|' read -r kind a b c d e f; do
        case "$kind" in
            S) printf 'range\tlab-scenario-%s\tScenario %s - all traffic (lab)\tEverything scenario %s puts on br-lab: its whole range, %s.\tsource.ip:"%s" or destination.ip:"%s"\n' \
                   "$a" "$a" "$a" "$b" "$b" "$b" ;;
            R) printf 'row\tlab-scenario-%s-row-%s\tScenario %s - %s (lab)\tRow %s of scenarios/%s/expect.txt: a flow every traffic run must show.\t%s\n' \
                   "$a" "$b" "$a" "$(expect_label "$c" "$d" "$e" "$f")" "$b" "$a" "$(expect_kql "$c" "$d" "$e" "$f")" ;;
        esac
    done < "$1"
}

# scenario_ndjson <spec> <out> — the searches and the overview dashboard, in the
# shape of config/malcolm/dashboards/ipsec.ndjson.template: one object per
# line, {"id":…,"type":…} first, no version fields, the index pattern as the
# token render() fills. python3 writes the JSON (Malcolm's installer already
# needs it); bash would have to hand-escape a query inside a JSON string inside
# a JSON string.
scenario_ndjson() {
    python3 - "$1" "$2" <<'PY'
import json, sys
spec, out = sys.argv[1], sys.argv[2]
tight = dict(separators=(",", ":"))
cols = ["source.ip", "destination.ip", "destination.port", "network.transport", "network.protocol", "event.provider"]
ref = "kibanaSavedObjectMeta.searchSourceJSON.index"
objs, panels = [], []
for raw in open(spec):
    kind, oid, title, desc, query = raw.rstrip("\n").split("\t")
    ssj = json.dumps({"query": {"query": query, "language": "kuery"}, "filter": [], "indexRefName": ref}, **tight)
    objs.append({"id": oid, "type": "search",
                 "attributes": {"title": title, "description": desc, "hits": 0, "columns": cols,
                                "sort": [["@timestamp", "desc"]],
                                "kibanaSavedObjectMeta": {"searchSourceJSON": ssj}},
                 "references": [{"name": ref, "type": "index-pattern", "id": "__NETWORK_INDEX_PATTERN_ID__"}]})
    if kind == "range":
        panels.append(oid)
grid = [{"version": "", "gridData": {"x": 0, "y": 12 * i, "w": 48, "h": 12, "i": str(i + 1)},
         "panelIndex": str(i + 1), "embeddableConfig": {}, "panelRefName": "panel_%d" % (i + 1)}
        for i in range(len(panels))]
objs.append({"id": "lab-scenarios-overview", "type": "dashboard",
             "attributes": {"title": "Lab scenarios - Overview (lab)",
                            "description": "One panel per scenario in the kit's pack: every session in its range. The per-row searches (Scenario <name> - ...) drill down.",
                            "hits": 0, "timeRestore": False, "version": 1,
                            "optionsJSON": json.dumps({"hidePanelTitles": False, "useMargins": True}, **tight),
                            "panelsJSON": json.dumps(grid, **tight),
                            "kibanaSavedObjectMeta": {"searchSourceJSON": json.dumps({"query": {"query": "", "language": "kuery"}, "filter": []}, **tight)}},
             "references": [{"name": "panel_%d" % (i + 1), "type": "search", "id": p} for i, p in enumerate(panels)]})
with open(out, "w") as f:
    for o in objs:
        f.write(json.dumps(o, ensure_ascii=False, **tight) + "\n")
PY
}

# scenario_views <pack-file> — the pack's Arkime views in the kit's .views
# format: the same expressions r770-scenario.sh check counts with. Arkime
# keeps only [-a-zA-Z0-9_: ] of a view's name, so a row view is named by its
# row number and protocol ("Scenario bgp - row 1 tcp 179"); the saved searches
# keep the full label, and arkime-views refuses any name Arkime would rewrite.
scenario_views() {
    local kind a b c d e f
    echo "# generated by r770-malcolm-deploy.sh arkime-views from scenarios/ — not edited by hand"
    while IFS='|' read -r kind a b c d e f; do
        case "$kind" in
            S) printf 'Scenario %s - all traffic|ip == %s\n' "$a" "$b" ;;
            R) printf 'Scenario %s - row %s %s%s|%s\n' "$a" "$b" "$c" "${d:+ $d}" "$(expect_arkime "$c" "$d" "$e" "$f")" ;;
        esac
    done < "$1"
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
    local dir tpl rendered idx base gen tpls=()
    dir="$KIT_CONFIG_DIR/malcolm/dashboards"
    [ -d "$dir" ] || die "no dashboards directory at $dir"
    for tpl in "$dir"/*.ndjson.template; do
        [ -e "$tpl" ] || die "no *.ndjson.template under $dir"
        tpls+=("$tpl")
    done
    if [ "$DRY" = "1" ]; then
        pack_rows > /dev/null
        for tpl in "${tpls[@]}"; do
            echo "DRY-RUN: render $(basename "$tpl"), import it, then assert every id it declares"
        done
        echo "DRY-RUN: generate the scenario pack's searches and overview from $SCEN_DIR, import them, then assert every id"
        footer "dashboards"
    fi
    # generated before any call: a refused row stops the step with nothing imported
    gen="$(home)/scenarios.ndjson.template"
    pack_rows > "$gen.pack"
    if [ -s "$gen.pack" ]; then
        scenario_spec "$gen.pack" > "$gen.tsv"
        scenario_ndjson "$gen.tsv" "$gen" || die "could not generate $gen"
        tpls+=("$gen")
    else
        note "no scenarios under $SCEN_DIR — only the kit's fixed objects"
    fi
    rm -f "$gen.pack" "$gen.tsv"
    osd_auth_file
    if ! osd_reachable; then
        skip "Dashboards did not answer on 127.0.0.1:8443 — start the stack first; nothing was changed"
        footer "dashboards"
    fi
    idx=$(resolve_index_pattern) || exit 1
    note "index pattern: $idx"
    for tpl in "${tpls[@]}"; do
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

# Arkime's view API, as measured on Malcolm's Arkime: GET /api/views lists
# ({"data":[…]}), POST /api/view creates and needs the x-arkime-cookie token
# (arkime_token), a name is stripped to [-a-zA-Z0-9_: ], and a second POST of
# the same name makes a second view. So every name is checked against that set
# before anything is posted, and a view already present by name is left as it
# is — a changed expression needs the old view deleted in Arkime first.
ARKIME_VIEW_CHARS='[-a-zA-Z0-9_: ]'
cmd_arkime_views() {
    banner "arkime-views — install the kit's Arkime views"
    need_root
    local dir f bn line name vexpr gen resp present i total=0 missing=0 files=() names=() exprs=()
    dir="$KIT_CONFIG_DIR/malcolm/arkime-views"
    [ -d "$dir" ] || die "no arkime views directory at $dir"
    for f in "$dir"/*.views; do
        [ -e "$f" ] || die "no *.views under $dir"
        files+=("$f")
    done
    if [ "$DRY" = "1" ]; then
        pack_rows > /dev/null
        for f in "${files[@]}"; do
            echo "DRY-RUN: post each view in $(basename "$f") not already present by name, then read them all back"
        done
        echo "DRY-RUN: generate the scenario pack's views from $SCEN_DIR, post those not already present, then read them all back"
        footer "arkime-views"
    fi
    # generated before any call: a refused row stops the step with nothing posted
    gen="$(home)/scenarios.views"
    pack_rows > "$gen.pack"
    if [ -s "$gen.pack" ]; then
        scenario_views "$gen.pack" > "$gen"
        files+=("$gen")
    else
        note "no scenarios under $SCEN_DIR — only the kit's fixed views"
    fi
    rm -f "$gen.pack"
    # every line checked before any call: a refusal leaves nothing posted
    for f in "${files[@]}"; do
        bn=$(basename "$f")
        while IFS= read -r line; do
            case "$line" in ''|'#'*) continue ;; esac
            case "$line" in *'|'*) ;; *) die "refusing ${bn}: '$line' is not <name>|<expression>" ;; esac
            name=${line%%|*}; vexpr=${line#*|}
            if [ -z "$name" ] || [ -z "$vexpr" ]; then
                die "refusing ${bn}: '$line' has an empty name or expression"
            fi
            case "$vexpr" in *'"'*|*\\*) die "refusing ${bn}: the expression of '${name}' carries a quote or backslash, which this format cannot encode without a JSON writer" ;; esac
            # spelled out, not a-z: a range in a bracket follows the locale
            case "$name" in
                *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_:\ -]*)
                    die "refusing ${bn}: view name '${name}' holds a character outside ${ARKIME_VIEW_CHARS}, which Arkime strips — the stored name would not match; nothing was posted" ;;
            esac
            printf '%s\n' "${names[@]}" | grep -qxF -- "$name" \
                && die "refusing ${bn}: view name '${name}' is declared twice — Arkime would store both; nothing was posted"
            names+=("$name"); exprs+=("$vexpr")
        done < "$f"
    done
    total=${#names[@]}
    osd_auth_file
    present=$(arkime_view_names) \
        || die "Arkime did not answer GET /api/views on 127.0.0.1:8443 with its view list — the stack is down, or this Arkime's view API moved; read the bundle's BUNDLE_NOTES.md before changing the kit"
    for i in "${!names[@]}"; do
        name=${names[$i]}
        if printf '%s\n' "$present" | grep -qxF -- "$name"; then
            echo "present ${name}"
            continue
        fi
        [ -n "$ARKIME_HDR" ] || arkime_token
        echo "+ POST /api/view   (${name})"
        resp=$(arkime_api POST "/api/view" -H "@${ARKIME_HDR}" \
                   -d "$(printf '{"name":"%s","expression":"%s"}' "$name" "${exprs[$i]}")" 2>&1 || true)
        case "$resp" in
            *'"success":true'*) ;;
            *) note "Arkime did not report success for '${name}': $(printf '%s' "$resp" | head -c 200)" ;;
        esac
    done
    present=$(arkime_view_names) || present=""
    for name in "${names[@]}"; do
        if printf '%s\n' "$present" | grep -qxF -- "$name"; then
            echo "ok      ${name}"
        else
            echo "MISSING ${name}"
            missing=$((missing + 1))
        fi
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
