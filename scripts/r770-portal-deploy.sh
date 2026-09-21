#!/usr/bin/env bash
#
# r770-portal-deploy.sh — the nginx front door: an internal CA generated ON
# the gapped box, one three-SAN certificate, the .lab vhosts and the analyst
# wiki built offline.
#
#   r770-portal-deploy.sh <subcommand> [--bundle <dir>] [options]
#
#   ca          easy-rsa PKI at /etc/lab/ca, CA cert published to /etc/nginx/ssl
#   cert        one server cert for malcolm/gns3/docs.lab
#   htpasswd    the shared analyst login, copied from Malcolm's auth material
#   nginx       vhosts + snippets installed, default site removed, nginx -t
#               BEFORE reload, every vhost probed after the reload settles (GATED)
#   docs        analyst wiki built with the bundled mkdocs image, --network none
#   status      certificate, permissions, enabled sites, who owns :443
#   --print-sans  print the SAN list and exit (tests and docs read it)
#
#   --wiki <dir>     wiki source (docs; default: the kit's docs/wiki)
#   EASYRSA_BIN      /usr/share/easy-rsa/easyrsa · MALCOLM_HOME /opt/malcolm
#   --yes / --non-interactive / --dry-run / --force   as everywhere in the kit
#
#   0  done · 2  done with warnings · 1  refused or failed
#
# Rehearsal lessons this encodes (2026-09-12): one three-SAN cert works;
# nginx starts on 0.0.0.0:443 with its default site the moment the package
# installs; a probe that races `systemctl reload` reads the old cert, so
# probe after it settles; the bundled nginx accepts `listen 443 ssl http2;`
# and not the newer standalone directive.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

SANS="malcolm.lab gns3.lab docs.lab"
PKI="/etc/lab/ca"
SSL="/etc/nginx/ssl"
EASYRSA_BIN="${EASYRSA_BIN:-/usr/share/easy-rsa/easyrsa}"
MALCOLM_HOME="${MALCOLM_HOME:-/opt/malcolm}"
SETTLE="${PORTAL_SETTLE_SECS:-2}"
BUNDLE=""; WIKI=""
usage() { usage_from_header 3; exit 0; }
easyrsa() { run env EASYRSA_PKI="$(p "$PKI")/pki" EASYRSA_BATCH=1 "$EASYRSA_BIN" "$@"; }

cmd_ca() {
    banner "ca — internal CA, generated here and never carried in"
    need_root
    require_pkg easy-rsa
    [ -x "$EASYRSA_BIN" ] || die "$EASYRSA_BIN not found or not executable (EASYRSA_BIN overrides)"
    local pki; pki="$(p "$PKI")/pki"
    if [ -s "$pki/ca.crt" ] && [ "$FORCE" != "1" ]; then
        pass "CA already exists at $pki/ca.crt (--force rebuilds it and invalidates every issued cert)"
    else
        run mkdir -p "$(p "$PKI")"
        run chmod 0700 "$(p "$PKI")"
        easyrsa init-pki || die "easyrsa init-pki failed"
        run env EASYRSA_PKI="$pki" EASYRSA_BATCH=1 EASYRSA_REQ_CN="R770 Lab CA" "$EASYRSA_BIN" build-ca nopass || die "easyrsa build-ca failed"
        [ "$DRY" = "1" ] || [ -s "$pki/ca.crt" ] || die "build-ca finished but $pki/ca.crt is missing"
        pass "CA built at $pki (private key stays under $PKI, mode 0700)"
    fi
    run mkdir -p "$(p "$SSL")"
    run install -m 0644 "$pki/ca.crt" "$(p "$SSL")/ca.crt" && pass "CA certificate published at $SSL/ca.crt (0644) — distribute this to analyst browsers"
    footer "ca"
}

cmd_cert() {
    banner "cert — one certificate, three SANs"
    need_root
    local pki ssl san n
    pki="$(p "$PKI")/pki"; ssl="$(p "$SSL")"
    [ -s "$pki/ca.crt" ] || die "no CA at $pki — run ca first"
    if [ -s "$ssl/lab.crt" ] && [ "$FORCE" != "1" ]; then
        pass "certificate already installed at $ssl/lab.crt (--force reissues)"
    else
        san=""; for n in $SANS; do san="${san:+$san,}DNS:$n"; done
        [ -e "$pki/issued/lab.crt" ] && [ "$FORCE" = "1" ] && run rm -f "$pki/issued/lab.crt" "$pki/private/lab.key" "$pki/reqs/lab.req"
        easyrsa --subject-alt-name="$san" build-server-full lab nopass || die "easyrsa build-server-full failed"
        run mkdir -p "$ssl"
        run install -m 0644 "$pki/issued/lab.crt"  "$ssl/lab.crt" || die "could not install lab.crt"
        run install -m 0600 "$pki/private/lab.key" "$ssl/lab.key" || die "could not install lab.key"
        pass "certificate installed: $SSL/lab.crt (0644), $SSL/lab.key (0600)"
    fi
    [ "$DRY" = "1" ] && footer "cert"
    if openssl verify -CAfile "$ssl/ca.crt" "$ssl/lab.crt" >/dev/null 2>&1; then
        pass "lab.crt verifies against ca.crt"
    else
        fail "lab.crt does not verify against $SSL/ca.crt"
    fi
    local ext; ext=$(openssl x509 -in "$ssl/lab.crt" -noout -ext subjectAltName 2>/dev/null || true)
    for n in $SANS; do
        if printf '%s\n' "$ext" | grep -q "DNS:$n"; then pass "SAN present: $n"; else fail "SAN missing: $n"; fi
    done
    note "expiry: $(openssl x509 -in "$ssl/lab.crt" -noout -enddate 2>/dev/null || echo '?')"
    footer "cert"
}

cmd_htpasswd() {
    banner "htpasswd — the shared analyst login"
    need_root
    local src dst; src="$(p "$MALCOLM_HOME")/malcolm/nginx/htpasswd"; dst="$(p /etc/nginx)/lab.htpasswd"
    [ -s "$src" ] || die "$src not found — run 'r770-malcolm-deploy.sh auth' first; the portal shares Malcolm's analyst login"
    run mkdir -p "$(p /etc/nginx)"
    run install -m 0640 "$src" "$dst" || die "could not install $dst"
    run chgrp www-data "$dst" || warn "could not chgrp www-data $dst — nginx must be able to read it"
    pass "$dst installed (0640, group www-data)"
    footer "htpasswd"
}

ng_current() {
    echo "    sites-enabled:"; find "$(p /etc/nginx/sites-enabled)" -maxdepth 1 -printf '      %f\n' 2>/dev/null || true
    printf '    :443 owner: %s\n' "$(ss -ltnp 2>/dev/null | grep -E '(0\.0\.0\.0|\*):443 ' | grep -oE 'users:\(\("[^"]+"' | head -1 | cut -d'"' -f2 || echo '?')"
}
ng_proposed() {
    echo "    sites-available/ + sites-enabled/: $(find "$KIT_CONFIG_DIR/nginx" -maxdepth 1 -name '*.lab.conf' -printf '%f ' )"
    echo "    snippets/: lab-tls.conf lab-auth.conf"
    echo "    sites-enabled/default: removed (the stock page answered on 0.0.0.0:443 since the package installed)"
    echo "    nginx -t, then reload, then every vhost probed at 127.0.0.1 with its own name"
}
cmd_nginx() {
    banner "nginx — vhosts behind one certificate"
    need_root
    require_pkg nginx
    local ssl; ssl="$(p "$SSL")"
    { [ -s "$ssl/lab.crt" ] && [ -s "$ssl/lab.key" ]; } || die "no certificate at $SSL — run ca and cert first"
    [ -s "$(p /etc/nginx)/lab.htpasswd" ] || die "no /etc/nginx/lab.htpasswd — run htpasswd first"
    local f
    for f in "$KIT_CONFIG_DIR"/nginx/*.lab.conf; do
        grep -q 'listen 443 ssl http2;' "$f" || die "$(basename "$f") lacks 'listen 443 ssl http2;' — the bundled nginx accepts only this form"
    done
    gate "install the portal vhosts and reload nginx" ng_current ng_proposed \
        "rm /etc/nginx/sites-enabled/*.lab.conf; ln -s ../sites-available/default /etc/nginx/sites-enabled/default; nginx -t && systemctl reload nginx"
    run mkdir -p "$(p /etc/nginx/sites-available)" "$(p /etc/nginx/sites-enabled)" "$(p /etc/nginx/snippets)"
    for f in "$KIT_CONFIG_DIR"/nginx/snippets/*.conf; do
        run install -m 0644 "$f" "$(p /etc/nginx/snippets)/$(basename "$f")" || die "could not install $(basename "$f")"
    done
    for f in "$KIT_CONFIG_DIR"/nginx/*.lab.conf; do
        run install -m 0644 "$f" "$(p /etc/nginx/sites-available)/$(basename "$f")" || die "could not install $(basename "$f")"
        run ln -sf "../sites-available/$(basename "$f")" "$(p /etc/nginx/sites-enabled)/$(basename "$f")"
    done
    run rm -f "$(p /etc/nginx/sites-enabled)/default"
    pass "five vhosts and two snippets installed; default site removed"
    # -t BEFORE reload: a bad config must never take the running portal down.
    run nginx -t || die "nginx -t rejected the configuration — nothing was reloaded; the previous config is still live"
    run systemctl reload nginx || die "reload failed"
    [ "$DRY" = "1" ] && footer "nginx"
    sleep "$SETTLE"       # a probe that races the reload reads the old certificate
    local n code
    for n in $SANS; do
        code=$(curl -sk --max-time 10 --resolve "$n:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://$n/" 2>/dev/null || echo 000)
        case "$code" in
            200|301|302|307|308|401) pass "$n answers over TLS (HTTP $code)" ;;
            *) fail "$n: HTTP ${code} — the vhost is not answering (502 = its backend is down, 000 = TLS/listen problem)" ;;
        esac
    done
    footer "nginx"
}

cmd_docs() {
    banner "docs — analyst wiki, built offline"
    need_root
    local b wiki img tmp; b=$(bundle_dir "$BUNDLE") || exit 1
    wiki="${WIKI:-$KIT_DIR/docs/wiki}"
    [ -f "$wiki/index.md" ] || die "no wiki at $wiki (index.md missing) — pass --wiki <dir>"
    img=$(image_ref_from_list "$b/docker/monitoring-image-list.txt" mkdocs-material) || exit 1
    if ! docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -qxF "$img"; then
        run docker load -i "$b/docker/monitoring-images.tar.gz" || die "docker load failed for the docs build image"
    fi
    tmp=$(mktemp -d)
    run cp -a "$wiki" "$tmp/docs"
    run install -m 0644 "$KIT_CONFIG_DIR/docs/mkdocs.yml" "$tmp/mkdocs.yml"
    # --network none: the build can want fonts and plugins; on an air gap it must not even try.
    run docker run --rm --network none -v "$tmp:/docs" "$img" build || { rm -rf "$tmp"; die "mkdocs build failed — is $img loaded (images stage)?"; }
    if [ "$DRY" != "1" ]; then
        [ -f "$tmp/site/index.html" ] || { rm -rf "$tmp"; die "mkdocs produced no site/index.html"; }
        run rm -rf "$(p /srv/www/docs)"
        run mkdir -p "$(p /srv/www)"
        run cp -a "$tmp/site" "$(p /srv/www/docs)"
        pass "wiki built into /srv/www/docs ($(find "$(p /srv/www/docs)" -name '*.html' | wc -l) pages)"
    fi
    rm -rf "$tmp"
    footer "docs"
}

cmd_status() {
    banner "portal status"
    local ssl f; ssl="$(p "$SSL")"
    for f in ca.crt lab.crt lab.key; do
        printf '%-24s %s\n' "$SSL/$f" "$([ -e "$ssl/$f" ] && stat -c '%a %U' "$ssl/$f" || echo absent)"
    done
    printf '%-24s %s\n' "/etc/nginx/lab.htpasswd" "$([ -e "$(p /etc/nginx)/lab.htpasswd" ] && stat -c '%a %U:%G' "$(p /etc/nginx)/lab.htpasswd" || echo absent)"
    [ -s "$ssl/lab.crt" ] && printf '%-24s %s\n' "SANs" "$(openssl x509 -in "$ssl/lab.crt" -noout -ext subjectAltName 2>/dev/null | tail -1 | xargs)"
    printf '%-24s %s\n' "sites-enabled" "$(find "$(p /etc/nginx/sites-enabled)" -maxdepth 1 -printf '%f ' 2>/dev/null)"
    printf '%-24s %s\n' ":443 owner" "$(ss -ltnp 2>/dev/null | grep -E '(0\.0\.0\.0|\*):443 ' | grep -oE 'users:\(\("[^"]+"' | cut -d'"' -f2 | sort -u | tr '\n' ' ')"
    return 0
}

SUB="${1:-}"; [ $# -gt 0 ] && shift
[ "$SUB" = "--print-sans" ] && { echo "$SANS"; exit 0; }
while [ $# -gt 0 ]; do
    case "$1" in
        --bundle)  BUNDLE="${2:-}"; shift ;;
        --wiki)    WIKI="${2:-}"; shift ;;
        --print-sans) echo "$SANS"; exit 0 ;;
        -h|--help) usage ;;
        *)         common_flag "$1" || die "unknown option: $1 (try --help)" ;;
    esac
    shift
done
kit_init "r770-portal-deploy"
case "$SUB" in
    ca)       cmd_ca ;;
    cert)     cmd_cert ;;
    htpasswd) cmd_htpasswd ;;
    nginx)    cmd_nginx ;;
    docs)     cmd_docs ;;
    status)   cmd_status ;;
    -h|--help|help|"") usage ;;
    *)        die "unknown subcommand: $SUB (try --help)" ;;
esac
