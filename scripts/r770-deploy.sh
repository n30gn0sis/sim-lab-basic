#!/usr/bin/env bash
#
# r770-deploy.sh — one command, the whole R770-side deployment, in order,
# stopping at the first stage that refuses.
#
#   r770-deploy.sh --bundle <dir> [--media <mnt> --device /dev/<discovered>]
#                  [--mgmt-ip <ip>] [--from STAGE] [--to STAGE] [--only STAGE]
#                  [--yes] [--non-interactive] [--dry-run] [--list]
#
# Stages, in order (each is a subcommand of one kit script; this runner
# holds no logic of its own):
#
#    1 preflight    import   is this host ready to receive a bundle?
#    2 gate         import   the verifier that travels IN the bundle
#    3 copy         import   cp -a to /srv/bundles, verify the copy
#    4 apt          import   local flat repo, sources rewritten        (GATED)
#    5 phone-home   import   nothing may try the internet              (GATED)
#    6 docker       import   engine from the bundle                    (GATED)
#    7 images       import   docker load, assert every tag
#    8 files        import   VM images, GNS3, enrichment, docs into place
#    9 gns3         gns3     venv, secrets, config, service            (GATED)
#   10 malcolm      malcolm  load, unpack, configure, secrets, auth, rebind, start
#   11 portal       portal   ca, cert, htpasswd, nginx, portal, docs   (GATED)
#   12 monitoring   monitoring  env, up
#   13 validate     -        air-gap posture, then the validation suite
#
#   0  every stage clean · 2  finished with warnings to disposition ·
#   1  a stage refused or failed — fix it, then rerun with --from <stage>
#
# A child that returns 2 (warnings) stops the run unless --yes accepted them
# or you answer the prompt. Every gate inside a child needs the same --yes.
# Test seams: DEPLOY_<STAGE>_CMD replaces the script for one stage;
# DEPLOY_ORDER_LOG is where stubs record themselves.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

STAGES=(preflight gate copy apt phone-home docker images files gns3 malcolm portal monitoring validate)
BUNDLE=""; MEDIA=""; DEVICE=""; MGMT_IP=""; FROM=""; TO=""; ONLY=""
usage() { usage_from_header 3 34; exit 0; }

stage_index() { local i; for i in "${!STAGES[@]}"; do [ "${STAGES[$i]}" = "$1" ] && { echo "$i"; return 0; }; done; return 1; }
script_for() {  # script_for <stage> -> the script path, or the test override
    local var; var="DEPLOY_$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')_CMD"
    if [ -n "${!var:-}" ]; then printf '%s' "${!var}"; return 0; fi
    case "$1" in
        preflight|gate|copy|apt|phone-home|docker|images|files) printf '%s' "$KIT_DIR/scripts/r770-import-bundle.sh" ;;
        gns3)       printf '%s' "$KIT_DIR/scripts/r770-gns3-deploy.sh" ;;
        malcolm)    printf '%s' "$KIT_DIR/scripts/r770-malcolm-deploy.sh" ;;
        portal)     printf '%s' "$KIT_DIR/scripts/r770-portal-deploy.sh" ;;
        monitoring) printf '%s' "$KIT_DIR/scripts/r770-monitoring-deploy.sh" ;;
        validate)   printf '%s' "$KIT_DIR/scripts/r770-validate.sh" ;;
    esac
}
local_bundle() {  # after copy, the bundle lives under /srv/bundles
    local l; l="$(p /srv/bundles)/$(basename "$BUNDLE")"
    if [ -d "$l" ]; then printf '%s' "$l"; else printf '%s' "$BUNDLE"; fi
}

WARNED_STAGES=""
child() {  # child <stage> <cmd...> — run, then apply the 0/2/1 contract
    local stage=$1; shift
    local rc=0
    DEPLOY_STAGE="$stage" "$@" || rc=$?
    case "$rc" in
        0) ;;
        2)
            WARNED_STAGES="$WARNED_STAGES $stage"
            echo
            echo "stage '$stage' finished with warnings."
            if [ "${KIT_YES:-0}" = "1" ]; then
                echo "accepted via --yes; disposition them in the cycle log."
            elif [ "${KIT_NON_INTERACTIVE:-0}" = "1" ]; then
                die "stage '$stage' warned and this run is non-interactive — read the warnings, then rerun with --yes --from $stage"
            else
                local a; read -r -p "Continue past the warnings from '$stage'? [y/N] " a
                case "$a" in [yY]*) ;; *) die "stopped after '$stage' — rerun with --from $stage once dispositioned" ;; esac
            fi ;;
        *) die "stage '$stage' refused or failed (exit $rc) — nothing after it ran; fix it, then rerun with --from $stage" ;;
    esac
}

run_stage() {
    local stage=$1 s b; s=$(script_for "$stage")
    banner "$(( $(stage_index "$stage") + 1 ))/${#STAGES[@]}  $stage"
    case "$stage" in
        preflight) child "$stage" "$s" preflight --bundle "$BUNDLE" ;;
        gate)
            if [ -n "$DEVICE" ]; then child "$stage" "$s" gate --bundle "$BUNDLE" --media "$MEDIA" --device "$DEVICE"
            else child "$stage" "$s" gate --bundle "$BUNDLE"; fi ;;
        copy)
            if [ -n "$MEDIA" ]; then child "$stage" "$s" copy --bundle "$BUNDLE" --media "$MEDIA"
            else child "$stage" "$s" copy --bundle "$BUNDLE"; fi ;;
        apt|phone-home|docker|images|files) child "$stage" "$s" "$stage" --bundle "$(local_bundle)" ;;
        gns3)
            b=$(local_bundle)
            child "$stage" "$s" venv --bundle "$b"; child "$stage" "$s" secrets
            child "$stage" "$s" config;           child "$stage" "$s" service ;;
        malcolm)
            b=$(local_bundle)
            child "$stage" "$s" load --bundle "$b";   child "$stage" "$s" unpack --bundle "$b"
            child "$stage" "$s" configure --bundle "$b"; child "$stage" "$s" secrets
            child "$stage" "$s" auth --bundle "$b";   child "$stage" "$s" rebind
            child "$stage" "$s" start ;;
        portal)
            b=$(local_bundle)
            child "$stage" "$s" ca; child "$stage" "$s" cert; child "$stage" "$s" htpasswd
            child "$stage" "$s" nginx
            [ -n "$MGMT_IP" ] || die "stage portal needs --mgmt-ip <address> for the landing page (never guessed)"
            child "$stage" "$s" portal --mgmt-ip "$MGMT_IP"
            child "$stage" "$s" docs --bundle "$b" ;;
        monitoring)
            b=$(local_bundle)
            child "$stage" "$s" env --bundle "$b"; child "$stage" "$s" up ;;
        validate)
            local ag="${DEPLOY_AIRGAP_CMD:-$KIT_DIR/scripts/r770-airgap-check.sh}"
            child "$stage" "$ag"
            child "$stage" "$s" --area airgap --area host --area storage --area portal --area monitoring --area gns3 ;;
    esac
}

while [ $# -gt 0 ]; do
    case "$1" in
        --bundle)  BUNDLE="${2:-}"; shift ;;
        --media)   MEDIA="${2:-}";  shift ;;
        --device)  DEVICE="${2:-}"; shift ;;
        --mgmt-ip) MGMT_IP="${2:-}"; shift ;;
        --from)    FROM="${2:-}"; shift ;;
        --to)      TO="${2:-}"; shift ;;
        --only)    ONLY="${2:-}"; shift ;;
        --list)    printf '%s\n' "${STAGES[@]}"; exit 0 ;;
        -h|--help) usage ;;
        *)         common_flag "$1" || die "unknown option: $1 (try --help)" ;;
    esac
    shift
done
[ -n "$BUNDLE" ] || die "--bundle <dir> is required (try --help)"
[ -n "$ONLY" ] && { FROM="$ONLY"; TO="$ONLY"; }
first=0; last=$(( ${#STAGES[@]} - 1 ))
[ -z "$FROM" ] || first=$(stage_index "$FROM") || die "unknown stage: $FROM (--list shows them)"
[ -z "$TO" ]   || last=$(stage_index "$TO")    || die "unknown stage: $TO (--list shows them)"
[ "$first" -le "$last" ] || die "--from $FROM comes after --to $TO"

kit_init "r770-deploy"
echo "bundle: $BUNDLE"; [ -n "$MEDIA" ] && echo "media: $MEDIA${DEVICE:+ ($DEVICE)}"
echo "stages: ${STAGES[*]:$first:$((last - first + 1))}"
for i in $(seq "$first" "$last"); do run_stage "${STAGES[$i]}"; done

echo
if [ -n "$WARNED_STAGES" ]; then
    echo "DEPLOYED WITH WARNINGS — stages:$WARNED_STAGES. Disposition each in the cycle log; evidence under ${KIT_EVIDENCE_DIR:-./r770-evidence}"
    exit 2
fi
echo "DEPLOYED — every stage clean; evidence under ${KIT_EVIDENCE_DIR:-./r770-evidence}"
exit 0
