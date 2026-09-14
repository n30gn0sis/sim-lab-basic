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
    done < <(grep -rhoP '(?<![\w/.-])(scripts|config|docs|tests)/[A-Za-z0-9_./-]+' README.md CLAUDE.md docs/*.md config/README.md tests/README.md \
             | sed 's/[.,)`:]*$//' | sort -u)
    echo "missing:$missing"
    [ -z "$missing" ]
}

@test "every script is executable and every doc-named script exists" {
    for f in scripts/*.sh tests/run.sh; do [ -x "$f" ] || { echo "not executable: $f"; false; }; done
    while read -r s; do [ -x "$s" ] || { echo "named but missing: $s"; false; }; done \
        < <(grep -rhoP '(?<![\w/.-])scripts/r770-[a-z-]+\.sh' README.md CLAUDE.md docs/*.md .claude/settings.json | sort -u)   # docs/wiki is the build repo's content
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

@test "every runner stage resolves to a script that exists" {
    while read -r st; do
        case "$st" in
            preflight|gate|copy|apt|phone-home|docker|images|files) s=scripts/r770-import-bundle.sh ;;
            gns3) s=scripts/r770-gns3-deploy.sh ;; malcolm) s=scripts/r770-malcolm-deploy.sh ;;
            portal) s=scripts/r770-portal-deploy.sh ;; monitoring) s=scripts/r770-monitoring-deploy.sh ;;
            validate) s=scripts/r770-validate.sh ;; *) echo "unknown stage $st"; false ;;
        esac
        [ -x "$s" ]
        grep -q "r770-$(basename "$s" .sh | sed 's/^r770-//')" scripts/r770-deploy.sh
    done < <(./scripts/r770-deploy.sh --list)
    [ "$(./scripts/r770-deploy.sh --list | wc -l)" -eq 13 ]
}

@test "every script named in .claude/settings.json exists" {
    while read -r s; do [ -x "$s" ] || { echo "settings names missing script: $s"; false; }; done \
        < <(grep -oE '\./scripts/r770-[a-z-]+\.sh' .claude/settings.json | sed 's|^\./||' | sort -u)
}
