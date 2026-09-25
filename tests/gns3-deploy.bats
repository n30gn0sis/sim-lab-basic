#!/usr/bin/env bats
#
# GNS3 on the rehearsal failed for three reasons that had nothing to do with
# GNS3: a missing python3-venv, a root-owned state directory, and a server
# with no unit. Each is a refusal or an assertion here.

load helpers/fixtures
load helpers/stubs

setup() {
    kit_test_env
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-gns3-deploy.sh"
    BUNDLE="$BATS_TEST_TMPDIR/bundle-fixture"
    make_bundle "$BUNDLE"
    make_root "$ROOT"
    export ROOT GNS3_WAIT_SECS=1
    export BATS_TEST_TMPDIR
    export GNS3_LABNET_WAIT_SECS=1
    stub dpkg 'exit 0'
    # python3 -m venv <dir> "creates" a venv whose pip and gns3server are stubs that log argv
    stub python3 'echo "python3 $*" >> "$STUB_LOG"
if [ "$1" = -m ] && [ "$2" = venv ]; then
  mkdir -p "$3/bin"
  printf "#!/usr/bin/env bash\necho \"pip \$*\" >> \"$STUB_LOG\"\ntouch \"$3/bin/gns3server\"; chmod +x \"$3/bin/gns3server\"\n" > "$3/bin/pip"
  chmod +x "$3/bin/pip"
fi'
    stub getent 'case "$1 $2" in "passwd gns3") exit 1;; "group kvm") exit 0;; "group docker") exit 1;; *) exit 1;; esac'
    stub_log useradd; stub_log usermod; stub_log chown; stub_log systemctl
    stub ss 'echo "LISTEN 0 128 127.0.0.1:3080 0.0.0.0:*"'
    stub curl 'echo "{\"version\":\"fixture\"}"'
    unset PIP_INDEX_URL PIP_EXTRA_INDEX_URL
}

gns3() { kit_run "$SCRIPT" "$@"; }

stub_docker_reporting() {  # docker image ls reports these tags once `docker
    # load` "loads" them — or immediately, if the caller sets PRELOADED=1
    # first. cmd_load pre-checks image ls before loading, so most tests want
    # the tags absent until a real load happens; the assert-tags-only tests
    # want them present from the start.
    printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/would-be-present.txt"
    if [ "${PRELOADED:-0}" = "1" ]; then
        cp "$BATS_TEST_TMPDIR/would-be-present.txt" "$BATS_TEST_TMPDIR/present.txt"
    else
        : > "$BATS_TEST_TMPDIR/present.txt"
    fi
    stub docker 'echo "docker $*" >> "$STUB_LOG"
case "$1" in
  image) [ "$2" = ls ] && cat "$BATS_TEST_TMPDIR/present.txt" 2>/dev/null ;;
  load) cp "$BATS_TEST_TMPDIR/would-be-present.txt" "$BATS_TEST_TMPDIR/present.txt" ;;
esac
exit 0'
}

# stub_import_bundle — a fake r770-import-bundle.sh that records "<subcommand>
# <argv...>" to $IMPORT_LOG and exits per IMPORT_RC_<SUBCOMMAND> (default 0),
# the same shape as make_bundle's r770-bundle.sh stub. Exercises the
# IMPORT_BUNDLE_CMD test seam `full` uses for its shared steps.
stub_import_bundle() {
    cat > "$BATS_TEST_TMPDIR/import-bundle-stub.sh" <<'STUB'
#!/usr/bin/env bash
echo "import-bundle $*" >> "$IMPORT_LOG"
sub="$1"
var="IMPORT_RC_$(printf '%s' "$sub" | tr 'a-z-' 'A-Z_')"
exit "${!var:-0}"
STUB
    chmod +x "$BATS_TEST_TMPDIR/import-bundle-stub.sh"
    export IMPORT_BUNDLE_CMD="$BATS_TEST_TMPDIR/import-bundle-stub.sh"
    export IMPORT_LOG="$BATS_TEST_TMPDIR/import-bundle.log"
    : > "$IMPORT_LOG"
}

# ── load / assert-tags — this script's own images, no longer shared ─────────

@test "assert-tags passes when every listed tag is present" {
    PRELOADED=1 stub_docker_reporting docker.io/library/alpine:latest quay.io/frrouting/frr:0.0.0-fixture
    run gns3 assert-tags --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"all images present"* ]]
}

@test "assert-tags FAILS when a tag is missing, and names it" {
    PRELOADED=1 stub_docker_reporting docker.io/library/alpine:latest
    run gns3 assert-tags --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"frrouting/frr:0.0.0-fixture"* ]]
}

@test "load runs docker load on the bundle's tarball and then asserts the tags, and is idempotent" {
    stub_docker_reporting docker.io/library/alpine:latest quay.io/frrouting/frr:0.0.0-fixture
    run gns3 load --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q "^docker load -i $BUNDLE/gns3/docker-nodes/gns3-node-images.tar.gz" "$STUB_LOG"
    # a second load: the images are present now that the first load "landed"
    # them in the stub, so the pre-check skips the reload entirely
    : > "$STUB_LOG"
    run gns3 load --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    ! grep -q '^docker load' "$STUB_LOG"
    [[ "$output" == *"load skipped"* ]]
}

@test "load skips docker load when every tag is already present" {
    PRELOADED=1 stub_docker_reporting docker.io/library/alpine:latest quay.io/frrouting/frr:0.0.0-fixture
    run gns3 load --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    ! grep -q '^docker load' "$STUB_LOG"
    [[ "$output" == *"load skipped"* ]]
}

@test "load refuses when docker is not installed" {
    unstub docker
    run gns3 load --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"docker is not installed"* ]]
}

# ── full ──────────────────────────────────────────────────────────────────

@test "full runs preflight through labnet in order: r770-import-bundle.sh for the shared steps, this script's own subcommands after" {
    stub_import_bundle
    stub_docker_reporting docker.io/library/alpine:latest quay.io/frrouting/frr:0.0.0-fixture
    # the service user exists once config's useradd has run, as on a real box
    stub useradd 'echo "useradd $*" >> "$STUB_LOG"; touch "$BATS_TEST_TMPDIR/gns3-user"'
    stub getent 'case "$1 $2" in "passwd gns3") [ -e "$BATS_TEST_TMPDIR/gns3-user" ];; "group kvm") exit 0;; "group docker") exit 0;; *) exit 1;; esac'
    stub_labnet_host
    run gns3 full --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(awk '{print $2}' "$IMPORT_LOG" | paste -sd' ')" = "preflight gate copy apt phone-home docker files" ]
    grep -q "^import-bundle preflight --bundle $BUNDLE\$" "$IMPORT_LOG"
    grep -q "^import-bundle gate --bundle $BUNDLE\$" "$IMPORT_LOG"
    grep -q "^import-bundle copy --bundle $BUNDLE\$" "$IMPORT_LOG"
    grep -q "^docker load -i $BUNDLE/gns3/docker-nodes/gns3-node-images.tar.gz" "$STUB_LOG"
    grep -q '^useradd --system' "$STUB_LOG"
    s=$(grep -n '^systemctl enable --now gns3' "$STUB_LOG" | cut -d: -f1)
    r=$(grep -n '^networkctl reload' "$STUB_LOG" | cut -d: -f1)
    [ -n "$s" ] && [ -n "$r" ] && [ "$s" -lt "$r" ]
    [[ "$output" == *"DEPLOYED — every step clean"* ]]
}

@test "full with --media/--device passes them to the gate step only, and --media alone to copy" {
    stub_import_bundle
    run gns3 full --bundle "$BUNDLE" --media /mnt/usb --device /dev/fixture0 --only gate
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q "^import-bundle gate --bundle $BUNDLE --media /mnt/usb --device /dev/fixture0\$" "$IMPORT_LOG"

    : > "$IMPORT_LOG"
    run gns3 full --bundle "$BUNDLE" --media /mnt/usb --only copy
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q "^import-bundle copy --bundle $BUNDLE --media /mnt/usb\$" "$IMPORT_LOG"
}

@test "full --only slices to exactly one step" {
    stub_import_bundle
    stub_docker_reporting docker.io/library/alpine:latest quay.io/frrouting/frr:0.0.0-fixture
    run gns3 full --bundle "$BUNDLE" --only load
    echo "$output"
    [ "$status" -eq 0 ]
    [ ! -s "$IMPORT_LOG" ]
    grep -q '^docker load' "$STUB_LOG"
    ! grep -q '^useradd' "$STUB_LOG"
    [[ "$output" == *"DEPLOYED — every step clean"* ]]
}

@test "full --from/--to slices to a contiguous range of steps" {
    stub_import_bundle
    run gns3 full --bundle "$BUNDLE" --from apt --to files
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(awk '{print $2}' "$IMPORT_LOG" | paste -sd' ')" = "apt phone-home docker files" ]
    ! grep -q '^docker load' "$STUB_LOG"
    ! grep -q '^useradd' "$STUB_LOG"
}

@test "full refuses when --from comes after --to, and names both" {
    run gns3 full --bundle "$BUNDLE" --from config --to apt
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"--from config"* ]]
    [[ "$output" == *"--to apt"* ]]
}

@test "full refuses naming an unknown --from/--to step" {
    run gns3 full --bundle "$BUNDLE" --from bogus
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown step: bogus"* ]]
}

@test "full stops after a step that warns without --yes, and finishes exit 2 once the warning is accepted" {
    stub_import_bundle
    export IMPORT_RC_APT=2
    unset KIT_YES
    run gns3 full --bundle "$BUNDLE" --only apt
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"warned and this run is non-interactive"* ]]

    export KIT_YES=1
    : > "$IMPORT_LOG"
    run gns3 full --bundle "$BUNDLE" --only apt
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"accepted via --yes"* ]]
    [[ "$output" == *"DEPLOYED WITH WARNINGS"* ]]
    [[ "$output" == *"steps: apt"* ]]
}

@test "venv refuses when python3-venv is absent, naming it and the apt stage" {
    stub dpkg 'case "$*" in *python3-venv*) exit 1;; *) exit 0;; esac'
    run gns3 venv --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"python3-venv"* ]]
    [[ "$output" == *"apt"* ]]
    ! grep -q '^python3 -m venv' "$STUB_LOG"
}

@test "venv installs from the wheelhouse with --no-index and no URL" {
    run gns3 venv --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q "^python3 -m venv $ROOT/opt/gns3" "$STUB_LOG"
    grep -q "^pip install --no-index --find-links $BUNDLE/gns3/wheelhouse gns3-server" "$STUB_LOG"
    ! grep -qE 'https?://' "$STUB_LOG"
    run gns3 venv --bundle "$BUNDLE"
    [[ "$output" == *"already holds gns3server"* ]]
}

@test "venv refuses to run while a pip index is configured in the environment" {
    export PIP_INDEX_URL="https://pypi.example/simple"
    run gns3 venv --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"PIP_INDEX_URL"* ]]
    ! grep -q '^pip' "$STUB_LOG"
}

@test "venv refuses a bundle with an empty wheelhouse" {
    rm "$BUNDLE"/gns3/wheelhouse/*.whl
    run gns3 venv --bundle "$BUNDLE"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no wheels"* ]]
}

@test "config creates the service user, renders the config without leftover tokens, and chowns the state dir (the rehearsal regression)" {
    gns3 secrets >/dev/null
    pw=$(head -1 "$ROOT/etc/lab/secrets/gns3-admin.pw")
    run gns3 config
    echo "$output"
    [ "$status" -eq 2 ]                                  # docker group absent -> WARN
    grep -q '^useradd --system --home-dir /etc/gns3 --no-create-home --shell /usr/sbin/nologin gns3' "$STUB_LOG"
    grep -q '^usermod -aG kvm gns3' "$STUB_LOG"
    [[ "$output" == *"WARN  group docker does not exist"* ]]
    c="$ROOT/etc/gns3/gns3_server.conf"
    [ "$(stat -c %a "$c")" = "600" ]
    ! grep -q '__' "$c"
    ! grep -q 'jwt_secret_key' "$c"
    grep -q "^default_admin_password = $pw$" "$c"
    grep -q "^chown -R gns3:gns3 $ROOT/etc/gns3" "$STUB_LOG"
    grep -q "^chown gns3:gns3 $ROOT/srv/gns3/projects" "$STUB_LOG"
    [[ "$output" != *"$pw"* ]]
}

@test "config refuses before the secret exists" {
    run gns3 config
    [ "$status" -eq 1 ]
    [[ "$output" == *"secrets"* ]]
}

@test "service is gated: unattended without --yes writes no unit" {
    gns3 secrets >/dev/null; gns3 venv --bundle "$BUNDLE" >/dev/null; gns3 config >/dev/null || true
    unset KIT_YES
    run gns3 service --non-interactive
    echo "$output"
    [ "$status" -eq 1 ]
    [ ! -e "$ROOT/etc/systemd/system/gns3.service" ]
    ! grep -q '^systemctl enable' "$STUB_LOG"
}

@test "service installs the unit, enables it, and asserts 127.0.0.1:3080" {
    gns3 secrets >/dev/null; gns3 venv --bundle "$BUNDLE" >/dev/null; gns3 config >/dev/null || true
    run gns3 service
    echo "$output"
    [ "$status" -eq 0 ]
    cmp -s "$ROOT/etc/systemd/system/gns3.service" "$BATS_TEST_DIRNAME/../config/systemd/gns3.service"
    grep -q '^systemctl daemon-reload' "$STUB_LOG"
    grep -q '^systemctl enable --now gns3' "$STUB_LOG"
    [[ "$output" == *"PASS  gns3server listening on 127.0.0.1:3080"* ]]
}

@test "service FAILs when the server listens on all interfaces" {
    gns3 secrets >/dev/null; gns3 venv --bundle "$BUNDLE" >/dev/null; gns3 config >/dev/null || true
    stub ss 'echo "LISTEN 0 128 0.0.0.0:3080 0.0.0.0:*"'
    run gns3 service
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"listens on all interfaces"* ]]
}

# ── labnet — the mirrored lab bridge ───────────────────────────────────────

NETD_DIR() { echo "$ROOT/etc/systemd/network"; }

# sys_after_reload [ageing_time] [physical-port] [mirror-flags] — what a
# networkctl reload leaves in sysfs, written by the networkctl stub under
# $ROOT. Defaults are the correct state: hub mode, no physical port, mirror
# end up and promiscuous (IFF_PROMISC = 0x100).
sys_after_reload() {
    cat > "$BATS_TEST_TMPDIR/on-reload" <<EOF
#!/usr/bin/env bash
s="$ROOT/sys/class/net"
mkdir -p "\$s/br-lab/bridge" "\$s/br-lab/brif" "\$s/lab-mirror0" "\$s/lab-mon0"
echo "${1:-0}" > "\$s/br-lab/bridge/ageing_time"
for i in 0 1 2 3; do mkdir -p "\$s/lab-tap\$i"; touch "\$s/br-lab/brif/lab-tap\$i"; done
touch "\$s/br-lab/brif/lab-mon0"
echo up > "\$s/lab-mirror0/operstate"
echo "${3:-0x1103}" > "\$s/lab-mirror0/flags"
if [ -n "${2:-}" ]; then mkdir -p "\$s/${2:-}/device"; touch "\$s/br-lab/brif/${2:-}"; fi
EOF
    chmod +x "$BATS_TEST_TMPDIR/on-reload"
}

# stub_labnet_host — networkd active, the service user present, networkctl
# reload "creates" the interfaces, and ip reports an address on lab-mirror0
# only when MIRROR_ADDR is set.
stub_labnet_host() {
    stub systemctl 'echo "systemctl $*" >> "$STUB_LOG"; [ "$*" = "is-active systemd-networkd" ] && echo active; exit 0'
    stub networkctl 'echo "networkctl $*" >> "$STUB_LOG"; [ "$1" = reload ] && [ -x "$BATS_TEST_TMPDIR/on-reload" ] && "$BATS_TEST_TMPDIR/on-reload"; exit 0'
    stub ip 'case "$*" in *"addr show dev lab-mirror0"*) [ -n "${MIRROR_ADDR:-}" ] && echo "9: lab-mirror0    inet6 fe80::1/64 scope link";; esac; exit 0'
    [ -e "$BATS_TEST_TMPDIR/on-reload" ] || sys_after_reload
}
labnet_user() { stub getent 'case "$1 $2" in "passwd gns3") exit 0;; *) exit 1;; esac'; }

@test "labnet is gated: unattended without --yes writes no file and reloads nothing" {
    stub_labnet_host; labnet_user
    unset KIT_YES
    run gns3 labnet
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"needs a decision"* ]]
    [[ "$output" == *"-- rollback --"* ]]
    [ -z "$(find "$(NETD_DIR)" -name '05-*' 2>/dev/null)" ]
    ! grep -q '^networkctl' "$STUB_LOG"
}

@test "labnet installs a hub-mode bridge, owned TAPs and a silent mirror end, then proves them" {
    stub_labnet_host; labnet_user
    run gns3 labnet
    echo "$output"
    [ "$status" -eq 0 ]
    d=$(NETD_DIR)
    grep -qx 'AgeingTimeSec=0' "$d/05-br-lab.netdev"
    for i in 0 1 2 3; do
        grep -qx "Name=lab-tap$i" "$d/05-lab-tap$i.netdev"
        grep -qx 'User=gns3' "$d/05-lab-tap$i.netdev"
        grep -qx 'Bridge=br-lab' "$d/05-lab-tap$i.network"
    done
    [ ! -e "$d/05-lab-tap4.netdev" ]
    grep -qx 'Bridge=br-lab' "$d/05-lab-mon0.network"
    grep -qx 'Name=lab-mirror0' "$d/05-lab-mirror.netdev"
    for k in 'LinkLocalAddressing=no' 'IPv6AcceptRA=no' 'ARP=no' 'Promiscuous=yes'; do grep -qx "$k" "$d/05-lab-mirror0.network"; done
    ! grep -rq '^Address=' "$d"
    ! grep -rq '__[A-Z_]*__' "$d"
    grep -q '^networkctl reload' "$STUB_LOG"
    [[ "$output" == *"PASS  br-lab is in hub mode"* ]]
    [[ "$output" == *"PASS  lab-mon0 and 4 TAP(s) are ports of br-lab"* ]]
    [[ "$output" == *"PASS  br-lab has no physical port"* ]]
    [[ "$output" == *"PASS  lab-mirror0 is up and promiscuous"* ]]
    [[ "$output" == *"PASS  lab-mirror0 carries no address"* ]]
}

@test "labnet honours GNS3_LAB_TAPS" {
    stub_labnet_host; labnet_user
    GNS3_LAB_TAPS=2 run gns3 labnet
    echo "$output"
    d=$(NETD_DIR)
    [ -e "$d/05-lab-tap1.netdev" ]
    [ ! -e "$d/05-lab-tap2.netdev" ]
}

@test "labnet refuses when systemd-networkd is not active, and writes nothing" {
    stub_labnet_host; labnet_user
    stub systemctl 'echo inactive; exit 3'
    run gns3 labnet
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"systemd-networkd is not active"* ]]
    [ -z "$(find "$(NETD_DIR)" -name '05-*' 2>/dev/null)" ]
}

@test "labnet refuses before the GNS3 service user exists, naming config" {
    stub_labnet_host
    run gns3 labnet
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"service user gns3 does not exist"* ]]
    [[ "$output" == *"run config first"* ]]
}

@test "labnet refuses a kit interface name that something else already owns" {
    stub_labnet_host; labnet_user
    mkdir -p "$ROOT/sys/class/net/br-lab"
    run gns3 labnet
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"interface br-lab already exists"* ]]
    [ -z "$(find "$(NETD_DIR)" -name '05-*' 2>/dev/null)" ]
}

@test "labnet is idempotent: a second run finds the files in place and skips the gate" {
    stub_labnet_host; labnet_user
    run gns3 labnet
    [ "$status" -eq 0 ]
    : > "$STUB_LOG"
    unset KIT_YES
    run gns3 labnet
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already in place"* ]]
    [[ "$output" != *"== GATE"* ]]
    ! grep -q '^networkctl reload' "$STUB_LOG"
}

@test "labnet FAILs when the bridge is not in hub mode" {
    stub_labnet_host; labnet_user; sys_after_reload 30000
    run gns3 labnet
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  br-lab ageing_time is 30000"* ]]
}

@test "labnet FAILs when a physical interface has joined br-lab (rule 8)" {
    stub_labnet_host; labnet_user; sys_after_reload 0 eno1
    run gns3 labnet
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  physical interface(s) on br-lab: eno1"* ]]
}

@test "labnet FAILs when the mirror end carries an address or is not promiscuous" {
    stub_labnet_host; labnet_user; sys_after_reload 0 "" 0x1003
    MIRROR_ADDR=1 run gns3 labnet
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  lab-mirror0 has 1 address(es)"* ]]
    [[ "$output" == *"FAIL  lab-mirror0 is not up and promiscuous"* ]]
}

@test "labnet --dry-run prints the files and writes nothing" {
    stub_labnet_host; labnet_user
    run gns3 labnet --dry-run
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"== 05-br-lab.netdev"* ]]
    [[ "$output" == *"DRY-RUN: networkctl reload"* ]]
    [ -z "$(find "$(NETD_DIR)" -name '05-*' 2>/dev/null)" ]
}
