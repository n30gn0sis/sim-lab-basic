#!/usr/bin/env bats
# Secret protection lives IN the repo. Evidence transcripts, generated
# credentials and bundles must be ignored by the kit's own .gitignore, and no
# credential-shaped string may be tracked.

load helpers/kit_files

setup() { cd "$BATS_TEST_DIRNAME/.."; }

# ignored_by <gitignore> <path>: is <path> ignored by that one file ALONE? The
# file is copied into a throwaway repo, so a rule surviving only in the real
# repo's .git/info/exclude or a global excludes file cannot hide its loss, and
# the check runs (not SKIPs) in a kit copy with no git history.
# --no-index: judge the pattern alone, even for a path git happens to track.
ignored_by() {
    local r=$BATS_TEST_TMPDIR/judge
    rm -rf "$r" && git init -q "$r" && tr -d '\r' < "$1" > "$r/.gitignore" || return 2
    env GIT_CONFIG_GLOBAL=/dev/null git -C "$r" -c core.excludesFile=/dev/null check-ignore -q --no-index "$2"
}
ignored() { ignored_by .gitignore "$1"; }
in_work_tree() { git rev-parse --is-inside-work-tree >/dev/null 2>&1; }

@test "a .gitignore exists in the repo" { [ -f .gitignore ]; }

@test "evidence, secrets, rendered files, bundles, the packed builder and local agent settings are ignored by the repo's .gitignore" {
    ignored r770-evidence/
    ignored r770-evidence/import-bundle-host-0.log
    ignored etc/lab/secrets/malcolm-admin.pw
    ignored grafana-admin.env
    ignored something.rendered
    ignored bundle-20260908/
    ignored .claude/settings.local.json
    ignored .claude/worktrees/
    ignored .claude/proven-config.json
    ignored scenarios/ipsec-ike/runs/r1/gt/esp-keys.txt
    ignored r770-bundle-builder.sh
    ! ignored config/malcolm/auth.env                  # the templates' negation still holds
}

@test "the protective check bites: a rule dropped from .gitignore fails it even when .git/info/exclude still lists it" {
    local r=$BATS_TEST_TMPDIR/repo
    git init -q "$r"
    grep -vxF 'r770-evidence/' .gitignore > "$r/.gitignore"          # a rewrite that lost the rule...
    printf 'r770-evidence/\n' >> "$r/.git/info/exclude"               # ...which survives only locally
    env GIT_CONFIG_GLOBAL=/dev/null git -C "$r" -c core.excludesFile=/dev/null check-ignore -q --no-index r770-evidence/x.log
    run ignored_by "$r/.gitignore" r770-evidence/x.log
    [ "$status" -eq 1 ]                                               # the guard is not fooled
    run ignored_by .gitignore r770-evidence/x.log
    [ "$status" -eq 0 ]
}

# A tool that rewrites .gitignore (an agent app, an editor template) can drop
# every rule above in one write while the samples it happens to keep still
# pass, and one appended negation ('!*.tar.gz') can un-ignore what a rule
# still lists. gitignore_drift <dir> prints, for the repo at <dir>, each rule
# of HEAD's .gitignore missing from the working tree's and each '!' line HEAD
# does not have; nothing when the file only grew by plain rules. Exit 3: HEAD
# has no .gitignore.
gitignore_drift() {
    local d=$1 head now rule
    head=$(git -C "$d" show HEAD:.gitignore 2>/dev/null) || return 3
    head=$(printf '%s\n' "$head" | tr -d '\r')
    now=$(tr -d '\r' < "$d/.gitignore")
    while IFS= read -r rule; do
        case "$rule" in ''|'#'*) continue ;; esac
        printf '%s\n' "$now" | grep -qxF -- "$rule" || printf 'missing:  %s\n' "$rule"
    done <<< "$head"
    while IFS= read -r rule; do
        case "$rule" in '!'*) printf '%s\n' "$head" | grep -qxF -- "$rule" || printf 'new negation:  %s\n' "$rule" ;; esac
    done <<< "$now"
}

@test "every rule in HEAD's .gitignore is still in the working tree's, and no negation was added" {
    in_work_tree || skip "not a git work tree: there is no committed .gitignore to compare with"
    local rc=0 drift
    drift=$(gitignore_drift .) || rc=$?
    [ "$rc" -ne 3 ] || skip "HEAD has no .gitignore (an export without history, or a first commit): nothing to compare with"
    [ -z "$drift" ] || { echo "the working tree's .gitignore drifted from HEAD's:"; echo "$drift"; false; }
}

@test "the drift guard bites: a lost rule or an added negation is reported, added plain rules and HEAD's own negations are not" {
    local r=$BATS_TEST_TMPDIR/repo
    git init -q "$r"
    printf '# evidence\nr770-evidence/\n*.env\n!config/**/*.env\n*.tar.gz\n' > "$r/.gitignore"
    git -C "$r" add .gitignore
    git -C "$r" -c user.name=t -c user.email=t@t.invalid commit -qm base
    [ -z "$(gitignore_drift "$r")" ]                                  # unchanged
    printf '.mcp.json\n' >> "$r/.gitignore"
    [ -z "$(gitignore_drift "$r")" ]                                  # a plain rule added
    printf '!*.tar.gz\n' >> "$r/.gitignore"
    run gitignore_drift "$r"
    [ "$output" = "new negation:  !*.tar.gz" ]                        # HEAD's own !config/**/*.env is not reported
    printf '.mcp.json\n' > "$r/.gitignore"
    run gitignore_drift "$r"
    [[ "$output" == *"missing:  r770-evidence/"* ]]
    [[ "$output" == *"missing:  !config/**/*.env"* ]]
    [[ "$output" == *"missing:  *.tar.gz"* ]]
}

@test "no credential-shaped string is tracked" {
    kit_list scripts/lib/common.sh                     # never a vacuous pass over an empty list
    run kit_scan '^(\./)?tests/' -nE 'sshpass -p [^$]|BEGIN [A-Z ]*PRIVATE KEY|GF_SECURITY_ADMIN_PASSWORD=[A-Za-z0-9]{8,}'
    echo "$output"
    [ -z "$output" ]
}

@test "no script echoes a secret it read" {
    # secret_read results must never be interpolated into echo/note/pass lines
    run grep -nE '(echo|note|pass|warn|fail) .*\$\{?pw\}?' scripts/*.sh
    echo "$output"
    [ "$status" -ne 0 ]
}
