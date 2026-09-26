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

osd_cleanup() {
    if [ -n "$OSD_NETRC" ]; then rm -f "$OSD_NETRC"; fi
    OSD_NETRC=""
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
