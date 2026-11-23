#!/usr/bin/env bats
#
# The kit carries NO version pins outside their one owner,
# staging/r770-offline-fetch.sh and its pin block. Everywhere else a pin would
# be a copy nothing updates on the next bump. Fixtures use 0.0.0-fixture, IPs
# are not versions, and the clean build image `ubuntu:24.04` the preflight
# names is a decision of record, not a pin.

load helpers/kit_files

OWNER='staging/r770-offline-fetch.sh'
NOT_OWNER='(^|/)r770-offline-fetch\.sh$'
NOT_OWNER_OR_TESTS='(^|/)r770-offline-fetch\.sh$|^(\./)?tests/'

# Every scan reads the one list kit_list writes; setup refuses to go on when
# that list is empty or lacks the owner, so no scan can pass over nothing.
setup() { cd "$BATS_TEST_DIRNAME/.." && kit_list "$OWNER"; }

# tokens <regex> — every match across the kit files minus the owner, one per line
tokens() {
    kit_scan "$NOT_OWNER" -hoE "$1" | sort -u
}

@test "the pin owner exists and is the only file allowed to carry the pin block" {
    grep -q '# ── pins: review each refresh cycle' "$OWNER"
    run kit_scan '^(\./)?tests/' -l 'pins: review each refresh cycle'
    echo "$output"
    [ "${output#./}" = "$OWNER" ]
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
    run kit_scan "$NOT_OWNER_OR_TESTS" -nE 'malcolm-[0-9]'
    echo "$output"
    [ -z "$output" ]
}

@test "no image reference carries a literal numeric tag" {
    # repo/name:1.2 or name:v1 forms; registry:2 is a floating major, allowed by name
    run kit_scan "$NOT_OWNER_OR_TESTS" -nE '[a-z0-9./-]+/[a-z0-9-]+:v?[0-9]+\.[0-9]+'
    echo "$output"
    out=$(printf '%s\n' "$output" | grep -v fixture | grep -v 'library/ubuntu:24\.04' || true)
    [ -z "$out" ]
}

@test "the scan covers every tracked file: only .agentsroom/ is carved out, and git tracks nothing there" {
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || skip "not a git work tree: kit_files walks the whole tree"
    [ -z "$(git ls-files .agentsroom)" ]
    missing=$(comm -23 <(git ls-files --cached | sort -u) <(kit_files | tr '\0' '\n' | sort -u))
    echo "tracked but not scanned: $missing"
    [ -z "$missing" ]
}

@test "outside a git work tree the scan walks the tree, never an empty list" {
    run bash -c "$(declare -f kit_files); GIT_DIR=/nonexistent kit_files | tr '\0' '\n'"
    [[ "$output" == *"./$OWNER"* ]]
    [[ "$output" == *"./scripts/r770-validate.sh"* ]]
}

@test "a kit copy nested in another repository's ignored dir is walked, and a planted pin is caught" {
    # git answers for the OUTER repo here and would list nothing: the vacuous pass a review reproduced
    local outer="$BATS_TEST_TMPDIR/outer" kit pin
    kit="$outer/bundle-x/kit"
    mkdir -p "$kit/staging"
    git init -q "$outer"
    printf 'bundle-*/\n' > "$outer/.gitignore"
    cp "$OWNER" "$kit/staging/"
    pin="9.9"; pin="$pin.9"                    # built at runtime: a literal here would trip this very suite
    printf 'image: example/thing:%s\n' "$pin" > "$kit/planted.sh"
    cd "$kit"
    kit_list "$OWNER"
    tr '\0' '\n' < "$KIT_LIST" | grep -qx './planted.sh'
    run tokens '[0-9]+\.[0-9]+\.[0-9]+'
    echo "$output"
    [ "$output" = "$pin" ]
}

@test "an empty file list, or one without the owner, refuses to scan" {
    mkdir -p "$BATS_TEST_TMPDIR/empty" && cd "$BATS_TEST_TMPDIR/empty"
    run kit_list "$OWNER"
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"listed 0 file(s) and not $OWNER: refusing to scan"* ]]
}
