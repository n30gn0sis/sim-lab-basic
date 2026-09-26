#!/usr/bin/env bash
#
# malcolm-api.sh — Malcolm's Dashboards and Arkime APIs, sourced after
# common.sh by r770-malcolm-deploy.sh (inventory, dashboards, arkime-views) and
# r770-scenario.sh (check).
#
# Everything here reaches the stack through the rebound proxy on
# 127.0.0.1:8443 — the entry point `rebind` guarantees, and the only one the
# air gap admits. The admin credential never reaches argv or the transcript:
# curl reads it from a 0600 netrc that lives only for the length of the run.
# There is no jq on this box, so every response is read with sed and grep, and
# any shape this kit was not written for is a refusal, never a guess.

MALCOLM_API_USER="${MALCOLM_ADMIN_USER:-analyst}"
MALCOLM_SECRET_FILE="/etc/lab/secrets/malcolm-admin.pw"
OSD_NETRC=""
ARKIME_JAR=""
ARKIME_HDR=""

osd_cleanup() {
    if [ -n "$OSD_NETRC" ]; then rm -f "$OSD_NETRC"; fi
    if [ -n "$ARKIME_JAR" ]; then rm -f "$ARKIME_JAR"; fi
    if [ -n "$ARKIME_HDR" ]; then rm -f "$ARKIME_HDR"; fi
    OSD_NETRC=""; ARKIME_JAR=""; ARKIME_HDR=""
}
osd_auth_file() {
    local pw
    pw=$(secret_read "$(p "$MALCOLM_SECRET_FILE")") || exit 1
    OSD_NETRC=$(mktemp) || die "mktemp failed"
    chmod 600 "$OSD_NETRC"
    printf 'machine 127.0.0.1 login %s password %s\n' "$MALCOLM_API_USER" "$pw" > "$OSD_NETRC"
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

# arkime_token — Arkime's write calls (POST /api/view) refuse without an
# x-arkime-cookie header ("Missing token"). The token is the ARKIME-COOKIE
# cookie that the /arkime/sessions page sets (GET /api/user sets none), sent
# back URL-decoded — both measured on Malcolm's Arkime on the staging stack.
# The jar and the header file are 0600 and live only for the run
# (osd_cleanup); the token reaches curl as `-H @"$ARKIME_HDR"`, never argv,
# and is never printed. Call after osd_auth_file.
arkime_token() {
    local raw tok
    ARKIME_JAR=$(mktemp) || die "mktemp failed"
    chmod 600 "$ARKIME_JAR"
    ARKIME_HDR=$(mktemp) || die "mktemp failed"
    chmod 600 "$ARKIME_HDR"
    arkime_api GET "/sessions" -c "$ARKIME_JAR" >/dev/null 2>&1 || true
    # Netscape jar: tab-separated, the name in field 6 and the value in 7; an
    # HttpOnly cookie's line starts "#HttpOnly_", so comments are not skipped
    raw=$(awk -F'\t' '$6 == "ARKIME-COOKIE" { v = $7 } END { print v }' "$ARKIME_JAR")
    [ -n "$raw" ] || die "Arkime's /arkime/sessions page set no ARKIME-COOKIE cookie, so there is no token for x-arkime-cookie — nothing was posted; read the bundle's BUNDLE_NOTES.md before changing the kit"
    case "$raw" in *\\*) die "Arkime's ARKIME-COOKIE value holds a backslash, which is not URL-encoding — nothing was posted" ;; esac
    tok=$(printf '%b' "${raw//%/\\x}")
    case "$tok" in *$'\r'*|*$'\n'*) die "Arkime's ARKIME-COOKIE value decodes to more than one line — nothing was posted" ;; esac
    printf 'x-arkime-cookie: %s\n' "$tok" > "$ARKIME_HDR"
}

# arkime_view_names — the names of the views Arkime holds, one per line, from
# GET /api/views ({"data":[{"name":…},…]}). Fails when Arkime does not answer
# or answers another shape. Names never hold a quote: Arkime keeps only
# [-a-zA-Z0-9_: ] in them.
arkime_view_names() {
    local body
    body=$(arkime_api GET "/api/views" --fail 2>/dev/null) || return 1
    case "$body" in *'"data":['*) ;; *) return 1 ;; esac
    printf '%s' "$body" | grep -o '"name":"[^"]*"' | sed 's/^"name":"//; s/"$//' || true
}
