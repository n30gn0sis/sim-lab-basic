#!/usr/bin/env bats
#
# The import script's value is REFUSAL at the right moments: it must gate on
# the verifier the bundle carries, refuse to write when a precondition is
# missing, undo an APT rewrite that reached upstream, and never call an
# incomplete image load a success. Every host tool is stubbed; every write
# lands in a fake root.

load helpers/fixtures
load helpers/stubs

setup() {
    kit_test_env
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-import-bundle.sh"
    BUNDLE="$BATS_TEST_TMPDIR/media/bundle-fixture"
    make_bundle "$BUNDLE"
    make_root "$ROOT"
    export FIXTURE_VERIFY_LOG="$BATS_TEST_TMPDIR/verify.log"
    # A healthy host: every LV is its own mount point, tools respond, docker
    # holds every tag the fixture lists.
    stub findmnt 'case "$1 $2" in "-n -o") echo "$5";; *) exit 1;; esac'
    stub docker 'echo "docker $*" >> "$STUB_LOG"
case "$1" in
  image) [ "$2" = ls ] && cat "$BATS_TEST_TMPDIR/present.txt" 2>/dev/null ;;
  info)  case "${3:-}" in *DockerRootDir*) echo /var/lib/docker;; *Mirrors*) echo "[]";; *Proxy*) echo;; *) echo 0.0.0-fixture;; esac ;;
esac
exit 0'
    stub_log apt-get; stub_log systemctl; stub_log mount; stub_log umount
    stub apt-cache 'echo "docker-ce: Candidate: fixture"'
    stub dpkg 'case "$*" in "-s snapd") exit 1;; *) exit 0;; esac'
    export BATS_TEST_TMPDIR
}

import() { kit_run "$SCRIPT" "$@"; }

# ── gate ────────────────────────────────────────────────────────────────────

@test "gate runs the verifier that travels IN the bundle, never a kit copy or a raw checksum" {
    run import gate --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q "^r770-bundle.sh verify $BUNDLE" "$FIXTURE_VERIFY_LOG"
    [[ "$output" != *"sha256sum -c"* ]]
    [[ "$output" == *"RESULT: PASS"* ]]
}

@test "gate refuses a bundle the verifier FAILS, and nothing is copied" {
    export FIXTURE_VERIFY_RC=1
    run import gate --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"do not import"* ]]
    [ ! -e "$ROOT/srv/bundles/bundle-fixture" ]
}

@test "gate with verifier warnings needs --yes when unattended, and passes them through when given" {
    export FIXTURE_VERIFY_RC=2
    unset KIT_YES
    run import gate --bundle "$BUNDLE" --non-interactive
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"non-interactive"* ]]
    run import gate --bundle "$BUNDLE" --non-interactive --yes
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"fixture warning"* ]]
}

@test "gate mounts a DISCOVERED device read-only when told to, and never picks one itself" {
    run import gate --bundle "$BUNDLE" --media "$BATS_TEST_TMPDIR/media" --device /dev/fixture0
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q '^mount -o ro /dev/fixture0' "$STUB_LOG"
    run import gate --bundle "$BUNDLE" --device /dev/fixture0
    [ "$status" -eq 1 ]
    [[ "$output" == *"--media"* ]]
}

# ── preflight ───────────────────────────────────────────────────────────────

@test "preflight FAILs naming every logical volume that is not its own mount point" {
    stub findmnt 'case "$*" in *"/data/index"*) echo /; exit 0;; *"/srv/work"*) echo /srv; exit 0;; -n\ -o\ TARGET\ -T\ *) echo "$5";; *) exit 1;; esac'
    run import preflight --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  /data/index is NOT a mount point"* ]]
    [[ "$output" == *"FAIL  /srv/work is NOT a mount point"* ]]
    [[ "$output" == *"PASS  /data/pcap is its own mount point"* ]]
}

@test "preflight warns, not fails, when there is no previous bundle to roll back to" {
    run import preflight --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"WARN  no previous bundle"* ]]
    mkdir -p "$ROOT/srv/bundles/bundle-older"
    run import preflight --bundle "$BUNDLE"
    [[ "$output" == *"PASS  previous bundle present"* ]]
}

# ── copy ────────────────────────────────────────────────────────────────────

@test "copy lands the bundle under /srv/bundles, verifies the COPY, stamps, and is idempotent" {
    run import copy --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [ -x "$ROOT/srv/bundles/bundle-fixture/r770-bundle.sh" ]
    grep -q "^r770-bundle.sh verify $ROOT/srv/bundles/bundle-fixture" "$FIXTURE_VERIFY_LOG"
    [ -f "$ROOT/srv/bundles/.kit-stamps/copied.bundle-fixture" ]
    run import copy --bundle "$BUNDLE"
    [[ "$output" == *"already copied"* ]]
}

# ── apt ─────────────────────────────────────────────────────────────────────

@test "apt shows current, proposed and rollback and refuses to write when unattended without --yes" {
    unset KIT_YES
    run import apt --bundle "$BUNDLE" --non-interactive
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"-- current --"*"archive.example"*"-- proposed --"*"file:/srv/repo/apt"*"-- rollback --"*"apt-sources-"* ]]
    [ ! -e "$ROOT/etc/apt/sources.list.d/r770-local.list" ]
    [ -s "$ROOT/etc/apt/sources.list" ]                       # untouched
}

@test "apt rewrites the sources to the local repo only and asserts apt-get update stayed on file:" {
    stub apt-get 'echo "apt-get $*" >> "$STUB_LOG"; echo "Ign:1 file:/srv/repo/apt ./ InRelease"; echo "Get:2 file:/srv/repo/apt ./ Packages [1 kB]"; echo "Reading package lists..."'
    run import apt --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(cat "$ROOT/etc/apt/sources.list.d/r770-local.list")" = 'deb [trusted=yes] file:/srv/repo/apt ./' ]
    [ ! -s "$ROOT/etc/apt/sources.list" ]
    [ -f "$ROOT/etc/apt/sources.list.d.upstream/ubuntu.list" ]
    [ -s "$ROOT/srv/repo/apt/Packages.gz" ]
    ls "$ROOT"/root/apt-sources-*.tar.gz
    [[ "$output" == *"PASS  apt-get update contacted only file:"* ]]
}

@test "apt regression: an upstream host surviving the rewrite FAILS and the old sources are restored" {
    stub apt-get 'echo "Hit:1 https://archive.ubuntu.com/ubuntu noble InRelease"; echo "Get:2 file:/srv/repo/apt ./ Packages"'
    run import apt --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"archive.ubuntu.com"* ]]
    [[ "$output" == *"restoring the previous sources"* ]]
    [ -f "$ROOT/etc/apt/sources.list.d/ubuntu.list" ]
}

@test "apt refuses a bundle whose flat-repo index is missing" {
    rm "$BUNDLE/apt/Packages.gz"
    run import apt --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Packages.gz"* ]]
}

# ── phone-home ──────────────────────────────────────────────────────────────

@test "phone-home disables the timers, purges snapd only when installed, and silences motd" {
    stub dpkg 'case "$*" in "-s snapd") exit 0;; *) exit 0;; esac'
    run import phone-home --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q '^systemctl disable --now unattended-upgrades.service' "$STUB_LOG"
    grep -q '^systemctl disable --now apt-daily.timer' "$STUB_LOG"
    grep -q '^apt-get purge -y snapd' "$STUB_LOG"
    grep -q '^ENABLED=0' "$ROOT/etc/default/motd-news"
    [ ! -x "$ROOT/etc/update-motd.d/50-motd-news" ]
}

# ── docker ──────────────────────────────────────────────────────────────────

@test "docker installs from the local repo and asserts the daemon's data root, mirrors and proxy" {
    run import docker --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q '^apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin' "$STUB_LOG"
    grep -q '^systemctl enable --now docker' "$STUB_LOG"
    [[ "$output" == *"PASS  docker data root is /var/lib/docker on its own mount"* ]]
}

@test "docker FAILs when the data root is not a mount point, or a registry mirror is configured" {
    stub findmnt 'echo /'
    run import docker --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a mount point"* ]]

    stub findmnt 'case "$*" in -n\ -o\ TARGET\ -T\ *) echo "$5";; esac'
    stub docker 'case "$*" in *Mirrors*) echo "[https://mirror.example]";; *DockerRootDir*) echo /var/lib/docker;; *) echo;; esac'
    run import docker --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"registry mirrors configured"* ]]
}

# ── files ───────────────────────────────────────────────────────────────────

@test "files routes payload into place: README skipped, signatures to checksums/, definitions without images WARN" {
    run import files --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [ -f "$ROOT/srv/vms/base/noble-server-cloudimg-amd64.img" ]
    [ -f "$ROOT/srv/gns3/appliances/vyos.gns3a" ]
    [ -f "$ROOT/srv/gns3/images/vyos-0.0.0-fixture-generic-amd64.iso" ]
    [ -f "$ROOT/srv/gns3/images/checksums/vyos-0.0.0-fixture-generic-amd64.iso.minisig" ]
    [ -f "$ROOT/srv/gns3/images/checksums/OPNsense-0.0.0-fixture-checksums-amd64.sha256" ]
    [ ! -e "$ROOT/srv/gns3/images/README.txt" ]
    [ -f "$ROOT/opt/enrichment/oui.txt" ]
    [ -f "$ROOT/opt/enrichment/rules/rules/emerging-fixture.rules" ]
    [ -f "$ROOT/srv/docs/gns3-docs/index.html" ]
    [ -f "$ROOT/srv/docs/malcolm/index.html" ]
    [[ "$output" != *"definition without image: vyos"* ]]
    [[ "$output" != *"definition without image: opnsense"* ]]
    echo '{"name": "IOSv"}' > "$BUNDLE/gns3/definitions/cisco-iosv.gns3a"
    run import files --bundle "$BUNDLE" --force
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"WARN  definition without image: cisco-iosv"* ]]
}

@test "files is dry-runnable: nothing lands outside the plan" {
    export KIT_DRY_RUN=1
    run import files --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN:"* ]]
    [ ! -e "$ROOT/srv/vms/base/noble-server-cloudimg-amd64.img" ]
}

@test "an unknown subcommand or option is rejected rather than ignored" {
    run import frobnicate --bundle "$BUNDLE"
    [ "$status" -eq 1 ]
    run import gate --bundle "$BUNDLE" --wat
    [ "$status" -eq 1 ]
}
