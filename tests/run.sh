#!/usr/bin/env bash
#
# The kit's one check. Run from anywhere:  ./tests/run.sh
#
# Everything here is offline and read-only: shellcheck over every script (as a
# bats case in lint.bats) and the bats suites against synthetic fixtures under
# $BATS_TEST_TMPDIR, with every privileged or network-facing tool stubbed. It
# never touches a real bundle, never reaches a daemon, never contacts the R770.
set -euo pipefail

cd "$(dirname "$0")/.."

for t in bats shellcheck; do
    command -v "$t" >/dev/null 2>&1 || { echo "tests/run.sh: $t is not installed (apt-get install -y shellcheck bats)" >&2; exit 1; }
done

echo "== bats =="
bats tests/*.bats
