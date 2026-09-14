#!/usr/bin/env bats
#
# The kit carries NO version pins. Every pin is owned by the build repo's
# fetch script and travels in the bundle (image lists, filenames,
# BUNDLE_NOTES.md); a pin written here would be a copy nothing updates on the
# next bump, which is the exact drift the build repo's OWNERS.md was written
# to stop. Fixtures use 0.0.0-fixture, and IPs are not versions.

setup() { cd "$BATS_TEST_DIRNAME/.."; }

# tokens <regex> — every match across the tracked tree, one per line
tokens() {
    grep -rhoE "$1" --exclude-dir=.git --exclude-dir=r770-evidence . | sort -u
}

@test "no three-part version number anywhere (IPs and 0.0.0-fixture excepted)" {
    bad=""
    while read -r t; do
        [ -n "$t" ] || continue
        case "$t" in
            *.*.*.*) continue ;;                         # dotted quad: an address
            *fixture*) continue ;;                       # synthetic
        esac
        bad="$bad $t"
    done < <(tokens '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)*([-.][a-z]+)?')
    echo "pins found:$bad"
    [ -z "$bad" ]
}

@test "no vX.Y-style tag anywhere (TLS protocol names and fixtures excepted)" {
    bad=""
    while read -r t; do
        [ -n "$t" ] || continue
        case "$t" in
            TLSv*|*fixture*) continue ;;
        esac
        bad="$bad $t"
    done < <(tokens '[A-Za-z]*v[0-9]+\.[0-9]+(\.[0-9]+)?(-[a-z]+)?')
    echo "tags found:$bad"
    [ -z "$bad" ]
}

@test "no file names a Malcolm artifact by version" {
    run grep -rnE 'malcolm-[0-9]' --exclude-dir=.git --exclude-dir=tests .
    echo "$output"
    [ "$status" -ne 0 ]
}

@test "no image reference carries a literal numeric tag" {
    # repo/name:1.2 or name:v1 forms; registry:2 is a floating major, allowed by name
    run grep -rnE '[a-z0-9./-]+/[a-z0-9-]+:v?[0-9]+\.[0-9]+' --exclude-dir=.git --exclude-dir=tests .
    echo "$output"
    out=$(printf '%s\n' "$output" | grep -v fixture || true)
    [ -z "$out" ]
}
