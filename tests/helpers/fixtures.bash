# Synthetic fixtures for the kit's suites. Never a real bundle, never a real host.
#
# Versions here are SYNTHETIC (0.0.0-fixture) and must stay that way: the kit
# carries no version pins (tests/no-pins.bats enforces it), and a fixture that
# spelled one out would be a copy nothing updates on the next bump. Every kit
# script pairs payloads with lists by glob and reads image tags out of the
# bundle's own list files, so nothing here depends on a real value.

# make_bundle <dir> — the directory shape r770-offline-fetch.sh writes, with
# byte-sized stand-ins for the payload. The verifier that travels in the bundle
# root is a STUB that records its invocation and exits per FIXTURE_VERIFY_RC
# (default 0), so a suite can prove the kit called the bundle's own copy.
make_bundle() {
    local d=$1
    mkdir -p "$d"/{apt,malcolm,docker,images,enrichment,isos,dell,docs,keys} \
             "$d"/gns3/{appliances,definitions,wheelhouse,docker-nodes} "$d"/.stamps
    echo "fake deb"            > "$d/apt/example_1.0_amd64.deb"
    echo "fake docker deb"     > "$d/apt/docker-ce_0.0.0-fixture_amd64.deb"
    printf 'Package: example\n' | gzip -c > "$d/apt/Packages.gz"
    echo "fake key"            > "$d/apt/docker-repo-key.asc"

    printf 'ghcr.io/idaholab/malcolm/arkime:0.0.0-fixture\nghcr.io/idaholab/malcolm/nginx-proxy:0.0.0-fixture\n' \
        > "$d/malcolm/image-list.txt"
    _fixture_targz "$d/malcolm/malcolm-images-0.0.0-fixture.tar.gz" "fake malcolm images"
    echo "fake zip"            > "$d/malcolm/malcolm-0.0.0-fixture-docker_install.zip"
    echo "services: {}"        > "$d/malcolm/docker-compose.yml"

    # Trimmed to the one image staging's fetch script still carries here
    # (Task 1): the docs build's mkdocs-material. "found by name not
    # position" is still exercised elsewhere, by Malcolm's and GNS3's own
    # multi-entry image lists.
    cat > "$d/docker/monitoring-image-list.txt" <<'LIST'
docker.io/squidfunk/mkdocs-material:latest
LIST
    _fixture_targz "$d/docker/monitoring-images.tar.gz" "fake monitoring images"

    printf 'docker.io/library/alpine:latest\nquay.io/frrouting/frr:0.0.0-fixture\n' \
        > "$d/gns3/docker-nodes/image-list.txt"
    _fixture_targz "$d/gns3/docker-nodes/gns3-node-images.tar.gz" "fake node images"
    : > "$d/gns3/wheelhouse/gns3_server-0.0.0.fixture-py3-none-any.whl"
    : > "$d/gns3/wheelhouse/pip-0.0.0.fixture-py3-none-any.whl"
    echo '{"name": "VyOS"}'     > "$d/gns3/definitions/vyos.gns3a"
    echo '{"name": "OPNsense"}' > "$d/gns3/definitions/opnsense.gns3a"
    echo "fake vyos iso"       > "$d/gns3/appliances/vyos-0.0.0-fixture-generic-amd64.iso"
    echo "fake sig"            > "$d/gns3/appliances/vyos-0.0.0-fixture-generic-amd64.iso.minisig"
    echo "fake opnsense"       > "$d/gns3/appliances/OPNsense-0.0.0-fixture-dvd-amd64.iso.bz2"
    echo "fake sha"            > "$d/gns3/appliances/OPNsense-0.0.0-fixture-checksums-amd64.sha256"
    echo "Stage licensed appliance images here" > "$d/gns3/appliances/README.txt"

    echo "fake cloud image"    > "$d/images/noble-server-cloudimg-amd64.img"
    echo "fake cirros"         > "$d/images/cirros-0.0.0-fixture-x86_64-disk.img"
    echo "fake iso"            > "$d/isos/ubuntu-0.0.0-fixture-live-server-amd64.iso"
    echo "fake oui"            > "$d/enrichment/oui.txt"
    echo "fake psl"            > "$d/enrichment/public_suffix_list.dat"
    _fixture_targz "$d/enrichment/emerging.rules.tar.gz" "alert tcp any any -> any any (msg:fixture;)" rules/emerging-fixture.rules
    _fixture_targz "$d/docs/gns3-server-docs.tar.gz" "<html>fixture</html>" gns3-docs/index.html
    mkdir -p "$d/docs/malcolm"; echo "<html>malcolm docs</html>" > "$d/docs/malcolm/index.html"
    echo "MANUAL DOWNLOADS from dell.com/support" > "$d/dell/README.txt"
    touch "$d/.stamps/apt" "$d/.stamps/wheelhouse"

    cat > "$d/BUNDLE_NOTES.md" <<'NOTES'
# Bundle notes

- Ubuntu ISO 0.0.0-fixture fetched
- Malcolm 0.0.0-fixture images saved

## Import order on the R770
1. ./r770-bundle.sh verify .
NOTES
    printf '%064d  ./BUNDLE_NOTES.md\n' 0 > "$d/MANIFEST.sha256"

    # The verifier that ships inside a real bundle is scripts/r770-bundle.sh
    # from the build repo. Here it is a stub: it records that it was called,
    # with what, and answers with the contract's RESULT line and exit code.
    cat > "$d/r770-bundle.sh" <<'STUB'
#!/usr/bin/env bash
[ -n "${FIXTURE_VERIFY_LOG:-}" ] && echo "r770-bundle.sh $*" >> "$FIXTURE_VERIFY_LOG"
rc="${FIXTURE_VERIFY_RC:-0}"
case "$rc" in
    0) echo "RESULT: PASS — bundle is complete, unmodified and ready to transfer." ;;
    2) echo "WARN  fixture warning"; echo "RESULT: PASS WITH WARNINGS — 1 warning(s) to disposition." ;;
    *) echo "FAIL  fixture failure"; echo "RESULT: FAIL — 1 failure(s), 0 warning(s). Do not import this bundle." ;;
esac
exit "$rc"
STUB
    chmod +x "$d/r770-bundle.sh"
}

# stage_manual <dir> — the operator has completed the staging runbook's manual step.
stage_manual() {
    local d=$1
    echo "fake bios dup"   > "$d/dell/BIOS_R770_fixture.EXE"
    echo "fake iosv qcow2" > "$d/gns3/appliances/vios-adventerprisek9.qcow2"
}

# make_root <dir> — a fake filesystem root for KIT_ROOT: every absolute path
# the kit writes is prefixed with it, so a suite never touches the real host.
make_root() {
    local r=$1
    mkdir -p "$r"/etc/apt/sources.list.d "$r"/etc/nginx/{sites-available,sites-enabled,snippets,ssl} \
             "$r"/etc/update-motd.d "$r"/etc/default "$r"/etc/systemd/system "$r"/etc/lab \
             "$r"/srv/bundles "$r"/srv/repo "$r"/opt "$r"/var/lib/docker "$r"/root \
             "$r"/data/pcap "$r"/data/index "$r"/data/staging "$r"/srv/vms "$r"/srv/gns3 \
             "$r"/srv/work "$r"/srv/backup "$r"/srv/www "$r"/var/log
    printf 'deb http://archive.example/ubuntu noble main\n' > "$r/etc/apt/sources.list"
    printf 'deb http://archive.example/ubuntu noble-updates main\n' > "$r/etc/apt/sources.list.d/ubuntu.list"
    printf '#!/bin/sh\necho motd\n' > "$r/etc/update-motd.d/50-motd-news"; chmod +x "$r/etc/update-motd.d/50-motd-news"
    printf 'ENABLED=1\n' > "$r/etc/default/motd-news"
    ln -s ../sites-available/default "$r/etc/nginx/sites-enabled/default"
    echo "server {}" > "$r/etc/nginx/sites-available/default"
}

# make_malcolm_tree <root> — what /opt/malcolm looks like AFTER `unpack` and
# the installer's extraction: the installer at scripts/install.py, the stack at
# malcolm/ with its compose file (carrying the 0.0.0.0:443 publish line the
# rebind must rewrite, at the indentation the installer's YAML writer emits
# -- measured 2026-09-12), auth_setup and start. All stubs: each prints a --help
# listing the flags the kit relies on and records its argv to MALCOLM_STUB_LOG.
make_malcolm_tree() {
    local r=$1 home="$1/opt/malcolm"
    mkdir -p "$home/scripts" "$home/malcolm/scripts" "$home/malcolm/config" "$home/malcolm/nginx" "$home/malcolm/pcap/upload"
    cat > "$home/scripts/install.py" <<'STUB'
#!/usr/bin/env bash
[ -n "${MALCOLM_STUB_LOG:-}" ] && echo "install.py $*" >> "$MALCOLM_STUB_LOG"
case " $* " in *" --help "*)
    echo "usage: install.py [-h] [--non-interactive] [--defaults] [--configure] [--skip-splash]"
    echo "  --import-malcolm-config-file FILE   import configuration"
    echo "  --export-malcolm-config-file FILE   export configuration"
    exit 0 ;;
esac
exit 0
STUB
    cat > "$home/malcolm/scripts/auth_setup" <<'STUB'
#!/usr/bin/env bash
[ -n "${MALCOLM_STUB_LOG:-}" ] && echo "auth_setup $*" >> "$MALCOLM_STUB_LOG"
case " $* " in *" --help "*)
    for f in ${MALCOLM_STUB_AUTH_FLAGS:-auth-noninteractive auth-method auth-admin-username auth-admin-password-openssl auth-admin-password-htpasswd auth-generate-webcerts auth-generate-fwcerts auth-generate-netbox-passwords auth-generate-valkey-password auth-generate-postgres-password auth-generate-opensearch-internal-creds auth-generate-keycloak-db-password}; do
        echo "  --$f"
    done
    exit 0 ;;
esac
mkdir -p "$(dirname "$0")/../nginx"; echo "analyst:fixture-hash" > "$(dirname "$0")/../nginx/htpasswd"
exit 0
STUB
    local s
    for s in start stop; do
        cat > "$home/malcolm/scripts/$s" <<STUB
#!/usr/bin/env bash
[ -n "\${MALCOLM_STUB_LOG:-}" ] && echo "$s \$*" >> "\$MALCOLM_STUB_LOG"
exit 0
STUB
    done
    chmod +x "$home/scripts/install.py" "$home/malcolm/scripts/"*
    cat > "$home/malcolm/docker-compose.yml" <<'YAML'
services:
  nginx-proxy:
    image: ghcr.io/idaholab/malcolm/nginx-proxy:0.0.0-fixture
    ports:
    - 0.0.0.0:443:443/tcp
  arkime:
    image: ghcr.io/idaholab/malcolm/arkime:0.0.0-fixture
YAML
    printf 'OPENSEARCH_JAVA_OPTS=-Xms4g -Xmx4g\n' > "$home/malcolm/config/opensearch.env"
}

# _fixture_targz <dest> <content> [member-name] — a real, tiny gzip tarball so
# `tar xzf` works wherever a kit script extracts a payload.
_fixture_targz() {
    local dest=$1 content=$2 member=${3:-payload.txt} tmp
    tmp=$(mktemp -d)
    mkdir -p "$tmp/$(dirname "$member")"
    printf '%s\n' "$content" > "$tmp/$member"
    tar -C "$tmp" -czf "$dest" "$member"
    rm -rf "$tmp"
}
