#!/usr/bin/env bats
# The bundle's integrity gate is the verifier that travels IN the bundle. The
# kit must reference it by name wherever it tells an operator to gate, invoke
# it from the library, and never carry a checksum recipe or a copy of its own.

setup() { cd "$BATS_TEST_DIRNAME/.."; }

@test "no hand-rolled checksum gate anywhere in the kit" {
    run grep -rnE 'sha256sum -c|xargs -0 sha256sum' scripts/ docs/ README.md CLAUDE.md config/
    echo "$output"
    [ "$status" -ne 0 ]
}

@test "the verifier is referenced by name from every operator-facing route" {
    for f in README.md CLAUDE.md docs/deployment-runbook.md docs/kit-sync.md; do
        grep -q 'r770-bundle\.sh verify' "$f" || { echo "$f does not name the verifier"; false; }
    done
}

@test "the library invokes the bundle's own copy of the verifier" {
    grep -q '"\$d/r770-bundle.sh" verify "\$d"' scripts/lib/common.sh
}

@test "the verifier exists only under staging/ (the copy the fetch places into the bundle)" {
    run find . -path ./.git -prune -o -name 'r770-bundle.sh' -print
    echo "$output"
    [ "$output" = "./staging/r770-bundle.sh" ]
}

@test "the R770 side never reaches for the staging copy" {
    run grep -rn 'staging/' scripts/
    echo "$output"
    [ "$status" -ne 0 ]
}

@test "the import script's gate goes through the library, never around it" {
    grep -q 'bundle_verify "\$b"' scripts/r770-import-bundle.sh
    run grep -n 'sha256sum' scripts/r770-import-bundle.sh
    [ "$status" -ne 0 ]
}
