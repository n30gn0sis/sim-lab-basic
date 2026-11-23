# shellcheck shell=bash
#
# The file list the repo-wide guards (tests/no-pins.bats,
# tests/no-credentials.bats) scan. Load it, cd to the kit root, call
# kit_list once (setup), then read "$KIT_LIST".

# kit_files — every file of the kit under the current directory, NUL-separated.
# git's own list is trusted only when the work tree's top level IS this
# directory: what git tracks, plus any untracked file it does not ignore (a new
# kit file is covered before its first commit), minus .agentsroom/ (the
# AgentsRoom app's mailbox: untracked, not ignored, and its mail quotes version
# strings). Gitignored leftovers (.claude/worktrees/, .claude/proven-config.json,
# r770-evidence/) drop out with the rest of what .gitignore names. In any other
# case (no git, or a kit copy nested inside another repository, where git would
# answer for the outer repo and could list nothing) it walks the tree.
kit_files() {
    local top here
    here=$(pwd -P)
    top=$(git rev-parse --show-toplevel 2>/dev/null) && top=$(cd "$top" && pwd -P) || top=""
    if [ -n "$top" ] && [ "$top" = "$here" ]; then
        git ls-files -z --cached --others --exclude-standard -- . ':(exclude).agentsroom'
    else
        find . \( -path ./.git -o -path ./.agentsroom -o -path ./r770-evidence \) -prune -o -type f -print0
    fi
}

# kit_list <must-contain> — write the list to $KIT_LIST, and refuse (return 1)
# if it is empty or lacks <must-contain>: a scan over nothing passes vacuously.
kit_list() {
    KIT_LIST="${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/kit-files.list"
    kit_files > "$KIT_LIST"
    if ! tr '\0' '\n' < "$KIT_LIST" | grep -qxE "(\./)?$1"; then
        echo "kit_files listed $(tr -cd '\0' < "$KIT_LIST" | wc -c) file(s) and not $1: refusing to scan" >&2
        return 1
    fi
}

# kit_scan <path-regex-to-drop> <grep-flags> <regex> — grep the listed files,
# minus the paths matching the first argument
kit_scan() {
    grep -zvE "$1" "$KIT_LIST" | xargs -0 -r grep -s "$2" -- "$3"
}
