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
