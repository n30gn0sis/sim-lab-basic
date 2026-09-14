# The replacement-PATH pattern. The script under test sees ONLY the stubs in
# $BIN plus a fixed allowlist of real, harmless host tools symlinked into
# $REAL. Inheriting the runner's PATH would let a real docker, apt-get,
# systemctl or nginx on GitHub's ubuntu-latest answer for the host under test
# after an `unstub` -- exactly the leak these suites exist to catch.
#
#   kit_test_env          set BIN, REAL, KIT_* seams; call from setup()
#   stub <name> <body>    write $BIN/<name> as a bash script
#   stub_log <name> [rc]  a stub that appends "<name> $*" to $STUB_LOG and exits rc
#   unstub <name>
#   kit_run <cmd...>      run with PATH replaced

kit_test_env() {
    BIN="$BATS_TEST_TMPDIR/bin"
    REAL="$BATS_TEST_TMPDIR/real"
    ROOT="$BATS_TEST_TMPDIR/root"
    STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
    mkdir -p "$BIN" "$REAL"
    : > "$STUB_LOG"
    local t p
    for t in bash env sh awk grep egrep sed cut tr sort uniq wc cat ls cp mv rm mkdir rmdir ln \
             chmod touch install date hostname basename dirname readlink realpath printf echo \
             true false test find xargs tee diff cmp comm tar gzip gunzip zcat stat mktemp \
             sleep timeout id sha256sum base64 od head tail paste seq expr uname nproc \
             du df getent python3 gpg openssl; do
        p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$REAL/$t"
    done
    KIT_PATH="$BIN:$REAL"
    export KIT_ROOT="$ROOT"
    export KIT_NO_TEE=1
    export KIT_EVIDENCE_DIR="$BATS_TEST_TMPDIR/evidence"
    export KIT_NON_INTERACTIVE=1
    export KIT_YES=1
    export STUB_LOG
    unset KIT_DRY_RUN
}

stub() {  # stub <name> <body>
    printf '#!/usr/bin/env bash\n%s\n' "$2" > "$BIN/$1"
    chmod +x "$BIN/$1"
}

stub_log() {  # stub_log <name> [rc] — records argv, exits rc (default 0)
    stub "$1" "echo \"$1 \$*\" >> \"\$STUB_LOG\"; exit ${2:-0}"
}

unstub() { rm -f "$BIN/$1"; }

kit_run() { PATH="$KIT_PATH" "$@"; }

stub_called() {  # stub_called <name> [<substring>] — did the log record it?
    if [ -n "${2:-}" ]; then grep -q "^$1 .*$2" "$STUB_LOG"; else grep -q "^$1" "$STUB_LOG"; fi
}
