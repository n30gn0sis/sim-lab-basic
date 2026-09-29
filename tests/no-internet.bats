#!/usr/bin/env bats
# The R770 has no internet, ever. Nothing on the R770 side (scripts/, config/)
# may name an external host, pull an image, reach for an index, or let a build
# container out. staging/ is exempt by design: it is the side that downloads,
# and it never runs on the R770 (tests/no-legacy-manifest.bats proves scripts/
# never reaches for it).

setup() { cd "$BATS_TEST_DIRNAME/.."; }

@test "no external URL in scripts or config" {
    # loopback, the three .lab names, and compose-internal service names only
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

# urls_outside_lab <dir> — every URL under <dir> that could leave the lab: not
# an address in the pack's ranges (10.201-10.208), and not a .lab name that
# the same line pins to such an address with curl --resolve (a pinned name is
# never looked up; it is there only so TLS carries SNI)
urls_outside_lab() {
    grep -rnE 'https?://[A-Za-z0-9._:-]+' "$1" | while IFS= read -r line; do
        for url in $(printf '%s' "$line" | grep -oE 'https?://[A-Za-z0-9._:-]+'); do
            host=${url#*://}; host=${host%%[:/]*}
            if [[ "$host" =~ ^10[.]20[1-8][.][0-9]+[.][0-9]+$ ]]; then continue; fi
            if [[ "$host" == *.lab ]] && [[ "$line" =~ --resolve\ ${host//./[.]}:[0-9]+:10[.]20[1-8][.][0-9]+[.][0-9]+ ]]; then continue; fi
            echo "${line%%:*}: $url"
        done
    done
}

@test "scenario traffic stays inside the lab ranges" {
    bad=$(urls_outside_lab scenarios/)
    echo "outside the lab: $bad"
    [ -z "$bad" ]
}

@test "the lab-range guard refuses a non-lab name, and a .lab name no --resolve pins" {
    d="$BATS_TEST_TMPDIR/scen"; mkdir -p "$d"
    printf 'curl -sk --resolve x.scenario.lab:443:10.207.0.20 https://x.scenario.lab/\n' > "$d/ok.sh"
    printf 'curl -s http://10.208.0.20/\n' > "$d/ok2.sh"
    printf 'curl -s https://example.com/\n' > "$d/bad1.sh"
    printf 'curl -sk https://x.scenario.lab/\n' > "$d/bad2.sh"
    printf 'curl -sk --resolve x.scenario.lab:443:8.8.8.8 https://x.scenario.lab/\n' > "$d/bad3.sh"
    printf 'curl -s http://10.209.0.1/\n' > "$d/bad4.sh"
    run urls_outside_lab "$d"
    echo "$output"
    [ "${#lines[@]}" -eq 4 ]
    [[ "$output" == *"bad1.sh"* ]] && [[ "$output" == *"bad2.sh"* ]] && [[ "$output" == *"bad3.sh"* ]] && [[ "$output" == *"bad4.sh"* ]]
    [[ "$output" != *"ok.sh"* ]] && [[ "$output" != *"ok2.sh"* ]]
}
