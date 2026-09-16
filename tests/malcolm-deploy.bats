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
    stub unzip 'echo "unzip $*" >> "$STUB_LOG"; mkdir -p "$ROOT/opt/malcolm/scripts"; touch "$ROOT/opt/malcolm/scripts/install.py"'
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
    cat > "$ROOT/opt/malcolm/scripts/install.py" <<'STUB'
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
