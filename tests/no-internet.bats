#!/usr/bin/env bats
# The R770 has no internet, ever. Nothing on the R770 side (scripts/, config/)
# may name an external host, pull an image, reach for an index, or let a build
# container out. staging/ is exempt by design: it is the side that downloads,
# and it never runs on the R770 (tests/no-legacy-manifest.bats proves scripts/
# never reaches for it).

setup() { cd "$BATS_TEST_DIRNAME/.."; }

@test "no external URL in scripts or config" {
    # loopback, the five .lab names, and compose-internal service names only
    allow='://(127[.]0[.]0[.]1|localhost|[a-z0-9]+[.]lab|host[.]docker[.]internal|prometheus|alertmanager|blackbox|cadvisor|grafana|arkime|dashboards|opensearch)(:|/|$)'
    bad=$(grep -rnoE 'https?://[A-Za-z0-9._:-]+' scripts/ config/ | grep -vE "$allow" || true)
    echo "external: $bad"
    [ -z "$bad" ]
}

@test "every pip invocation is --no-index" {
    while read -r line; do
        [[ "$line" == *"--no-index"* ]] || { echo "pip without --no-index: $line"; false; }
    done < <(grep -hE 'bin/pip"? install|pip3? install' scripts/*.sh | grep -v 'die "' || true)
}

@test "every docker run carries --network none" {
    while read -r line; do
        [[ "$line" == *"--network none"* ]] || { echo "docker run without --network none: $line"; false; }
    done < <(grep -hE 'docker run ' scripts/*.sh | grep -v '^\s*#' | grep -v 'DRY-RUN' || true)
}

@test "no script pulls an image, adds a repository, or installs a snap" {
    run grep -nE 'docker pull|compose pull|add-apt-repository|apt-add-repository|snap install|pip download' scripts/*.sh
    echo "$output"
    [ "$status" -ne 0 ]
}

@test "compose is always brought up with --pull never" {
    while read -r line; do
        [[ "$line" == *"--pull never"* ]] || { echo "compose up without --pull never: $line"; false; }
    done < <(grep -hE 'compose .* up ' scripts/*.sh | grep -v '^\s*#' || true)
}

@test "curl and wget are used only against loopback or a .lab name" {
    while read -r line; do
        [[ "$line" == *"127.0.0.1"* ]] || [[ "$line" == *'"https://$n/"'* ]] || { echo "curl beyond loopback: $line"; false; }
    done < <(grep -hE '\b(curl|wget) ' scripts/*.sh | grep -vE '^\s*#|command -v|DRY-RUN|note "API' || true)
}
