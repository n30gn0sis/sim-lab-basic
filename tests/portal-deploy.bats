#!/usr/bin/env bats
#
# The portal is where a wrong file mode, a missing SAN or a bad reload takes
# every service off the air at once. The suite pins the SAN list, the file
# modes, the -t-before-reload order and the gate. The wiki it serves at
# docs.lab is built elsewhere (tests/docs-deploy.bats).

load helpers/fixtures
load helpers/stubs

setup() {
    kit_test_env
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-portal-deploy.sh"
    BUNDLE="$BATS_TEST_TMPDIR/bundle-fixture"
    make_bundle "$BUNDLE"
    make_root "$ROOT"
    export ROOT PORTAL_SETTLE_SECS=0
    export EASYRSA_BIN="$BIN/easyrsa"
    stub dpkg 'exit 0'
    # easyrsa writes the files a real run would, into $EASYRSA_PKI
    stub easyrsa 'echo "easyrsa $*" >> "$STUB_LOG"
case "$*" in
  init-pki) mkdir -p "$EASYRSA_PKI" ;;
  "build-ca nopass") echo "-----FIXTURE CA-----" > "$EASYRSA_PKI/ca.crt" ;;
  *build-server-full*) mkdir -p "$EASYRSA_PKI/issued" "$EASYRSA_PKI/private"; echo "-----FIXTURE CERT-----" > "$EASYRSA_PKI/issued/lab.crt"; echo "-----FIXTURE KEY-----" > "$EASYRSA_PKI/private/lab.key" ;;
esac
exit 0'
    stub openssl 'case "$1" in
  verify) echo "lab.crt: OK" ;;
  x509) case "$*" in *subjectAltName*) echo "X509v3 Subject Alternative Name:"; echo "    DNS:portal.lab, DNS:malcolm.lab, DNS:gns3.lab, DNS:monitoring.lab, DNS:docs.lab";; *enddate*) echo "notAfter=fixture";; esac ;;
esac
exit 0'
    stub_log chgrp; stub_log systemctl; stub_log nginx
    stub ss 'echo "LISTEN 0 511 0.0.0.0:443 0.0.0.0:* users:((\"nginx\",pid=1,fd=6))"'
    stub curl 'echo -n 200'
}

portal() { kit_run "$SCRIPT" "$@"; }
all_the_way_to_nginx() {
    portal ca >/dev/null; portal cert >/dev/null
    mkdir -p "$ROOT/opt/malcolm/malcolm/nginx"; echo "analyst:hash" > "$ROOT/opt/malcolm/malcolm/nginx/htpasswd"
    portal htpasswd >/dev/null
}

@test "--print-sans lists exactly the three lab names" {
    run portal --print-sans
    [ "$output" = "malcolm.lab gns3.lab docs.lab" ]
}

@test "ca builds the PKI once, publishes ca.crt 0644, and is idempotent" {
    run portal ca
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q '^easyrsa init-pki' "$STUB_LOG"
    grep -q '^easyrsa build-ca nopass' "$STUB_LOG"
    [ "$(stat -c %a "$ROOT/etc/nginx/ssl/ca.crt")" = "644" ]
    [ "$(stat -c %a "$ROOT/etc/lab/ca")" = "700" ]
    run portal ca
    [[ "$output" == *"already exists"* ]]
}

@test "cert asks easyrsa for exactly the three SANs and installs crt 0644 / key 0600" {
    portal ca >/dev/null
    run portal cert
    echo "$output"
    [ "$status" -eq 0 ]
    grep -q -- '--subject-alt-name=DNS:malcolm.lab,DNS:gns3.lab,DNS:docs.lab build-server-full lab nopass' "$STUB_LOG"
    [ "$(stat -c %a "$ROOT/etc/nginx/ssl/lab.crt")" = "644" ]
    [ "$(stat -c %a "$ROOT/etc/nginx/ssl/lab.key")" = "600" ]
    for n in malcolm gns3 docs; do [[ "$output" == *"PASS  SAN present: $n.lab"* ]]; done
}

@test "cert FAILs when the issued certificate lacks a SAN" {
    portal ca >/dev/null
    stub openssl 'case "$1" in verify) echo OK;; x509) echo "DNS:portal.lab, DNS:malcolm.lab";; esac'
    run portal cert
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  SAN missing: gns3.lab"* ]]
}

@test "htpasswd dies naming the Malcolm auth step when the source is absent" {
    run portal htpasswd
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"r770-malcolm-deploy.sh auth"* ]]
}

@test "nginx is gated, and refuses to run before cert and htpasswd exist" {
    run portal nginx
    [ "$status" -eq 1 ]; [[ "$output" == *"run ca and cert first"* ]]
    all_the_way_to_nginx
    unset KIT_YES
    run portal nginx --non-interactive
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"-- current --"*"-- proposed --"*"-- rollback --"* ]]
    [ ! -e "$ROOT/etc/nginx/sites-enabled/portal.lab.conf" ]
}

@test "nginx installs the vhosts, removes the default site, tests BEFORE reloading, then probes every name" {
    all_the_way_to_nginx
    run portal nginx
    echo "$output"
    [ "$status" -eq 0 ]
    for n in malcolm gns3 docs; do
        [ -f "$ROOT/etc/nginx/sites-available/$n.lab.conf" ]
        [ -L "$ROOT/etc/nginx/sites-enabled/$n.lab.conf" ]
        [[ "$output" == *"PASS  $n.lab answers over TLS"* ]]
    done
    [ -f "$ROOT/etc/nginx/snippets/lab-tls.conf" ]
    [ ! -e "$ROOT/etc/nginx/sites-enabled/default" ]
    t=$(grep -n '^nginx -t' "$STUB_LOG" | cut -d: -f1)
    r=$(grep -n '^systemctl reload nginx' "$STUB_LOG" | cut -d: -f1)
    [ -n "$t" ] && [ -n "$r" ] && [ "$t" -lt "$r" ]
}

@test "nginx aborts without reloading when nginx -t rejects the config" {
    all_the_way_to_nginx
    stub nginx 'echo "nginx $*" >> "$STUB_LOG"; echo "nginx: configuration file test failed"; exit 1'
    run portal nginx
    echo "$output"
    [ "$status" -eq 1 ]
    ! grep -q '^systemctl reload' "$STUB_LOG"
    [[ "$output" == *"previous config is still live"* ]]
}

@test "nginx probe treats 401 as answering and 502 as FAIL" {
    all_the_way_to_nginx
    stub curl 'case "$*" in *malcolm.lab*) echo -n 502;; *) echo -n 401;; esac'
    run portal nginx
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"PASS  gns3.lab answers over TLS (HTTP 401)"* ]]
    [[ "$output" == *"FAIL  malcolm.lab: HTTP 502"* ]]
}

@test "docs is no longer a portal subcommand, and the portal takes no --bundle or --wiki" {
    run portal docs
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown subcommand: docs"* ]]
    run portal status --bundle "$BUNDLE"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown option: --bundle"* ]]
    run portal status --wiki /tmp
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown option: --wiki"* ]]
}
