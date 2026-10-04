#!/usr/bin/env bats
#
# r770-install.sh against stubbed children and a stubbed host: the
# installer's own contract. install.conf is parsed (never sourced) and
# refused on any guess; discovery chooses nothing; each step calls the
# kit entry point it names with arguments from install.conf, in order; the
# verdict is INSTALLED only when every step is clean.

load helpers/fixtures
load helpers/stubs

setup() {
    kit_test_env
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-install.sh"
    export T="$BATS_TEST_TMPDIR"
    make_root "$ROOT"
    BUNDLE="$T/media/bundle-fixture"; make_bundle "$BUNDLE"
    CONF="$T/install.conf"
    stub lsblk 'printf "/dev/sda 400G disk \n/dev/sda1 400G part /\n/dev/sdb 64G disk \n/dev/sdb1 64G part /media/usb\n"'
    stub ip 'case "$*" in
  "-br addr"*)                  printf "lo UNKNOWN 127.0.0.1/8\neno1 UP 192.168.4.78/24\nens2f0 UP \n" ;;
  "-br link show type bridge"*) printf "br-lab UP\n" ;;
  "-br link"*)                  printf "lo UNKNOWN\neno1 UP\nens2f0 UP\nbr-lab UP\nlab_mirror0 UP\n" ;;
esac'
    stub findmnt 'case "$*" in -lno\ TARGET,SOURCE*) printf "/ /dev/sda1\n/media/usb /dev/sdb1\n" ;; *) exit 1 ;; esac'
    for c in import gns3 malcolm docs portal validate e2e; do
        stub "$c-stub" 'echo "'"$c"' $*" >> "$STUB_LOG"; f="$T/rc-'"$c"'"; [ -f "$f" ] && exit "$(cat "$f")"; exit 0'
    done
    export INSTALL_IMPORT_CMD="$BIN/import-stub" INSTALL_GNS3_CMD="$BIN/gns3-stub" INSTALL_MALCOLM_CMD="$BIN/malcolm-stub" \
           INSTALL_DOCS_CMD="$BIN/docs-stub" INSTALL_PORTAL_CMD="$BIN/portal-stub" INSTALL_VALIDATE_CMD="$BIN/validate-stub" \
           INSTALL_E2E_CMD="$BIN/e2e-stub"
}

inst() { kit_run "$SCRIPT" "$@"; }
good_conf() {
    cat > "$CONF" <<EOF
# a filled-in answers file
BUNDLE=$BUNDLE
MEDIA=/media/usb
DEVICE=/dev/sdb1
CAPTURE_IFS=lab_mirror0
LAB_BRIDGE=br-lab
MGMT_IF=eno1
MGMT_CIDR=192.168.4.0/24
EOF
}

@test "discover prints what the host has and writes only the template — every value empty" {
    run inst discover
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/dev/sdb1"* ]]; [[ "$output" == *"eno1"* ]]; [[ "$output" == *"/media/usb"* ]]
    tpl="$ROOT/etc/lab/install.conf.template"
    [ -s "$tpl" ]
    [ ! -e "$ROOT/etc/lab/install.conf" ]
    run grep -E '^[A-Z_]+=.+' "$tpl"
    [ "$status" -ne 0 ]     # no key carries a value
    for k in BUNDLE MEDIA DEVICE CAPTURE_IFS LAB_BRIDGE MGMT_IF MGMT_CIDR VALIDATE_AREAS; do grep -q "^$k=$" "$tpl"; done
}

@test "a missing answers file is refused, naming discover" {
    run inst run --conf "$T/nope.conf" --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"discover"* ]]
    [ ! -s "$STUB_LOG" ]
}

@test "install.conf is parsed, never sourced: shell in a value is not executed" {
    good_conf
    printf 'MGMT_CIDR=$(touch %s/pwned)\n' "$T" >> "$CONF"
    run inst run --conf "$CONF" --yes --from gns3 --to gns3
    [ ! -e "$T/pwned" ]
    [ "$status" -eq 1 ]
    [[ "$output" == *"MGMT_CIDR"* ]]
}

@test "install.conf: an unknown key, an empty required key and each placeholder are FAILs, all reported, no child runs" {
    good_conf
    echo "NIC=eno1" >> "$CONF"
    run inst run --conf "$CONF" --yes
    [ "$status" -eq 1 ]; [[ "$output" == *"unknown key NIC"* ]]
    good_conf; sed -i 's#^DEVICE=.*#DEVICE=/dev/sdX#; s#^MGMT_IF=.*#MGMT_IF=#; s#^MEDIA=.*#MEDIA=<mountpoint>#' "$CONF"
    run inst run --conf "$CONF" --yes
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  install.conf: DEVICE is a placeholder"* ]]
    [[ "$output" == *"FAIL  install.conf: MGMT_IF is empty"* ]]
    [[ "$output" == *"FAIL  install.conf: MEDIA is a placeholder"* ]]
    [ ! -s "$STUB_LOG" ]
}

@test "install.conf: a device or interface this host does not have is a FAIL; lab_mirror0 and the lab bridge may wait for labnet" {
    good_conf; sed -i 's#^DEVICE=.*#DEVICE=/dev/sdz1#; s#^CAPTURE_IFS=.*#CAPTURE_IFS="lab_mirror0 ens9"#' "$CONF"
    run inst run --conf "$CONF" --yes
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"DEVICE /dev/sdz1 is not a block device on this host"* ]]
    [[ "$output" == *"CAPTURE_IFS: ens9 does not exist"* ]]
    stub ip 'case "$*" in "-br link"*) printf "lo UNKNOWN\neno1 UP\n" ;; esac'
    good_conf
    run inst run --conf "$CONF" --yes --from gns3 --to gns3
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"lab_mirror0"*"created by the gns3 step"* ]]
}

@test "install.conf with CRLF endings, trailing spaces and quoted values parses the same as a clean one" {
    good_conf
    sed -i 's/$/  \r/; s#^MGMT_CIDR=.*#MGMT_CIDR="192.168.4.0/24"  \r#' "$CONF"
    run inst run --conf "$CONF" --yes --from gns3 --to gns3
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qx "gns3 full --bundle $BUNDLE" "$STUB_LOG"
}

@test "BUNDLE may be left empty only when the installer sits inside a bundle bundle_dir accepts" {
    good_conf; sed -i 's#^BUNDLE=.*#BUNDLE=#' "$CONF"
    run inst run --conf "$CONF" --yes --from gns3 --to gns3
    [ "$status" -eq 1 ]
    [[ "$output" == *"BUNDLE is empty and this installer is not inside a bundle"* ]]
    mkdir -p "$BUNDLE/kit"; cp -r "$BATS_TEST_DIRNAME/../scripts" "$BUNDLE/kit/"
    run kit_run "$BUNDLE/kit/scripts/r770-install.sh" run --conf "$CONF" --yes --from gns3 --to gns3
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qx "gns3 full --bundle $BUNDLE" "$STUB_LOG"
}

@test "wizard writes exactly the values picked from what discovery found, and nothing else" {
    mkdir -p "$BUNDLE/kit"; cp -r "$BATS_TEST_DIRNAME/../scripts" "$BUNDLE/kit/"
    # media 2 (/media/usb) · device 4 (/dev/sdb1) · mgmt 1 (eno1) · extra capture ports: none · bridge 1 (br-lab)
    run bash -c "printf '2\n4\n1\n\n1\n' | PATH='$KIT_PATH' '$BUNDLE/kit/scripts/r770-install.sh' wizard --conf '$CONF'"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qx "BUNDLE=$BUNDLE" "$CONF"
    grep -qx "MEDIA=/media/usb" "$CONF"
    grep -qx "DEVICE=/dev/sdb1" "$CONF"
    grep -qx "MGMT_IF=eno1" "$CONF"
    grep -qx "MGMT_CIDR=192.168.4.0/24" "$CONF"
    grep -qx "CAPTURE_IFS=lab_mirror0" "$CONF"
    grep -qx "LAB_BRIDGE=br-lab" "$CONF"
    [ ! -s "$STUB_LOG" ]
}

@test "wizard: extra capture ports are picked by number; an out-of-range answer is asked again" {
    mkdir -p "$BUNDLE/kit"; cp -r "$BATS_TEST_DIRNAME/../scripts" "$BUNDLE/kit/"
    # device answer 9 is out of range, then 4; extra capture port 1 (ens2f0)
    run bash -c "printf '2\n9\n4\n1\n1\n1\n' | PATH='$KIT_PATH' '$BUNDLE/kit/scripts/r770-install.sh' wizard --conf '$CONF'"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"not one of"* ]]
    grep -qx "CAPTURE_IFS=lab_mirror0 ens2f0" "$CONF"
}

@test "wizard refuses a management interface with no address" {
    mkdir -p "$BUNDLE/kit"; cp -r "$BATS_TEST_DIRNAME/../scripts" "$BUNDLE/kit/"
    run bash -c "printf '2\n4\n2\n' | PATH='$KIT_PATH' '$BUNDLE/kit/scripts/r770-install.sh' wizard --conf '$CONF'"
    [ "$status" -eq 1 ]; [[ "$output" == *"has no IPv4 address"* ]]
    [ ! -e "$CONF" ]
}

@test "wizard never overwrites an existing install.conf without --force, and dies on end of input" {
    good_conf
    run bash -c "printf '' | PATH='$KIT_PATH' '$SCRIPT' wizard --conf '$CONF'"
    [ "$status" -eq 1 ]; [[ "$output" == *"--force"* ]]
    rm -f "$CONF"
    mkdir -p "$BUNDLE/kit"; cp -r "$BATS_TEST_DIRNAME/../scripts" "$BUNDLE/kit/"
    run bash -c "printf '2\n' | PATH='$KIT_PATH' '$BUNDLE/kit/scripts/r770-install.sh' wizard --conf '$CONF'"
    [ "$status" -eq 1 ]
    [ ! -e "$CONF" ]
}

@test "run --from gns3: every step calls its entry point with install.conf's values, in order, and ends INSTALLED" {
    good_conf
    run inst run --conf "$CONF" --yes --from gns3
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"INSTALLED"* ]]; [[ "$output" != *"NOT INSTALLED"* ]]
    logdir=$(ls -d "$KIT_EVIDENCE_DIR"/install-*/ | head -1); logdir=${logdir%/}
    run cat "$STUB_LOG"
    [ "${lines[0]}" = "gns3 full --bundle $BUNDLE" ]
    [ "${lines[1]}" = "malcolm full --bundle $BUNDLE --capture-ifs lab_mirror0" ]
    [ "${lines[2]}" = "docs full --bundle $BUNDLE" ]
    [ "${lines[3]}" = "portal ca" ]
    [ "${lines[4]}" = "portal cert" ]
    [ "${lines[5]}" = "portal htpasswd" ]
    [ "${lines[6]}" = "portal nginx" ]
    [ "${lines[7]}" = "malcolm dashboards" ]
    [ "${lines[8]}" = "malcolm arkime-views" ]
    [ "${lines[9]}" = "validate --capture-ifs lab_mirror0 --lab-bridge br-lab --mgmt-if eno1 --mgmt-cidr 192.168.4.0/24 --out $logdir" ]
    [ "${lines[10]}" = "e2e --bundle $BUNDLE --capture-ifs lab_mirror0 --lab-bridge br-lab --skip-validate --out $logdir" ]
    grep -q '^| e2e | PASS |' "$logdir.md"
    grep -q '^INSTALLED' "$logdir.md"
    grep -q 'umount /media/usb' "$logdir.md"
}

@test "run passes VALIDATE_AREAS as one --area per area, and the local bundle copy once it exists" {
    good_conf; echo 'VALIDATE_AREAS=network gns3' >> "$CONF"
    mkdir -p "$ROOT/srv/bundles/bundle-fixture"
    run inst run --conf "$CONF" --yes --from validate
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q -- '--area network --area gns3' "$STUB_LOG"
    grep -q "^e2e --bundle $ROOT/srv/bundles/bundle-fixture " "$STUB_LOG"
}

@test "the first FAIL stops the run, names the step to rerun with --from, and lands in the summary" {
    good_conf; echo 1 > "$T/rc-malcolm"
    run inst run --conf "$CONF" --yes --from gns3
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"--from malcolm"* ]]
    ! grep -q '^docs ' "$STUB_LOG"
    logdir=$(ls -d "$KIT_EVIDENCE_DIR"/install-*/ | head -1); logdir=${logdir%/}
    grep -q '^| malcolm | FAIL |' "$logdir.md"
    grep -q '^NOT INSTALLED' "$logdir.md"
}

@test "a step that warns makes the verdict NOT INSTALLED (exit 2), never INSTALLED" {
    good_conf; echo 2 > "$T/rc-e2e"
    run inst run --conf "$CONF" --yes --from gns3
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"NOT INSTALLED — finished with warnings from: e2e"* ]]
}

@test "run without --yes adds no answer: the child sees no KIT_YES and its gate decides" {
    good_conf
    unset KIT_YES
    stub gns3-stub 'echo "gns3 $* yes=${KIT_YES:-}" >> "$STUB_LOG"; exit 1'
    run inst run --conf "$CONF" --non-interactive --from gns3
    echo "$output"
    [ "$status" -eq 1 ]
    grep -qx "gns3 full --bundle $BUNDLE yes=" "$STUB_LOG"
}

@test "--from/--to: a slice runs alone; a typo names the valid steps and runs nothing" {
    good_conf
    run inst run --conf "$CONF" --yes --from docs --to portal
    [ "$status" -eq 0 ]
    run cut -d' ' -f1 "$STUB_LOG"; [ "${lines[0]}" = docs ]; [ "${#lines[@]}" -eq 5 ]
    : > "$STUB_LOG"
    run inst run --conf "$CONF" --yes --from malcom
    [ "$status" -eq 1 ]
    [[ "$output" == *"import gns3 malcolm docs portal dashboards validate e2e"* ]]
    [ ! -s "$STUB_LOG" ]
}

@test "Ctrl-C mid-run: the summary says interrupted and names the step to rerun" {
    good_conf
    stub docs-stub 'echo "docs $*" >> "$STUB_LOG"; pg=$(cut -d" " -f5 /proc/$$/stat); kill -INT -- "-$pg"; sleep 2'
    # its own session, so the stub's process-group signal reaches the installer and never bats
    run setsid -w env PATH="$KIT_PATH" "$SCRIPT" run --conf "$CONF" --yes --from gns3
    echo "$output"
    [ "$status" -ne 0 ]
    logdir=$(ls -d "$KIT_EVIDENCE_DIR"/install-*/ | head -1); logdir=${logdir%/}
    grep -q '^| docs | FAIL | interrupted' "$logdir.md"
    grep -q -- '--from docs' "$logdir.md"
}

@test "run again after INSTALLED: not refused, INSTALLED again (the children are idempotent)" {
    good_conf
    run inst run --conf "$CONF" --yes --from gns3; [ "$status" -eq 0 ]
    run inst run --conf "$CONF" --yes --from gns3; [ "$status" -eq 0 ]
    [[ "$output" == *"INSTALLED"* ]]
}

@test "status lists each step as done or not, from the installer's own stamps" {
    good_conf
    run inst run --conf "$CONF" --yes --from gns3 --to malcolm
    run inst status
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"gns3"*"done"* ]]
    [[ "$output" == *"docs"*"not yet"* ]]
}

# the import stub's copy lands a local bundle whose kit/ installer only records how it was called
copy_lands_kit() {
    stub import-stub 'echo "import $*" >> "$STUB_LOG"
if [ "$1" = copy ]; then
  d="$KIT_ROOT/srv/bundles/bundle-fixture/kit/scripts"; mkdir -p "$d"
  printf "#!/usr/bin/env bash\necho \"handoff \$* logdir=\$INSTALL_LOGDIR\" >> \"%s\"\n" "$STUB_LOG" > "$d/r770-install.sh"; chmod +x "$d/r770-install.sh"
fi'
}

@test "import from the media: preflight, gate with media and device, copy WITHOUT media, then exec the local copy from gns3" {
    good_conf; copy_lands_kit
    run inst run --conf "$CONF" --yes
    echo "$output"
    [ "$status" -eq 0 ]
    run cat "$STUB_LOG"
    [ "${lines[0]}" = "import preflight --bundle $BUNDLE" ]
    [ "${lines[1]}" = "import gate --bundle $BUNDLE --media /media/usb --device /dev/sdb1" ]
    [ "${lines[2]}" = "import copy --bundle $BUNDLE" ]
    [[ "${lines[3]}" == "handoff run --from gns3 --conf $CONF --yes --non-interactive logdir=$KIT_EVIDENCE_DIR/install-"* ]]
    [ "${#lines[@]}" -eq 4 ]
}

@test "--to import stops after the copy: no hand-off" {
    good_conf; copy_lands_kit
    run inst run --conf "$CONF" --yes --to import
    [ "$status" -eq 0 ]
    ! grep -q '^handoff' "$STUB_LOG"
}

@test "a copied bundle with no kit/ installer is a FAIL that says how the bundle was cut" {
    good_conf
    run inst run --conf "$CONF" --yes
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"KIT_SRC_ROOT"* ]]
}

@test "already running from the local copy: import continues in-process, no exec" {
    good_conf
    local kit="$ROOT/srv/bundles/bundle-fixture/kit"
    mkdir -p "$kit"; cp -r "$BATS_TEST_DIRNAME/../scripts" "$kit/"
    run kit_run "$kit/scripts/r770-install.sh" run --conf "$CONF" --yes --to gns3
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qx "gns3 full --from apt --bundle $ROOT/srv/bundles/bundle-fixture" "$STUB_LOG"
}

@test "plan: the storage check, then every gated step under --dry-run; read-only steps are listed, not run" {
    good_conf
    unset KIT_YES
    stub gns3-stub 'echo "gns3 $* yes=${KIT_YES:-} dry=${KIT_DRY_RUN:-}" >> "$STUB_LOG"'
    run inst plan --conf "$CONF"
    echo "$output"
    [ "$status" -eq 0 ]
    plan_out=$output
    run cat "$STUB_LOG"
    [ "${lines[0]}" = "import storage --bundle $BUNDLE" ]
    [ "${lines[1]}" = "import gate --bundle $BUNDLE --media /media/usb --device /dev/sdb1 --dry-run" ]
    [ "${lines[2]}" = "import copy --bundle $BUNDLE --dry-run" ]
    [ "${lines[3]}" = "gns3 full --bundle $BUNDLE --dry-run yes=1 dry=1" ]
    [ "${lines[4]}" = "malcolm full --bundle $BUNDLE --capture-ifs lab_mirror0 --dry-run" ]
    [ "${lines[5]}" = "docs full --bundle $BUNDLE --dry-run" ]
    [ "${lines[6]}" = "portal ca --dry-run" ]
    [ "${lines[9]}" = "portal nginx --dry-run" ]
    [ "${#lines[@]}" -eq 10 ]
    [[ "$plan_out" == *"dashboards"*"after Malcolm is up"* ]]
    [[ "$plan_out" == *"e2e"*"read-only"* ]]
}

@test "plan reports a child's refusal as FAIL, never PASS (e.g. Malcolm before labnet exists)" {
    good_conf; echo 1 > "$T/rc-malcolm"
    run inst plan --conf "$CONF"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  malcolm"* ]]
    grep -q '^docs ' "$STUB_LOG"     # plan reviews everything; it does not stop at the first refusal
}

@test "plan refuses a bad install.conf before any child runs" {
    good_conf; sed -i 's#^DEVICE=.*#DEVICE=/dev/sdX#' "$CONF"
    run inst plan --conf "$CONF"
    [ "$status" -eq 1 ]
    [ ! -s "$STUB_LOG" ]
}

# ── final-review fixes ─────────────────────────────────────────────────────
# the import stub's copy lands a local bundle carrying the REAL kit scripts, so the exec'd run is real
copy_lands_real_kit() {
    stub import-stub 'echo "import $*" >> "$STUB_LOG"
case "$1" in
  preflight) [ -f "$T/preflight.out" ] && cat "$T/preflight.out"; [ -f "$T/rc-preflight" ] && exit "$(cat "$T/rc-preflight")" ;;
  copy) mkdir -p "$KIT_ROOT/srv/bundles/bundle-fixture/kit"; cp -r "'"$BATS_TEST_DIRNAME"'/../scripts" "$KIT_ROOT/srv/bundles/bundle-fixture/kit/" ;;
esac
exit 0'
}

@test "I1: a warning from import survives the hand-off — NOT INSTALLED, exit 2" {
    good_conf; copy_lands_real_kit
    printf 'WARN  something nobody expected\n' > "$T/preflight.out"; echo 2 > "$T/rc-preflight"
    run inst run --conf "$CONF" --yes
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"NOT INSTALLED — finished with warnings from: import"* ]]
}

@test "I1: preflight's first-install warnings alone are a note, not a disposition — INSTALLED" {
    good_conf; copy_lands_real_kit
    printf 'WARN  tool not yet present: docker — it is installed later\nWARN  tool not yet present: unzip — x\nWARN  no previous bundle under /srv/bundles — first cycle?\n' > "$T/preflight.out"; echo 2 > "$T/rc-preflight"
    run inst run --conf "$CONF" --yes
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"expected first-install"* ]]
    [[ "$output" == *"INSTALLED — every step clean"* ]]
}

@test "I2: re-entry past import works with the media gone — the local copy stands in for BUNDLE" {
    good_conf
    make_bundle "$ROOT/srv/bundles/bundle-fixture"
    mv "$BUNDLE" "$T/stick-removed"
    stub lsblk 'printf "/dev/sda 400G disk \n/dev/sda1 400G part /\n"'
    run inst run --conf "$CONF" --yes --from validate
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q "^e2e --bundle $ROOT/srv/bundles/bundle-fixture " "$STUB_LOG"
}

@test "I2: a run that includes import still requires the media and its device" {
    good_conf
    stub lsblk 'printf "/dev/sda 400G disk \n"'
    run inst run --conf "$CONF" --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *"DEVICE /dev/sdb1 is not a block device"* ]]
}

@test "I3: once import is done, each pipeline starts at apt — no second preflight/gate/copy" {
    good_conf
    mkdir -p "$ROOT/srv/bundles/.kit-stamps"; date -Is > "$ROOT/srv/bundles/.kit-stamps/install.import"
    run inst run --conf "$CONF" --yes --from gns3 --to docs
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qx "gns3 full --from apt --bundle $BUNDLE" "$STUB_LOG"
    grep -qx "malcolm full --from apt --bundle $BUNDLE --capture-ifs lab_mirror0" "$STUB_LOG"
    grep -qx "docs full --from apt --bundle $BUNDLE" "$STUB_LOG"
}

@test "I5: plan before labnet reviews Malcolm up to unpack and SKIPs the rest, naming labnet — not a FAIL" {
    good_conf
    stub ip 'case "$*" in "-br link"*) printf "lo UNKNOWN\neno1 UP\nens2f0 UP\n" ;; esac'
    run inst plan --conf "$CONF"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qx "malcolm full --bundle $BUNDLE --to unpack --dry-run" "$STUB_LOG"
    [[ "$output" == *"SKIP  malcolm configure"*"labnet"* ]]
}

@test "INDEX_PATTERN reaches the dashboards step as --index-pattern; left empty, the child decides (and refuses)" {
    good_conf; echo 'INDEX_PATTERN=arkime_sessions3-*' >> "$CONF"
    run inst run --conf "$CONF" --yes --from dashboards --to dashboards
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qx 'malcolm dashboards --index-pattern arkime_sessions3-\*' "$STUB_LOG"
    grep -qx 'malcolm arkime-views' "$STUB_LOG"
    : > "$STUB_LOG"; good_conf
    run inst run --conf "$CONF" --yes --from dashboards --to dashboards
    grep -qx 'malcolm dashboards' "$STUB_LOG"
}
