# Scenario Dashboards and End-to-End Check — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver two things from each scenario's `expect.txt`:
- Malcolm saved searches, Arkime views and a "Lab scenarios" overview dashboard, generated from it;
- `r770-scenario.sh check <name>`, which proves a traffic run's window shows every row in Arkime.

**Architecture:** Three pieces share one sourced translator (`scripts/lib/expect.sh`), so a dashboard and the check run the same query:
- `r770-malcolm-deploy.sh dashboards` and `arkime-views` generate the scenario objects beside the fixed IPsec ones, through the same import and read-back.
- `r770-scenario.sh check` counts sessions through Arkime's API with `bounding=either`.
- The Malcolm login moves into `scripts/lib/malcolm-api.sh`, which both scripts source.

**Tech Stack:** bash, bats, python3 (writing JSON only, as elsewhere in the kit), curl to 127.0.0.1:8443.

**Spec:** `docs/superpowers/specs/2026-09-26-scenario-dashboards-and-check-design.md`

## Global Constraints

- **Exit contract.** `./tests/run.sh` must be green before every commit: shellcheck with **no exclusions** over `scripts/*.sh scripts/lib/*.sh`, and every `tests/*.bats`. Every check line is `PASS  `/`WARN  `/`FAIL  `/`SKIP  `, and exits follow 0 / 2 / 1 (`footer`).
- **Offline URLs.** The only URL any new code touches is `https://127.0.0.1:8443/...`, and there is no other host (`tests/no-internet.bats`).
- **Secrets.** The Malcolm password never reaches argv or the transcript. It goes only into a 0600 netrc made by `osd_auth_file`, from `/etc/lab/secrets/malcolm-admin.pw`, as user `${MALCOLM_ADMIN_USER:-analyst}`.
- **No pins.** No version numbers anywhere (`tests/no-pins.bats`). Test fixtures use synthetic values only.
- **Ranges live once.** Scenario ranges live only in `scenarios/<s>/scenario.conf`, and nothing under `config/` restates one.
- **The protocol set is closed:** `tcp udp icmp esp ah ospf`, with `esp`=50, `ah`=51, `ospf`=89. An unknown protocol is refused, never guessed.
- **Arkime session queries:**
  - always send `bounding=either` and `length=1`;
  - **never** send `date=`, because `date=-1` means all time;
  - read the count from `recordsFiltered`;
  - an answer without `recordsFiltered` is a FAIL naming the HTTP status, never a 0.
- **Object ids and titles** are exact:
  - range search `lab-scenario-<s>`, titled `Scenario <s> - all traffic (lab)`;
  - row search `lab-scenario-<s>-row-<n>`, titled `Scenario <s> - <label> (lab)`;
  - dashboard `lab-scenarios-overview`, titled `Lab scenarios - Overview (lab)`;
  - Arkime views `Scenario <s> - all traffic` and `Scenario <s> - <label>`.
- **Labels:** `<proto>[/<port>] <src> -> <dst>` (ASCII `->`).
- **Row lists** are `|`-separated, because the port field is often empty and bash `read` collapses empty tab-separated fields.
- **Existing tests.** The existing IPsec dashboards and arkime-views tests pass with no edits to their bodies. `tests/malcolm-deploy.bats`'s `setup()` gains `SCENARIO_DIR` pointing at an empty directory.
- **Cite paths** as backticked bare paths in docs under `docs/*.md`. `tests/references.bats` checks that they exist.

## File Structure

| File | Responsibility |
|---|---|
| `scripts/lib/expect.sh` (new) | Pure translator: `expect_rows`, `expect_problem`, `expect_cidr`, `expect_arkime`, `expect_kql`, `expect_label` |
| `scripts/lib/malcolm-api.sh` (new) | Malcolm API access through 127.0.0.1:8443: `osd_auth_file`, `osd_cleanup`, `osd_api`, `arkime_api`, `osd_reachable` (moved verbatim from `r770-malcolm-deploy.sh`) |
| `scripts/r770-malcolm-deploy.sh` | Sources both libs; `pack_rows`, `scenario_spec`, `scenario_ndjson`, `scenario_views`; `dashboards`/`arkime-views` import the generated objects too |
| `scripts/r770-scenario.sh` | Sources both libs; new `check` subcommand, `--run`, `arkime_count`, `row_bpf` |
| `tests/expect.bats` (new) | The translator |
| `tests/malcolm-deploy.bats` | Generated objects, views, refusals, netrc ownership |
| `tests/scenario.bats` | `check` |
| `tests/scenarios.bats` | Every pack row translates |
| `README.md`, `docs/deployment-runbook.md`, `config/README.md` | The two libs, the generated objects, `check` |

---

### Task 1: The translator — `scripts/lib/expect.sh`

**Files:**
- Create: `scripts/lib/expect.sh`
- Create: `tests/expect.bats`
- Modify: `tests/scenarios.bats` (one new test)
- Modify: `README.md` (one table row after the `scripts/lib/common.sh` row)

**Interfaces:**
- Consumes: `die` from `scripts/lib/common.sh` (sourced first by every caller).
- Produces, for Tasks 3–5:
  - `expect_rows <scenario-dir>`: stdout `<n>|<proto>|<port>|<src>|<dst>` per data line, where `n` counts data lines only. It dies when `<dir>/expect.txt` is missing.
  - `expect_problem <proto> <port> <src> <dst>`: stdout is the reason the row can't be translated; empty when it can. Always returns 0.
  - `expect_cidr <string>`: returns 0 for an IPv4 CIDR `a.b.c.d/len`, with octets 0–255 and len 0–32.
  - `expect_arkime`, `expect_kql`, `expect_label` `<proto> <port> <src> <dst>`: one string on stdout, no newline. They assume `expect_problem` returned empty.

- [ ] **Step 1: Write the failing tests** — create `tests/expect.bats`:

```bash
#!/usr/bin/env bats
#
# scripts/lib/expect.sh: one expect.txt row into the Arkime expression and the
# Dashboards (KQL) query that find it, and the refusals that keep a guess out
# of both. Pure functions: no stubs needed beyond the kit's PATH.

load helpers/stubs

setup() {
    kit_test_env
    LIB="$BATS_TEST_DIRNAME/../scripts/lib"
}

# x <snippet> — run a snippet with common.sh and expect.sh sourced
x() { kit_run bash -c "set -uo pipefail; . '$LIB/common.sh'; . '$LIB/expect.sh'; $1"; }

@test "a tcp row with a port: the port matches either side, in both languages" {
    run x 'expect_arkime tcp 179 10.204.0.0/24 10.204.0.0/24'
    [ "$output" = 'ip.protocol == tcp && port == 179 && ip.src == 10.204.0.0/24 && ip.dst == 10.204.0.0/24' ]
    run x 'expect_kql tcp 179 10.204.0.0/24 10.204.0.0/24'
    [ "$output" = 'network.transport:tcp and (source.port:179 or destination.port:179) and source.ip:"10.204.0.0/24" and destination.ip:"10.204.0.0/24"' ]
}

@test "icmp and udp are matched by name; a row with no port has no port clause" {
    run x 'expect_arkime icmp "" 10.205.0.10/32 10.205.0.20/32'
    [ "$output" = 'ip.protocol == icmp && ip.src == 10.205.0.10/32 && ip.dst == 10.205.0.20/32' ]
    run x 'expect_kql udp 500 10.202.0.1/32 10.202.0.2/32'
    [ "$output" = 'network.transport:udp and (source.port:500 or destination.port:500) and source.ip:"10.202.0.1/32" and destination.ip:"10.202.0.2/32"' ]
}

@test "esp, ah and ospf are matched by IANA protocol number, in both languages" {
    for pair in esp:50 ah:51 ospf:89; do
        p=${pair%%:*}; num=${pair#*:}
        run x "expect_arkime $p '' 10.0.0.1/32 10.0.0.2/32"
        [ "$output" = "ip.protocol == $num && ip.src == 10.0.0.1/32 && ip.dst == 10.0.0.2/32" ]
        run x "expect_kql $p '' 10.0.0.1/32 10.0.0.2/32"
        [ "$output" = "network.iana_number:$num and source.ip:\"10.0.0.1/32\" and destination.ip:\"10.0.0.2/32\"" ]
    done
}

@test "labels are <proto>[/<port>] <src> -> <dst>" {
    run x 'expect_label udp 500 10.202.0.1/32 10.202.0.2/32'
    [ "$output" = 'udp/500 10.202.0.1/32 -> 10.202.0.2/32' ]
    run x 'expect_label esp "" 10.201.0.1/32 10.201.0.2/32'
    [ "$output" = 'esp 10.201.0.1/32 -> 10.201.0.2/32' ]
}

@test "expect_rows numbers data lines only, keeps an empty port, and reads a last line with no newline" {
    d="$BATS_TEST_TMPDIR/s"; mkdir -p "$d"
    printf '# a comment\n\nesp||10.0.0.1/32|10.0.0.2/32\n# mid\ntcp|80|10.0.0.1/32|10.0.0.2/32' > "$d/expect.txt"
    run x "expect_rows '$d'"
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [ "${lines[0]}" = '1|esp||10.0.0.1/32|10.0.0.2/32' ]
    [ "${lines[1]}" = '2|tcp|80|10.0.0.1/32|10.0.0.2/32' ]
}

@test "expect_rows dies naming the directory when there is no expect.txt" {
    run x "expect_rows '$BATS_TEST_TMPDIR/none'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no expect.txt in $BATS_TEST_TMPDIR/none"* ]]
}

@test "expect_problem is empty for a good row and names each kind of bad one" {
    run x 'expect_problem tcp 179 10.204.0.0/24 10.204.0.0/24'
    [ -z "$output" ]
    run x 'expect_problem sctp "" 10.0.0.1/32 10.0.0.2/32'
    [[ "$output" == "unknown protocol 'sctp' (known: tcp udp icmp esp ah ospf)" ]]
    run x 'expect_problem ospf 89 10.0.0.1/32 10.0.0.2/32'
    [[ "$output" == "ospf carries no port (got 89)" ]]
    for bad in 0 70000 http; do
        run x "expect_problem tcp $bad 10.0.0.1/32 10.0.0.2/32"
        [[ "$output" == "port '$bad' is not 1-65535" ]]
    done
    for bad in 10.0.0.1 300.0.0.1/32 10.0.0.0/33 host; do
        run x "expect_problem tcp 80 $bad 10.0.0.2/32"
        [[ "$output" == "src '$bad' is not an IPv4 CIDR" ]]
    done
    run x 'expect_problem tcp 80 10.0.0.1/32 10.0.0.0/33'
    [[ "$output" == "dst '10.0.0.0/33' is not an IPv4 CIDR" ]]
}
```

Add to `tests/scenarios.bats`, directly before the `@test "every traffic.sh and node script is shellcheck-clean as POSIX sh"` line:

```bash
@test "every expect.txt row translates (scripts/lib/expect.sh), so dashboards and check can use it" {
    run bash -c '. scripts/lib/common.sh; . scripts/lib/expect.sh
        for d in scenarios/*/; do
            while IFS="|" read -r n p port s t; do
                w=$(expect_problem "$p" "$port" "$s" "$t")
                [ -z "$w" ] || { echo "$d expect.txt row $n: $w"; exit 1; }
            done < <(expect_rows "$d")
        done'
    echo "$output"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
```

- [ ] **Step 2: Run the tests; they should fail**

Run: `bats tests/expect.bats; bats tests/scenarios.bats --filter 'translates'`
Expected: FAIL. `scripts/lib/expect.sh` does not exist (`No such file or directory`).

- [ ] **Step 3: Write `scripts/lib/expect.sh`**

```bash
#!/usr/bin/env bash
#
# expect.sh — one scenario expect.txt row (proto|port|src|dst), as the queries
# that find it. Sourced after common.sh by r770-malcolm-deploy.sh (the
# generated saved searches and Arkime views) and r770-scenario.sh (check), so
# what a dashboard shows and what the check proves are the same query.
#
# The protocol set is closed on purpose: a protocol this file does not know is
# a refusal (expect_problem), never a guess. Adding one is a line in
# expect_iana or the named list, and a test.

# expect_rows <scenario-dir> — "<n>|<proto>|<port>|<src>|<dst>" per data line
# of its expect.txt; n counts data lines only (comments and blank lines are
# skipped). '|' and not a tab: bash's read collapses an empty field between
# tabs, and the port is often empty.
expect_rows() {
    local f="$1/expect.txt" line n=0 proto port src dst
    [ -f "$f" ] || die "no expect.txt in $1"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        n=$((n + 1))
        IFS='|' read -r proto port src dst <<< "$line"
        printf '%s|%s|%s|%s|%s\n' "$n" "$proto" "$port" "$src" "$dst"
    done < "$f"
}

# expect_cidr <string> — 0 for an IPv4 CIDR a.b.c.d/len (octets 0-255, len 0-32)
expect_cidr() {
    local o
    [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || return 1
    for o in 1 2 3 4; do [ "$((10#${BASH_REMATCH[$o]}))" -le 255 ] || return 1; done
    [ "$((10#${BASH_REMATCH[5]}))" -le 32 ]
}

# expect_iana <proto> — the IP protocol number of a protocol matched by number
expect_iana() {
    case "$1" in
        esp)  echo 50 ;;
        ah)   echo 51 ;;
        ospf) echo 89 ;;
        *)    return 1 ;;
    esac
}

# expect_problem <proto> <port> <src> <dst> — why this row cannot be
# translated; empty when it can. Callers name the file and row around it.
expect_problem() {
    local proto=$1 port=$2 src=$3 dst=$4
    case "$proto" in
        tcp|udp) ;;
        icmp|esp|ah|ospf)
            if [ -n "$port" ]; then printf '%s carries no port (got %s)' "$proto" "$port"; return 0; fi ;;
        *)  printf "unknown protocol '%s' (known: tcp udp icmp esp ah ospf)" "$proto"; return 0 ;;
    esac
    if [ -n "$port" ]; then
        if ! [[ "$port" =~ ^[0-9]{1,5}$ ]] || [ "$((10#$port))" -lt 1 ] || [ "$((10#$port))" -gt 65535 ]; then
            printf "port '%s' is not 1-65535" "$port"; return 0
        fi
    fi
    expect_cidr "$src" || { printf "src '%s' is not an IPv4 CIDR" "$src"; return 0; }
    expect_cidr "$dst" || { printf "dst '%s' is not an IPv4 CIDR" "$dst"; return 0; }
    return 0
}

# expect_arkime <proto> <port> <src> <dst> — the Arkime expression. A port
# matches either side: IKE is 500<->500, and a reply's source port is the
# request's destination.
expect_arkime() {
    local proto=$1 port=$2 src=$3 dst=$4 q
    case "$proto" in
        tcp|udp|icmp) q="ip.protocol == $proto" ;;
        *)            q="ip.protocol == $(expect_iana "$proto")" ;;
    esac
    [ -z "$port" ] || q="$q && port == $port"
    printf '%s && ip.src == %s && ip.dst == %s' "$q" "$src" "$dst"
}

# expect_kql <proto> <port> <src> <dst> — the Dashboards query (KQL, the
# language the kit's IPsec searches use), over Malcolm's ECS field names
expect_kql() {
    local proto=$1 port=$2 src=$3 dst=$4 q
    case "$proto" in
        tcp|udp|icmp) q="network.transport:$proto" ;;
        *)            q="network.iana_number:$(expect_iana "$proto")" ;;
    esac
    [ -z "$port" ] || q="$q and (source.port:$port or destination.port:$port)"
    printf '%s and source.ip:"%s" and destination.ip:"%s"' "$q" "$src" "$dst"
}

# expect_label <proto> <port> <src> <dst> — "<proto>[/<port>] <src> -> <dst>"
expect_label() {
    printf '%s%s %s -> %s' "$1" "${2:+/$2}" "$3" "$4"
}
```

- [ ] **Step 4: Run the tests; they should pass**

Run: `bats tests/expect.bats && bats tests/scenarios.bats && shellcheck -x scripts/lib/expect.sh`
Expected: every test `ok`, and shellcheck silent.

- [ ] **Step 5: Add the README row.** In `README.md`'s file table, directly after the row that starts `` | `scripts/lib/common.sh` | ``, add:

```markdown
| `scripts/lib/expect.sh` | One scenario `expect.txt` row as the Arkime expression and the Dashboards (KQL) query that find it — the one translator behind the generated scenario searches and views and `r770-scenario.sh check`; refuses a protocol it does not know |
```

- [ ] **Step 6: Run the gate and commit**

Run: `./tests/run.sh`
Expected: exit 0.

```bash
git add scripts/lib/expect.sh tests/expect.bats tests/scenarios.bats README.md
git commit -m "Scenario translator: an expect.txt row as its Arkime expression and KQL query"
```

---

### Task 2: Move the Malcolm login into `scripts/lib/malcolm-api.sh`

**Files:**
- Create: `scripts/lib/malcolm-api.sh`
- Modify: `scripts/r770-malcolm-deploy.sh`:
  - line 71: `BUNDLE=""; FREE_G=""; IDX=""; OSD_NETRC=""`
  - line 75: `ADMIN_USER=…`
  - line 85: `SECRET=…`
  - lines 475–504: the block from the `# ── dashboards and arkime views ──` comment through `osd_reachable()`
- Modify: `tests/malcolm-deploy.bats` (one new test)
- Modify: `README.md` (one row)

**Interfaces:**
- Consumes: `p`, `secret_read`, `die` from `scripts/lib/common.sh`.
- Produces, for Tasks 3–5:
  - Globals: `MALCOLM_API_USER` (`${MALCOLM_ADMIN_USER:-analyst}`), `MALCOLM_SECRET_FILE` (`/etc/lab/secrets/malcolm-admin.pw`), `OSD_NETRC`.
  - `osd_auth_file`: writes the 0600 netrc and sets `trap osd_cleanup EXIT`.
  - `osd_api <method> <path> [curl args…]`: Dashboards, under `https://127.0.0.1:8443/dashboards`.
  - `arkime_api <method> <path> [curl args…]`: Arkime, under `https://127.0.0.1:8443/arkime`.
  - `osd_reachable`: 0 when Dashboards answers.
  - The behaviour is byte-for-byte what `r770-malcolm-deploy.sh` had.

- [ ] **Step 1: Write the failing test.** Add to `tests/malcolm-deploy.bats`, directly after the `@test "dashboards sends the credential through a netrc, never through argv"` test:

```bash
@test "the Malcolm netrc is written in one place, scripts/lib/malcolm-api.sh, which both API users source" {
    cd "$BATS_TEST_DIRNAME/.."
    run grep -l -- '--netrc-file' scripts/*.sh scripts/lib/*.sh
    [ "$output" = "scripts/lib/malcolm-api.sh" ]
    grep -q '^\. "$(dirname "${BASH_SOURCE\[0\]}")/lib/malcolm-api.sh"' scripts/r770-malcolm-deploy.sh
}
```

- [ ] **Step 2: Run the test; it should fail**

Run: `bats tests/malcolm-deploy.bats --filter 'written in one place'`
Expected: FAIL. The output is `scripts/r770-malcolm-deploy.sh`.

- [ ] **Step 3: Create `scripts/lib/malcolm-api.sh`** with the block moved from `r770-malcolm-deploy.sh`. Only the variable names in `osd_auth_file` change:

```bash
#!/usr/bin/env bash
#
# malcolm-api.sh — Malcolm's Dashboards and Arkime APIs, sourced after
# common.sh by r770-malcolm-deploy.sh (inventory, dashboards, arkime-views) and
# r770-scenario.sh (check).
#
# Everything here reaches the stack through the rebound proxy on
# 127.0.0.1:8443 — the entry point `rebind` guarantees, and the only one the
# air gap admits. The admin credential never reaches argv or the transcript:
# curl reads it from a 0600 netrc that lives only for the length of the run.
# There is no jq on this box, so every response is read with sed and grep, and
# any shape this kit was not written for is a refusal, never a guess.

MALCOLM_API_USER="${MALCOLM_ADMIN_USER:-analyst}"
MALCOLM_SECRET_FILE="/etc/lab/secrets/malcolm-admin.pw"
OSD_NETRC=""

osd_cleanup() {
    if [ -n "$OSD_NETRC" ]; then rm -f "$OSD_NETRC"; fi
    OSD_NETRC=""
}
osd_auth_file() {
    local pw
    pw=$(secret_read "$(p "$MALCOLM_SECRET_FILE")") || exit 1
    OSD_NETRC=$(mktemp) || die "mktemp failed"
    chmod 600 "$OSD_NETRC"
    printf 'machine 127.0.0.1 login %s password %s\n' "$MALCOLM_API_USER" "$pw" > "$OSD_NETRC"
    trap osd_cleanup EXIT
}
osd_api() {  # osd_api <method> <path> [extra args...]
    local m=$1 path=$2; shift 2
    curl -sS -k --max-time 60 --netrc-file "$OSD_NETRC" -X "$m" -H 'osd-xsrf: true' "https://127.0.0.1:8443/dashboards${path}" "$@"
}
arkime_api() {  # arkime_api <method> <path> [extra args...]
    local m=$1 path=$2; shift 2
    curl -sS -k --max-time 60 --netrc-file "$OSD_NETRC" -X "$m" -H 'Content-Type: application/json' "https://127.0.0.1:8443/arkime${path}" "$@"
}
# osd_reachable — a named SKIP beats a wall of curl errors when the stack is
# simply not up yet.
osd_reachable() { osd_api GET "/api/status" --fail >/dev/null 2>&1; }
```

- [ ] **Step 4: Edit `scripts/r770-malcolm-deploy.sh`**

1. After the existing lines

```bash
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
```

add:

```bash
# shellcheck source=lib/malcolm-api.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/malcolm-api.sh"
```

2. Change `BUNDLE=""; FREE_G=""; IDX=""; OSD_NETRC=""` to `BUNDLE=""; FREE_G=""; IDX=""`. `OSD_NETRC` is now the lib's.
3. Change the `ADMIN_USER=` line to `ADMIN_USER="$MALCOLM_API_USER"`, and the `SECRET=` line to `SECRET="$MALCOLM_SECRET_FILE"`.
4. Delete the moved block: from `# Everything below reaches the stack through the rebound proxy on` through the `osd_reachable() {…}` line. Keep the `# ── dashboards and arkime views ──` heading, followed by one line: `# The API helpers (osd_api, arkime_api, the netrc) are scripts/lib/malcolm-api.sh's.`

- [ ] **Step 5: Run the tests; they should pass**

Run: `bats tests/malcolm-deploy.bats && shellcheck -x scripts/r770-malcolm-deploy.sh scripts/lib/malcolm-api.sh`
Expected: every test `ok`, including all the pre-existing dashboards, inventory and arkime-views tests unchanged, and shellcheck silent.

- [ ] **Step 6: Add the README row**, directly after the `scripts/lib/expect.sh` row:

```markdown
| `scripts/lib/malcolm-api.sh` | Malcolm's Dashboards and Arkime APIs through 127.0.0.1:8443 only, the credential through a 0600 netrc and never argv — sourced by `r770-malcolm-deploy.sh` and `r770-scenario.sh` |
```

- [ ] **Step 7: Run the gate and commit**

Run: `./tests/run.sh` (expected: exit 0)

```bash
git add scripts/lib/malcolm-api.sh scripts/r770-malcolm-deploy.sh tests/malcolm-deploy.bats README.md
git commit -m "Malcolm API access moves to scripts/lib/malcolm-api.sh, for the scenario check to share"
```

---

### Task 3: `dashboards` generates the scenario pack's searches and overview

**Files:**
- Modify: `scripts/r770-malcolm-deploy.sh`:
  - the header env list near line 53;
  - globals near line 85;
  - new functions placed directly before `cmd_inventory()`;
  - `cmd_dashboards()`.
- Modify: `tests/malcolm-deploy.bats`: `setup()` plus new helpers and tests after the arkime-views tests.
- Modify: `docs/deployment-runbook.md` (the dashboards paragraph), `config/README.md` (one paragraph).

**Interfaces:**
- Consumes: from Task 1, `expect_rows`, `expect_problem`, `expect_cidr`, `expect_kql`, `expect_label`; from Task 2, `osd_*`; the existing `render`, `assert_saved_objects`, `resolve_index_pattern`, `home`.
- Produces, for Task 4:
  - `pack_rows`: stdout is `S|<name>|<range>` per scenario, then `R|<name>|<n>|<proto>|<port>|<src>|<dst>` per row. It dies (in the current shell) on a bad range, a missing `expect.txt` or a refused row, and **must be called with a redirect, never in `$()` or a pipe**.
  - `SCEN_DIR` global.

- [ ] **Step 1: Make the existing tests independent of the real pack.** In `tests/malcolm-deploy.bats` `setup()`, add as its last line:

```bash
    export SCENARIO_DIR="$BATS_TEST_TMPDIR/no-scenarios"   # tests that want the pack call use_pack
```

- [ ] **Step 2: Write the failing tests.** Append to `tests/malcolm-deploy.bats`, directly before the `# ── full ──` heading:

```bash
# ── the scenario pack's generated objects ────────────────────────────────────
use_pack() { export SCENARIO_DIR="$BATS_TEST_DIRNAME/../scenarios"; }

pack_ids() {  # every id dashboards should generate from $SCENARIO_DIR, in file order
    local d s n i
    for d in "$SCENARIO_DIR"/*/; do
        s=$(basename "$d"); echo "lab-scenario-$s"
        n=$(grep -cvE '^(#|$)' "$d/expect.txt")
        for i in $(seq 1 "$n"); do echo "lab-scenario-$s-row-$i"; done
    done
    echo lab-scenarios-overview
}

search_of() {  # search_of <ndjson> <id> — its title, then its query
    python3 -c 'import json, sys
for l in open(sys.argv[1]):
    o = json.loads(l)
    if o["id"] == sys.argv[2]:
        print(o["attributes"]["title"])
        print(json.loads(o["attributes"]["kibanaSavedObjectMeta"]["searchSourceJSON"])["query"]["query"])' "$1" "$2"
}

bad_pack() {  # a one-scenario pack whose second row the translator refuses
    export SCENARIO_DIR="$BATS_TEST_TMPDIR/bad-pack"
    mkdir -p "$SCENARIO_DIR/bad"
    printf 'name=bad\nrange=10.250.0.0/16\n' > "$SCENARIO_DIR/bad/scenario.conf"
    printf 'icmp||10.250.0.1/32|10.250.0.2/32\nsctp||10.250.0.1/32|10.250.0.2/32\n' > "$SCENARIO_DIR/bad/expect.txt"
}

@test "dashboards generates a range search per scenario, a search per expect row, and an overview of exactly the range searches" {
    make_malcolm_tree "$ROOT"; malcolm_secret; use_pack
    stub_curl_osd $(ipsec_ids) $(pack_ids)
    run malcolm dashboards
    echo "$output"
    [ "$status" -eq 0 ]
    f="$ROOT/opt/malcolm/scenarios.ndjson"
    [ "$(sed -n 's/^{"id":"\([^"]*\)".*/\1/p' "$f")" = "$(pack_ids)" ]
    run python3 -c 'import json, sys
d = [json.loads(l) for l in open(sys.argv[1]) if json.loads(l)["type"] == "dashboard"][0]
print(d["attributes"]["title"]); print(" ".join(r["id"] for r in d["references"]))' "$f"
    [ "${lines[0]}" = "Lab scenarios - Overview (lab)" ]
    [ "${lines[1]}" = "$(for d in "$SCENARIO_DIR"/*/; do printf 'lab-scenario-%s ' "$(basename "$d")"; done | sed 's/ $//')" ]
    grep -q '"id":"idx-net"' "$f"
    run grep -c '__NETWORK_INDEX_PATTERN_ID__' "$f"
    [ "$output" = 0 ]
}

@test "a generated row search carries the translator's KQL; the range search, the scenario's range" {
    make_malcolm_tree "$ROOT"; malcolm_secret; use_pack
    stub_curl_osd $(ipsec_ids) $(pack_ids)
    run malcolm dashboards
    [ "$status" -eq 0 ]
    f="$ROOT/opt/malcolm/scenarios.ndjson"
    run search_of "$f" lab-scenario-bgp-row-1
    [ "${lines[0]}" = 'Scenario bgp - tcp/179 10.204.0.0/24 -> 10.204.0.0/24 (lab)' ]
    [ "${lines[1]}" = 'network.transport:tcp and (source.port:179 or destination.port:179) and source.ip:"10.204.0.0/24" and destination.ip:"10.204.0.0/24"' ]
    run search_of "$f" lab-scenario-bgp
    [ "${lines[0]}" = 'Scenario bgp - all traffic (lab)' ]
    [ "${lines[1]}" = 'source.ip:"10.204.0.0/16" or destination.ip:"10.204.0.0/16"' ]
}

@test "the generated objects are identical across runs, so a re-import overwrites rather than piles up" {
    make_malcolm_tree "$ROOT"; malcolm_secret; use_pack
    stub_curl_osd $(ipsec_ids) $(pack_ids)
    run malcolm dashboards
    [ "$status" -eq 0 ]
    cp "$ROOT/opt/malcolm/scenarios.ndjson" "$BATS_TEST_TMPDIR/first.ndjson"
    run malcolm dashboards
    [ "$status" -eq 0 ]
    cmp "$BATS_TEST_TMPDIR/first.ndjson" "$ROOT/opt/malcolm/scenarios.ndjson"
}

@test "a generated object that did not land is a FAIL that names it" {
    make_malcolm_tree "$ROOT"; malcolm_secret; use_pack
    stub_curl_osd $(ipsec_ids) $(pack_ids | grep -v '^lab-scenarios-overview$')
    run malcolm dashboards
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"MISSING dashboard/lab-scenarios-overview"* ]]
}

@test "a row the translator refuses stops dashboards before any import, naming the file and the row" {
    make_malcolm_tree "$ROOT"; malcolm_secret; bad_pack
    stub_curl_osd $(ipsec_ids)
    run malcolm dashboards
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"refusing scenarios/bad/expect.txt row 2: unknown protocol 'sctp'"* ]]
    run grep -c '_import' "$STUB_LOG"
    [ "$output" = 0 ]
}
```

- [ ] **Step 3: Run the new tests; they should fail**

Run: `bats tests/malcolm-deploy.bats --filter 'generat|refuses stops dashboards'`
Expected: FAIL. No `scenarios.ndjson` is written, and the refusal test sees status 0.

- [ ] **Step 4: Implement in `scripts/r770-malcolm-deploy.sh`**

(a) Directly after the `malcolm-api.sh` source line from Task 2, add:

```bash
# shellcheck source=lib/expect.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/expect.sh"
```

(b) Directly after the `SECRET=` line, add:

```bash
SCEN_DIR="${SCENARIO_DIR:-$KIT_DIR/scenarios}"   # the pack dashboards and arkime-views generate from
```

(c) In the header's environment list, next to the `MALCOLM_ADMIN_USER` entry, add a line in the same style: `SCENARIO_DIR  <kit>/scenarios`.

(d) Directly before `cmd_inventory() {`, add:

```bash
# ── the scenario pack's objects, generated ──────────────────────────────────
# Each scenario's range lives once, in its scenario.conf; its flows once, in
# its expect.txt. The searches and views below are generated from them through
# scripts/lib/expect.sh — the same translator r770-scenario.sh check queries
# with — so nothing under config/ restates a range.

# pack_rows — the pack as lines the generators read, every row already through
# the translator's checks: "S|<name>|<range>" per scenario, then
# "R|<name>|<n>|<proto>|<port>|<src>|<dst>" per expect.txt row. Call it with a
# redirect, never in $() or a pipe: a refusal must stop the step, and it must
# stop it before anything is imported.
pack_rows() {
    local c d s range n proto port src dst why
    for c in "$SCEN_DIR"/*/scenario.conf; do
        [ -e "$c" ] || continue
        d=$(dirname "$c"); s=$(basename "$d")
        range=$(sed -n 's/^range=//p' "$c" | head -1)
        expect_cidr "$range" || die "refusing scenarios/$s/scenario.conf: range '$range' is not an IPv4 CIDR — nothing was imported"
        [ -f "$d/expect.txt" ] || die "refusing scenarios/$s: no expect.txt — nothing was imported"
        printf 'S|%s|%s\n' "$s" "$range"
        while IFS='|' read -r n proto port src dst; do
            why=$(expect_problem "$proto" "$port" "$src" "$dst")
            [ -z "$why" ] || die "refusing scenarios/$s/expect.txt row $n: $why — nothing was imported"
            printf 'R|%s|%s|%s|%s|%s|%s\n' "$s" "$n" "$proto" "$port" "$src" "$dst"
        done < <(expect_rows "$d")
    done
}

# scenario_spec <pack-file> — "<range|row><TAB><id><TAB><title><TAB><description><TAB><kql>" per search
scenario_spec() {
    local kind a b c d e f
    while IFS='|' read -r kind a b c d e f; do
        case "$kind" in
            S) printf 'range\tlab-scenario-%s\tScenario %s - all traffic (lab)\tEverything scenario %s puts on br-lab: its whole range, %s.\tsource.ip:"%s" or destination.ip:"%s"\n' \
                   "$a" "$a" "$a" "$b" "$b" "$b" ;;
            R) printf 'row\tlab-scenario-%s-row-%s\tScenario %s - %s (lab)\tRow %s of scenarios/%s/expect.txt: a flow every traffic run must show.\t%s\n' \
                   "$a" "$b" "$a" "$(expect_label "$c" "$d" "$e" "$f")" "$b" "$a" "$(expect_kql "$c" "$d" "$e" "$f")" ;;
        esac
    done < "$1"
}

# scenario_ndjson <spec> <out> — the searches and the overview dashboard, in the
# shape of config/malcolm/dashboards/ipsec.ndjson.template: one object per
# line, {"id":…,"type":…} first, no version fields, the index pattern as the
# token render() fills. python3 writes the JSON (Malcolm's installer already
# needs it); bash would have to hand-escape a query inside a JSON string inside
# a JSON string.
scenario_ndjson() {
    python3 - "$1" "$2" <<'PY'
import json, sys
spec, out = sys.argv[1], sys.argv[2]
tight = dict(separators=(",", ":"))
cols = ["source.ip", "destination.ip", "destination.port", "network.transport", "network.protocol", "event.provider"]
ref = "kibanaSavedObjectMeta.searchSourceJSON.index"
objs, panels = [], []
for raw in open(spec):
    kind, oid, title, desc, query = raw.rstrip("\n").split("\t")
    ssj = json.dumps({"query": {"query": query, "language": "kuery"}, "filter": [], "indexRefName": ref}, **tight)
    objs.append({"id": oid, "type": "search",
                 "attributes": {"title": title, "description": desc, "hits": 0, "columns": cols,
                                "sort": [["@timestamp", "desc"]],
                                "kibanaSavedObjectMeta": {"searchSourceJSON": ssj}},
                 "references": [{"name": ref, "type": "index-pattern", "id": "__NETWORK_INDEX_PATTERN_ID__"}]})
    if kind == "range":
        panels.append(oid)
grid = [{"version": "", "gridData": {"x": 0, "y": 12 * i, "w": 48, "h": 12, "i": str(i + 1)},
         "panelIndex": str(i + 1), "embeddableConfig": {}, "panelRefName": "panel_%d" % (i + 1)}
        for i in range(len(panels))]
objs.append({"id": "lab-scenarios-overview", "type": "dashboard",
             "attributes": {"title": "Lab scenarios - Overview (lab)",
                            "description": "One panel per scenario in the kit's pack: every session in its range. The per-row searches (Scenario <name> - ...) drill down.",
                            "hits": 0, "timeRestore": False, "version": 1,
                            "optionsJSON": json.dumps({"hidePanelTitles": False, "useMargins": True}, **tight),
                            "panelsJSON": json.dumps(grid, **tight),
                            "kibanaSavedObjectMeta": {"searchSourceJSON": json.dumps({"query": {"query": "", "language": "kuery"}, "filter": []}, **tight)}},
             "references": [{"name": "panel_%d" % (i + 1), "type": "search", "id": p} for i, p in enumerate(panels)]})
with open(out, "w") as f:
    for o in objs:
        f.write(json.dumps(o, ensure_ascii=False, **tight) + "\n")
PY
}
```

(e) Replace `cmd_dashboards()` in full with:

```bash
cmd_dashboards() {
    banner "dashboards — install the kit's saved objects"
    need_root
    local dir tpl rendered idx base gen tpls=()
    dir="$KIT_CONFIG_DIR/malcolm/dashboards"
    [ -d "$dir" ] || die "no dashboards directory at $dir"
    for tpl in "$dir"/*.ndjson.template; do
        [ -e "$tpl" ] || die "no *.ndjson.template under $dir"
        tpls+=("$tpl")
    done
    if [ "$DRY" = "1" ]; then
        pack_rows > /dev/null
        for tpl in "${tpls[@]}"; do
            echo "DRY-RUN: render $(basename "$tpl"), import it, then assert every id it declares"
        done
        echo "DRY-RUN: generate the scenario pack's searches and overview from $SCEN_DIR, import them, then assert every id"
        footer "dashboards"
    fi
    # generated before any call: a refused row stops the step with nothing imported
    gen="$(home)/scenarios.ndjson.template"
    pack_rows > "$gen.pack"
    if [ -s "$gen.pack" ]; then
        scenario_spec "$gen.pack" > "$gen.tsv"
        scenario_ndjson "$gen.tsv" "$gen" || die "could not generate $gen"
        tpls+=("$gen")
    else
        note "no scenarios under $SCEN_DIR — only the kit's fixed objects"
    fi
    rm -f "$gen.pack" "$gen.tsv"
    osd_auth_file
    if ! osd_reachable; then
        skip "Dashboards did not answer on 127.0.0.1:8443 — start the stack first; nothing was changed"
        footer "dashboards"
    fi
    idx=$(resolve_index_pattern) || exit 1
    note "index pattern: $idx"
    for tpl in "${tpls[@]}"; do
        base=$(basename "${tpl%.template}")
        rendered="$(home)/$base"
        render "$tpl" "$rendered" "NETWORK_INDEX_PATTERN_ID=$idx"
        echo "+ POST /api/saved_objects/_import?overwrite=true   ($base)"
        osd_api POST "/api/saved_objects/_import?overwrite=true" -F "file=@${rendered}" > "${rendered}.result" \
            || die "the import call failed — ${rendered}.result holds what came back"
        grep -q '"success":true' "${rendered}.result" \
            || die "import did not report success for ${base} — read ${rendered}.result"
        assert_saved_objects "$rendered" || true
    done
    footer "dashboards"
}
```

- [ ] **Step 5: Run the tests; they should pass**

Run: `bats tests/malcolm-deploy.bats && shellcheck -x scripts/r770-malcolm-deploy.sh`
Expected: every test `ok`, including the pre-existing IPsec ones, and shellcheck silent.

- [ ] **Step 6: Docs**

In `docs/deployment-runbook.md`, directly after the paragraph that ends ``reading each view back by name.``, add:

```markdown
Both steps also generate the scenario pack's objects from `scenarios/`, so
each scenario's range and flows live once, in its `scenario.conf` and
`expect.txt`: a saved search and an Arkime view for its whole range
(`Scenario <name> - all traffic`), one of each per `expect.txt` row, and the
**Lab scenarios - Overview** dashboard with one panel per scenario. The
queries come from `scripts/lib/expect.sh`, the same translator
`r770-scenario.sh check` counts with. A row the translator refuses stops the
step before anything is imported, naming the file and row.
```

In `config/README.md`, append at the end of the file:

```markdown
**Generated, not carried:** the scenario pack's saved searches, Arkime views
and the Lab scenarios overview are generated by
`scripts/r770-malcolm-deploy.sh dashboards` / `arkime-views` from
`scenarios/*/scenario.conf` and `expect.txt`; no file here restates a
scenario's range.
```

- [ ] **Step 7: Run the gate and commit**

Run: `./tests/run.sh` (expected: exit 0)

```bash
git add scripts/r770-malcolm-deploy.sh tests/malcolm-deploy.bats docs/deployment-runbook.md config/README.md
git commit -m "dashboards: generate the scenario pack's searches and a Lab scenarios overview from scenarios/"
```

---

### Task 4: `arkime-views` generates the scenario pack's views

**Files:**
- Modify: `scripts/r770-malcolm-deploy.sh` (a new `scenario_views` directly after `scenario_ndjson`; `cmd_arkime_views()`)
- Modify: `tests/malcolm-deploy.bats` (new tests after Task 3's)

**Interfaces:**
- Consumes: `pack_rows` and `SCEN_DIR` (Task 3); `expect_arkime`, `expect_label` (Task 1); `arkime_api`, `osd_auth_file` (Task 2).
- Produces: `scenario_views <pack-file>`: stdout in the kit's `.views` format (`<name>|<expression>`, `#` comments).

- [ ] **Step 1: Write the failing tests.** Append after Task 3's tests:

```bash
pack_view_names() {  # every view name arkime-views should generate from $SCENARIO_DIR
    local d s n p port src dst
    for d in "$SCENARIO_DIR"/*/; do
        s=$(basename "$d"); echo "Scenario $s - all traffic"
        grep -vE '^(#|$)' "$d/expect.txt" | while IFS='|' read -r p port src dst; do
            echo "Scenario $s - $p${port:+/$port} $src -> $dst"
        done
    done
}

@test "arkime-views posts a range view and a view per expect row for every scenario, and reads them all back" {
    make_malcolm_tree "$ROOT"; malcolm_secret; use_pack
    stub_curl_osd
    { sed -n 's/^\([^#|][^|]*\)|.*/\1/p' config/malcolm/arkime-views/ipsec.views; pack_view_names; } \
        | sed 's/.*/{"name":"&"}/' | paste -sd, - | sed 's/^/[/;s/$/]/' > "$BATS_TEST_TMPDIR/views.json"
    run malcolm arkime-views
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ok      Scenario bgp - tcp/179 10.204.0.0/24 -> 10.204.0.0/24"* ]]
    [[ "$output" == *"view(s) present"* ]]
    grep -qF 'ip.protocol == tcp && port == 179 && ip.src == 10.204.0.0/24 && ip.dst == 10.204.0.0/24' "$STUB_LOG"
    grep -qF '"name":"Scenario bgp - all traffic","expression":"ip == 10.204.0.0/16"' "$STUB_LOG"
    grep -qF 'ip.protocol == 89 && ip.src == 10.203.23.0/24 && ip.dst == 224.0.0.5/32' "$STUB_LOG"
}

@test "a row the translator refuses stops arkime-views before any view is posted" {
    make_malcolm_tree "$ROOT"; malcolm_secret; bad_pack
    stub_curl_osd
    run malcolm arkime-views
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"refusing scenarios/bad/expect.txt row 2: unknown protocol 'sctp'"* ]]
    run grep -c -- '-X POST' "$STUB_LOG"
    [ "$output" = 0 ]
}
```

Note: this assumes the ospf pack's `expect.txt` row 1 is `ospf||10.203.23.0/24|224.0.0.5/32`. Verify with `head -1 scenarios/ospf/expect.txt` before running. If it differs, change only that `grep -qF` line to that row's `expect_arkime` output.

- [ ] **Step 2: Run the new tests; they should fail**

Run: `bats tests/malcolm-deploy.bats --filter 'arkime-views posts a range|stops arkime-views'`
Expected: FAIL. No scenario view names are posted, and the refusal test sees status 0.

- [ ] **Step 3: Implement.** Directly after `scenario_ndjson()`, add:

```bash
# scenario_views <pack-file> — the pack's Arkime views in the kit's .views
# format: the same expressions r770-scenario.sh check counts with
scenario_views() {
    local kind a b c d e f
    echo "# generated by r770-malcolm-deploy.sh arkime-views from scenarios/ — not edited by hand"
    while IFS='|' read -r kind a b c d e f; do
        case "$kind" in
            S) printf 'Scenario %s - all traffic|ip == %s\n' "$a" "$b" ;;
            R) printf 'Scenario %s - %s|%s\n' "$a" "$(expect_label "$c" "$d" "$e" "$f")" "$(expect_arkime "$c" "$d" "$e" "$f")" ;;
        esac
    done < "$1"
}
```

In `cmd_arkime_views()`, make four changes:

1. Change the `local` line to:

```bash
    local dir f bn line name vexpr listed gen total=0 missing=0 files=()
```

2. Replace the block from `if [ "$DRY" = "1" ]; then` through its closing `fi` with:

```bash
    for f in "$dir"/*.views; do
        [ -e "$f" ] || die "no *.views under $dir"
        files+=("$f")
    done
    if [ "$DRY" = "1" ]; then
        pack_rows > /dev/null
        for f in "${files[@]}"; do
            echo "DRY-RUN: post each view in $(basename "$f"), then read them all back"
        done
        echo "DRY-RUN: generate the scenario pack's views from $SCEN_DIR, post them, then read them all back"
        footer "arkime-views"
    fi
    # generated before any call: a refused row stops the step with nothing posted
    gen="$(home)/scenarios.views"
    pack_rows > "$gen.pack"
    if [ -s "$gen.pack" ]; then
        scenario_views "$gen.pack" > "$gen"
        files+=("$gen")
    else
        note "no scenarios under $SCEN_DIR — only the kit's fixed views"
    fi
    rm -f "$gen.pack"
```

3. In the posting loop, change `for f in "$dir"/*.views; do` and the `[ -e "$f" ] || die "no *.views under $dir"` line after it to `for f in "${files[@]}"; do`, deleting that `[ -e … ]` line.
4. In the read-back loop, change `for f in "$dir"/*.views; do` to `for f in "${files[@]}"; do`.

- [ ] **Step 4: Run the tests; they should pass**

Run: `bats tests/malcolm-deploy.bats && shellcheck -x scripts/r770-malcolm-deploy.sh`
Expected: every test `ok`, including the three pre-existing arkime-views tests, and shellcheck silent.

- [ ] **Step 5: Run the gate and commit**

Run: `./tests/run.sh` (expected: exit 0)

```bash
git add scripts/r770-malcolm-deploy.sh tests/malcolm-deploy.bats
git commit -m "arkime-views: generate the scenario pack's views from scenarios/"
```

---

### Task 5: `r770-scenario.sh check`

**Files:**
- Modify: `scripts/r770-scenario.sh`:
  - the header (lines 11–27);
  - the source lines after line 38;
  - globals near line 44;
  - a new `# ── check ──` section directly before `# ── status ──`;
  - dispatch.
- Modify: `tests/scenario.bats` (new helpers and tests at the end of the file)
- Modify: `docs/deployment-runbook.md` (the scenarios section)

**Interfaces:**
- Consumes: Task 1's `expect_rows`, `expect_problem`, `expect_arkime`, `expect_label`; Task 2's `osd_auth_file`, `arkime_api`, `MALCOLM_SECRET_FILE`; the existing `scenario_check`, `SCEN_DIR`, `p`.
- Produces: `r770-scenario.sh check <name> [--run <file>]`, with the exit code from `footer`.

- [ ] **Step 1: Write the failing tests.** Append to the end of `tests/scenario.bats`:

```bash
# ── check ────────────────────────────────────────────────────────────────────
# Arkime is a curl stub: counts.tsv maps an expression to its session count;
# late.tsv gives an expression's count only from its second query on (the
# session was indexed while the check waited). arkime-down makes every call
# fail; arkime-html makes the sessions answer a login page.

arkime_stub() {
    printf 'fixture-malcolm-pw\n' > "$ROOT/etc/lab/secrets/malcolm-admin.pw"
    : > "$BATS_TEST_TMPDIR/counts.tsv"
    printf 'tcp|80|10.209.0.1/32|10.209.0.2/32\n' >> "$SCENARIO_DIR/demo/expect.txt"
    stub curl "$(cat <<'EOF'
echo "curl $*" >> "$STUB_LOG"
T="$BATS_TEST_TMPDIR"; ex=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    --data-urlencode) case "$2" in expression=*) ex=${2#expression=} ;; esac; shift ;;
    https://*) url=$1 ;;
  esac
  shift
done
[ -e "$T/arkime-down" ] && exit 7
case "$url" in
  */arkime/api/user/views) echo '[]' ;;
  */arkime/api/sessions)
    [ -e "$T/arkime-html" ] && { printf '<!DOCTYPE html>\n401'; exit 0; }
    k=$(printf '%s' "$ex" | sha256sum | cut -c1-16)
    m=$(( $(cat "$T/q-$k" 2>/dev/null || echo 0) + 1 )); echo "$m" > "$T/q-$k"
    c=$(awk -F'\t' -v e="$ex" '$1 == e {print $2}' "$T/counts.tsv")
    l=$(awk -F'\t' -v e="$ex" '$1 == e {print $2}' "$T/late.tsv" 2>/dev/null)
    if [ -n "$l" ] && [ "$m" -ge 2 ]; then c=$l; fi
    printf '{"recordsTotal":9,"recordsFiltered":%s,"data":[]}\n200' "${c:-0}" ;;
  *) exit 7 ;;
esac
EOF
)"
}

ROW1='ip.protocol == icmp && ip.src == 10.209.0.0/24 && ip.dst == 10.209.0.0/24'
ROW2='ip.protocol == tcp && port == 80 && ip.src == 10.209.0.1/32 && ip.dst == 10.209.0.2/32'
count() { printf '%s\t%s\n' "$1" "$2" >> "$BATS_TEST_TMPDIR/${3:-counts}.tsv"; }

run_record() {  # run_record <scenario> [<suffix>] [no-end] — a run record in the evidence dir; prints its path
    mkdir -p "$KIT_EVIDENCE_DIR"
    local f="$KIT_EVIDENCE_DIR/scenario-$1-fixturehost-${2:-20260101-000100}.run"
    printf 'scenario=%s\nrange=10.209.0.0/16\nstart=2026-01-01T00:00:00Z\n' "$1" > "$f"
    [ "${3:-}" = no-end ] || printf 'end=2026-01-01T00:01:00Z\nsecs=60\n' >> "$f"
    printf '%s' "$f"
}

@test "check PASSes every row with sessions in the run's window, with bounding=either and never date=" {
    arkime_stub; run_record demo >/dev/null
    count "$ROW1" 3; count "$ROW2" 7
    run scenario check demo
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  demo row 1 icmp 10.209.0.0/24 -> 10.209.0.0/24: 3 session(s) in 2026-01-01T00:00:00Z–2026-01-01T00:01:00Z"* ]]
    [[ "$output" == *"PASS  demo row 2 tcp/80 10.209.0.1/32 -> 10.209.0.2/32: 7 session(s)"* ]]
    grep -q -- '--data-urlencode bounding=either' "$STUB_LOG"
    grep -q -- "--data-urlencode startTime=$(date -u -d 2026-01-01T00:00:00Z +%s)" "$STUB_LOG"
    grep -q -- "--data-urlencode stopTime=$(date -u -d 2026-01-01T00:01:00Z +%s)" "$STUB_LOG"
    run grep -c 'date=' "$STUB_LOG"
    [ "$output" = 0 ]
}

@test "a row with no sessions after the wait is a FAIL that points at the mirror first; a passed row is not asked again" {
    arkime_stub; run_record demo >/dev/null
    count "$ROW1" 3
    SCENARIO_CHECK_WAIT_SECS=20 run scenario check demo
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"PASS  demo row 1"* ]]
    [[ "$output" == *"FAIL  demo row 2 tcp/80 10.209.0.1/32 -> 10.209.0.2/32: 0 sessions after 20s"* ]]
    [[ "$output" == *"tcpdump -ni lab_mirror0 'tcp port 80 and src net 10.209.0.1/32 and dst net 10.209.0.2/32'"* ]]
    [[ "$output" == *"r770-validate.sh --area capture"* ]]
    run grep -cF "expression=$ROW1" "$STUB_LOG"
    [ "$output" = 1 ]
}

@test "a count that appears while check waits is a PASS" {
    arkime_stub; run_record demo >/dev/null
    count "$ROW1" 3; count "$ROW2" 5 late
    run scenario check demo
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS  demo row 2 tcp/80 10.209.0.1/32 -> 10.209.0.2/32: 5 session(s)"* ]]
}

@test "an answer with no session count is a FAIL naming the HTTP status, never a zero" {
    arkime_stub; run_record demo >/dev/null
    touch "$BATS_TEST_TMPDIR/arkime-html"
    SCENARIO_CHECK_WAIT_SECS=0 run scenario check demo
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  demo row 1 icmp 10.209.0.0/24 -> 10.209.0.0/24: Arkime's answer had no session count (HTTP 401)"* ]]
    [[ "$output" != *"0 sessions"* ]]
}

@test "check SKIPs, and changes nothing, when Arkime does not answer, when there is no credential, and when there is no run" {
    arkime_stub; run_record demo >/dev/null
    touch "$BATS_TEST_TMPDIR/arkime-down"
    run scenario check demo
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  Arkime did not answer on 127.0.0.1:8443 — start Malcolm (r770-malcolm-deploy.sh start)"* ]]
    rm -f "$BATS_TEST_TMPDIR/arkime-down" "$ROOT/etc/lab/secrets/malcolm-admin.pw"
    run scenario check demo
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  no Malcolm credential at /etc/lab/secrets/malcolm-admin.pw — Malcolm is not set up here"* ]]
    rm -f "$KIT_EVIDENCE_DIR"/scenario-demo-*.run
    run scenario check demo
    [ "$status" -eq 0 ]
    [[ "$output" == *"SKIP  no run record — run r770-scenario.sh traffic demo first"* ]]
}

@test "check refuses a record of another scenario or an unfinished one; --run picks the record named" {
    arkime_stub
    count "$ROW1" 3; count "$ROW2" 7
    other=$(run_record needs-ike)
    run scenario check demo --run "$other"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is a run of 'needs-ike', not demo"* ]]
    open=$(run_record demo 20260101-000200 no-end)
    run scenario check demo --run "$open"
    [ "$status" -eq 1 ]
    [[ "$output" == *"has no start= or end= — the traffic run did not finish"* ]]
    done_rec=$(run_record demo 20260101-000100)
    run scenario check demo --run "$done_rec"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"run record: $done_rec"* ]]
}

@test "check sends the Malcolm credential through a netrc, never argv or the transcript" {
    arkime_stub; run_record demo >/dev/null
    count "$ROW1" 3; count "$ROW2" 7
    run scenario check demo
    [ "$status" -eq 0 ]
    [[ "$output" != *"fixture-malcolm-pw"* ]]
    run grep -c 'fixture-malcolm-pw' "$STUB_LOG"
    [ "$output" = 0 ]
    grep -q -- '--netrc-file' "$STUB_LOG"
}
```

- [ ] **Step 2: Run the tests; they should fail**

Run: `bats tests/scenario.bats --filter 'check'`
Expected: FAIL with `unknown subcommand: check`.

- [ ] **Step 3: Implement in `scripts/r770-scenario.sh`**

(a) Header. After the `status` line (`#   status          which scenarios are up, …`), add:

```bash
#   check <name>    judge the newest traffic run in Malcolm: every expect.txt
#                   row must show sessions in Arkime within the run's window
```

After the `--force` line, add:

```bash
#   --run <file>    check: judge this run record instead of the newest
```

Change `#   SCENARIO_WAIT_SECS 120 · SCENARIO_TRAFFIC_SECS (default: the scenario's` to `#   SCENARIO_WAIT_SECS 120 · SCENARIO_CHECK_WAIT_SECS 180 · SCENARIO_TRAFFIC_SECS (default: the scenario's`.

(b) After the `. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"` line, add:

```bash
# shellcheck source=lib/expect.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/expect.sh"
# shellcheck source=lib/malcolm-api.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/malcolm-api.sh"
```

(c) Change `TAPS=""; TAP_A=""; TAP_B=""` to `TAPS=""; TAP_A=""; TAP_B=""; RUN_FILE=""`.

(d) Directly before `# ── status ──`, add:

```bash
# ── check ────────────────────────────────────────────────────────────────────
# Each expect.txt row, as the Arkime expression the kit's generated views use
# (scripts/lib/expect.sh), counted over the run record's window through
# Arkime's session API. bounding=either (the session overlaps the window): a
# long-lived session -- BGP, an IKE SA -- starts before the window and is saved
# after it, and Arkime's default (last packet in range) counts it 0; measured
# on staging VM 9770. date= is never sent: date=-1 means all time. Uses only
# the Malcolm netrc (scripts/lib/malcolm-api.sh, which sets the EXIT trap), never
# the GNS3 work dir.
arkime_count() {  # arkime_count <expression> <start-epoch> <stop-epoch> — the count; non-zero with the HTTP status instead
    local body code n
    body=$(arkime_api GET "/api/sessions" -G -w '\n%{http_code}' \
        --data-urlencode "expression=$1" --data-urlencode "startTime=$2" --data-urlencode "stopTime=$3" \
        --data-urlencode "bounding=either" --data-urlencode "length=1" 2>/dev/null) || true
    code=${body##*$'\n'}
    n=$(printf '%s' "$body" | sed -n 's/.*"recordsFiltered":\([0-9][0-9]*\).*/\1/p' | head -1)
    if [ -z "$n" ]; then printf '%s' "${code:-none}"; return 1; fi
    printf '%s' "$n"
}
row_bpf() {  # row_bpf <proto> <port> <src> <dst> — the tcpdump filter that shows one row on the mirror
    local p=$1
    [ "$p" = ospf ] && p="proto ospf"
    printf '%s%s and src net %s and dst net %s' "$p" "${2:+ port $2}" "$3" "$4"
}
cmd_check() {
    banner "check — $NAME"
    need_root
    scenario_check "$NAME"
    local ev="${KIT_EVIDENCE_DIR:-$PWD/r770-evidence}" wait="${SCENARIO_CHECK_WAIT_SECS:-180}" waited=0
    local rec start end s e r n proto port src dst why c pending lbl rows=()
    local -A cnt=()
    case "$wait" in ''|*[!0-9]*) die "SCENARIO_CHECK_WAIT_SECS must be whole seconds (got '$wait')" ;; esac
    [ -f "$SCEN_DIR/$NAME/expect.txt" ] || die "scenarios/$NAME has no expect.txt — nothing to check"
    while IFS= read -r r; do
        IFS='|' read -r n proto port src dst <<< "$r"
        why=$(expect_problem "$proto" "$port" "$src" "$dst")
        [ -z "$why" ] || die "refusing scenarios/$NAME/expect.txt row $n: $why"
        rows+=("$r")
    done < <(expect_rows "$SCEN_DIR/$NAME")
    rec=${RUN_FILE:-$(find "$ev" -maxdepth 1 -name "scenario-$NAME-*.run" 2>/dev/null | sort | tail -1)}
    if [ -z "$rec" ]; then skip "no run record — run r770-scenario.sh traffic $NAME first"; footer "check"; fi
    [ -f "$rec" ] || die "no run record at $rec"
    r=$(sed -n 's/^scenario=//p' "$rec" | head -1)
    [ "$r" = "$NAME" ] || die "$rec is a run of '$r', not $NAME"
    start=$(sed -n 's/^start=//p' "$rec" | head -1); end=$(sed -n 's/^end=//p' "$rec" | head -1)
    { [ -n "$start" ] && [ -n "$end" ]; } || die "$rec has no start= or end= — the traffic run did not finish; rerun r770-scenario.sh traffic $NAME"
    s=$(date -u -d "$start" +%s 2>/dev/null) || die "$rec: start '$start' is not a timestamp"
    e=$(date -u -d "$end" +%s 2>/dev/null) || die "$rec: end '$end' is not a timestamp"
    note "run record: $rec ($start – $end)"
    if [ ! -s "$(p "$MALCOLM_SECRET_FILE")" ]; then
        skip "no Malcolm credential at $MALCOLM_SECRET_FILE — Malcolm is not set up here (r770-malcolm-deploy.sh secrets)"
        footer "check"
    fi
    osd_auth_file
    if ! arkime_api GET "/api/user/views" --fail >/dev/null 2>&1; then
        skip "Arkime did not answer on 127.0.0.1:8443 — start Malcolm (r770-malcolm-deploy.sh start)"
        footer "check"
    fi
    # Arkime writes a session when it closes or at its periodic save, so an
    # immediate check can be early: ask again every 10s for rows still at 0
    while :; do
        pending=0
        for r in "${rows[@]}"; do
            IFS='|' read -r n proto port src dst <<< "$r"
            case "${cnt[$n]:-}" in ''|0|ERR*) ;; *) continue ;; esac
            if c=$(arkime_count "$(expect_arkime "$proto" "$port" "$src" "$dst")" "$s" "$e"); then cnt[$n]=$c; else cnt[$n]="ERR$c"; fi
            case "${cnt[$n]}" in 0|ERR*) pending=$((pending + 1)) ;; esac
        done
        [ "$pending" -eq 0 ] && break
        [ "$waited" -ge "$wait" ] && break
        sleep 10; waited=$((waited + 10))
    done
    for r in "${rows[@]}"; do
        IFS='|' read -r n proto port src dst <<< "$r"
        lbl=$(expect_label "$proto" "$port" "$src" "$dst")
        case "${cnt[$n]}" in
            ERR*) fail "$NAME row $n $lbl: Arkime's answer had no session count (HTTP ${cnt[$n]#ERR}) — is 127.0.0.1:8443 Malcolm, and is the kit's user an Arkime user?" ;;
            0)    fail "$NAME row $n $lbl: 0 sessions after ${waited}s"
                  note "first, is the flow on the mirror while traffic runs? tcpdump -ni lab_mirror0 '$(row_bpf "$proto" "$port" "$src" "$dst")'"
                  note "then, is Malcolm capturing? r770-validate.sh --area capture" ;;
            *)    pass "$NAME row $n $lbl: ${cnt[$n]} session(s) in $start–$end" ;;
        esac
    done
    footer "check"
}
```

(e) Dispatch. Change `up|traffic|down) case "${1:-}" in -*|"") ;; *) NAME=$1; shift ;; esac ;;` to `up|traffic|down|check) case "${1:-}" in -*|"") ;; *) NAME=$1; shift ;; esac ;;`.

In the option loop, add after the `--taps` line:

```bash
        --run)     RUN_FILE="${2:-}"; shift ;;
```

In the subcommand case, change `up|traffic|down)` to `up|traffic|down|check)`.

- [ ] **Step 4: Run the tests; they should pass**

Run: `bats tests/scenario.bats && shellcheck -x scripts/r770-scenario.sh`
Expected: every test `ok` (existing and new), and shellcheck silent.

- [ ] **Step 5: Runbook.** In `docs/deployment-runbook.md`'s `## Scenarios` code block, add after the `traffic ospf` line:

```bash
sudo ./scripts/r770-scenario.sh check ospf              # every expect.txt row, as Arkime sessions in the run's window
```

Directly after the paragraph that starts `A scenario's \`expect.txt\` lists the flows`, add a new paragraph:

```markdown
`check` judges a finished run end to end. It reads the newest run record
(or `--run <file>`) and counts each `expect.txt` row in Arkime over the
run's window — the same expressions as the generated `Scenario <name> - …`
views — PASS above zero, FAIL at zero after `SCENARIO_CHECK_WAIT_SECS`
(180 s; Arkime indexes a session when it closes or at its periodic save).
A FAIL points at the mirror first, with the `tcpdump` filter for that row.
It counts sessions that *overlap* the window, because a BGP session or an
IKE SA outlives a traffic run. It SKIPs, with the reason, when Malcolm is
not answering or there is no run to judge.
```

- [ ] **Step 6: Run the gate and commit**

Run: `./tests/run.sh` (expected: exit 0)

```bash
git add scripts/r770-scenario.sh tests/scenario.bats docs/deployment-runbook.md
git commit -m "r770-scenario.sh check: judge a traffic run's expect.txt rows in Arkime over its window"
```

---

### Task 6: Staging proof on VM 9770 (controller, not a subagent)

This task needs SSH to the staging VM and must be run by the controlling session. It is not bats work.

- [ ] **Step 1: Sync and deploy the objects.**
  - Copy the kit to the VM: `tar -c scripts scenarios config | ssh ubuntu@192.168.4.78 'tar -x -C ~/sim-lab-basic'`.
  - Run `sudo ./scripts/r770-malcolm-deploy.sh dashboards` and `sudo ./scripts/r770-malcolm-deploy.sh arkime-views`.
  - Expected: both READY; the scenario objects are all `ok`; the IPsec objects are unchanged.
- [ ] **Step 2: Check every scenario.** For each of `client-server ipsec-esp ipsec-ike ospf bgp`, run `up … --bundle /srv/bundles/bundle-20260925`, then `traffic`, then `check`, then `down`.
  - Expected: `check` READY, with every row PASS.
  - A FAIL is a finding. Diagnose it one change at a time (CLAUDE.md rule 7), starting with the row's `tcpdump` filter.
- [ ] **Step 3: Verify the dashboard.**
  - Through the portal, open "Lab scenarios - Overview (lab)" for the rehearsal's time range, and confirm each panel lists its scenario's sessions. This also proves KQL accepts `source.ip:"<cidr>"`.
  - Open one row search per scenario, and confirm Arkime's `Scenario <name> - …` views return the run's sessions.
  - Record what was seen.
- [ ] **Step 4: Carry the record back.**
  - Add the transcripts' verdict lines to the build repo's rehearsal record: an addendum section in `state/inventory/staging-kit-rehearsal-2026-09-26.md` on the simlab-build branch, plus one BUILD-STATE log line.
  - Push both branches and open the kit PR (base: `rehearsal-fixes`, or `main` once PR #5 merges).

---

## Addendum (2026-09-26, user-approved after the staging proof)

### Task 7: ESP visibility, direction-aware rows, check's wait

The brief used for execution is reproduced here as the record.


Context: the staging proof (Task 6) on VM 9770, against the live Malcolm (Arkime 5), measured three facts. Build to them.

1. **Malcolm's Arkime tracks no ESP** (IP protocol 50) by default, and Zeek's conn log has no ESP. So no session from the ESP scenarios existed at all. Appending `ARKIME_default__trackESP=true` to `/opt/malcolm/malcolm/config/arkime.env` fixed it: both Arkime containers load that env file, and Arkime 5 reads `ARKIME_<section>__<key>` env overrides. Afterwards the ESP flow appeared as a session. This held only after Malcolm's `stop`/`start`, which recreates the containers. The installer rewrites the `config/*.env` files on every configure run, so the setting has to be re-applied after each installer run, just as `rebind` re-applies its compose edit.
2. **Arkime sessions are bidirectional**, oriented by the first packet. The live ESP session was `10.201.0.1 -> 10.201.0.2`, with `source.packets` 7818 and `destination.packets` 2182. The expect row `esp||10.201.0.2/32|10.201.0.1/32` has no session of its own; its packets are the destination half of that session.

   Verified live, this expression matches the session for **both** rows of the pair:

   `ip.protocol == 50 && ((ip.src == S && ip.dst == D) || (ip.src == D && ip.dst == S && packets.dst > 0))`

   (with S and D the row's src and dst).
3. **Arkime indexes about 10 minutes late on this Malcolm.** Arkime is not capturing live (`ARKIME_LIVE_CAPTURE=false`). netsniff writes PCAP files that rotate every `PCAP_ROTATE_MINUTES` (10, set in `/opt/malcolm/malcolm/config/pcap-capture.env`), and Arkime indexes each file after it closes. The ESP session appeared within 20 minutes; `check`'s 180 s default missed it.

## Requirements

### A — `r770-malcolm-deploy.sh configure` turns ESP tracking on (scripts/r770-malcolm-deploy.sh, tests/malcolm-deploy.bats, tests/helpers/fixtures.bash)

- **New function `track_esp`.** It makes `$(stack)/config/arkime.env` contain exactly one line `ARKIME_default__trackESP=true`:
  - if that exact line is already there: PASS `trackESP already on in <file>`;
  - if some other `ARKIME_default__trackESP=` line is there: replace it, and PASS `trackESP turned on in <file> (was: <old value>)`;
  - otherwise append the line, and PASS `trackESP turned on in <file> — ESP (IP protocol 50) becomes an Arkime session`.
  - If `arkime.env` is missing: FAIL naming the file ("the installer did not write it"), not die.
  - Under `--dry-run` it prints `DRY-RUN: set ARKIME_default__trackESP=true in <file>` and changes nothing.
- **Where it runs.** Call it from `cmd_configure` right after the `live_kept` / `pcap/upload` block and before `do_rebind`, whether or not live capture is on. ESP scenarios can reach Malcolm through uploaded PCAP too. Keep the file's mode and owner: edit in place with `sed -i` or an append, never by recreating the file.
- **Comment above it.** State why:
  - Malcolm ships no knob for this;
  - Arkime 5 reads `ARKIME_<section>__<key>` from the environment;
  - the installer rewrites `config/*.env` on every run;
  - it was measured on VM 9770, 2026-09-26.
- **Fixture.** `make_malcolm_tree` creates `$home/malcolm/config/arkime.env` with two synthetic lines, e.g. `ARKIME_FREESPACEG=` and `ARKIME_ROTATE_INDEX=daily`, as the installer would.
- **Tests:**
  - configure appends the line once;
  - a second configure leaves exactly one line (`grep -c` = 1) and says "already on";
  - a pre-existing `ARKIME_default__trackESP=false` is replaced, not duplicated;
  - a missing `arkime.env` is a FAIL naming it;
  - `--dry-run` changes nothing.
- **Runbook.** In `docs/deployment-runbook.md`'s Malcolm configure paragraph, add one or two sentences saying `configure` sets `ARKIME_default__trackESP=true` in `config/arkime.env` after every installer run, and why: without it ESP traffic is never an Arkime session, and the IPsec "ESP payload" search and view stay empty.

### B — rows match either orientation (scripts/lib/expect.sh, tests/expect.bats, tests that assert generated queries)

- **`expect_arkime <proto> <port> <src> <dst>`** becomes
  `<proto clause>[ && port == N] && ((ip.src == S && ip.dst == D) || (ip.src == D && ip.dst == S && packets.dst > 0))`
- **`expect_kql`** becomes
  `<proto clause>[ and (source.port:N or destination.port:N)] and ((source.ip:"S" and destination.ip:"D") or (source.ip:"D" and destination.ip:"S" and destination.packets > 0))`
- **Header comment.** Put a short comment above the two functions saying why: Arkime and Zeek record one bidirectional session per flow, oriented by its first packet. A row's direction is proven either by a session oriented that way, or by the reply half (`packets.dst`/`destination.packets` above 0) of a session opened the other way.
- **Tests.** Update the exact-string expectations in `tests/expect.bats` for Arkime and KQL. Also update the tests that assert generated queries or expressions:
  - `tests/malcolm-deploy.bats`: the bgp row-1 KQL, and the views `grep -qF` expressions;
  - `tests/scenario.bats`: `ROW1`/`ROW2`, which must equal `expect_arkime`'s new output exactly because the stub keys on the expression.

  These edits are required by the contract change; say so in the report.
- **Views.** A view expression now contains `||`, `(`, `)` and `>`. Confirm the `.views` reader still splits name from expression at the first `|` only (`name=${line%%|*}; vexpr=${line#*|}`), and that no guard refuses those characters in expressions. Add one test asserting a generated view's posted expression contains the `||` alternative intact.

### C — `check`'s default wait follows this Malcolm's PCAP rotation (scripts/r770-scenario.sh, tests/scenario.bats)

- **When `SCENARIO_CHECK_WAIT_SECS` is unset:**
  - Read `PCAP_ROTATE_MINUTES` from `$(p "${MALCOLM_HOME:-/opt/malcolm}/malcolm/config/pcap-capture.env")` (last matching `PCAP_ROTATE_MINUTES=<digits>` line).
  - If it is found, the wait is `minutes*60 + 180`, printed as `note "waiting up to <N>s for Arkime: it indexes PCAP when netsniff rotates it (PCAP_ROTATE_MINUTES=<m>)"`.
  - If the file or the value is absent or not digits, use 180 with `note "waiting up to 180s (no PCAP_ROTATE_MINUTES in <file>)"`.
- **When `SCENARIO_CHECK_WAIT_SECS` is set,** it wins, with its existing validation.
- **Tests (all with `sleep` stubbed, as today):**
  - with a fixture `pcap-capture.env` holding `PCAP_ROTATE_MINUTES=1`, a row whose count never arrives FAILs `after 240s`;
  - with no file, `after 180s`;
  - `SCENARIO_CHECK_WAIT_SECS=20` still gives `after 20s`.
- **Header and runbook.** Update the usage header line (`SCENARIO_CHECK_WAIT_SECS 180` becomes something like `SCENARIO_CHECK_WAIT_SECS (default: PCAP_ROTATE_MINUTES*60+180, else 180)`), and the runbook's `check` paragraph, which currently says 180 s.

### Also

- **Spec.** Update `docs/superpowers/specs/2026-09-26-scenario-dashboards-and-check-design.md`:
  - the translation-rules table (the either-orientation clause);
  - the check section's wait;
  - an evidence line recording facts 1–3 above.
- **Commits.** One commit per requirement (A, B, C). Each commit keeps `./tests/run.sh` green: shellcheck no exclusions, no version numbers, only 127.0.0.1 URLs, no secrets on argv.
