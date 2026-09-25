#!/usr/bin/env bash
#
# common.sh — the shared library every kit script sources. Never executed.
#
# The kit runs on the AIR-GAPPED R770: bash >= 4.4 and coreutils only, no
# network, no jq. Everything that touches the host goes through the helpers
# here so that one set of seams makes every script dry-runnable and testable:
#
#   KIT_ROOT=<dir>         prefix for every absolute target path (tests point
#                          it at a fake root; production leaves it empty)
#   KIT_DRY_RUN=1          print every command instead of executing it
#   KIT_YES=1              accept every gate (same as --yes)
#   KIT_NON_INTERACTIVE=1  never prompt; a gate without KIT_YES then refuses
#   KIT_EVIDENCE_DIR=<dir> where transcripts land (default ./r770-evidence)
#   KIT_NO_TEE=1           do not tee the transcript (test harnesses set this)
#
# Reporting vocabulary is fixed across the kit: `PASS  ` / `WARN  ` / `FAIL  `
# / `SKIP  ` lines, no colour, and one of three exit codes:
#   0  clean · 2  done with warnings to disposition · 1  refused or failed
#
# The bundle verifier is NOT here. The bundle carries its own copy of
# r770-bundle.sh, covered by the manifest; bundle_verify() runs that copy.

# ── identity ────────────────────────────────────────────────────────────────
KIT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT_DIR="$(cd "$KIT_LIB_DIR/../.." && pwd)"
KIT_CONFIG_DIR="$KIT_DIR/config"; export KIT_CONFIG_DIR
ROOT="${KIT_ROOT:-}"
DRY="${KIT_DRY_RUN:-0}"
SELF="kit"
PASSED=0; WARNED=0; FAILED=0; SKIPPED=0
KIT_LOG=""

# kit_init <script-name> — set identity, open the evidence transcript.
kit_init() {
    SELF="$1"
    local dir="${KIT_EVIDENCE_DIR:-$PWD/r770-evidence}"
    if [ "${KIT_NO_TEE:-0}" != "1" ]; then
        mkdir -p "$dir"
        KIT_LOG="$dir/${SELF}-$(hostname -s 2>/dev/null || echo host)-$(date +%Y%m%d-%H%M%S).log"
        exec > >(tee -a "$KIT_LOG") 2>&1
        echo "# $SELF — $(date -Is) — transcript $KIT_LOG"
    fi
    umask 022
}

die()  { echo "${SELF}: $*" >&2; exit 1; }
pass() { printf 'PASS  %s\n' "$*"; PASSED=$((PASSED + 1)); }
warn() { printf 'WARN  %s\n' "$*"; WARNED=$((WARNED + 1)); }
fail() { printf 'FAIL  %s\n' "$*"; FAILED=$((FAILED + 1)); }
skip() { printf 'SKIP  %s\n' "$*"; SKIPPED=$((SKIPPED + 1)); }
banner() { printf '\n== %s ==\n' "$*"; }
note()   { printf '      %s\n' "$*"; }

# footer [what] — the three-outcome summary; exits.
footer() {
    local what="${1:-$SELF}"
    echo
    if [ "$FAILED" -gt 0 ]; then
        echo "NOT READY — ${what}: ${FAILED} failure(s), ${WARNED} warning(s), ${SKIPPED} skipped"
        exit 1
    elif [ "$WARNED" -gt 0 ]; then
        echo "READY WITH WARNINGS — ${what}: ${WARNED} warning(s), ${SKIPPED} skipped; disposition each"
        exit 2
    fi
    echo "READY — ${what}: ${PASSED} check(s) passed, ${SKIPPED} skipped"
    exit 0
}

# ── paths and execution ─────────────────────────────────────────────────────
# p <absolute-path> — the path on the host under test. Every target the kit
# writes goes through this, which is what lets a suite redirect the whole
# run into a temporary root.
p() { printf '%s' "${ROOT}${1}"; }

# run <cmd...> — echo, then execute (or only echo under KIT_DRY_RUN=1).
run() {
    if [ "$DRY" = "1" ]; then
        printf 'DRY-RUN:'; printf ' %q' "$@"; printf '\n'
        return 0
    fi
    printf '+'; printf ' %q' "$@"; printf '\n'
    "$@"
}

# need_root — production writes need uid 0; a KIT_ROOT run never does.
need_root() {
    [ -n "$ROOT" ] && return 0
    [ "$(id -u)" -eq 0 ] || die "this subcommand writes to the host — run it as root (sudo)"
}

# require_pkg <pkg...> — every named package must be installed. The kit never
# installs a missing one on the spot: packages come from the bundle's apt/
# through the import script's apt stage, and nowhere else.
require_pkg() {
    local pkg missing=""
    for pkg in "$@"; do
        dpkg -s "$pkg" >/dev/null 2>&1 || missing="$missing $pkg"
    done
    [ -z "$missing" ] || die "package(s) not installed:${missing} — they ship in the bundle's apt/; run 'r770-import-bundle.sh apt' (and check the curated list if apt cannot find them)"
}

# common_flag <arg> — consume the flags every script shares; 0 if consumed.
FORCE=0
common_flag() {
    case "$1" in
        --yes|-y)          KIT_YES=1; export KIT_YES ;;
        --non-interactive) KIT_NON_INTERACTIVE=1; export KIT_NON_INTERACTIVE ;;
        --dry-run)         DRY=1; KIT_DRY_RUN=1; export KIT_DRY_RUN ;;
        --force)           FORCE=1 ;;
        *)                 return 1 ;;
    esac
    return 0
}

# ── step orchestration ──────────────────────────────────────────────────────
# step_index <array-name> <target> — index of <target> in the named array
# (passed by name, via nameref), or return 1 if absent. Generalizes
# r770-deploy.sh's old stage_index() for use by more than one script.
step_index() {
    local -n _arr=$1; local target=$2 i
    for i in "${!_arr[@]}"; do [ "${_arr[$i]}" = "$target" ] && { echo "$i"; return 0; }; done
    return 1
}

# run_step <step-name> <cmd...> — run, then apply the kit's 0/2/1 contract:
# 0 continue; 2 warn (collected into the caller's WARNED_STEPS, gated on
# KIT_YES / a prompt / KIT_NON_INTERACTIVE exactly like every other gate);
# anything else dies naming the step to resume with. Generalizes
# r770-deploy.sh's old child(). Caller declares WARNED_STEPS="" before its
# first call and reads it after the loop to report warnings.
#
# <cmd...> runs in a subshell ( ), not bare. r770-deploy.sh's child() always
# ran a SEPARATE script (a new process), so that script's own die()/footer()
# `exit` only ever ended that process. A "full" pipeline now also runs a few
# steps in-process, as this script's own cmd_* functions — and those end in
# die()/footer(), which call `exit`. Called bare, that `exit` would kill this
# whole script on the first such step, not just the step. The subshell keeps
# `exit` scoped to the step, so run_step always gets a clean $? back.
run_step() {
    local step=$1; shift
    local rc=0
    ( "$@" ) || rc=$?
    case "$rc" in
        0) ;;
        2)
            WARNED_STEPS="${WARNED_STEPS:-} $step"
            echo
            echo "step '$step' finished with warnings."
            if [ "${KIT_YES:-0}" = "1" ]; then
                echo "accepted via --yes; disposition them in the cycle log."
            elif [ "${KIT_NON_INTERACTIVE:-0}" = "1" ]; then
                die "step '$step' warned and this run is non-interactive — read the warnings, then rerun with --yes --from $step"
            else
                local a; read -r -p "Continue past the warnings from '$step'? [y/N] " a
                case "$a" in [yY]*) ;; *) die "stopped after '$step' — rerun with --from $step once dispositioned" ;; esac
            fi ;;
        *) die "step '$step' refused or failed (exit $rc) — nothing after it ran; fix it, then rerun with --from $step" ;;
    esac
}

# gate <title> <current-fn> <proposed-fn> <rollback-text>
# Shows what is, what will be, and how to undo it — then needs a decision.
# --non-interactive without --yes refuses: a gate is a question, and an
# unattended run that cannot answer must stop, never assume.
gate() {
    local title=$1 current=$2 proposed=$3 rollback=$4
    echo
    echo "== GATE: ${title} =="
    echo "-- current --";  "$current"
    echo "-- proposed --"; "$proposed"
    echo "-- rollback --"; printf '%s\n' "$rollback"
    if [ "${KIT_YES:-0}" = "1" ]; then
        echo "-- accepted via --yes --"
        return 0
    fi
    if [ "${KIT_NON_INTERACTIVE:-0}" = "1" ]; then
        die "gate '${title}' needs a decision and this run is non-interactive — rerun with --yes once you have read current/proposed/rollback"
    fi
    local a
    read -r -p "Apply '${title}'? [y/N] " a
    case "$a" in [yY]*) return 0 ;; *) die "stopped at gate '${title}' — nothing was changed by it" ;; esac
}

# ── the bundle ───────────────────────────────────────────────────────────────
# bundle_dir <dir> — resolve and validate a bundle directory. A bundle is
# recognisable by what the fetch script always writes into its root.
bundle_dir() {
    local d=${1:-}
    [ -n "$d" ] || die "a bundle directory is required (--bundle <dir>)"
    [ -d "$d" ] || die "not a directory: $d"
    d=$(cd "$d" && pwd)
    local f
    for f in r770-bundle.sh BUNDLE_NOTES.md MANIFEST.sha256; do
        [ -e "$d/$f" ] || die "$d is not a bundle: $f is missing from its root"
    done
    [ -x "$d/r770-bundle.sh" ] || die "$d/r770-bundle.sh is not executable — the verifier travels in the bundle root"
    printf '%s' "$d"
}

# bundle_verify <dir> [--strict] — run the verifier that travels IN the bundle.
# Prints its output, then the RESULT line again for the evidence reader, and
# returns its exit code: 0 PASS · 2 PASS WITH WARNINGS · 1 FAIL.
bundle_verify() {
    local d=$1; shift
    local out rc=0
    echo "+ ${d}/r770-bundle.sh verify ${d} $*"
    out=$("$d/r770-bundle.sh" verify "$d" "$@" 2>&1) || rc=$?
    printf '%s\n' "$out"
    local result
    result=$(printf '%s\n' "$out" | grep '^RESULT:' | tail -1)
    echo "verifier exit ${rc}: ${result:-<no RESULT line printed>}"
    return "$rc"
}

# image_list <file> — the tags in a bundle image list, comments/blanks stripped.
image_list() {
    local f=$1
    [ -s "$f" ] || die "missing or empty $f — is this a bundle directory?"
    local out
    out=$(grep -vE '^[[:space:]]*(#|$)' "$f" || true)
    [ -n "$out" ] || die "no image tags in $f — only comments or blank lines"
    printf '%s\n' "$out"
}

# image_norm [<ref>...] — each image reference (args, or one per line on
# stdin) in docker's familiar form: a leading docker.io/ stripped, then a
# leading library/. `docker image ls` prints alpine:latest where a bundle's
# list says docker.io/library/alpine:latest; any other registry keeps its name.
image_norm() {
    if [ $# -gt 0 ]; then printf '%s\n' "$@"; else cat; fi | sed -e 's#^docker\.io/##' -e 's#^library/##'
}

# docker_loaded_images — every repository:tag in the docker image store,
# normalised by image_norm; empty (never an error) when docker cannot answer.
docker_loaded_images() {
    docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | image_norm || true
}

# assert_image_tags <list-file> — every tag in the list is present in the
# docker image store (both sides compared through image_norm; the lines
# printed keep the list's own names). `docker load` reports success even when
# the resulting tag set is incomplete, which is why this exists. Returns 1
# with the count.
#
# The list is read into the shell BEFORE the loop. Feeding the loop from a
# process substitution would put image_list in a subshell, where its die()
# exits that subshell only: the loop would see EOF, `missing` stay 0, and a
# bundle with NO list at all be reported "all images present".
assert_image_tags() {
    local f=$1 list present missing=0 want
    # `|| return 1`: image_list dies inside the substitution's subshell, which
    # would otherwise leave `list` empty and the loop reporting success.
    list=$(image_list "$f") || return 1
    present=$(docker_loaded_images)
    while IFS= read -r want; do
        [ -n "$want" ] || continue
        if printf '%s\n' "$present" | grep -qxF "$(image_norm "$want")"; then
            echo "ok      $want"
        else
            echo "MISSING $want"
            missing=$((missing + 1))
        fi
    done <<< "$list"
    if [ "$missing" -gt 0 ]; then
        echo "$missing image(s) missing from $f — the tarball is incomplete or the load failed"
        return 1
    fi
    echo "all images present ($f)"
}

# image_ref_from_list <list-file> <repository-basename> — the one full
# image reference whose repository ends in /<basename>. Tags are never typed
# into the kit; they are read out of the bundle that carries the images.
image_ref_from_list() {
    local f=$1 name=$2 hits n
    [ -s "$f" ] || die "missing or empty $f — is this a bundle directory?"
    hits=$(image_list "$f" | grep -E "(^|/)${name}:[^/]+$" || true)
    n=$(printf '%s' "$hits" | grep -c . || true)
    [ "$n" -ne 0 ] || die "no image named '${name}' in $f — this bundle does not carry it"
    [ "$n" -eq 1 ] || die "${n} images named '${name}' in $f — cannot choose: $(printf '%s' "$hits" | tr '\n' ' ')"
    printf '%s' "$hits"
}

# ── files ────────────────────────────────────────────────────────────────────
# render <template> <dest> [KEY=VALUE...] — substitute __KEY__ tokens, refuse
# to write if any __TOKEN__ survives. Mode via RENDER_MODE (default 0644).
render() {
    local tpl=$1 dest=$2; shift 2
    [ -f "$tpl" ] || die "template not found: $tpl"
    local tmp expr="" kv key val
    tmp=$(mktemp)
    for kv in "$@"; do
        key=${kv%%=*}; val=${kv#*=}
        val=${val//\\/\\\\}; val=${val//|/\\|}; val=${val//&/\\&}
        expr="${expr}s|__${key}__|${val}|g;"
    done
    sed -e "$expr" "$tpl" > "$tmp"
    local left
    left=$(grep -oE '__[A-Z][A-Z0-9_]*__' "$tmp" | sort -u | tr '\n' ' ' || true)
    if [ -n "$left" ]; then
        rm -f "$tmp"
        die "unrendered token(s) in $(basename "$tpl"): ${left}— every __TOKEN__ must be given a value"
    fi
    if [ "$DRY" = "1" ]; then
        echo "DRY-RUN: render $tpl -> $dest"
        rm -f "$tmp"; return 0
    fi
    mkdir -p "$(dirname "$dest")"
    install -m "${RENDER_MODE:-0644}" "$tmp" "$dest"
    rm -f "$tmp"
    echo "rendered $dest"
}

# assert_edit <file> <grep -E pattern> <expected-count> — refuse to edit a
# file whose shape is not the one the edit was written for. The kit never
# blind-seds an installer-generated file: a pattern that matches zero lines
# means the format moved, and matching two means the edit would be wrong.
assert_edit() {
    local f=$1 pat=$2 want=$3 have
    [ -f "$f" ] || die "cannot edit $f: file not found"
    have=$(grep -cE -- "$pat" "$f" || true)
    [ "$have" -eq "$want" ] || die "refusing to edit $f: expected ${want} line(s) matching '${pat}', found ${have} — the file's format is not the one this edit was written for"
}

# stamp / stamped <name> — idempotency markers for the copy steps, kept beside
# the bundles so a re-run skips what already landed.
STAMP_DIR=""
stamp_init() { STAMP_DIR="$(p /srv/bundles/.kit-stamps)"; }
stamped() { [ -n "$STAMP_DIR" ] || stamp_init; [ -f "$STAMP_DIR/$1" ]; }
stamp()   { [ -n "$STAMP_DIR" ] || stamp_init; [ "$DRY" = "1" ] && return 0; mkdir -p "$STAMP_DIR" && date -Is > "$STAMP_DIR/$1"; }

# ── secrets ──────────────────────────────────────────────────────────────────
# secret_file <path> — generate once, mode 0600 in a 0700 directory, print
# the LOCATION once and never the value. Existing file: no-op unless FORCE=1.
secret_file() {
    local f=$1 dir
    dir=$(dirname "$f")
    if [ -s "$f" ] && [ "$FORCE" != "1" ]; then
        echo "secret present: $f (use --force to regenerate)"
        return 0
    fi
    if [ "$DRY" = "1" ]; then echo "DRY-RUN: generate secret $f"; return 0; fi
    mkdir -p "$dir"; chmod 0700 "$dir"
    ( umask 077; head -c 48 /dev/urandom | base64 | tr -d '/+=\n' | head -c 32 > "$f"; echo >> "$f" )
    chmod 0600 "$f"
    echo "generated secret: $f (0600) — the value is never printed or logged"
}

secret_read() {
    local f=$1
    [ -s "$f" ] || die "secret not found: $f — run the 'secrets' subcommand first"
    head -1 "$f"
}

# ── network ──────────────────────────────────────────────────────────────────
# net_is_physical <ifname> [depth] — 0 if the interface is backed by hardware:
# it has a sysfs `device` link, or one of its lower devices (a VLAN's parent,
# a bond's slaves, recursively) does. Depth-limited, so a lower-device cycle
# ends instead of looping. Read through p(), so a suite fakes sysfs under ROOT.
net_is_physical() {
    local n=$1 depth=${2:-0} sys l
    [ "$depth" -le 8 ] || return 1
    sys="$(p /sys/class/net)"
    [ -e "$sys/$n/device" ] && return 0
    for l in "$sys/$n"/lower_*; do
        [ -e "$l" ] || [ -L "$l" ] || continue
        net_is_physical "${l##*/lower_}" $((depth + 1)) && return 0
    done
    return 1
}

# bridge_physical_ports <bridge> — the bridge's ports that are physical, per
# net_is_physical, space-separated (nothing when there are none or the
# bridge is absent). Rule 8: the lab fabric never touches a physical port,
# not even through a VLAN or a bond.
bridge_physical_ports() {
    local port n out=""
    for port in "$(p /sys/class/net)/$1"/brif/*; do
        [ -e "$port" ] || continue
        n=${port##*/}
        net_is_physical "$n" && out="${out:+$out }$n"
    done
    printf '%s' "$out"
}

# ── misc ─────────────────────────────────────────────────────────────────────
# usage_from_header <first-line> — the caller's header comment block, from
# <first-line> to the last line before the first line that is not a comment.
# The end is FOUND, never declared. A declared last line silently truncates
# --help the moment a line is added above it, and it did: four scripts shipped
# a help that stopped mid-sentence, one of them closing on `set -uo pipefail`.
usage_from_header() {
    local first=$1 src=${BASH_SOURCE[1]} last
    last=$(awk -v s="$first" 'NR >= s && $0 !~ /^#/ { print NR - 1; exit }' "$src")
    [ -n "$last" ] || last=$(wc -l < "$src")
    sed -n "${first},${last}p" "$src" | sed 's/^# \{0,1\}//'
}

# glob_one <dir> <glob> — exactly one match, or die naming the count.
glob_one() {
    local d=$1 g=$2 hits=() f
    for f in "$d"/$g; do [ -e "$f" ] && hits+=("$f"); done
    [ "${#hits[@]}" -ne 0 ] || die "nothing matches $g under $d"
    [ "${#hits[@]}" -eq 1 ] || die "${#hits[@]} files match $g under $d — expected exactly one: ${hits[*]}"
    printf '%s' "${hits[0]}"
}

# help_has_flag <cmd...> -- <flag...> — every named flag appears in --help.
# The kit hard-codes the flag set a rehearsal proved, then checks the bundled
# tool still advertises each one before invoking it, so a version bump fails
# by name instead of by surprise.
help_has_flags() {
    local -a cmd=() flags=()
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do cmd+=("$1"); shift; done
    shift || true
    flags=("$@")
    local help f missing=""
    help=$("${cmd[@]}" --help 2>&1 || true)
    for f in "${flags[@]}"; do
        printf '%s\n' "$help" | grep -qF -- "$f" || missing="$missing $f"
    done
    [ -z "$missing" ] || die "${cmd[*]} --help does not list:${missing} — the bundled tool's interface moved; read the bundle's BUNDLE_NOTES.md and update the kit before continuing"
}
