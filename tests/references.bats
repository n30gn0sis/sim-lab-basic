#!/usr/bin/env bats
# Every kit path named in the docs must exist, every script must be
# executable, every config file must be installed by some script, and every
# runner stage must resolve to a script that exists.

setup() { cd "$BATS_TEST_DIRNAME/.."; }

@test "every kit path named in README, CLAUDE.md and docs/ exists" {
    missing=""
    while read -r p; do
        case "$p" in *'<'*) continue ;; esac
        [ -e "$p" ] || missing="$missing $p"
    done < <(grep -rhoP '(?<![\w/.-])(scripts|config|docs|tests|staging)/[A-Za-z0-9_./-]+' README.md CLAUDE.md docs/*.md config/README.md tests/README.md staging/README.md \
             | sed 's/[.,)`:]*$//' | sort -u)
    echo "missing:$missing"
    [ -z "$missing" ]
}

@test "every script is executable and every doc-named script exists" {
    for f in scripts/*.sh staging/*.sh tests/run.sh; do [ -x "$f" ] || { echo "not executable: $f"; false; }; done
    while read -r s; do [ -x "$s" ] || { echo "named but missing: $s"; false; }; done \
        < <(grep -rhoP '(?<![\w/.-])(scripts|staging)/r770-[a-z-]+\.sh' README.md CLAUDE.md docs/*.md staging/README.md .claude/settings.json | sort -u)   # docs/wiki is the build repo's content
}

@test "every config file is installed or rendered by some script" {
    while read -r f; do
        b=$(basename "$f")
        case "$f" in config/README.md) continue ;; esac
        # by name, by the directory glob a script copies, or by an ancestor directory a script copies whole
        d=$(dirname "$f"); d=${d#config/}; hit=0
        grep -rqF -- "$b" scripts/ && hit=1
        grep -rqF -- "$d/*.${b##*.}" scripts/ && hit=1
        while [ "$d" != "." ] && [ "$hit" -eq 0 ]; do grep -rqE -- "/${d}[\"'/ ]" scripts/ && hit=1; d=$(dirname "$d"); done
        [ "$hit" -eq 1 ] || { echo "config file no script uses: $f"; false; }
    done < <(find config -type f | sort)
}

@test "every full step of every pipeline resolves to a subcommand that exists" {
    # No outer orchestrator: r770-malcolm-deploy.sh, r770-gns3-deploy.sh and
    # r770-docs-deploy.sh full each hold their own STEPS array. The shared
    # prefix (preflight gate copy apt phone-home docker files) must be a
    # subcommand of r770-import-bundle.sh; every other step must be a
    # cmd_<step> function defined in the pipeline's own script.
    for s in scripts/r770-malcolm-deploy.sh scripts/r770-gns3-deploy.sh scripts/r770-docs-deploy.sh; do
        steps=$(grep -oP '^STEPS=\(\K[^)]+' "$s")
        [ -n "$steps" ] || { echo "no STEPS array in $s"; false; }
        for st in $steps; do
            case "$st" in
                preflight|gate|copy|apt|phone-home|docker|files)
                    grep -qE "^\s*${st})" scripts/r770-import-bundle.sh \
                        || { echo "$s step $st: no matching subcommand in r770-import-bundle.sh"; false; } ;;
                *)
                    fn="cmd_$(echo "$st" | tr '-' '_')"
                    grep -q "^${fn}(" "$s" \
                        || { echo "$s step $st: no $fn() in $s"; false; } ;;
            esac
        done
    done
}

@test "every script named in .claude/settings.json exists" {
    while read -r s; do [ -x "$s" ] || { echo "settings names missing script: $s"; false; }; done \
        < <(grep -oE '\./(scripts|staging)/r770-[a-z-]+\.sh' .claude/settings.json | sed 's|^\./||' | sort -u)
}
