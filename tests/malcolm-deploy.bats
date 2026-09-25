#!/usr/bin/env bats
#
# Malcolm is the stack the staging rehearsal burned the most time on. Every
# trap it hit is a refusal here, and every refusal is a test: the installer's
# and auth_setup's interfaces are asserted before use, the port rebind is an
# assert-then-edit that is idempotent and refuses drift, secrets never reach
# the transcript, and start goes through Malcolm's own script.

load helpers/fixtures
load helpers/stubs

setup() {
    kit_test_env
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-malcolm-deploy.sh"
    BUNDLE="$BATS_TEST_TMPDIR/bundle-fixture"
    make_bundle "$BUNDLE"
    make_root "$ROOT"
    export MALCOLM_STUB_LOG="$BATS_TEST_TMPDIR/malcolm-stub.log"
    export MALCOLM_WAIT_SECS=1
    export BATS_TEST_TMPDIR
    stub dpkg 'exit 0'
    stub python3 'exec bash "$@"'          # the stub installer is bash; the real one is python
    # the stack's owner: PUID 1000 in the fixture's config/process.env, in the docker group
    stub getent 'case "$1 $2" in "passwd 1000") echo "labop:x:1000:1000::/home/labop:/bin/bash";; "group docker") echo "docker:x:988:labop";; *) exit 2;; esac'
    stub runuser 'echo "runuser $*" >> "$STUB_LOG"; [ "$1" = -u ] && shift 2; [ "$1" = -- ] && shift; exec "$@"'
    stub free 'echo "               total        used        free"; echo "Mem:             128           4         124"'
    stub_log unzip
    stub_log chown
    stub ss 'echo "LISTEN 0 4096 127.0.0.1:8443 0.0.0.0:*"'
    stub docker 'echo "docker $*" >> "$STUB_LOG"
case "$1" in
  image) [ "$2" = ls ] && cat "$BATS_TEST_TMPDIR/present.txt" 2>/dev/null ;;
  run)   echo "analyst:\$2y\$10\$fixturehash" ;;
  compose) [ "$2" = ps ] && printf "arkime running healthy\nzeek running healthy\nnginx-proxy running healthy\n" ;;
esac
exit 0'
}

malcolm() { kit_run "$SCRIPT" "$@"; }
stub_docker_reporting() {  # the build repo's helper: docker image ls prints the given tags
    printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/present.txt"
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

# ── load / assert-tags — ported from the build repo's suite ─────────────────

@test "assert-tags passes when every listed tag is present" {
    stub_docker_reporting ghcr.io/idaholab/malcolm/arkime:0.0.0-fixture ghcr.io/idaholab/malcolm/nginx-proxy:0.0.0-fixture
    run malcolm assert-tags --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"all images present"* ]]
}

@test "assert-tags FAILS when a tag is missing, and names it" {
    stub_docker_reporting ghcr.io/idaholab/malcolm/arkime:0.0.0-fixture
    run malcolm assert-tags --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"nginx-proxy:0.0.0-fixture"* ]]
}

@test "load runs docker load on the bundle's tarball and then asserts the tags" {
    stub_docker_reporting ghcr.io/idaholab/malcolm/arkime:0.0.0-fixture ghcr.io/idaholab/malcolm/nginx-proxy:0.0.0-fixture
    run malcolm load --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q "^docker load -i $BUNDLE/malcolm/malcolm-images-0.0.0-fixture.tar.gz" "$STUB_LOG"
}

@test "a missing image list never reports success (the subshell regression)" {
    rm "$BUNDLE/malcolm/image-list.txt"
    run malcolm assert-tags --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" != *"all images present"* ]]
}

@test "a list holding only comments is refused, not treated as 'nothing to check'" {
    printf '# nothing here\n\n' > "$BUNDLE/malcolm/image-list.txt"
    run malcolm assert-tags --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" != *"all images present"* ]]
}

@test "a bare bundle path still works, as the build repo's script took it" {
    stub_docker_reporting ghcr.io/idaholab/malcolm/arkime:0.0.0-fixture ghcr.io/idaholab/malcolm/nginx-proxy:0.0.0-fixture
    run malcolm assert-tags "$BUNDLE"
    [ "$status" -eq 0 ]
}

@test "a non-bundle directory is refused by name" {
    run malcolm assert-tags --bundle "$BATS_TEST_TMPDIR"
    echo "$output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"is not a bundle"* ]]
}

# ── unpack / configure ──────────────────────────────────────────────────────

@test "unpack refuses when the installer's python deps are not installed, naming them" {
    stub dpkg 'case "$*" in *ruamel*) exit 1;; *) exit 0;; esac'
    run malcolm unpack --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"python3-ruamel.yaml"* ]]
    ! grep -q '^unzip' "$STUB_LOG"
}

@test "unpack unzips the one bundled installer into /opt/malcolm and is idempotent" {
    # the real docker_install.zip (measured on staging VM 9770, 2026-09-25) puts
    # install.py at its root, beside the stack tarball -- not under scripts/
    stub unzip 'echo "unzip $*" >> "$STUB_LOG"; mkdir -p "$ROOT/opt/malcolm"; touch "$ROOT/opt/malcolm/install.py" "$ROOT/opt/malcolm/malcolm_fixture.tar.gz"'
    export ROOT
    run malcolm unpack --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q "^unzip -o -q $BUNDLE/malcolm/malcolm-0.0.0-fixture-docker_install.zip -d $ROOT/opt/malcolm" "$STUB_LOG"
    run malcolm unpack --bundle "$BUNDLE"
    [[ "$output" == *"already unpacked"* ]]
}

@test "configure renders the template with host-derived values and replays it through the installer" {
    make_malcolm_tree "$ROOT"
    run malcolm configure --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q -- "--import-malcolm-config-file $ROOT/opt/malcolm/malcolm-config.rendered.json" "$MALCOLM_STUB_LOG"
    grep -q -- '--non-interactive' "$MALCOLM_STUB_LOG"
    # the installer finds its stack tarball in its working directory, so the
    # kit must run it from /opt/malcolm (measured on staging VM 9770, 2026-09-25)
    grep -qx "install.py cwd $ROOT/opt/malcolm" "$MALCOLM_STUB_LOG"
    r="$ROOT/opt/malcolm/malcolm-config.rendered.json"
    ! grep -q '__[A-Z_]*__' "$r"
    grep -q '"osMemory": "24g"' "$r"                # 128 GB host -> 24g (buildout §8)
    grep -q '"lsMemory": "4096m"' "$r"
    grep -q "\"pcapNodeName\": \"$(hostname -s)\"" "$r"
    grep -q '"version": "0.0.0-fixture"' "$r"        # from the fixture zip's name
    grep -q '"arkimeManagePCAP": false' "$r"
    grep -q '"pcapDir": "/data/pcap/raw"' "$r"
    grep -q '^chown 1000:1000 ' "$STUB_LOG"
    [[ "$output" == *"0.0.0.0:443 -> 127.0.0.1:8443"* ]]
}

@test "configure caps the OpenSearch heap at 31g on a very large host and honours --arkime-free-space-g" {
    make_malcolm_tree "$ROOT"
    stub free 'echo "Mem: 512 4 500"'
    run malcolm configure --bundle "$BUNDLE" --arkime-free-space-g 200
    echo "$output"
    [ "$status" -eq 0 ]
    r="$ROOT/opt/malcolm/malcolm-config.rendered.json"
    grep -q '"osMemory": "31g"' "$r"
    grep -q '"arkimeManagePCAP": true' "$r"
    grep -q '"arkimeFreeSpaceG": "200"' "$r"
}

@test "configure refuses when the bundled installer no longer advertises a flag the kit relies on" {
    make_malcolm_tree "$ROOT"
    cat > "$ROOT/opt/malcolm/install.py" <<'STUB'
#!/usr/bin/env bash
echo "install.py $*" >> "$MALCOLM_STUB_LOG"
case " $* " in *" --help "*) echo "usage: install.py [--non-interactive] [--configure] [--skip-splash]"; exit 0;; esac
STUB
    run malcolm configure --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"--import-malcolm-config-file"* ]]
    [[ "$output" == *"BUNDLE_NOTES.md"* ]]
    ! grep -q -- '--configure' "$MALCOLM_STUB_LOG"
}

@test "configure without --capture-ifs keeps live capture off, exactly as before" {
    make_malcolm_tree "$ROOT"
    run malcolm configure --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    r="$ROOT/opt/malcolm/malcolm-config.rendered.json"
    grep -q '"pcapIface": \[\],' "$r"
    grep -q '"captureLiveNetworkTraffic": false,' "$r"
    grep -q '"liveArkime": false,' "$r"
    grep -q '"liveZeek": false,' "$r"
    grep -q '"liveSuricata": false,' "$r"
    grep -q '"tweakIface": false,' "$r"
}

@test "configure --capture-ifs turns on live Arkime and Zeek on exactly those interfaces" {
    make_malcolm_tree "$ROOT"
    mkdir -p "$ROOT/sys/class/net/lab-mirror0"
    stub ip 'exit 0'
    run malcolm configure --bundle "$BUNDLE" --capture-ifs lab-mirror0
    echo "$output"
    [ "$status" -eq 0 ]
    r="$ROOT/opt/malcolm/malcolm-config.rendered.json"
    grep -q '"pcapIface": \["lab-mirror0"\],' "$r"
    grep -q '"captureLiveNetworkTraffic": true,' "$r"
    grep -q '"liveArkime": true,' "$r"
    grep -q '"liveZeek": true,' "$r"
    grep -q '"liveSuricata": false,' "$r"
    grep -q '"tweakIface": false,' "$r"
    [[ "$output" == *"live capture on: lab-mirror0"* ]]
}

@test "configure --capture-ifs renders several interfaces as one JSON list" {
    make_malcolm_tree "$ROOT"
    mkdir -p "$ROOT/sys/class/net/lab-mirror0" "$ROOT/sys/class/net/cap0"
    stub ip 'exit 0'
    run malcolm configure --bundle "$BUNDLE" --capture-ifs "lab-mirror0 cap0"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q '"pcapIface": \["lab-mirror0", "cap0"\],' "$ROOT/opt/malcolm/malcolm-config.rendered.json"
}

@test "configure --capture-ifs proves the installer kept every live key in its exported config (F5)" {
    make_malcolm_tree "$ROOT"
    mkdir -p "$ROOT/sys/class/net/lab-mirror0" "$ROOT/sys/class/net/cap0"
    stub ip 'exit 0'
    run malcolm configure --bundle "$BUNDLE" --capture-ifs "lab-mirror0 cap0"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  the installer kept live capture on lab-mirror0 cap0 (Zeek live; Arkime via liveArkime)"* ]]
}

@test "configure accepts Arkime capture through netsniff when the installer turns liveArkime off (measured on staging)" {
    make_malcolm_tree "$ROOT"
    mkdir -p "$ROOT/sys/class/net/lab-mirror0"
    stub ip 'exit 0'
    MALCOLM_STUB_EXPORT_SED='s/"liveArkime": true/"liveArkime": false/; s/"pcapNetSniff": false/"pcapNetSniff": true/' \
        run malcolm configure --bundle "$BUNDLE" --capture-ifs lab-mirror0
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  the installer kept live capture on lab-mirror0 (Zeek live; Arkime via pcapNetSniff)"* ]]
}

@test "configure FAILs when the installer kept no capture path into Arkime" {
    make_malcolm_tree "$ROOT"
    mkdir -p "$ROOT/sys/class/net/lab-mirror0"
    stub ip 'exit 0'
    MALCOLM_STUB_EXPORT_SED='s/"liveArkime": true/"liveArkime": false/' \
        run malcolm configure --bundle "$BUNDLE" --capture-ifs lab-mirror0
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  the installer kept no capture path into Arkime (liveArkime, pcapNetSniff, pcapTcpDump all off)"* ]]
}

@test "configure reconfigures an extracted stack with the stack's own installer, from inside the stack" {
    make_malcolm_tree "$ROOT"
    # once the stack is extracted, the zip-root installer refuses ("already
    # exists"); the stack carries scripts/install.py to reconfigure itself
    cp "$ROOT/opt/malcolm/install.py" "$ROOT/opt/malcolm/malcolm/scripts/install.py"
    run malcolm configure --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -qx "install.py cwd $ROOT/opt/malcolm/malcolm" "$MALCOLM_STUB_LOG"
    ! grep -qx "install.py cwd $ROOT/opt/malcolm" "$MALCOLM_STUB_LOG"
    [[ "$output" == *"reconfiguring the extracted stack with its own installer"* ]]
}

@test "configure --capture-ifs FAILs, naming the key, when the installer's export dropped liveZeek (F5)" {
    make_malcolm_tree "$ROOT"
    mkdir -p "$ROOT/sys/class/net/lab-mirror0"
    stub ip 'exit 0'
    MALCOLM_STUB_EXPORT_DROP=liveZeek run malcolm configure --bundle "$BUNDLE" --capture-ifs lab-mirror0
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  the installer did not keep \"liveZeek\": true — live capture will not start; read $ROOT/opt/malcolm/malcolm-config.exported.json"* ]]
    [[ "$output" != *"did not keep \"liveArkime\""* ]]
}

@test "status reads live capture from the installer's export, and labels a rendered-only config unconfirmed (F5)" {
    make_malcolm_tree "$ROOT"
    mkdir -p "$ROOT/sys/class/net/lab-mirror0"
    stub ip 'exit 0'
    run malcolm configure --bundle "$BUNDLE" --capture-ifs lab-mirror0
    [ "$status" -eq 0 ]
    run malcolm status
    echo "$output"
    [[ "$output" == *'live capture'*'on ["lab-mirror0"]'* ]]
    [[ "$output" != *"not yet confirmed"* ]]
    rm -f "$ROOT/opt/malcolm/malcolm-config.exported.json"
    run malcolm status
    echo "$output"
    [[ "$output" == *'on ["lab-mirror0"] (rendered, not yet confirmed)'* ]]
}

@test "configure refuses a capture interface that does not exist, pointing a lab-* name at labnet" {
    make_malcolm_tree "$ROOT"
    run malcolm configure --bundle "$BUNDLE" --capture-ifs lab-mirror0
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"capture interface lab-mirror0 does not exist"* ]]
    [[ "$output" == *"r770-gns3-deploy.sh labnet"* ]]
    ! grep -q -- '--configure' "$MALCOLM_STUB_LOG"
}

@test "configure refuses a capture interface that carries an address (rule 8)" {
    make_malcolm_tree "$ROOT"
    mkdir -p "$ROOT/sys/class/net/cap0"
    stub ip 'case "$*" in *"addr show dev cap0"*) echo "3: cap0    inet 10.0.0.9/24 scope global cap0";; esac; exit 0'
    run malcolm configure --bundle "$BUNDLE" --capture-ifs cap0
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"capture interface cap0 carries an address"* ]]
    ! grep -q -- '--configure' "$MALCOLM_STUB_LOG"
}

@test "configure refuses a repeated, empty or malformed --capture-ifs" {
    make_malcolm_tree "$ROOT"
    mkdir -p "$ROOT/sys/class/net/lab-mirror0"
    stub ip 'exit 0'
    run malcolm configure --bundle "$BUNDLE" --capture-ifs "lab-mirror0 lab-mirror0"
    [ "$status" -eq 1 ]
    [[ "$output" == *"names lab-mirror0 twice"* ]]
    run malcolm configure --bundle "$BUNDLE" --capture-ifs ""
    [ "$status" -eq 1 ]
    [[ "$output" == *"names no interface"* ]]
    run malcolm configure --bundle "$BUNDLE" --capture-ifs 'bad"name'
    [ "$status" -eq 1 ]
    [[ "$output" == *"not an interface name"* ]]
    ! grep -q -- '--configure' "$MALCOLM_STUB_LOG"
}

# ── rebind ──────────────────────────────────────────────────────────────────

@test "rebind rewrites exactly one publish line and is idempotent" {
    make_malcolm_tree "$ROOT"
    run malcolm rebind
    echo "$output"
    [ "$status" -eq 0 ]
    c="$ROOT/opt/malcolm/malcolm/docker-compose.yml"
    [ "$(grep -c '    - 127.0.0.1:8443:443/tcp' "$c")" -eq 1 ]
    ! grep -q '0.0.0.0:443:443' "$c"
    run malcolm rebind
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already bound"* ]]
}

@test "rebind refuses a compose file whose format moved, and leaves it untouched" {
    make_malcolm_tree "$ROOT"
    c="$ROOT/opt/malcolm/malcolm/docker-compose.yml"
    sed -i 's|    - 0.0.0.0:443:443/tcp|    - "443:443"|' "$c"
    before=$(sha256sum "$c")
    run malcolm rebind
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"format is not the one this edit was written for"* ]]
    [ "$(sha256sum "$c")" = "$before" ]
}

# ── secrets / auth ──────────────────────────────────────────────────────────

@test "auth refuses when auth_setup no longer advertises a flag, and never invokes it" {
    make_malcolm_tree "$ROOT"
    malcolm secrets >/dev/null
    export MALCOLM_STUB_AUTH_FLAGS="auth-noninteractive auth-method auth-admin-username"
    run malcolm auth --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"--auth-generate-keycloak-db-password"* ]]
    ! grep -q '^auth_setup --auth-noninteractive' "$MALCOLM_STUB_LOG"
}

@test "auth derives the nginx-proxy image from the bundle's list and never prints the password" {
    make_malcolm_tree "$ROOT"
    malcolm secrets >/dev/null
    pw=$(head -1 "$ROOT/etc/lab/secrets/malcolm-admin.pw")
    run malcolm auth --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q 'docker run --rm --network none -e PW=.* --entrypoint sh ghcr.io/idaholab/malcolm/nginx-proxy:0.0.0-fixture' "$STUB_LOG"
    grep -q '^auth_setup --auth-noninteractive --auth-method basic --auth-admin-username analyst' "$MALCOLM_STUB_LOG"
    [[ "$output" != *"$pw"* ]]
    [ -s "$ROOT/opt/malcolm/malcolm/nginx/htpasswd" ]
}

@test "auth dies when the bundle's list carries no nginx-proxy image" {
    make_malcolm_tree "$ROOT"
    malcolm secrets >/dev/null
    printf 'ghcr.io/idaholab/malcolm/arkime:0.0.0-fixture\n' > "$BUNDLE/malcolm/image-list.txt"
    run malcolm auth --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"nginx-proxy"* ]]
}

@test "auth is idempotent once the material exists" {
    make_malcolm_tree "$ROOT"
    malcolm secrets >/dev/null
    echo "x" > "$ROOT/opt/malcolm/malcolm/nginx/htpasswd"
    run malcolm auth --bundle "$BUNDLE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already present"* ]]
    ! grep -q '^auth_setup' "$MALCOLM_STUB_LOG"
}

# ── start ───────────────────────────────────────────────────────────────────

@test "start uses Malcolm's own start script, never raw compose up, and waits for health" {
    make_malcolm_tree "$ROOT"
    echo "x" > "$ROOT/opt/malcolm/malcolm/nginx/htpasswd"
    malcolm rebind >/dev/null
    run malcolm start
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q '^start' "$MALCOLM_STUB_LOG"
    ! grep -q 'compose up' "$STUB_LOG"
    [[ "$output" == *"all 3 services running/healthy"* ]]
    [[ "$output" == *"127.0.0.1:8443"* ]]
}

@test "start refuses before auth material exists, and before the rebind" {
    make_malcolm_tree "$ROOT"
    run malcolm start
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"run auth first"* ]]
    echo "x" > "$ROOT/opt/malcolm/malcolm/nginx/htpasswd"
    run malcolm start
    [ "$status" -eq 1 ]
    [[ "$output" == *"run rebind first"* ]]
}

@test "start FAILs, naming the count, when services are still not ready at the deadline" {
    make_malcolm_tree "$ROOT"
    echo "x" > "$ROOT/opt/malcolm/malcolm/nginx/htpasswd"
    malcolm rebind >/dev/null
    stub docker 'case "$1 $2" in "compose ps") printf "arkime running starting\nzeek running healthy\n";; esac; exit 0'
    run malcolm start
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"1 of 2 services not ready"* ]]
}

# ── dashboards and arkime views ─────────────────────────────────────────────
# The stack is a curl stub: these prove the kit's side of the contract — that
# it reads the index pattern rather than assuming one, that it asserts every
# saved object back after an import that claims success, and that the admin
# credential reaches curl through a netrc and never through argv.

malcolm_secret() {  # the admin credential the API calls authenticate with
    mkdir -p "$ROOT/etc/lab/secrets"
    printf 'fixture-credential\n' > "$ROOT/etc/lab/secrets/malcolm-admin.pw"
}

stub_curl_osd() {  # a stack that answers; $1.. are the object ids that exist
    printf '%s\n' "$@" > "$BATS_TEST_TMPDIR/present-objects.txt"
    : > "$BATS_TEST_TMPDIR/views.json"
    [ -s "$BATS_TEST_TMPDIR/index-patterns.json" ] || \
        printf '{"saved_objects":[{"type":"index-pattern","id":"idx-net","attributes":{"title":"lab-sessions-*"}}]}' \
            > "$BATS_TEST_TMPDIR/index-patterns.json"
    stub curl '
echo "curl $*" >> "$STUB_LOG"
url=""; method=GET
while [ $# -gt 0 ]; do
  case "$1" in -X) method="$2"; shift ;; https://*) url="$1" ;; esac
  shift
done
case "$url" in
  */api/status*)               echo "{\"status\":{\"overall\":{\"state\":\"green\"}}}" ;;
  */_find*type=search*)        cat "$BATS_TEST_TMPDIR/objects.json" 2>/dev/null || echo "{\"saved_objects\":[]}" ;;
  */_find*type=index-pattern*) cat "$BATS_TEST_TMPDIR/index-patterns.json" ;;
  */_find*)                    cat "$BATS_TEST_TMPDIR/objects.json" 2>/dev/null || echo "{\"saved_objects\":[]}" ;;
  */_import*)                  echo "{\"success\":true}" ;;
  */api/user/views*)           cat "$BATS_TEST_TMPDIR/views.json" 2>/dev/null || echo "[]" ;;
  */saved_objects/*)
      id="${url##*/}"
      if grep -qxF "$id" "$BATS_TEST_TMPDIR/present-objects.txt" 2>/dev/null; then
        echo "{\"id\":\"$id\"}"
      else
        echo "{\"statusCode\":404}"
      fi ;;
esac
exit 0'
}

stub_curl_down() { stub curl 'echo "curl $*" >> "$STUB_LOG"; exit 7'; }

ipsec_ids() {  # every id the shipped template declares
    sed -n 's/^{"id":"\([^"]*\)".*/\1/p' config/malcolm/dashboards/ipsec.ndjson.template
}

@test "inventory SKIPs with a reason when Dashboards does not answer, and changes nothing" {
    make_malcolm_tree "$ROOT"; malcolm_secret
    stub_curl_down
    run malcolm inventory
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP"* ]]
    [[ "$output" == *"did not answer on 127.0.0.1:8443"* ]]
}

@test "inventory lists what the stack holds, grouped by type" {
    make_malcolm_tree "$ROOT"; malcolm_secret
    printf '{"saved_objects":[{"type":"index-pattern","id":"idx-net","attributes":{"title":"lab-sessions-*"}},{"type":"dashboard","id":"malcolm-overview","attributes":{"title":"Malcolm Overview"}}]}' \
        > "$BATS_TEST_TMPDIR/objects.json"
    stub_curl_osd
    run malcolm inventory
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"idx-net"* ]]
    [[ "$output" == *"malcolm-overview"* ]]
    [[ "$output" == *"Malcolm Overview"* ]]
}

@test "dashboards refuses to choose between several index patterns, and names them" {
    make_malcolm_tree "$ROOT"; malcolm_secret
    printf '{"saved_objects":[{"type":"index-pattern","id":"idx-net","attributes":{"title":"lab-sessions-*"}},{"type":"index-pattern","id":"idx-other","attributes":{"title":"lab-other-*"}}]}' \
        > "$BATS_TEST_TMPDIR/index-patterns.json"
    stub_curl_osd
    run malcolm dashboards
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"2 index patterns"* ]]
    [[ "$output" == *"--index-pattern"* ]]
    [[ "$output" == *"does not choose for you"* ]]
}

@test "dashboards takes the index pattern it is given, by title, and renders it in" {
    make_malcolm_tree "$ROOT"; malcolm_secret
    printf '{"saved_objects":[{"type":"index-pattern","id":"idx-net","attributes":{"title":"lab-sessions-*"}},{"type":"index-pattern","id":"idx-other","attributes":{"title":"lab-other-*"}}]}' \
        > "$BATS_TEST_TMPDIR/index-patterns.json"
    stub_curl_osd $(ipsec_ids)
    run malcolm dashboards --index-pattern 'lab-sessions-*'
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"index pattern: idx-net"* ]]
    grep -q '"id":"idx-net"' "$ROOT/opt/malcolm/ipsec.ndjson"
    run grep -c '__NETWORK_INDEX_PATTERN_ID__' "$ROOT/opt/malcolm/ipsec.ndjson"
    [ "$status" -ne 0 ]
}

@test "dashboards asserts every saved object back and PASSes when they all landed" {
    make_malcolm_tree "$ROOT"; malcolm_secret
    stub_curl_osd $(ipsec_ids)
    run malcolm dashboards
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"lab-ipsec-overview"* ]]
    [[ "$output" == *"saved object(s) present"* ]]
}

@test "dashboards regression: an import that claims success with an object missing is a FAIL that names it" {
    make_malcolm_tree "$ROOT"; malcolm_secret
    # the import reports {"success":true} but the dashboard never landed
    stub_curl_osd lab-ipsec-esp lab-ipsec-ah lab-ipsec-ike lab-ipsec-natt lab-ipsec-all
    run malcolm dashboards
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MISSING dashboard/lab-ipsec-overview"* ]]
    [[ "$output" == *"absent after import"* ]]
}

@test "dashboards sends the credential through a netrc, never through argv" {
    make_malcolm_tree "$ROOT"; malcolm_secret
    stub_curl_osd $(ipsec_ids)
    run malcolm dashboards
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" != *"fixture-credential"* ]]
    run grep -c 'fixture-credential' "$STUB_LOG"
    [ "$status" -ne 0 ]
    grep -q -- '--netrc-file' "$STUB_LOG"
}

@test "arkime-views posts every view in the kit's file and reads them all back" {
    make_malcolm_tree "$ROOT"; malcolm_secret
    stub_curl_osd
    sed -n 's/^\([^#|][^|]*\)|.*/{"name":"\1"}/p' config/malcolm/arkime-views/ipsec.views \
        | paste -sd, - | sed 's/^/[/;s/$/]/' > "$BATS_TEST_TMPDIR/views.json"
    run malcolm arkime-views
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"IPsec - ESP payload"* ]]
    [[ "$output" == *"view(s) present"* ]]
    grep -q 'ip.protocol == 50' "$STUB_LOG"
}

@test "arkime-views FAILs, naming the view, when Arkime accepted the post but stored nothing" {
    make_malcolm_tree "$ROOT"; malcolm_secret
    stub_curl_osd
    printf '[]' > "$BATS_TEST_TMPDIR/views.json"
    run malcolm arkime-views
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MISSING IPsec - ESP payload"* ]]
    [[ "$output" == *"did not store them"* ]]
}

@test "arkime-views dies naming the endpoint when Arkime's view API does not answer" {
    make_malcolm_tree "$ROOT"; malcolm_secret
    stub_curl_down
    run malcolm arkime-views
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"/api/user/views"* ]]
    [[ "$output" == *"BUNDLE_NOTES.md"* ]]
}

# ── full ─────────────────────────────────────────────────────────────────────

@test "full runs preflight through start in order: r770-import-bundle.sh for the shared steps, this script's own subcommands after" {
    make_malcolm_tree "$ROOT"
    stub_import_bundle
    stub_docker_reporting ghcr.io/idaholab/malcolm/arkime:0.0.0-fixture ghcr.io/idaholab/malcolm/nginx-proxy:0.0.0-fixture
    run malcolm full --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(awk '{print $2}' "$IMPORT_LOG" | paste -sd' ')" = "preflight gate copy apt phone-home docker files" ]
    grep -q "^import-bundle preflight --bundle $BUNDLE\$" "$IMPORT_LOG"
    grep -q "^import-bundle gate --bundle $BUNDLE\$" "$IMPORT_LOG"
    grep -q "^import-bundle copy --bundle $BUNDLE\$" "$IMPORT_LOG"
    grep -q "^docker load -i $BUNDLE/malcolm/malcolm-images-0.0.0-fixture.tar.gz" "$STUB_LOG"
    grep -q -- '--import-malcolm-config-file' "$MALCOLM_STUB_LOG"
    grep -q '^auth_setup --auth-noninteractive' "$MALCOLM_STUB_LOG"
    grep -q '^start' "$MALCOLM_STUB_LOG"
    [[ "$output" == *"DEPLOYED — every step clean"* ]]
}

@test "full with --media/--device passes them to the gate step only, and --media alone to copy" {
    stub_import_bundle
    run malcolm full --bundle "$BUNDLE" --media /mnt/usb --device /dev/fixture0 --only gate
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q "^import-bundle gate --bundle $BUNDLE --media /mnt/usb --device /dev/fixture0\$" "$IMPORT_LOG"

    : > "$IMPORT_LOG"
    run malcolm full --bundle "$BUNDLE" --media /mnt/usb --only copy
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q "^import-bundle copy --bundle $BUNDLE --media /mnt/usb\$" "$IMPORT_LOG"
}

@test "full --only slices to exactly one step" {
    stub_import_bundle
    stub_docker_reporting ghcr.io/idaholab/malcolm/arkime:0.0.0-fixture ghcr.io/idaholab/malcolm/nginx-proxy:0.0.0-fixture
    run malcolm full --bundle "$BUNDLE" --only load
    echo "$output"
    [ "$status" -eq 0 ]
    [ ! -s "$IMPORT_LOG" ]
    grep -q '^docker load' "$STUB_LOG"
    ! grep -q -- '--import-malcolm-config-file' "$MALCOLM_STUB_LOG"
    [[ "$output" == *"DEPLOYED — every step clean"* ]]
}

@test "full --from/--to slices to a contiguous range of steps" {
    stub_import_bundle
    run malcolm full --bundle "$BUNDLE" --from apt --to files
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(awk '{print $2}' "$IMPORT_LOG" | paste -sd' ')" = "apt phone-home docker files" ]
    ! grep -q '^docker load' "$STUB_LOG"
    ! grep -q -- '--import-malcolm-config-file' "$MALCOLM_STUB_LOG"
}

@test "full refuses when --from comes after --to, and names both" {
    run malcolm full --bundle "$BUNDLE" --from start --to apt
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"--from start"* ]]
    [[ "$output" == *"--to apt"* ]]
}

@test "full refuses naming an unknown --from/--to step" {
    run malcolm full --bundle "$BUNDLE" --from bogus
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown step: bogus"* ]]
}

@test "full stops after a step that warns without --yes, and finishes exit 2 once the warning is accepted" {
    stub_import_bundle
    export IMPORT_RC_APT=2
    unset KIT_YES
    run malcolm full --bundle "$BUNDLE" --only apt
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"warned and this run is non-interactive"* ]]

    export KIT_YES=1
    : > "$IMPORT_LOG"
    run malcolm full --bundle "$BUNDLE" --only apt
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" == *"accepted via --yes"* ]]
    [[ "$output" == *"DEPLOYED WITH WARNINGS"* ]]
    [[ "$output" == *"steps: apt"* ]]
}

# ── Malcolm's control scripts refuse root (measured on staging) ─────────────

@test "configure gives the stack to the user in config/process.env, whom Malcolm's scripts run as" {
    make_malcolm_tree "$ROOT"
    run malcolm configure --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q "^chown -R 1000:1000 $ROOT/opt/malcolm/malcolm$" "$STUB_LOG"
    [[ "$output" == *"PASS  $ROOT/opt/malcolm/malcolm owned by labop (1000:1000, from config/process.env)"* ]]
}

@test "configure refuses a stack whose recorded PUID is root" {
    make_malcolm_tree "$ROOT"
    printf 'PUID=0\nPGID=0\n' > "$ROOT/opt/malcolm/malcolm/config/process.env"
    run malcolm configure --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"PUID is 0"* ]]
}

@test "auth runs auth_setup as the stack's owner, never as root" {
    make_malcolm_tree "$ROOT"
    mkdir -p "$ROOT/etc/lab/secrets"; echo fixture-pw > "$ROOT/etc/lab/secrets/malcolm-admin.pw"
    rm -f "$ROOT/opt/malcolm/malcolm/nginx/htpasswd"
    run malcolm auth --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q '^runuser -u labop -- ./scripts/auth_setup --auth-noninteractive' "$STUB_LOG"
}

@test "start and stop run Malcolm's scripts as the stack's owner, and refuse an owner outside the docker group" {
    make_malcolm_tree "$ROOT"
    echo "analyst:hash" > "$ROOT/opt/malcolm/malcolm/nginx/htpasswd"
    sed -i 's|0.0.0.0:443:443/tcp|127.0.0.1:8443:443/tcp|' "$ROOT/opt/malcolm/malcolm/docker-compose.yml"
    run malcolm start
    echo "$output"
    grep -q '^runuser -u labop -- ./scripts/start' "$STUB_LOG"
    run malcolm stop
    grep -q '^runuser -u labop -- ./scripts/stop' "$STUB_LOG"
    stub getent 'case "$1 $2" in "passwd 1000") echo "labop:x:1000:1000::/home/labop:/bin/bash";; "group docker") echo "docker:x:988:";; *) exit 2;; esac'
    run malcolm start
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"labop is not in the docker group"* ]]
}
