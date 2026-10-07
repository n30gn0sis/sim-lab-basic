# IPsec & Simulated-WAN Scenarios — Implementation Plan (increment 1: S0, S1 over W1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `r770-scenario.sh record s1-w1-ss` leaves a reference set (outer + inner PCAP, ground truth, manifest, checksums) for IKEv2/ESP over a simulated single-ISP WAN, and `verify` + `ingest` + `check` judge it on the box and in Malcolm — spec phases IP0–IP4, with IP5–IP9 as a dependency-ordered roadmap.

**Architecture:** Two new pack scenarios (`s0-w1`, `s1-w1-ss`) on the existing one-mirrored-link model (gw-a's uplink on `br-lab` through two kit TAPs); a WAN-impairment script that shapes only kit TAPs; `r770-scenario.sh` gains `record`, `verify`, `ingest`. Inner capture is the host's `tcpdump` inside the gateway's network namespace, so it never touches the mirrored bridge. No new daemons, images or bridges.

**Tech Stack:** bash ≥ 4.4, coreutils, iproute2 (`tc`, `nsenter` from util-linux), `tcpdump`, `tshark` (both in the bundle's dependency manifest), python3 (JSON), bats-core, shellcheck. strongSwan and FRR images already pinned in the bundle.

**Spec:** `docs/superpowers/specs/2026-09-24-ipsec-scenarios-spec.md` (the build repo's 0.1 draft, filed with its pins redacted) and `docs/superpowers/specs/2026-10-07-ipsec-wan-scenarios-kit-design.md` (how the kit as built carries it out — the plan argues from both; read the design note first, it overrides the spec where they differ).

## Global Constraints

- Every rule in `CLAUDE.md` holds: discover, never guess (TAPs come from the GNS3 API, interfaces from `run.conf`, never a literal); gates print current · proposed · rollback and need `--yes`; the verifier is the bundle's; **one pin owner** (`staging/r770-offline-fetch.sh`, edited only in simlab-build — this plan adds no image, no deb and no version anywhere); no secrets on argv or in git; `0 / 2 / 1` exits; `PASS  / WARN  / FAIL  / SKIP  `; evidence under `r770-evidence/`.
- `./tests/run.sh` green before every commit: shellcheck with **no exclusions**, every suite.
- A new kit script gets the `KIT_*` seams via `scripts/lib/common.sh`, a bats suite, a `README.md` row, an `allow` entry in `.claude/settings.json`, and a row in `docs/CODEMAPS/stages.md`'s operator-tools table.
- `staging/` and `docs/wiki/` are never edited here (build-repo content); decisions they need go into `docs/kit-sync.md`'s carry-back list.
- Tests never see the real host: stubbed `PATH` (`tests/helpers/stubs.bash`), fake root under `KIT_ROOT`, fake GNS3 (`tests/helpers/fake_gns3.py`), `0.0.0-fixture` versions only.
- Scenario names: `s0-w1`, `s1-w1-ss`. Ranges: `s0-w1` = `198.18.10.0/24 10.210.0.0/16`; `s1-w1-ss` = `198.18.11.0/24 10.211.0.0/16`. Addresses per the design note's table.
- WAN profile values are the wiki's (`docs/wiki/wan.md`) and the spec §6.2's; they are **parameters, not pins**, and live in `config/wan/profiles/<name>.conf`.
- `r770-wan.sh` touches only names matching `^lab-tap[0-9]+$` that exist under `/sys/class/net` (through `p()`).
- Run directories: `${SCENARIO_CASES_DIR:-/data/pcap/cases}/<name>/<run-id>/`, `run-id` = `<name>-$(date -u +%Y%m%dT%H%MZ)`. Free-space floor `SCENARIO_CASES_MIN_FREE_MB` default `10240`.
- `run.conf` and `events.log` are key=value / pipe-separated text; no YAML.
- Key material (`gt/`) never enters git (`.gitignore`) and never reaches Malcolm (`ingest` copies `outer-*.pcapng` and `inner-*.pcapng` only).
- Never push or merge without the operator's go-ahead.

## Review Focus

1. **Ctrl-C during `record`, between capture start and traffic end.** A person expects no `tcpdump` left running and no qdisc left on any TAP; the partial run directory stays for inspection with `run.conf` marking `end=interrupted`. Pinned in Task 6 ("record's EXIT trap stops every capture and clears every qdisc it applied").
2. **`record` on a scenario that has no `inner_capture=` or `gt=` keys** (any of the eight existing scenarios). A person expects an outer-only run that still verifies and ingests, not a refusal. Pinned in Task 6 ("record works with outer capture alone").
3. **A profile file with a typo (`rate=20mbps`, a missing key, a key tc does not know).** `r770-wan.sh apply` must refuse before touching any qdisc, naming the key. Pinned in Task 3.
4. **`--impair branch-wan@c`, `--impair @a`, a profile that does not exist.** Refused before captures start — nothing to clean up. Pinned in Task 7.
5. **`ingest` of a run directory that contains only `gt/` (captures lost) or `outer-*.pcapng` of zero bytes.** A person expects FAIL naming the file, and nothing in the drop-off. Pinned in Task 10.

---

## Part 1 — the kit (`/root/git/sim-lab-basic`, branch `offline-installer` or a new `ipsec-wan-scenarios` branch off it)

### Task 1: File the spec and the design; point the docs at them

**Files:**
- Create: `docs/superpowers/specs/2026-09-24-ipsec-scenarios-spec.md` (the build repo's draft, verbatim, with a provenance note)
- Create: `docs/superpowers/specs/2026-10-07-ipsec-wan-scenarios-kit-design.md`
- Create: `docs/superpowers/plans/2026-10-07-ipsec-wan-scenarios.md` (this file)
- Modify: `docs/deployment-runbook.md` (an "IPsec & WAN scenarios" section after "End to end", status NOT STARTED, pointing at the three files)
- Modify: `README.md` (one sentence under the scenario paragraph)
- Modify: `docs/kit-sync.md` (carry-backs: inner capture in-namespace, one 198.18 slice per scenario, MOBIKE float, the WAN profiles, `lab-transit.sh` deferred)

**Interfaces:**
- Produces: the three documents every later task cites. `tests/references.bats` only scans `docs/*.md`, so the runbook may name `docs/superpowers/...` paths (they exist) but must not name `scripts/r770-wan.sh` as a path until Task 3 creates it — write it as `r770-wan.sh` (no `scripts/` prefix) until then.

- [x] **Step 1:** Copy the attached spec to `docs/superpowers/specs/2026-09-24-ipsec-scenarios-spec.md`; prepend the provenance note naming the design and the plan.
- [x] **Step 2:** Write the design note (decision table, topology table, `record`/`verify`/`ingest` contracts, risks).
- [x] **Step 3:** Write this plan.
- [x] **Step 4:** Runbook section, README sentence, kit-sync carry-backs (done in this session; see those files).
- [x] **Step 5:** Run `bats tests/references.bats` — every named path exists.
- [ ] **Step 6: Commit**

```bash
git add docs/superpowers/specs/2026-09-24-ipsec-scenarios-spec.md docs/superpowers/specs/2026-10-07-ipsec-wan-scenarios-kit-design.md docs/superpowers/plans/2026-10-07-ipsec-wan-scenarios.md docs/deployment-runbook.md README.md docs/kit-sync.md
git commit -m "Spec and plan: IPsec & simulated-WAN scenarios on the kit's scenario pack — S0/S1 over W1 first, roadmap for the rest"
```

---

### Task 2: `range=` is a list — the content lint and the driver accept several CIDRs per scenario

**Files:**
- Modify: `tests/helpers/lint_scenarios.py` (`check_addresses`, `check_expect`, `main`'s uniqueness)
- Modify: `tests/scenarios.bats` (new test: a two-range fixture passes; overlapping ranges across scenarios fail)
- Modify: `scripts/r770-scenario.sh` (nothing functional: `conf range` is printed and recorded as is; `list`'s column widens to 36)
- Modify: `docs/deployment-runbook.md` (Scenarios paragraph: "one or more ranges")

**Interfaces:**
- Consumes: `scenario.conf`'s `range=` key.
- Produces: `range=` = space-separated CIDRs. Lint rule: every IPv4 literal in `scenario.conf`, `traffic.sh`, `expect.txt`, `nodes/*` lies in the union; `expect.txt` src/dst inside the union; no CIDR of one scenario overlaps any CIDR of another.

- [ ] **Step 1: Write the failing tests** (append to `tests/scenarios.bats`)

```bash
@test "the layout lint accepts a range list and rejects a CIDR shared between scenarios" {
    d="$BATS_TEST_TMPDIR/pack"; mkdir -p "$d"
    for s in one two; do
        mkdir -p "$d/$s/project" "$d/$s/nodes"
        cp scenarios/client-server/project/client-server.gns3 "$d/$s/project/$s.gns3"
        printf 'name=%s\ndescription=x\nimages=netshoot\ntraffic_secs=10\nready=cl|true\ntraffic_nodes=cl\n' "$s" > "$d/$s/scenario.conf"
        printf '#!/bin/sh\nping -c 1 198.18.10.2\n' > "$d/$s/traffic.sh"
        printf 'icmp||198.18.10.0/30|10.210.1.0/24\n' > "$d/$s/expect.txt"
    done
    echo 'range=198.18.10.0/24 10.210.0.0/16' >> "$d/one/scenario.conf"
    echo 'range=198.18.11.0/24 10.211.0.0/16' >> "$d/two/scenario.conf"
    printf '#!/bin/sh\nping -c 1 198.18.11.2\n' > "$d/two/traffic.sh"
    printf 'icmp||198.18.11.0/30|10.211.1.0/24\n' > "$d/two/expect.txt"
    SCENARIO_ROOT="$d" run python3 tests/helpers/lint_scenarios.py layout; echo "$output"; [ "$status" -eq 0 ]
    SCENARIO_ROOT="$d" run python3 tests/helpers/lint_scenarios.py addresses; echo "$output"; [ "$status" -eq 0 ]
    SCENARIO_ROOT="$d" run python3 tests/helpers/lint_scenarios.py expect; echo "$output"; [ "$status" -eq 0 ]
    # the second scenario claims a slice inside the first's /16
    sed -i 's|^range=.*|range=198.18.11.0/24 10.210.5.0/24|' "$d/two/scenario.conf"
    SCENARIO_ROOT="$d" run python3 tests/helpers/lint_scenarios.py layout; echo "$output"
    [ "$status" -ne 0 ]; [[ "$output" == *"overlaps"* ]]
}
```

- [ ] **Step 2: Run it** — `bats tests/scenarios.bats --filter 'range list'`. Expected: FAIL (`SCENARIO_ROOT` is not honoured and `ip_network("198.18.10.0/24 10.210.0.0/16")` raises).

- [ ] **Step 3: Implement** in `tests/helpers/lint_scenarios.py`

```python
ROOT = os.environ.get("SCENARIO_ROOT") or os.path.join(os.path.dirname(__file__), "..", "..", "scenarios")

def ranges_of(c):
    """range= is a space-separated list of CIDRs; one is the common case."""
    return [ipaddress.ip_network(r) for r in c["range"].split()]

def in_ranges(ip, nets):
    return any(ip in n for n in nets)
```

In `check_addresses`: `nets = ranges_of(c)` and `if in_ranges(ip, nets) or ip.is_multicast or ...: continue`; the error names `c["range"]`.
In `check_expect`: `nets = ranges_of(c)`; a row's network passes when `any(n.subnet_of(net) for net in nets)`.
In `main`, replace the exact-string uniqueness with pairwise overlap:

```python
    owned = []  # (scenario, network)
    for s in scenarios():
        c = conf(s)
        for n in ranges_of(c):
            for (s2, n2) in owned:
                if s2 != s and n.overlaps(n2):
                    errs.append(f"range {n} of {s} overlaps {n2} of {s2}")
            owned.append((s, n))
```

- [ ] **Step 4: Run** `bats tests/scenarios.bats` — all green, including the existing single-range scenarios.
- [ ] **Step 5:** In `scripts/r770-scenario.sh` `cmd_list`, widen `%-16s` for the range column to `%-36s`. In the runbook's Scenarios paragraph change "Each scenario owns one /16" to "Each scenario owns one or more ranges, none overlapping another's".
- [ ] **Step 6: Run** `./tests/run.sh`. **Commit:** `git commit -am "scenarios lint: range= is a list of CIDRs; overlap across scenarios is the error, not inequality"`

---

### Task 3: `r770-wan.sh` — impairment on kit TAPs only

**Files:**
- Create: `scripts/r770-wan.sh`
- Create: `config/wan/profiles/branch-wan.conf`, `satellite.conf`, `poor-broadband.conf`, `asym-adsl.conf`, `asym-adsl-up.conf`, `lte-good.conf`, `lte-good-up.conf`, `lte-poor.conf`, `lte-poor-up.conf`, `leo.conf`, `leo-up.conf`, `mpls-metro.conf`
- Create: `tests/wan.bats`
- Modify: `README.md` (script row), `.claude/settings.json` (`"Bash(./scripts/r770-wan.sh:*)"`), `docs/CODEMAPS/stages.md` (operator-tool row), `tests/README.md` (suite row), `config/README.md` (a `wan/profiles/*.conf` row: kit-originated, values from `docs/wiki/wan.md` and spec §6.2, carry-back)

**Interfaces:**
- Produces:
  - `r770-wan.sh apply <profile> <lab-tapN>` — HTB rate + netem; prints current · proposed · rollback; not gated (kit-owned interfaces only); exit 1 on any refusal before `tc` runs.
  - `r770-wan.sh show` — one line per kit TAP: `<tap>  <profile or clean>` then its `tc qdisc show` output; exit 0.
  - `r770-wan.sh clear <lab-tapN> | --all` — `tc qdisc del dev <tap> root`; idempotent.
  - Profile file keys: `rate=` (tc rate, e.g. `20mbit`), `delay=` (e.g. `40ms`), optional `jitter=` (`5ms`), `loss=` (`0.2%`), `reorder=` (`1%`), `description=`. Up/down asymmetry is two profiles (`asym-adsl` is the down side; the up side is `asym-adsl-up`), applied to the two TAPs.
  - The applied profile name is recorded in `/run/r770-wan/<tap>` (through `p()`), so `show` and `record` can name it.

- [ ] **Step 1: Write the failing tests** (`tests/wan.bats`)

```bash
#!/usr/bin/env bats
# r770-wan.sh: impairment profiles on kit TAPs only, tc stubbed.
load helpers/fixtures
load helpers/stubs

setup() {
    kit_test_env
    SCRIPT="$BATS_TEST_DIRNAME/../scripts/r770-wan.sh"
    make_root "$ROOT"
    for i in 0 1; do mkdir -p "$ROOT/sys/class/net/lab-tap$i"; done
    mkdir -p "$ROOT/sys/class/net/eno1" "$ROOT/run"
    export ROOT
    stub_log tc
}
wan() { kit_run "$SCRIPT" "$@"; }

@test "apply refuses an interface that is not a kit TAP, before any tc" {
    run wan apply branch-wan eno1
    [ "$status" -eq 1 ]; [[ "$output" == *"not a kit TAP"* ]]
    ! grep -q '^tc' "$STUB_LOG"
    run wan apply branch-wan lab-tap7
    [ "$status" -eq 1 ]; [[ "$output" == *"does not exist"* ]]
}

@test "apply refuses an unknown profile and a malformed one, naming the key" {
    run wan apply no-such lab-tap0
    [ "$status" -eq 1 ]; [[ "$output" == *"no profile"* ]]
    mkdir -p "$BATS_TEST_TMPDIR/profiles"
    printf 'rate=20mbps\ndelay=40ms\n' > "$BATS_TEST_TMPDIR/profiles/bad.conf"
    WAN_PROFILE_DIR="$BATS_TEST_TMPDIR/profiles" run wan apply bad lab-tap0
    [ "$status" -eq 1 ]; [[ "$output" == *"rate=20mbps"* ]]
    printf 'delay=40ms\n' > "$BATS_TEST_TMPDIR/profiles/norate.conf"
    WAN_PROFILE_DIR="$BATS_TEST_TMPDIR/profiles" run wan apply norate lab-tap0
    [ "$status" -eq 1 ]; [[ "$output" == *"rate="* ]]
    ! grep -q '^tc' "$STUB_LOG"
}

@test "apply shapes with HTB then netem, records the profile, and show names it" {
    run wan apply branch-wan lab-tap0
    echo "$output"; [ "$status" -eq 0 ]
    grep -q 'tc qdisc replace dev lab-tap0 root handle 1: htb default 10' "$STUB_LOG"
    grep -q 'tc class replace dev lab-tap0 parent 1: classid 1:10 htb rate 20mbit' "$STUB_LOG"
    grep -qE 'tc qdisc replace dev lab-tap0 parent 1:10 handle 10: netem delay 40ms 5ms .*loss 0.2%' "$STUB_LOG"
    [ "$(cat "$ROOT/run/r770-wan/lab-tap0")" = branch-wan ]
    [[ "$output" == *"current"* && "$output" == *"proposed"* && "$output" == *"rollback"* ]]
    run wan show
    [[ "$output" == *"lab-tap0"*"branch-wan"* && "$output" == *"lab-tap1"*"clean"* ]]
}

@test "clear removes the qdisc and the record; --all covers every kit TAP; idempotent" {
    wan apply branch-wan lab-tap0 >/dev/null
    run wan clear lab-tap0; [ "$status" -eq 0 ]
    grep -q 'tc qdisc del dev lab-tap0 root' "$STUB_LOG"
    [ ! -e "$ROOT/run/r770-wan/lab-tap0" ]
    run wan clear lab-tap0; [ "$status" -eq 0 ]; [[ "$output" == *"already clean"* ]]
    run wan clear --all; [ "$status" -eq 0 ]
    grep -q 'tc qdisc del dev lab-tap1 root' "$STUB_LOG"
    run wan clear eno1; [ "$status" -eq 1 ]
}

@test "every shipped profile parses" {
    for f in "$BATS_TEST_DIRNAME"/../config/wan/profiles/*.conf; do
        run wan apply "$(basename "$f" .conf)" lab-tap0; echo "$f: $output"; [ "$status" -eq 0 ]
    done
}
```

- [ ] **Step 2: Run** `bats tests/wan.bats`. Expected: every test FAILS (no script).

- [ ] **Step 3: Write the profiles.** One file each, e.g. `config/wan/profiles/branch-wan.conf`:

```text
# branch-wan: a typical branch-office circuit (docs/wiki/wan.md)
description=typical branch-office circuit
rate=20mbit
delay=40ms
jitter=5ms
loss=0.2%
```

| file | rate | delay | jitter | loss |
|---|---|---|---|---|
| `satellite.conf` | 25mbit | 300ms | 20ms | — |
| `poor-broadband.conf` | 10mbit | 80ms | — | 2% |
| `asym-adsl.conf` (down) | 16mbit | 20ms | 3ms | 0.1% |
| `asym-adsl-up.conf` | 1mbit | 20ms | 3ms | 0.1% |
| `lte-good.conf` | 30mbit | 45ms | 10ms | 0.3% |
| `lte-good-up.conf` | 10mbit | 45ms | 10ms | 0.3% |
| `lte-poor.conf` | 5mbit | 90ms | 30ms | 2% |
| `lte-poor-up.conf` | 1mbit | 90ms | 30ms | 2% |
| `leo.conf` | 100mbit | 30ms | 10ms | 0.5% |
| `leo-up.conf` | 15mbit | 30ms | 10ms | 0.5% |
| `mpls-metro.conf` | 100mbit | 5ms | 1ms | — |

(`satellite`'s 600 ms RTT-equivalent is 300 ms per direction — the wiki's direction rule.)

- [ ] **Step 4: Write `scripts/r770-wan.sh`**

```bash
#!/usr/bin/env bash
#
# r770-wan.sh — WAN impairment on the kit's lab TAPs: HTB rate cap plus netem
# delay/jitter/loss, from a profile file. Shapes only lab-tapN (created by
# r770-gns3-deploy.sh labnet), never a physical port, the mgmt bond or a
# capture interface -- the guard list is the refusal of any other name.
#
#   r770-wan.sh apply <profile> <lab-tapN>   shape frames the host sends INTO the TAP
#   r770-wan.sh show                         every kit TAP: profile or clean, and its qdiscs
#   r770-wan.sh clear <lab-tapN> | --all     back to the default qdisc (idempotent)
#
#   WAN_PROFILE_DIR   where <profile>.conf lives (default: the kit's config/wan/profiles)
#   GNS3_LAB_TAPS 4
#
#   0  done · 1  refused
#
# netem shapes egress. A frame from the node on TAP_A to the node on TAP_B
# enters the host through lab-tapA and leaves through lab-tapB, so a profile
# on lab-tapB shapes the A->B direction; asymmetry is two profiles on two TAPs.
# Not gated: it changes only interfaces the kit created and records what it
# applied under /run/r770-wan/<tap>, which show and r770-scenario.sh record read.
set -uo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

PROFILES="${WAN_PROFILE_DIR:-$KIT_DIR/config/wan/profiles}"
LAB_TAPS="${GNS3_LAB_TAPS:-4}"
STATE="/run/r770-wan"
usage() { usage_from_header 3; exit 0; }

tap_check() {  # tap_check <name> — a kit TAP that exists, or die
    [[ "$1" =~ ^lab-tap[0-9]+$ ]] || die "$1 is not a kit TAP (lab-tapN) — r770-wan.sh shapes nothing else"
    [ -e "$(p /sys/class/net)/$1" ] || die "$1 does not exist — run r770-gns3-deploy.sh labnet"
}
profile_read() {  # profile_read <name> — sets RATE DELAY JITTER LOSS REORDER DESC, or die before any tc
    local f="$PROFILES/$1.conf" line k v
    [[ "$1" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "'$1' is not a profile name"
    [ -f "$f" ] || die "no profile '$1' in $PROFILES (have: $(ls "$PROFILES" | sed 's/\.conf$//' | tr '\n' ' '))"
    RATE=""; DELAY=""; JITTER=""; LOSS=""; REORDER=""; DESC=""
    while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        k=${line%%=*}; v=${line#*=}
        case "$k" in
            rate)    [[ "$v" =~ ^[0-9]+(k|m|g)?bit$ ]] || die "$f: rate=$v is not a tc rate (e.g. 20mbit)"; RATE=$v ;;
            delay)   [[ "$v" =~ ^[0-9]+(us|ms|s)$ ]] || die "$f: delay=$v is not a tc time (e.g. 40ms)"; DELAY=$v ;;
            jitter)  [[ "$v" =~ ^[0-9]+(us|ms|s)$ ]] || die "$f: jitter=$v is not a tc time"; JITTER=$v ;;
            loss|reorder) [[ "$v" =~ ^[0-9]+(\.[0-9]+)?%$ ]] || die "$f: $k=$v is not a percentage (e.g. 0.2%)"
                     if [ "$k" = loss ]; then LOSS=$v; else REORDER=$v; fi ;;
            description) DESC=$v ;;
            *)       die "$f: unknown key '$k' (known: rate delay jitter loss reorder description)" ;;
        esac
    done < "$f"
    [ -n "$RATE" ] || die "$f: no rate= line"
    [ -n "$DELAY" ] || die "$f: no delay= line"
}
netem_args() {  # netem_args — fills NETEM (an array) from the profile just read
    NETEM=(delay "$DELAY")
    [ -n "$JITTER" ] && NETEM+=("$JITTER" distribution normal)
    [ -n "$LOSS" ] && NETEM+=(loss "$LOSS")
    [ -n "$REORDER" ] && NETEM+=(reorder "$REORDER")
    return 0
}
applied() { cat "$(p "$STATE")/$1" 2>/dev/null || true; }  # applied <tap> — the recorded profile, or empty

cmd_apply() {
    local prof=$1 tap=$2 cur
    need_root; tap_check "$tap"; profile_read "$prof"; netem_args
    cur=$(applied "$tap")
    note "current:  $tap ${cur:+profile $cur}${cur:-clean (default qdisc)}"
    note "proposed: htb rate $RATE, netem ${NETEM[*]}${DESC:+ — $DESC}"
    note "rollback: r770-wan.sh clear $tap"
    run tc qdisc replace dev "$tap" root handle 1: htb default 10 \
        && run tc class replace dev "$tap" parent 1: classid 1:10 htb rate "$RATE" \
        && run tc qdisc replace dev "$tap" parent 1:10 handle 10: netem "${NETEM[@]}" \
        || die "tc refused — $tap may be partly shaped; run r770-wan.sh clear $tap"
    if [ "$DRY" != "1" ]; then mkdir -p "$(p "$STATE")"; printf '%s\n' "$prof" > "$(p "$STATE")/$tap"; fi
    pass "$tap shaped as $prof (frames the host sends into $tap)"
    footer "apply"
}
clear_one() {  # clear_one <tap>
    if [ -z "$(applied "$1")" ] && ! tc qdisc show dev "$1" 2>/dev/null | grep -q netem; then pass "$1 already clean"; return 0; fi
    run tc qdisc del dev "$1" root || warn "tc could not delete $1's root qdisc (already default?)"
    rm -f "$(p "$STATE")/$1"
    pass "$1 clean"
}
cmd_clear() {
    need_root
    local i
    if [ "${1:-}" = "--all" ]; then
        for ((i = 0; i < LAB_TAPS; i++)); do [ -e "$(p /sys/class/net)/lab-tap$i" ] && clear_one "lab-tap$i"; done
    else
        [ -n "${1:-}" ] || die "clear needs a kit TAP or --all"
        tap_check "$1"; clear_one "$1"
    fi
    footer "clear"
}
cmd_show() {
    local i t prof
    for ((i = 0; i < LAB_TAPS; i++)); do
        t="lab-tap$i"; [ -e "$(p /sys/class/net)/$t" ] || continue
        prof=$(applied "$t")
        printf '%-10s %s\n' "$t" "${prof:-clean}"
        tc qdisc show dev "$t" 2>/dev/null | sed 's/^/           /'
    done
    return 0
}

SUB="${1:-}"; [ $# -gt 0 ] && shift
ARGS=()
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage ;;
        --all)     ARGS+=("$1") ;;
        -*)        common_flag "$1" || die "unknown option: $1 (try --help)" ;;
        *)         ARGS+=("$1") ;;
    esac
    shift
done
kit_init "r770-wan"
case "$SUB" in
    apply) [ "${#ARGS[@]}" -eq 2 ] || die "apply needs <profile> <lab-tapN>"; cmd_apply "${ARGS[@]}" ;;
    clear) cmd_clear "${ARGS[@]:-}" ;;
    show)  cmd_show ;;
    -h|--help|help|"") usage ;;
    *) die "unknown subcommand: $SUB (try --help)" ;;
esac
```

`chmod +x scripts/r770-wan.sh`.

- [ ] **Step 5: Run** `bats tests/wan.bats` and `shellcheck scripts/r770-wan.sh` — green, no directives.
- [ ] **Step 6: Docs and settings:** README row (`scripts/r770-wan.sh` — "WAN impairment on kit TAPs only: `apply <profile> <lab-tapN>`, `show`, `clear`; profiles in `config/wan/profiles/`; not gated — it touches only interfaces `labnet` created"); `.claude/settings.json` allow entry; `docs/CODEMAPS/stages.md` row; `tests/README.md` row; `config/README.md` row for `wan/profiles/*.conf`. In the runbook's IPsec & WAN section, replace the bare `r770-wan.sh` mentions with `scripts/r770-wan.sh`.
- [ ] **Step 7: Run** `./tests/run.sh` (references.bats now sees `scripts/r770-wan.sh` exists; the config-file test sees every profile used via the `wan/profiles/*.conf` glob). **Commit:** `git commit -m "r770-wan.sh: impairment profiles on kit TAPs only — HTB rate plus netem, recorded under /run/r770-wan, refused anywhere else"`

---

### Task 4: Scenario `s0-w1` — plaintext baseline over a single-ISP WAN

**Files:**
- Create: `scenarios/s0-w1/scenario.conf`, `project/s0-w1.gns3`, `nodes/{h-a,gw-a,isp1,gw-b,h-b}.sh`, `nodes/isp1.frr.conf`, `traffic.sh`, `expect.txt`, `pcap-expect.txt`
- Modify: `tests/scenarios.bats` (the documented-pack list and count: 8 → 9)
- Modify: `docs/deployment-runbook.md` (range table gains `s0-w1`)

**Interfaces:**
- Consumes: `__IMG_NETSHOOT__`, `__IMG_FRR__`, `__TAP_A__`, `__TAP_B__`, `__PROJECT_NAME__`, `__PROJECT_ID__`, `__SCENARIO__` tokens (rendered by `up`).
- Produces: a scenario whose `traffic.sh` is the spec §4 plain-transport validation plus lane-A traffic; `pcap-expect.txt` rows are read by Task 9's `verify`.

- [ ] **Step 1: Write the content test first** (`tests/scenarios.bats`): change the documented list to include `s0-w1` and the count to 9. Run `bats tests/scenarios.bats` — FAIL (missing).

- [ ] **Step 2: `scenario.conf`**

```text
name=s0-w1
description=S0 plaintext baseline over W1: site A - gw-a - ISP (FRR) - gw-b - site B, no IPsec; gw-a's uplink on br-lab
range=198.18.10.0/24 10.210.0.0/16
images=netshoot frr
traffic_secs=90
idle_secs=0
ready=h-a|ping -c 1 -W 2 10.210.2.10
traffic_nodes=h-b h-a
inner_capture=gw-a:eth0 gw-b:eth0
```

(`idle_secs` and `inner_capture` are read by Task 6; `up`/`traffic` ignore unknown keys today — `conf()` is a plain `sed`.)

- [ ] **Step 3: Node scripts.** Interface order in the project: each docker node's `eth0` is its LAN side, `eth1` its uplink (two-adapter nodes); `isp1` has `eth0` toward gw-a's Cloud, `eth1` toward gw-b.

`nodes/gw-a.sh`:
```sh
# gw-a: CE router for site A — LAN on eth0, uplink to isp1 on eth1 (through br-lab)
set -e
ip addr replace 10.210.1.1/24 dev eth0
ip addr replace 198.18.10.2/30 dev eth1
ip link set dev eth0 up; ip link set dev eth1 up
sysctl -w net.ipv4.ip_forward=1
ip route replace default via 198.18.10.1
```
`nodes/gw-b.sh`: `10.210.2.1/24` on eth0, `198.18.10.6/30` on eth1, default via `198.18.10.5`.
`nodes/h-a.sh`: `ip addr replace 10.210.1.10/24 dev eth0; ip link set dev eth0 up; ip route replace default via 10.210.1.1`. `nodes/h-b.sh`: `.2.10` via `10.210.2.1`.
`nodes/isp1.sh`: addresses only (`198.18.10.1/30` eth0, `198.18.10.5/30` eth1, forwarding on); `nodes/isp1.frr.conf`:
```text
! isp1: the only router that knows both sites — S0 is the plaintext baseline
ip route 10.210.1.0/24 198.18.10.2
ip route 10.210.2.0/24 198.18.10.6
```

- [ ] **Step 4: `traffic.sh`** (spec §4 validation, then lane A, all rate-capped)

```sh
#!/bin/sh
# traffic.sh <node> <seconds> — W1 plain-transport validation from site A, then lane-A traffic.
node=$1 secs=$2
case "$node" in
    h-b) pkill iperf3 2>/dev/null; iperf3 -s -D -1 ;;
    h-a) ping -c 20 -i 0.2 198.18.10.6 \
         && traceroute -n -m 5 198.18.10.6 \
         && ping -M do -s 1472 -c 5 198.18.10.6 \
         && ping -c 10 -i 0.2 10.210.2.10 \
         && iperf3 -c 10.210.2.10 -b 50M -t "$((secs - 20))" -P 2 ;;
    *) echo "traffic.sh: no traffic role for node $node" >&2; exit 1 ;;
esac
```

- [ ] **Step 5: `expect.txt`** (what the mirror shows — the uplink carries the sites in clear):
```text
icmp||10.210.1.0/24|10.210.2.0/24
tcp|5201|10.210.1.0/24|10.210.2.0/24
icmp||10.210.1.0/24|198.18.10.4/30
```
`pcap-expect.txt` (Task 9's format; the baseline's distinctive fact is that site addresses ARE visible on the outer side):
```text
outer|count|ip.addr==10.210.0.0/16|>0|B1 site addresses visible in clear on the uplink
outer|count|esp|0|B2 no ESP on a plaintext baseline
inner-gw-a|count|tcp.port==5201|>0|B3 iperf3 seen on site A's LAN
```

- [ ] **Step 6: The project file.** Copy `scenarios/bgp/project/bgp.gns3` as the template (it already has FRR-style docker nodes and the two Clouds). Nodes: `h-a`, `gw-a` (netshoot, `adapters: 2`), `tap-a` Cloud (`__TAP_A__`), `tap-b` Cloud (`__TAP_B__`), `isp1` (FRR, `adapters: 2`, start command as `bgp`'s routers), `gw-b` (netshoot, 2), `h-b`. Links: h-a:0↔gw-a:0, gw-a:1↔tap-a:0, tap-b:0↔isp1:0, isp1:1↔gw-b:1, gw-b:0↔h-b:0. Node ids `0000000a-0000-4000-8000-00000000000N`. `revision: 9`.
- [ ] **Step 7: Run** `bats tests/scenarios.bats` — all green (layout, JSON, exactly two TAP Clouds on one link each, images bundled, addresses inside the two ranges, expect rows inside the ranges, shellcheck on the scripts).
- [ ] **Step 8:** Runbook range table gains `s0-w1`: `198.18.10.0/24` and `10.210.0.0/16`. **Commit:** `git commit -m "Scenario s0-w1: plaintext baseline over a single-ISP WAN — W1 validation in traffic.sh, site addresses in clear on the uplink"`

---

### Task 5: Scenario `s1-w1-ss` — site-to-site IKEv2 PSK over W1, strongSwan

**Files:**
- Create: `scenarios/s1-w1-ss/scenario.conf`, `project/s1-w1-ss.gns3`, `nodes/{h-a,gw-a,isp1,gw-b,h-b}.sh`, `nodes/{gw-a,gw-b}.swanctl.conf`, `nodes/isp1.frr.conf`, `traffic.sh`, `expect.txt`, `pcap-expect.txt`
- Modify: `tests/scenarios.bats` (count 10; a test that `s1-w1-ss` sets `mobike = no` on both gateways and that `isp1.frr.conf` names no `10.211.` route)
- Modify: `.gitignore` (`**/gt/` — run output never lands in the repo, but a `KIT_ROOT` pointed inside the checkout must not either)

**Interfaces:**
- Consumes: `__IMG_STRONGSWAN__` (basename `strongswan`, as `ipsec-ike`), `__IMG_NETSHOOT__`, `__IMG_FRR__`.
- Produces: `gt=` key (Task 8 reads it), `gt_dirs=` key, `idle_secs=40`, `pcap-expect.txt` rows X1–X6, X8.

- [ ] **Step 1: Write the content tests** (append to `tests/scenarios.bats`)

```bash
@test "s1-w1-ss disables MOBIKE on both gateways, so IKE stays on udp/500 with no NAT (spec X2)" {
    for g in gw-a gw-b; do grep -qE '^\s*mobike\s*=\s*no' "scenarios/s1-w1-ss/nodes/$g.swanctl.conf"; done
}
@test "s1-w1-ss's ISP knows neither site, so any 10.211.x.x address on the outer side is leakage" {
    ! grep -q '10\.211\.' scenarios/s1-w1-ss/nodes/isp1.frr.conf
    ! grep -q '10\.211\.' scenarios/s1-w1-ss/nodes/isp1.sh
}
@test "s1-w1-ss's gateways enable save-keys only when the plugin is present, never assume it" {
    grep -q 'save-keys' scenarios/s1-w1-ss/nodes/gw-a.sh
    grep -qE 'if .*libstrongswan-save-keys\.so' scenarios/s1-w1-ss/nodes/gw-a.sh
}
```

Run — FAIL (missing scenario).

- [ ] **Step 2: `scenario.conf`**

```text
name=s1-w1-ss
description=S1 site-to-site IKEv2 PSK (policy-based) over W1, strongSwan both ends; gw-a initiates; gw-a's uplink on br-lab
range=198.18.11.0/24 10.211.0.0/16
images=netshoot frr strongswan
traffic_secs=240
idle_secs=40
ready=h-a|ping -c 1 -W 2 10.211.2.10
traffic_nodes=gw-a h-b h-a
inner_capture=gw-a:eth0 gw-b:eth0
gt=gw-a|swanctl --list-sas;gw-b|swanctl --list-sas
gt_dirs=gw-a:/gt gw-b:/gt
```

- [ ] **Step 3: Gateway scripts.** `nodes/gw-a.sh`:

```sh
# gw-a: strongSwan CE for site A — LAN eth0, uplink eth1. Ground truth under /gt
# (charon log, SA snapshots by the harness, ESP/IKE keys if save-keys exists).
set -e
mkdir -p /gt/keys
# O3: save-keys is enabled only when the bundled image carries the plugin — discovered, never assumed
if ls /usr/lib*/ipsec/plugins/libstrongswan-save-keys.so >/dev/null 2>&1; then
    mkdir -p /etc/strongswan.d/charon
    printf 'charon {\n  plugins {\n    save-keys {\n      load = yes\n      esp = yes\n      ike = yes\n      wireshark_keys = /gt/keys\n    }\n  }\n}\n' > /etc/strongswan.d/charon/save-keys.conf
    echo present > /gt/keys.state
else
    echo absent > /gt/keys.state
fi
ip addr replace 10.211.1.1/24 dev eth0
ip addr replace 198.18.11.2/30 dev eth1
ip link set dev eth0 up; ip link set dev eth1 up
sysctl -w net.ipv4.ip_forward=1
ip route replace default via 198.18.11.1
# the image does not start charon by itself (ipsec-ike, staging 2026-09-25); log to /gt
pgrep -x charon >/dev/null || /usr/libexec/ipsec/charon </dev/null >/gt/charon.log 2>&1 &
```

`nodes/gw-b.sh` mirrors it: `10.211.2.1/24`, `198.18.11.6/30`, default via `198.18.11.5`.

`nodes/gw-a.swanctl.conf` (spec §11.2, plus `mobike = no`):

```text
# gw-a: IKEv2 PSK, policy-based, always the initiator (start_action = start)
connections {
    s1 {
        version = 2
        mobike = no
        local_addrs  = 198.18.11.2
        remote_addrs = 198.18.11.6
        proposals = aes256gcm16-prfsha384-ecp384
        rekey_time = 600s
        dpd_delay = 10s
        local  { auth = psk  id = gw-a.site-a.lab }
        remote { auth = psk  id = gw-b.site-b.lab }
        children {
            s1-net {
                local_ts  = 10.211.1.0/24
                remote_ts = 10.211.2.0/24
                esp_proposals = aes256gcm16-ecp384
                rekey_time = 120s
                dpd_action = restart
                start_action = start
            }
        }
    }
}
secrets {
    ike-s1 {
        id-a = gw-a.site-a.lab
        id-b = gw-b.site-b.lab
        secret = "lab-scenario-s1-w1-ss"
    }
}
```

`gw-b.swanctl.conf`: addresses, ids and selectors swapped, `start_action = trap`. The PSK is lab traffic, not a secret (the pack's `ipsec-ike` convention); the spec's per-run PSK is a roadmap item (IP6, interop) once `record` can render a per-run secret into the node without putting it on argv.

`nodes/isp1.frr.conf` holds **no** route to either site (comment says why). `h-a.sh`/`h-b.sh` as in `s0-w1` with 10.211.

- [ ] **Step 4: `traffic.sh`** — gw-a tears the IKE SA down first so IKE_SA_INIT is in the window (the `ipsec-ike` pattern), then 240 s of lane A spanning ≥ 1 CHILD_SA rekey; the idle tail comes from `record` (`idle_secs`), not from here.

```sh
#!/bin/sh
# traffic.sh <node> <seconds> — gw-a renegotiates inside the window; h-b serves; h-a drives lane A.
node=$1 secs=$2
case "$node" in
    gw-a) swanctl --terminate --ike s1 >/dev/null 2>&1; swanctl --initiate --child s1-net >/dev/null ;;
    h-b)  pkill iperf3 2>/dev/null; iperf3 -s -D ;;   # no -1: h-a runs two iperf3 tests; the next window's pkill removes the server
    h-a)  ping -c 20 -i 0.2 10.211.2.10 \
          && iperf3 -c 10.211.2.10 -b 20M -t "$((secs - 60))" -P 2 \
          && iperf3 -c 10.211.2.10 -u -b 5M -t 30 \
          && ping -c 20 -i 0.5 10.211.2.10 ;;
    *) echo "traffic.sh: no traffic role for node $node" >&2; exit 1 ;;
esac
```

- [ ] **Step 5: `expect.txt`** (the mirror sees only IKE and ESP between the public addresses):
```text
udp|500|198.18.11.2/32|198.18.11.6/32
esp||198.18.11.2/32|198.18.11.6/32
esp||198.18.11.6/32|198.18.11.2/32
```
`pcap-expect.txt` (spec X1–X6, X8; X7 and X9 are `verify`'s built-ins):
```text
outer|count|isakmp && udp.port==500 && ip.addr==198.18.11.2 && ip.addr==198.18.11.6|>0|X1 IKE_SA_INIT/IKE_AUTH on udp/500 between the public addresses
outer|count|udp.port==4500|0|X2 no NAT, MOBIKE off: nothing on udp/4500
outer|count|esp && !udp|>0|X3 data as ESP (proto 50), not UDP-encapsulated
outer|count|ip.addr==10.211.0.0/16|0|X4 no site address on the outer side
outer|distinct esp.spi|esp|>=4|X5 at least one CHILD_SA rekey: a second SPI pair
outer|count|isakmp && frame.time_epoch >= __IDLE_START__|>0|X6 DPD INFORMATIONAL during the idle tail
inner-gw-a|count|tcp.port==5201 && ip.src==10.211.1.10|>0|I1 iperf3 in clear on site A's LAN
```

- [ ] **Step 6: Project file** as Task 4's with `gw-a`/`gw-b` on `__IMG_STRONGSWAN__`, node ids `0000000b-…`.
- [ ] **Step 7:** `.gitignore` gains:
```text
# Reference-run ground truth (SA dumps, ESP/IKE keys) — lab-only, never in git
**/gt/
```
- [ ] **Step 8: Run** `bats tests/scenarios.bats` → green (10 scenarios). `./tests/run.sh` green (no-pins: the swanctl proposals are algorithm names, not versions; if `tests/no-pins.bats` matches `aes256gcm16`, the pattern is the test's to tighten, never the config's). **Commit:** `git commit -m "Scenario s1-w1-ss: IKEv2 PSK site-to-site over W1 with strongSwan — MOBIKE off so udp/500 holds, ISP blind to the sites, save-keys discovered at run time"`

---

### Task 6: `r770-scenario.sh record` — captures, idle tail, manifest, checksums, trap cleanup

**Files:**
- Modify: `scripts/r770-scenario.sh` (header, `cmd_record`, helpers `cases_gate`, `capture_start`, `capture_stop_all`, `record_cleanup`, `run_traffic` + `write_run_record` factored out of `cmd_traffic`, dispatch)
- Modify: `tests/scenario.bats` (a `record` section); `tests/helpers/stubs.bash` (`sha256sum` joins the `REAL` allowlist — real, harmless)
- Modify: `README.md` row, `docs/deployment-runbook.md` (Scenarios: the `record` paragraph), `tests/README.md`

**Interfaces:**
- Consumes: `conf <name> inner_capture|idle_secs|traffic_secs|traffic_nodes`; `nodes()`'s TSV (column 4 = container id, column 5 = TAPs); `/run/r770-wan/<tap>` records of `r770-wan.sh`.
- Produces: `cmd_record` writing `$RUN_DIR` (a global for Tasks 7–8); `run.conf` keys `scenario run_id project taps tap_a tap_b secs idle_secs spec load_start outer=<file>:<iface> inner=<file>:<node>:<iface>… start traffic_end idle_start keys=present|absent|n/a load_end end` plus the pack's `.run` record beside the transcript. Functions `capture_start <label> <iface> [<netns-pid>]`, `capture_stop_all`, `run_traffic <scenario> <nodes.tsv> <secs>` (sets `T_OK T_OKN T_BADN`), `write_run_record <start> <end> <secs> <ok> <badn> <taps> [<run-dir>]`.

- [ ] **Step 1: Write the failing tests** (append to `tests/scenario.bats`)

```bash
# ── record — a reference run: captures, idle tail, manifest, checksums ───────
record_env() {
    export SCENARIO_CASES_DIR="$BATS_TEST_TMPDIR/cases" SCENARIO_CASES_MIN_FREE_MB=0
    printf 'idle_secs=3\ninner_capture=a:eth0\n' >> "$SCENARIO_DIR/demo/scenario.conf"
    # tcpdump: records argv, writes the -w file, prints drop stats on SIGINT like the real one
    stub tcpdump 'echo "tcpdump $*" >> "$STUB_LOG"
while [ $# -gt 0 ]; do [ "$1" = -w ] && out=$2; shift; done
trap "echo \"7 packets captured\" >&2; echo \"7 packets received by filter\" >&2; echo \"0 packets dropped by kernel\" >&2; exit 0" INT TERM
printf pcap > "$out"; while :; do command sleep 0.1; done'
    stub nsenter 'echo "nsenter $*" >> "$STUB_LOG"; shift; exec "$@"'
    unstub sleep; stub sleep 'command sleep 0.05'
    # docker inspect -f {{.State.Pid}} <cid>: the pid file for that container, else 1
    sed -i 's|^  exec)|  inspect) cat "$BATS_TEST_TMPDIR/pid-${*##* }" 2>/dev/null \|\| echo 1 ;;\n  exec)|' "$BIN/docker"
}

@test "record refuses when free space is under the floor, before any capture" {
    record_env; export SCENARIO_CASES_MIN_FREE_MB=999999999
    scenario up demo --bundle "$BUNDLE" >/dev/null
    run scenario record demo
    [ "$status" -eq 1 ]; [[ "$output" == *"free space"* ]]
    ! grep -q '^tcpdump' "$STUB_LOG"
    [ ! -d "$SCENARIO_CASES_DIR/demo" ]
}

@test "record captures outer on TAP_A and inner inside the node's netns, runs traffic, idles, writes the manifest" {
    record_env
    scenario up demo --bundle "$BUNDLE" >/dev/null
    cid=$(grep -o 'docker exec -i [^ ]*' "$STUB_LOG" | head -1 | awk '{print $4}'); echo 4242 > "$BATS_TEST_TMPDIR/pid-$cid"
    run scenario record demo
    echo "$output"; [ "$status" -eq 0 ]
    d=$(find "$SCENARIO_CASES_DIR/demo" -mindepth 1 -maxdepth 1 -type d | head -1); [ -n "$d" ]
    grep -q 'tcpdump -ni lab-tap0 .*-w .*/outer-lab-tap0.pcapng' "$STUB_LOG"
    grep -q 'nsenter --net=/proc/4242/ns/net tcpdump -ni eth0 .*-w .*/inner-a.pcapng' "$STUB_LOG"
    [ -s "$d/outer-lab-tap0.pcapng" ] && [ -s "$d/inner-a.pcapng" ]
    grep -q '^scenario=demo$' "$d/run.conf"; grep -q '^run_id=demo-[0-9]\{8\}T[0-9]\{4\}Z$' "$d/run.conf"
    grep -q '^tap_a=lab-tap0$' "$d/run.conf"; grep -q '^idle_secs=3$' "$d/run.conf"
    grep -q '^idle_start=' "$d/run.conf"; grep -q '^end=20' "$d/run.conf"; grep -q '^keys=n/a$' "$d/run.conf"
    grep -q 'outer-lab-tap0: .*0 packets dropped by kernel' "$d/capture-stats.txt"
    grep -q 'outer-lab-tap0.pcapng' "$d/sha256sums"; grep -q 'inner-a.pcapng' "$d/sha256sums"; ! grep -q 'run.conf' "$d/sha256sums"
    # the captures started before traffic.sh ran in any node
    [ "$(grep -n '^tcpdump' "$STUB_LOG" | head -1 | cut -d: -f1)" -lt "$(grep -n '^docker exec -i' "$STUB_LOG" | tail -1 | cut -d: -f1)" ]
    # the pack's own run record, so check works unchanged
    ls "$KIT_EVIDENCE_DIR"/scenario-demo-*.run
}

@test "record works with outer capture alone when the scenario names no inner point" {
    record_env; sed -i '/^inner_capture=/d' "$SCENARIO_DIR/demo/scenario.conf"
    scenario up demo --bundle "$BUNDLE" >/dev/null
    run scenario record demo; echo "$output"; [ "$status" -eq 0 ]
    ! grep -q '^nsenter' "$STUB_LOG"
}

@test "record's EXIT trap stops every capture and clears every qdisc it applied" {
    record_env
    scenario up demo --bundle "$BUNDLE" >/dev/null
    cid=$(grep -o 'docker exec -i [^ ]*' "$STUB_LOG" | head -1 | awk '{print $4}'); echo 1 > "$BATS_TEST_TMPDIR/rc-execi-$cid"   # traffic fails in every node -> FAIL
    run scenario record demo
    [ "$status" -eq 1 ]
    command sleep 0.3; ! pgrep -f 'tcpdump -ni' >/dev/null
    d=$(find "$SCENARIO_CASES_DIR/demo" -mindepth 1 -maxdepth 1 -type d | head -1)
    grep -q '^end=' "$d/run.conf"
}

@test "record refuses when the scenario is not up" {
    record_env
    run scenario record demo; [ "$status" -eq 1 ]; [[ "$output" == *"not up"* ]]
}
```

(The demo scenario has two traffic nodes; the trap test makes both fail by also writing `rc-execi-` for the second container id, or asserts `status -eq 2` for a partial failure — pick whichever the fixture gives and say so in the test name.)

- [ ] **Step 2: Run** `bats tests/scenario.bats --filter record` — FAIL (`unknown subcommand: record`).

- [ ] **Step 3: Implement.** Header: add `record <name>` to the subcommand list, `SCENARIO_CASES_DIR` / `SCENARIO_CASES_MIN_FREE_MB` to the env list, and the sentence "`record` is `traffic` with captures, an idle tail and a run directory under `SCENARIO_CASES_DIR`; its EXIT trap stops every capture and clears every qdisc it applied." Then:

```bash
# ── record ───────────────────────────────────────────────────────────────────
CASES="${SCENARIO_CASES_DIR:-/data/pcap/cases}"
MIN_FREE_MB="${SCENARIO_CASES_MIN_FREE_MB:-10240}"
RUN_DIR=""; RUN_ID=""
CAP_PIDS=(); CAP_LABELS=()   # running tcpdumps, by label
IMPAIRED_TAPS=()             # Task 7 fills it; the trap clears them
# hooks filled by later tasks (ground truth: Task 8; events: Task 7)
gt_snapshot() { :; }; gt_collect() { :; }; gt_keys_state() { printf 'n/a'; }
events_start() { :; }; events_stop() { :; }
run_traffic() {  # run_traffic <scenario> <nodes.tsv> <secs> — traffic.sh in every traffic node; sets T_OK T_OKN T_BADN
    local n cid; T_OK=0; T_OKN=""; T_BADN=""
    for n in $(conf "$1" traffic_nodes); do
        cid=$(container_of "$2" "$n") || exit 1
        if run docker exec -i "$cid" sh -s "$n" "$3" < "$SCEN_DIR/$1/traffic.sh"; then T_OK=$((T_OK + 1)); T_OKN="$T_OKN $n"; else T_BADN="$T_BADN $n"; fi
    done
}
write_run_record() {  # write_run_record <start> <end> <secs> <ok> <badn> <taps> [<run-dir>] — the pack's .run record
    [ "$DRY" = "1" ] && return 0
    local rec="${KIT_EVIDENCE_DIR:-$PWD/r770-evidence}/scenario-$NAME-$(hostname -s 2>/dev/null || echo host)-$(date +%Y%m%d-%H%M%S).run"
    mkdir -p "$(dirname "$rec")"
    {
        echo "scenario=$NAME"; echo "range=$(conf "$NAME" range)"; echo "project=lab-scenario-$NAME"
        echo "taps=$6"; echo "start=$1"; echo "end=$2"; echo "secs=$3"
        echo "nodes_ok=$4"; echo "nodes_failed=$(printf '%s' "$5" | wc -w)"
        echo "expect=scenarios/$NAME/expect.txt"
        [ -n "${7:-}" ] && echo "case=$7"
    } > "$rec"
    note "run record: $rec"
}
cases_gate() {  # cases_gate <secs> — refuse when the run could not fit; prints the estimate
    local dir free est
    dir=$(p "$CASES"); mkdir -p "$dir" || die "cannot create $dir"
    free=$(df -Pm "$dir" | awk 'NR == 2 {print $4}')
    # every iperf3 client in the pack is capped at 50 Mbit/s (tests/scenarios.bats), captured twice (outer, inner): 2 * 50 Mbit/s * secs / 8
    est=$(( 2 * 50 * $1 / 8 + 64 ))
    [ "$free" -ge $((MIN_FREE_MB + est)) ] \
        || die "free space on $dir is ${free} MB; this run needs about ${est} MB above the ${MIN_FREE_MB} MB floor (SCENARIO_CASES_MIN_FREE_MB) — nothing was captured"
    note "free space: ${free} MB on $dir (run estimate ${est} MB, floor ${MIN_FREE_MB} MB)"
}
capture_start() {  # capture_start <label> <iface> [<netns-pid>] — a tcpdump into $RUN_DIR/<label>.pcapng
    local out="$RUN_DIR/$1.pcapng" err="$RUN_DIR/.$1.stats"
    if [ "$DRY" = "1" ]; then echo "DRY-RUN: tcpdump -ni $2 -w $out${3:+ (in netns of pid $3)}"; return 0; fi
    if [ -n "${3:-}" ]; then
        nsenter --net="/proc/$3/ns/net" tcpdump -ni "$2" -s 0 -U -w "$out" 2> "$err" &
    else
        tcpdump -ni "$2" -s 0 -U -w "$out" 2> "$err" &
    fi
    CAP_PIDS+=($!); CAP_LABELS+=("$1")
    note "capture $1: $2${3:+ inside netns of pid $3} -> $out"
}
capture_stop_all() {  # capture_stop_all — SIGINT each tcpdump, wait, collect "dropped by kernel"
    local i
    for i in "${!CAP_PIDS[@]}"; do kill -INT "${CAP_PIDS[$i]}" 2>/dev/null || true; done
    for i in "${!CAP_PIDS[@]}"; do
        wait "${CAP_PIDS[$i]}" 2>/dev/null || true
        printf '%s: %s\n' "${CAP_LABELS[$i]}" "$(grep -E 'dropped by kernel|captured' "$RUN_DIR/.${CAP_LABELS[$i]}.stats" 2>/dev/null | paste -sd';' - | sed 's/;/; /g')" >> "$RUN_DIR/capture-stats.txt"
        rm -f "$RUN_DIR/.${CAP_LABELS[$i]}.stats"
    done
    CAP_PIDS=(); CAP_LABELS=()
}
record_cleanup() {  # the EXIT trap: nothing left running, nothing left shaped, the manifest closed
    local t
    events_stop
    capture_stop_all
    for t in "${IMPAIRED_TAPS[@]}"; do "$KIT_DIR/scripts/r770-wan.sh" clear "$t" >/dev/null 2>&1 || true; done
    if [ -n "$RUN_DIR" ] && [ -f "$RUN_DIR/run.conf" ] && ! grep -q '^end=' "$RUN_DIR/run.conf"; then
        echo "end=interrupted $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$RUN_DIR/run.conf"
    fi
    cleanup
}
cmd_record() {
    banner "record — $NAME"
    need_root
    scenario_check "$NAME"
    gns3_login
    local pid secs idle start tend istart end tap_a tap_b cp node iface cid npid keys
    pid=$(our_project "$NAME") || die "could not list GNS3 projects"
    if [ -z "$pid" ] || [ "$pid" = "FOREIGN" ]; then die "$NAME is not up — r770-scenario.sh up $NAME --bundle <dir>"; fi
    nodes "$pid" > "$WORK/nodes.tsv" || die "could not read the project's nodes"
    ready_check "$NAME" 0 || die "$NAME is up but not ready ($(conf "$NAME" ready)) — nothing was recorded"
    secs=${SCENARIO_TRAFFIC_SECS:-$(conf "$NAME" traffic_secs)}; idle=$(conf "$NAME" idle_secs); idle=${idle:-0}
    case "$secs$idle" in ''|*[!0-9]*) die "traffic_secs and idle_secs must be whole seconds" ;; esac
    read -r tap_a tap_b <<< "$(awk -F'\t' '$2 == "cloud" && $5 != "" {print $5}' "$WORK/nodes.tsv" | paste -sd' ' -)"
    [ -n "$tap_a" ] || die "no kit TAP bound by this project's Cloud nodes — not a pack scenario?"
    cases_gate "$secs"
    RUN_ID="$NAME-$(date -u +%Y%m%dT%H%MZ)"; RUN_DIR="$(p "$CASES")/$NAME/$RUN_ID"
    mkdir -p "$RUN_DIR" || die "cannot create $RUN_DIR"
    trap record_cleanup EXIT
    {
        echo "scenario=$NAME"; echo "run_id=$RUN_ID"; echo "project=lab-scenario-$NAME"
        echo "taps=$tap_a,$tap_b"; echo "tap_a=$tap_a"; echo "tap_b=$tap_b"
        echo "secs=$secs"; echo "idle_secs=$idle"; echo "spec=ipsec-scenarios-0.1"
        echo "load_start=$(cut -d' ' -f1 "$(p /proc/loadavg)")"
    } > "$RUN_DIR/run.conf"
    note "run directory: $RUN_DIR"
    capture_start "outer-$tap_a" "$tap_a"; echo "outer=outer-$tap_a.pcapng:$tap_a" >> "$RUN_DIR/run.conf"
    for cp in $(conf "$NAME" inner_capture); do
        node=${cp%%:*}; iface=${cp#*:}
        cid=$(container_of "$WORK/nodes.tsv" "$node") || exit 1
        npid=$(docker inspect -f '{{.State.Pid}}' "$cid" 2>/dev/null) || die "docker inspect gave no pid for $node ($cid)"
        case "$npid" in ''|0|*[!0-9]*) die "docker reports no running pid for $node ($cid)" ;; esac
        capture_start "inner-$node" "$iface" "$npid"; echo "inner=inner-$node.pcapng:$node:$iface" >> "$RUN_DIR/run.conf"
    done
    sleep 2   # the capture files open before the first frame
    gt_snapshot "$NAME" start
    start=$(date -u +%Y-%m-%dT%H:%M:%SZ); echo "start=$start" >> "$RUN_DIR/run.conf"
    events_start "$NAME"
    run_traffic "$NAME" "$WORK/nodes.tsv" "$secs"
    tend=$(date -u +%Y-%m-%dT%H:%M:%SZ); echo "traffic_end=$tend" >> "$RUN_DIR/run.conf"
    istart=$(date -u +%s); echo "idle_start=$istart" >> "$RUN_DIR/run.conf"
    if [ "$idle" -gt 0 ]; then note "idle tail: ${idle}s (DPD, keepalives)"; sleep "$idle"; fi
    events_stop
    gt_snapshot "$NAME" end
    capture_stop_all
    gt_collect "$NAME"; keys=$(gt_keys_state)
    end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    { echo "keys=$keys"; echo "load_end=$(cut -d' ' -f1 "$(p /proc/loadavg)")"; echo "end=$end"; } >> "$RUN_DIR/run.conf"
    ( cd "$RUN_DIR" && find . -maxdepth 1 -name '*.pcapng' -printf '%P\n' | sort | xargs -r sha256sum > sha256sums )
    write_run_record "$start" "$end" "$secs" "$T_OK" "$T_BADN" "$tap_a,$tap_b" "$RUN_DIR"
    if [ -z "$T_BADN" ]; then pass "recorded $RUN_ID: traffic ran in every node:$T_OKN"
    elif [ "$T_OK" -gt 0 ]; then warn "recorded $RUN_ID with traffic failed in:$T_BADN"
    else fail "no traffic generator ran (failed in:$T_BADN) — $RUN_DIR kept for inspection"; fi
    note "next: r770-scenario.sh verify $RUN_DIR · r770-scenario.sh ingest $RUN_DIR · r770-scenario.sh check $NAME"
    footer "record"
}
```

`cmd_traffic` becomes: the same preamble, then `run_traffic "$NAME" "$WORK/nodes.tsv" "$secs"`, `write_run_record "$start" "$end" "$secs" "$T_OK" "$T_BADN" "$taps"`, the same PASS/WARN/FAIL. `make_root` in `tests/helpers/fixtures.bash` must provide `proc/loadavg` (`0.42 0.40 0.38 1/200 1234`) if it does not already. Dispatch: `up|traffic|down|check|record)` in both `case` lists.

- [ ] **Step 4: Run** `bats tests/scenario.bats` — all green (the old `traffic` tests still pass through `run_traffic`/`write_run_record`).
- [ ] **Step 5: Docs.** README row for `r770-scenario.sh` gains `record`. Runbook's IPsec & WAN section gets the `record` paragraph (what it captures, where, the idle tail, the free-space gate, Ctrl-C behaviour) — the text is in `docs/superpowers/specs/2026-10-07-ipsec-wan-scenarios-kit-design.md` under "`record`: one run, one directory"; keep the two in step.
- [ ] **Step 6: Run** `./tests/run.sh`. **Commit:** `git commit -m "r770-scenario.sh record: outer capture on the TAP, inner capture inside the node's netns, idle tail, run.conf, drop stats, checksums; EXIT trap leaves nothing running"`

---

### Task 7: `record --impair` and `--events` — impairment as a run parameter, timed events with a log

**Files:**
- Modify: `scripts/r770-scenario.sh` (`--impair`, `--events` flags; `impair_check`, `impair_apply`, `events_check`, `events_start`, `events_stop`, `event_run`, `tap_of_role`)
- Modify: `tests/scenario.bats`
- Create: `scenarios/s1-w1-ss/events/baseline.txt`, `scenarios/s1-w1-ss/events/wan-flap.txt`
- Modify: `tests/helpers/lint_scenarios.py` + `tests/scenarios.bats` (`check_events`: every `events/*.txt` line is `t|action|arg`, action known, `t` non-decreasing)

**Interfaces:**
- Consumes: `r770-wan.sh apply|clear` (Task 3); `tap_a`/`tap_b` of the run (globals `TAP_A_RUN`, `TAP_B_RUN` set in `cmd_record`).
- Produces: `--impair <profile>@a|b` (repeatable); `--events <file>`; `events.log` lines `<UTC ms>|<t>|<action>|<arg>|<rc>`; `run.conf` lines `impair=<profile>@<a|b>:<tap>` and `events=<file>`; a copy of the events file as `events.txt` in the run directory. Event actions: `note <text>`, `wan-apply <profile>@a|b`, `wan-clear a|b`, `link-down a|b`, `link-up a|b`, `exec <node>|<command>`.

- [ ] **Step 1: Failing tests**

```bash
@test "record --impair refuses a bad spec or an unknown profile before any capture" {
    record_env; scenario up demo --bundle "$BUNDLE" >/dev/null
    for bad in branch-wan@c @a branch-wan no-such@a; do
        run scenario record demo --impair "$bad"; [ "$status" -eq 1 ]; echo "$bad: $output"
    done
    ! grep -q '^tcpdump' "$STUB_LOG"
}
@test "record --impair applies the profile to the named TAP via r770-wan.sh after captures start, records it, clears it at the end" {
    record_env; scenario up demo --bundle "$BUNDLE" >/dev/null
    stub tc 'echo "tc $*" >> "$STUB_LOG"'
    run scenario record demo --impair branch-wan@b; echo "$output"; [ "$status" -eq 0 ]
    d=$(find "$SCENARIO_CASES_DIR/demo" -mindepth 1 -maxdepth 1 -type d | head -1)
    grep -q '^impair=branch-wan@b:lab-tap1$' "$d/run.conf"
    [ "$(grep -n '^tcpdump' "$STUB_LOG" | head -1 | cut -d: -f1)" -lt "$(grep -n 'tc qdisc replace dev lab-tap1' "$STUB_LOG" | head -1 | cut -d: -f1)" ]
    grep -q 'tc qdisc del dev lab-tap1 root' "$STUB_LOG"
}
@test "record --events runs each action at its time, logs it with a millisecond UTC stamp, refuses an unknown action up front" {
    record_env; scenario up demo --bundle "$BUNDLE" >/dev/null
    stub tc 'echo "tc $*" >> "$STUB_LOG"'; stub ip 'echo "ip $*" >> "$STUB_LOG"'
    printf '0|note|traffic start\n1|wan-apply|poor-broadband@a\n2|link-down|b\n2|link-up|b\n3|wan-clear|a\n3|exec|a|echo hi\n' > "$BATS_TEST_TMPDIR/ev.txt"
    run scenario record demo --events "$BATS_TEST_TMPDIR/ev.txt"; echo "$output"; [ "$status" -eq 0 ]
    d=$(find "$SCENARIO_CASES_DIR/demo" -mindepth 1 -maxdepth 1 -type d | head -1)
    [ "$(wc -l < "$d/events.log")" -eq 6 ]
    grep -qE '^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9:]{8}\.[0-9]{3}Z\|1\|wan-apply\|poor-broadband@a\|0$' "$d/events.log"
    grep -q 'ip link set dev lab-tap1 down' "$STUB_LOG"; grep -q 'ip link set dev lab-tap1 up' "$STUB_LOG"
    grep -q 'docker exec .* sh -c echo hi' "$STUB_LOG"
    [ -f "$d/events.txt" ]
    printf '0|teleport|x\n' > "$BATS_TEST_TMPDIR/bad.txt"
    run scenario record demo --events "$BATS_TEST_TMPDIR/bad.txt"; [ "$status" -eq 1 ]; [[ "$output" == *"teleport"* ]]
}
```

The demo scenario's `traffic.sh` returns at once under the stubs, so the scheduler must still reach `t=3`: `events_stop` waits for the scheduler rather than killing it (and the idle tail covers it on the box). Under the test's `sleep 0.05` stub the scheduler's one-second ticks are fast.

- [ ] **Step 2: Run** — FAIL (unknown option `--impair`).

- [ ] **Step 3: Implement** (replace Task 6's `events_start`/`events_stop` no-ops)

```bash
IMPAIR=(); EVENTS_FILE=""; EV_PID=""; TAP_A_RUN=""; TAP_B_RUN=""
tap_of_role() { case "$1" in a) printf '%s' "$TAP_A_RUN" ;; b) printf '%s' "$TAP_B_RUN" ;; *) return 1 ;; esac; }
impair_check() {  # impair_check <profile@role> — valid shape and an existing profile, or die (before any capture)
    local prof=${1%@*} role=${1##*@}
    { [ "$prof" != "$1" ] && [ -n "$prof" ] && [[ "$role" =~ ^[ab]$ ]]; } || die "--impair takes <profile>@a or <profile>@b (got '$1')"
    [ -f "${WAN_PROFILE_DIR:-$KIT_DIR/config/wan/profiles}/$prof.conf" ] || die "no WAN profile '$prof' (see: r770-wan.sh show, config/wan/profiles/)"
}
impair_apply() {  # impair_apply <profile@role> — through r770-wan.sh; remembered for the trap and the manifest
    local prof=${1%@*} role=${1##*@} tap; tap=$(tap_of_role "$role")
    if [ "$DRY" = "1" ]; then echo "DRY-RUN: r770-wan.sh apply $prof $tap"; return 0; fi
    "$KIT_DIR/scripts/r770-wan.sh" apply "$prof" "$tap" || die "r770-wan.sh refused $prof on $tap"
    IMPAIRED_TAPS+=("$tap"); echo "impair=$1:$tap" >> "$RUN_DIR/run.conf"
}
events_check() {  # events_check <file> — every line t|action|arg, known action, t non-decreasing
    local line t act arg prev=-1 n=0
    [ -f "$1" ] || die "no events file $1"
    while IFS= read -r line; do
        n=$((n + 1)); case "$line" in ''|'#'*) continue ;; esac
        IFS='|' read -r t act arg <<< "$line"
        case "$t" in ''|*[!0-9]*) die "$1 line $n: t must be whole seconds" ;; esac
        [ "$t" -ge "$prev" ] || die "$1 line $n: times must not decrease"; prev=$t
        case "$act" in
            note|exec) [ -n "$arg" ] || die "$1 line $n: $act needs an argument" ;;
            wan-apply) impair_check "$arg" ;;
            wan-clear|link-down|link-up) [[ "$arg" =~ ^[ab]$ ]] || die "$1 line $n: $act takes a or b" ;;
            *) die "$1 line $n: unknown action '$act' (known: note wan-apply wan-clear link-down link-up exec)" ;;
        esac
    done < "$1"
}
event_run() {  # event_run <t> <action> <arg> — do it, log it, snapshot ground truth after it
    local rc=0 tap node cmd cid
    case "$2" in
        note)      : ;;
        wan-apply) impair_apply "$3" || rc=$? ;;
        wan-clear) tap=$(tap_of_role "$3"); "$KIT_DIR/scripts/r770-wan.sh" clear "$tap" >/dev/null || rc=$? ;;
        link-down|link-up) tap=$(tap_of_role "$3"); run ip link set dev "$tap" "${2#link-}" || rc=$? ;;
        exec)      node=${3%%|*}; cmd=${3#*|}
                   if cid=$(container_of "$WORK/nodes.tsv" "$node"); then run docker exec "$cid" sh -c "$cmd" || rc=$?; else rc=1; fi ;;
    esac
    printf '%s|%s|%s|%s|%s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$1" "$2" "$3" "$rc" >> "$RUN_DIR/events.log"
    [ "$2" = note ] || gt_snapshot "$NAME" "t$1-$2"
    return 0
}
events_start() {  # events_start — the scheduler, in the background, relative to now
    [ -n "$EVENTS_FILE" ] || return 0
    echo "events=$EVENTS_FILE" >> "$RUN_DIR/run.conf"; cp "$EVENTS_FILE" "$RUN_DIR/events.txt"
    (
        t0=$(date +%s)
        while IFS='|' read -r t act arg; do
            case "$t" in ''|'#'*) continue ;; esac
            while [ $(( $(date +%s) - t0 )) -lt "$t" ]; do sleep 1; done
            event_run "$t" "$act" "$arg"
        done < "$EVENTS_FILE"
    ) & EV_PID=$!
}
events_stop() { if [ -n "$EV_PID" ]; then wait "$EV_PID" 2>/dev/null || true; EV_PID=""; fi; }
```

In `cmd_record`, after reading `tap_a tap_b`: `TAP_A_RUN=$tap_a; TAP_B_RUN=$tap_b`; **before** `cases_gate`: `local i; for i in "${IMPAIR[@]}"; do impair_check "$i"; done; [ -z "$EVENTS_FILE" ] || events_check "$EVENTS_FILE"`; after the captures start and before `start=`: `for i in "${IMPAIR[@]}"; do impair_apply "$i"; done`. Flags: `--impair) IMPAIR+=("${2:-}"); shift ;;` and `--events) EVENTS_FILE=${2:-}; shift ;;`. The scheduler runs in a subshell, so its `impair_apply` cannot grow the parent's `IMPAIRED_TAPS`: `record_cleanup` must also clear every TAP named by an `impair=` line in `run.conf` (`sed -n 's/^impair=.*:\(lab-tap[0-9]*\)$/\1/p'`) — that covers both paths. `record_cleanup` kills a still-running scheduler (`kill "$EV_PID"`) before waiting.

- [ ] **Step 4: Event files.** `scenarios/s1-w1-ss/events/baseline.txt`:
```text
# S1 baseline: no impairment, notes only (times are seconds after traffic start)
0|note|traffic start
```
`scenarios/s1-w1-ss/events/wan-flap.txt`:
```text
# S1 under a branch circuit that drops for 30 s mid-run (an S7 preview; a DPD restart should follow)
0|note|traffic start
10|wan-apply|branch-wan@b
10|wan-apply|branch-wan@a
90|link-down|b
120|link-up|b
200|wan-clear|a
200|wan-clear|b
```
`check_events` in `tests/helpers/lint_scenarios.py` applies `events_check`'s rules to every `scenarios/*/events/*.txt`; a bats test calls `lint events`.

- [ ] **Step 5: Run** both suites and `./tests/run.sh`. Runbook IPsec & WAN section: a paragraph on `--impair <profile>@a|b` (direction rule: `@b` shapes site A → site B, marked "to be measured on staging — Task 11, H7") and `--events <file>` with the action list and `events.log`'s format. **Commit:** `git commit -m "record: --impair <profile>@a|b through r770-wan.sh, --events t|action|arg with a millisecond log; both checked before any capture, both undone by the trap"`

---

### Task 8: Ground truth — SA snapshots, `/gt` collection, `keys=` state

**Files:**
- Modify: `scripts/r770-scenario.sh` (`gt_snapshot`, `gt_collect`, `gt_keys_state` replace the no-ops)
- Modify: `tests/scenario.bats`; `tests/helpers/fake_gns3.py` only if it does not already let a test map a container id back to its node name

**Interfaces:**
- Consumes: `conf <name> gt` — `;`-separated `node|command` entries (a command may contain spaces, hence `;`) — and `conf <name> gt_dirs` — space-separated `node:/path` pairs.
- Produces: `gt/<node>/sa/<tag>-<UTC>.txt` per snapshot; `gt/<node>/` ← `docker cp <cid>:<path>/. gt/<node>/`; `keys=present|absent|n/a` from `gt/<node>/keys.state` (any node `present` → `present`; all `absent` → `absent`; no `gt_dirs` → `n/a`).

- [ ] **Step 1: Failing tests**

```bash
@test "record snapshots ground truth at start, after each event and at end, collects /gt, and reports keys=" {
    record_env; scenario up demo --bundle "$BUNDLE" >/dev/null
    printf 'gt=a|swanctl --list-sas;b|swanctl --list-sas\ngt_dirs=a:/gt b:/gt\n' >> "$SCENARIO_DIR/demo/scenario.conf"
    cid_a=$(grep -o 'docker exec -i [^ ]*' "$STUB_LOG" | head -1 | awk '{print $4}')
    mkdir -p "$BATS_TEST_TMPDIR/gt-$cid_a/keys"; echo present > "$BATS_TEST_TMPDIR/gt-$cid_a/keys.state"; echo k > "$BATS_TEST_TMPDIR/gt-$cid_a/keys/esp_sa"
    # docker cp <cid>:/gt/. <dst> copies gt-<cid> when it exists (node b has none -> absent by default)
    sed -i 's|^  exec)|  cp) src=${2%%:*}; [ -d "$BATS_TEST_TMPDIR/gt-$src" ] \&\& cp -r "$BATS_TEST_TMPDIR/gt-$src/." "$3" \|\| echo absent > "$3/keys.state" ;;\n  exec)|' "$BIN/docker"
    printf '0|note|go\n1|link-down|b\n' > "$BATS_TEST_TMPDIR/ev.txt"; stub ip 'exit 0'
    run scenario record demo --events "$BATS_TEST_TMPDIR/ev.txt"; echo "$output"; [ "$status" -eq 0 ]
    d=$(find "$SCENARIO_CASES_DIR/demo" -mindepth 1 -maxdepth 1 -type d | head -1)
    ls "$d/gt/a/sa/" | grep -q '^start-'; ls "$d/gt/a/sa/" | grep -q '^t1-link-down-'; ls "$d/gt/a/sa/" | grep -q '^end-'
    grep -q 'docker exec .* sh -c swanctl --list-sas' "$STUB_LOG"
    [ -f "$d/gt/a/keys/esp_sa" ]; grep -q '^keys=present$' "$d/run.conf"
    ! grep -q 'gt/' "$d/sha256sums"
}
```

- [ ] **Step 2: Run** — FAIL (no `gt/`).
- [ ] **Step 3: Implement** (replace Task 6's no-ops)

```bash
gt_snapshot() {  # gt_snapshot <scenario> <tag> — each gt= command's output into gt/<node>/sa/<tag>-<UTC>.txt
    local spec entry node cmd cid out
    local -a entries
    spec=$(conf "$1" gt); [ -n "$spec" ] || return 0
    IFS=';' read -ra entries <<< "$spec"
    for entry in "${entries[@]}"; do
        node=${entry%%|*}; cmd=${entry#*|}
        cid=$(container_of "$WORK/nodes.tsv" "$node") || return 0
        out="$RUN_DIR/gt/$node/sa/$2-$(date -u +%Y%m%dT%H%M%SZ).txt"; mkdir -p "${out%/*}"
        if [ "$DRY" = "1" ]; then echo "DRY-RUN: docker exec $cid sh -c '$cmd' > $out"; continue; fi
        docker exec "$cid" sh -c "$cmd" > "$out" 2>&1 || warn "ground truth: '$cmd' in $node exited $? (kept: $out)"
    done
}
gt_collect() {  # gt_collect <scenario> — docker cp each gt_dirs=node:/path into gt/<node>/
    local pair node path cid
    for pair in $(conf "$1" gt_dirs); do
        node=${pair%%:*}; path=${pair#*:}
        cid=$(container_of "$WORK/nodes.tsv" "$node") || continue
        mkdir -p "$RUN_DIR/gt/$node"
        run docker cp "$cid:$path/." "$RUN_DIR/gt/$node/" || warn "ground truth: could not copy $node:$path"
    done
}
gt_keys_state() {  # present if any node says so, absent if every node says so, n/a without gt_dirs
    local f any=0 present=0
    for f in "$RUN_DIR"/gt/*/keys.state; do [ -e "$f" ] || continue; any=1; grep -qx present "$f" && present=1; done
    if [ "$any" -eq 0 ]; then printf 'n/a'; elif [ "$present" -eq 1 ]; then printf 'present'; else printf 'absent'; fi
}
```

`sha256sums` stays `-maxdepth 1 *.pcapng` (keys are never checksummed into a file that might travel).

- [ ] **Step 4: Run** suites; **Commit:** `git commit -m "record: ground truth — SA snapshots at start, each event and end; /gt collected per node; keys= discovered from the node, never assumed"`

---

### Task 9: `r770-scenario.sh verify <run-dir>` — the expected observations, with tshark

**Files:**
- Modify: `scripts/r770-scenario.sh` (`cmd_verify`, `rc_get`, `pcap_file`, `pcap_check`, `decrypt_check`, `drops_check`, `expected_row`)
- Modify: `tests/scenario.bats`; `tests/helpers/lint_scenarios.py` + `tests/scenarios.bats` (`check_pcap_expect`: 5 fields, mode `count|distinct <field>`, expectation `0|>0|>=N`, file `outer|inner-<node>` with the node in the project)
- Modify: `README.md`, `docs/deployment-runbook.md`

**Interfaces:**
- Consumes: `run.conf` (`scenario`, `run_id`, `idle_start`, `keys`, `outer=`, `inner=`), `scenarios/<name>/pcap-expect.txt` rows `<file>|<mode>|<filter>|<expectation>|<label>`, `capture-stats.txt`, `gt/*/keys/esp_sa`.
- Produces: one PASS/FAIL per row written both to the transcript and to `<run-dir>/expected.md`; built-ins `X7 decryption` (SKIP when `keys` ≠ `present`; else tshark with a Wireshark profile built from the keys must decode ≥ 1 ESP packet) and `X8 drops` (every `capture-stats.txt` line says `0 packets dropped by kernel`). Exit 0/2/1.

- [ ] **Step 1: Failing tests**

```bash
# ── verify — tshark over a run directory ────────────────────────────────────
make_run_dir() {  # make_run_dir <scenario> — a finished run under cases/, keys absent
    RD="$SCENARIO_CASES_DIR/$1/$1-20261001T1400Z"; mkdir -p "$RD"
    printf 'scenario=%s\nrun_id=%s-20261001T1400Z\ntap_a=lab-tap0\nouter=outer-lab-tap0.pcapng:lab-tap0\ninner=inner-a.pcapng:a:eth0\nidle_start=1759327440\nkeys=absent\nend=2026-10-01T14:05:00Z\n' "$1" "$1" > "$RD/run.conf"
    printf pcap > "$RD/outer-lab-tap0.pcapng"; printf pcap > "$RD/inner-a.pcapng"
    printf 'outer-lab-tap0: 7 packets captured; 0 packets dropped by kernel\ninner-a: 7 packets captured; 0 packets dropped by kernel\n' > "$RD/capture-stats.txt"
}
@test "verify judges every pcap-expect.txt row with tshark, renders __IDLE_START__, SKIPs decryption without keys, checks drops" {
    record_env; make_run_dir demo
    printf 'outer|count|isakmp|>0|X1 ike seen\nouter|count|udp.port==4500|0|X2 nothing on 4500\nouter|distinct esp.spi|esp|>=4|X5 two SPI pairs\nouter|count|isakmp && frame.time_epoch >= __IDLE_START__|>0|X6 dpd in tail\n' > "$SCENARIO_DIR/demo/pcap-expect.txt"
    # tshark: count = lines printed; -T fields prints the field per packet
    stub tshark 'echo "tshark $*" >> "$STUB_LOG"
case "$*" in
  *"isakmp && frame.time_epoch >= 1759327440"*) printf "1\n2\n" ;;
  *isakmp*) printf "1\n2\n3\n" ;;
  *4500*) : ;;
  *"-e esp.spi"*) printf "0x1\n0x2\n0x3\n0x4\n0x1\n" ;;
esac'
    run scenario verify "$RD"; echo "$output"; [ "$status" -eq 0 ]   # a SKIP does not change the exit (footer)
    [[ "$output" == *"PASS  X1"* && "$output" == *"PASS  X2"* && "$output" == *"PASS  X5"*"4 distinct"* && "$output" == *"PASS  X6"* ]]
    [[ "$output" == *"SKIP  X7"*"keys=absent"* && "$output" == *"PASS  X8"* ]]
    grep -q -- '-r .*/outer-lab-tap0.pcapng -Y isakmp' "$STUB_LOG"
    [ -f "$RD/expected.md" ]; grep -q 'X1' "$RD/expected.md"
}
@test "verify FAILs a row whose expectation does not hold, and a capture with kernel drops" {
    record_env; make_run_dir demo
    printf 'outer|count|udp.port==4500|0|X2 nothing on 4500\n' > "$SCENARIO_DIR/demo/pcap-expect.txt"
    stub tshark 'printf "1\n"'
    sed -i 's/inner-a: .*/inner-a: 7 packets captured; 3 packets dropped by kernel/' "$RD/capture-stats.txt"
    run scenario verify "$RD"; [ "$status" -eq 1 ]
    [[ "$output" == *"FAIL  X2"*"1 packet"* && "$output" == *"FAIL  X8"*"inner-a"* ]]
}
@test "verify refuses a directory that is not a run, and a row it cannot parse" {
    record_env; run scenario verify "$BATS_TEST_TMPDIR"; [ "$status" -eq 1 ]; [[ "$output" == *"run.conf"* ]]
    make_run_dir demo; printf 'outer|weird|x|0|bad\n' > "$SCENARIO_DIR/demo/pcap-expect.txt"
    run scenario verify "$RD"; [ "$status" -eq 1 ]; [[ "$output" == *"weird"* ]]
}
```

- [ ] **Step 2: Run** — FAIL (unknown subcommand).
- [ ] **Step 3: Implement**

```bash
# ── verify ───────────────────────────────────────────────────────────────────
RUN_DIR_ARG=""
rc_get() { sed -n "s/^$2=//p" "$1/run.conf" | head -1; }   # rc_get <run-dir> <key>
expected_row() {  # expected_row <PASS|FAIL|SKIP> <text> — the verdict, in the transcript and in expected.md
    case "$1" in PASS) pass "$2" ;; FAIL) fail "$2" ;; SKIP) skip "$2" ;; esac
    printf -- '- %s  %s\n' "$1" "$2" >> "$RUN_DIR_ARG/expected.md"
}
pcap_file() {  # pcap_file <run-dir> <outer|inner-node> — the capture's path from run.conf, or die
    local f
    case "$2" in
        outer)   f=$(rc_get "$1" outer); f=${f%%:*} ;;
        inner-*) f=$(sed -n "s/^inner=\(inner-${2#inner-}\.pcapng\):.*/\1/p" "$1/run.conf" | head -1) ;;
        *)       die "pcap-expect.txt names '$2'; a row's file is outer or inner-<node>" ;;
    esac
    [ -n "$f" ] && [ -s "$1/$f" ] || die "run has no capture '$2' (run.conf names: $(grep -E '^(outer|inner)=' "$1/run.conf" | cut -d= -f2 | cut -d: -f1 | tr '\n' ' '))"
    printf '%s' "$1/$f"
}
pcap_check() {  # pcap_check <run-dir> <file> <mode> <filter> <expect> <label> — one row -> PASS/FAIL
    local pc n field want=$5
    pc=$(pcap_file "$1" "$2") || exit 1
    case "$3" in
        count)
            n=$(tshark -r "$pc" -Y "$4" 2>/dev/null | wc -l)
            case "$want" in
                0)    if [ "$n" -eq 0 ]; then expected_row PASS "$6"; else expected_row FAIL "$6: $n packet(s) match '$4', expected none"; fi ;;
                '>0') if [ "$n" -gt 0 ]; then expected_row PASS "$6 ($n packets)"; else expected_row FAIL "$6: 0 packets match '$4'"; fi ;;
                *)    die "pcap-expect.txt: count expects 0 or >0 (got '$want')" ;;
            esac ;;
        "distinct "*)
            field=${3#distinct }
            [[ "$want" =~ ^\>=([0-9]+)$ ]] || die "pcap-expect.txt: distinct expects >=N (got '$want')"
            n=$(tshark -r "$pc" -Y "$4" -T fields -e "$field" 2>/dev/null | grep -v '^$' | sort -u | wc -l)
            if [ "$n" -ge "${BASH_REMATCH[1]}" ]; then expected_row PASS "$6 ($n distinct $field)"; else expected_row FAIL "$6: $n distinct $field, expected $want"; fi ;;
        *)  die "pcap-expect.txt: unknown mode '$3' (count | distinct <field>)" ;;
    esac
}
decrypt_check() {  # decrypt_check <run-dir> — X7: outer ESP decrypts with the node's keys
    local keys prof esp_sa n pc
    keys=$(rc_get "$1" keys)
    if [ "$keys" != present ]; then expected_row SKIP "X7 decryption: keys=$keys — the inner capture is the plaintext truth"; return 0; fi
    esp_sa=$(find "$1/gt" -path '*/keys/esp_sa' 2>/dev/null | head -1)
    if [ -z "$esp_sa" ]; then expected_row FAIL "X7 decryption: keys=present but no gt/*/keys/esp_sa"; return 0; fi
    prof="$WORK/.config/wireshark/profiles/gt"; mkdir -p "$prof"; cp "$esp_sa" "$prof/esp_sa"
    pc=$(pcap_file "$1" outer) || exit 1
    # a decrypted ESP packet dissects to its inner protocol; count ESP frames that also carry tcp/udp/icmp
    n=$(HOME="$WORK" tshark -C gt -o esp.enable_encryption_decode:TRUE -r "$pc" -Y 'esp && (tcp || udp || icmp)' 2>/dev/null | wc -l)
    if [ "$n" -gt 0 ]; then expected_row PASS "X7 decryption: $n ESP packets decode with the run's keys"
    else expected_row FAIL "X7 decryption: keys present but no ESP packet decoded — compare esp_sa's SPIs with the outer capture"; fi
}
drops_check() {  # drops_check <run-dir> — X8
    local bad
    if [ ! -s "$1/capture-stats.txt" ]; then expected_row FAIL "X8 drops: no capture-stats.txt"; return 0; fi
    bad=$(grep -v ' 0 packets dropped by kernel' "$1/capture-stats.txt" | cut -d: -f1 | tr '\n' ' ')
    if [ -z "$bad" ]; then expected_row PASS "X8 drops: 0 packets dropped by kernel on every capture"
    else expected_row FAIL "X8 drops: kernel drops on: ${bad% }"; fi
}
cmd_verify() {
    banner "verify — $RUN_DIR_ARG"
    local d=$RUN_DIR_ARG s f line n file mode filt want label istart
    [ -n "$d" ] && [ -f "$d/run.conf" ] || die "${d:-verify} has no run.conf — not a run directory (see: r770-scenario.sh status)"
    s=$(rc_get "$d" scenario); scenario_check "$s"; NAME=$s
    grep -q '^end=20' "$d/run.conf" || warn "run.conf has no clean end= — the run was interrupted; judging what is there"
    work
    f="$SCEN_DIR/$s/pcap-expect.txt"
    istart=$(rc_get "$d" idle_start)
    { echo "# expected observations — $(rc_get "$d" run_id)"; echo; } > "$d/expected.md"
    if [ -f "$f" ]; then
        n=0
        while IFS= read -r line; do
            n=$((n + 1)); case "$line" in ''|'#'*) continue ;; esac
            IFS='|' read -r file mode filt want label <<< "$line"
            [ -n "$label" ] || die "$f line $n: need <file>|<mode>|<filter>|<expectation>|<label>"
            pcap_check "$d" "$file" "$mode" "${filt//__IDLE_START__/$istart}" "$want" "$label"
        done < "$f"
    else
        skip "scenarios/$s has no pcap-expect.txt — only the built-in checks"
    fi
    decrypt_check "$d"
    drops_check "$d"
    note "X9 (Malcolm): r770-scenario.sh ingest $d, then r770-scenario.sh check $s"
    footer "verify"
}
```

Dispatch: `verify|ingest) case "${1:-}" in -*|"") ;; *) RUN_DIR_ARG=$1; shift ;; esac ;;` in the positional block; `verify) cmd_verify ;;` in the final `case`. `tshark` is stubbed in tests; on the box it is in the bundle's apt set.

- [ ] **Step 4:** `check_pcap_expect` in `tests/helpers/lint_scenarios.py`, wired as `lint pcap-expect` in `tests/scenarios.bats`. Run both suites; `./tests/run.sh`.
- [ ] **Step 5: Docs.** README row gains `verify`; the runbook's IPsec & WAN section gets the `verify` paragraph (rows from `pcap-expect.txt` with tshark; decryption only with discovered keys, SKIP with the reason otherwise; zero kernel drops; `expected.md` in the run directory). **Commit:** `git commit -m "r770-scenario.sh verify: pcap-expect.txt rows with tshark, __IDLE_START__ from the manifest, decryption only with discovered keys, zero drops as the bar"`

---

### Task 10: `r770-scenario.sh ingest <run-dir>` — PCAPs into Malcolm, never `gt/`

**Files:**
- Modify: `scripts/r770-scenario.sh` (`cmd_ingest`)
- Modify: `tests/scenario.bats`
- Modify: `README.md`, `docs/deployment-runbook.md`

**Interfaces:**
- Consumes: `run.conf` (`run_id`, `outer=`, `inner=`); `MALCOLM_HOME` (default `/opt/malcolm`, as `check_wait_secs` reads it) → drop-off `$(p "$MALCOLM_HOME")/malcolm/pcap/upload/`.
- Produces: `<run-id>,outer.pcapng` and `<run-id>,inner-<node>.pcapng` in the drop-off, owned `1000:1000` (the rehearsal's measurement in `r770-malcolm-deploy.sh`), `ingest=<UTC>` appended to `run.conf`. FAIL (nothing copied) on a missing or empty capture; refuses when the drop-off does not exist (Malcolm not set up here).

- [ ] **Step 1: Failing tests**

```bash
# ── ingest — into Malcolm's upload drop-off, never gt/ ──────────────────────
@test "ingest copies outer and inner captures with the run id as a tag, never anything under gt/" {
    record_env; make_run_dir demo
    mkdir -p "$RD/gt/a/keys"; echo k > "$RD/gt/a/keys/esp_sa"
    up="$ROOT/opt/malcolm/malcolm/pcap/upload"; mkdir -p "$up"
    stub chown 'echo "chown $*" >> "$STUB_LOG"'
    run scenario ingest "$RD"; echo "$output"; [ "$status" -eq 0 ]
    [ -f "$up/demo-20261001T1400Z,outer.pcapng" ]; [ -f "$up/demo-20261001T1400Z,inner-a.pcapng" ]
    [ "$(find "$up" -type f | wc -l)" -eq 2 ]
    ! find "$up" -name 'esp_sa' | grep -q .
    grep -q 'chown 1000:1000' "$STUB_LOG"; grep -q '^ingest=20' "$RD/run.conf"
}
@test "ingest refuses an empty capture or a run with no captures, copying nothing; and a host without Malcolm" {
    record_env; make_run_dir demo; up="$ROOT/opt/malcolm/malcolm/pcap/upload"; mkdir -p "$up"
    : > "$RD/outer-lab-tap0.pcapng"
    run scenario ingest "$RD"; [ "$status" -eq 1 ]; [[ "$output" == *"outer-lab-tap0.pcapng"*"empty"* ]]
    [ "$(find "$up" -type f | wc -l)" -eq 0 ]
    rm -rf "$up"; printf pcap > "$RD/outer-lab-tap0.pcapng"
    run scenario ingest "$RD"; [ "$status" -eq 1 ]; [[ "$output" == *"pcap/upload"* ]]
}
```

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement**

```bash
# ── ingest ───────────────────────────────────────────────────────────────────
# Copies only the captures run.conf names, by their explicit outer=/inner=
# lines -- never a glob over the run directory, so gt/ (SA dumps, keys) cannot
# travel. Malcolm tags an uploaded file from the comma-separated parts of its
# name: <run-id>,<view>.pcapng shows up under tags <run-id> and <view>.
ingest_views() {  # ingest_views <run-dir> — "<file> <view>" per capture run.conf names
    local line f
    while IFS= read -r line; do
        f=${line#*=}; f=${f%%:*}
        case "$line" in outer=*) printf '%s outer\n' "$f" ;; *) printf '%s %s\n' "$f" "${f%.pcapng}" ;; esac
    done < <(grep -E '^(outer|inner)=' "$1/run.conf")
}
cmd_ingest() {
    banner "ingest — $RUN_DIR_ARG"
    need_root
    local d=$RUN_DIR_ARG up rid f view n=0
    [ -n "$d" ] && [ -f "$d/run.conf" ] || die "${d:-ingest} has no run.conf — not a run directory"
    rid=$(rc_get "$d" run_id); [ -n "$rid" ] || die "$d/run.conf has no run_id"
    up="$(p "${MALCOLM_HOME:-/opt/malcolm}")/malcolm/pcap/upload"
    [ -d "$up" ] || die "no Malcolm drop-off at $up — Malcolm is not set up here (r770-malcolm-deploy.sh full)"
    while read -r f view; do
        [ -s "$d/$f" ] || die "$f is missing or empty in $d — nothing was copied"
    done < <(ingest_views "$d")
    while read -r f view; do
        run cp "$d/$f" "$up/$rid,$view.pcapng" || die "copy of $f failed — the drop-off may hold a partial $rid,$view.pcapng"
        run chown 1000:1000 "$up/$rid,$view.pcapng" || warn "could not chown $rid,$view.pcapng to 1000:1000 — Malcolm's upload watcher may ignore it"
        n=$((n + 1))
    done < <(ingest_views "$d")
    [ "$n" -gt 0 ] || die "$d/run.conf names no capture (outer=/inner=) — nothing to ingest"
    [ "$DRY" = "1" ] || echo "ingest=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$d/run.conf"
    pass "$n capture(s) handed to Malcolm as $rid,<view>.pcapng (tags: $rid, outer, inner-<node>); gt/ stayed in $d"
    note "then: r770-scenario.sh check $(rc_get "$d" scenario)   (record wrote the run record)"
    footer "ingest"
}
```

Dispatch: `ingest) cmd_ingest ;;`.

- [ ] **Step 4: Run** suites; docs: README row gains `ingest`; the runbook's IPsec & WAN section gets the `ingest` paragraph (explicit names, never a glob; `<run-id>,<view>.pcapng`; then `check`). **Commit:** `git commit -m "r770-scenario.sh ingest: the run's captures into Malcolm's drop-off by explicit name, tagged by filename; gt/ never travels"`

---

### Task 11: The staging rehearsal — harness validation H1–H7, then S0 and S1; docs become "as measured"

This task runs on the staging host (VM 9770, air gap blocked, a bundle cut from this kit's commit — `docs/kit-sync.md`, "Cutting a bundle that carries this kit"). Nothing here is a code change until a measurement says so; every result is a transcript under `r770-evidence/` and a run directory under `cases/`. Rule 7 applies throughout: one hypothesis, one change, rerun.

**Files:**
- Modify (after measuring): `docs/deployment-runbook.md` (the IPsec & WAN section: status → "rehearsed <date>", measured values, any correction), `docs/kit-sync.md` (carry-backs confirmed or changed), `scenarios/s1-w1-ss/*` only if a measurement contradicts the content
- Evidence: `r770-evidence/r770-scenario-*.log`, `r770-evidence/r770-wan-*.log`, `cases/s0-w1/*`, `cases/s1-w1-ss/*`

**Procedure (each line is a step with its own PASS/FAIL):**

- [ ] **H0 — prerequisites.** `r770-gns3-deploy.sh full` and `r770-malcolm-deploy.sh full --capture-ifs lab_mirror0` done; `r770-validate.sh --area network --area capture --area gns3 --capture-ifs lab_mirror0 --lab-bridge br-lab` all PASS; `r770-scenario.sh list --bundle $B` shows `s0-w1` and `s1-w1-ss` runnable; `r770-wan.sh show` all clean; `command -v tcpdump tshark nsenter tc`.
- [ ] **H1 — bridge vs member port.** `up s0-w1`; in two shells `tcpdump -ni br-lab icmp -c 20` and `tcpdump -ni lab-tap0 icmp -c 20` while `h-a` pings `h-b`; both show the flow, counts equal. If the bridge capture misses frames (spec R3), the harness is already on the TAP — note it and move on.
- [ ] **H2 — outer + inner, one clock.** `record s0-w1`; `tshark -r outer-*.pcapng -Y icmp -T fields -e frame.time_epoch -e icmp.seq | head -3` vs the same on `inner-gw-a.pcapng`: same packets by `icmp.seq`, inner timestamps earlier than outer by microseconds for site-A-originated frames, never out of order.
- [ ] **H3 — drops.** `verify` of that run: X8 PASS at lane-A rates (50 Mbit/s cap).
- [ ] **H4 — ingest round trip.** `ingest <run-dir>`; after `PCAP_ROTATE_MINUTES`, Arkime shows sessions tagged `s0-w1-<ts>` and `outer`; `find /opt/malcolm/malcolm/pcap/upload -name esp_sa` finds nothing; `check s0-w1` PASS.
- [ ] **H5 — clear.** `r770-wan.sh apply branch-wan lab-tap1`; `ping` h-a→h-b shows ≈ +40 ms one way; `r770-wan.sh clear --all`; RTT back within 1 ms of H2's baseline.
- [ ] **H6 — trap.** `record s0-w1` then Ctrl-C at ~20 s: `pgrep tcpdump` empty, `r770-wan.sh show` clean, the run directory has `end=interrupted …`.
- [ ] **H7 — impairment direction.** `record s0-w1 --impair poor-broadband@b` (expected: site A → site B capped to 10 Mbit/s and +80 ms; `iperf3 -R` or the reverse ping unchanged). **Write the measured direction into the runbook**; if it is the opposite of the design note's claim, swap `a`/`b` in `tap_of_role` (one change), rerun, and correct the design note.
- [ ] **W1 validation (spec §4, `s0-w1`'s `traffic.sh` output in the transcript):** inside `isp1`, `vtysh -c 'show ip route static'` lists both site routes (FRR starts `staticd` with zebra unconditionally — the plan relies on it, this is where it is proven); 20 pings, traceroute showing `198.18.10.1`, `ping -M do -s 1472` succeeding (path MTU 1500), iperf3 ≈ 50 Mbit/s (the cap). Record RTT and throughput in the runbook as the S0 baseline.
- [ ] **S1 — `up s1-w1-ss`**; inside `gw-a`: `swanctl --list-sas` shows `s1-net` INSTALLED; `cat /gt/keys.state` → the O3 answer (present/absent) — **write it into `docs/kit-sync.md`**. `ip xfrm state` non-empty (spec R2).
- [ ] **S1 — negative test (spec §11.1):** with the tunnel down (`swanctl --terminate --ike s1` on gw-a, then before any traffic re-triggers it) a ping h-a→h-b fails — the ISP has no route to the sites. Recorded as the expected failure.
- [ ] **S1 — reference run:** `record s1-w1-ss --events scenarios/s1-w1-ss/events/baseline.txt`, then `verify <run-dir>`: X1–X6, X8 PASS; X7 PASS or SKIP per O3. **If X2 fails (packets on 4500):** MOBIKE is not the whole story — read `gt/gw-a/charon.log` for the float reason; one hypothesis, one change. **If X5 fails:** the 240 s window did not span a rekey (strongSwan randomises `rekey_time` downward by `rand_time`, default 10%); raise `traffic_secs` to 300 — one change.
- [ ] **S1 — X9:** `ingest`, then `check s1-w1-ss` PASS; Arkime tag query shows IKE/ESP only under `outer`, the clear flows under `inner-gw-a`.
- [ ] **S1 — flap variant:** `record s1-w1-ss --events scenarios/s1-w1-ss/events/wan-flap.txt`; `events.log` complete; `gt/gw-a/sa/t90-link-down-*.txt` vs `t120-link-up-*.txt` show the DPD restart (new IKE SPIs); `verify` X1–X6 PASS.
- [ ] **Docs.** Runbook section: status "rehearsed <date> on VM 9770, bundle <id>"; measured baseline RTT/throughput; O3's answer; H7's direction; the pass table X1–X9 with the run ids. `docs/kit-sync.md`: the carry-backs as confirmed. `./tests/run.sh` green. **Commit:** `git commit -m "IPsec & WAN scenarios: staging rehearsal — H1–H7, S0 baseline, S1 reference set; docs as measured"`

---

## Part 2 — roadmap (spec IP5–IP9), entered only after Task 11

Not step-coded on purpose: each item's design depends on a Task-11 measurement (O3 keys, O4 GNS3 docker-node behaviour, H7 direction) or on a build-repo delivery (an image in the pin block). When one is entered, it gets its own plan in `docs/superpowers/plans/` with the same shape as Part 1; the spec's own section is the design input.

| # | Work | Enters when | Kit pieces (sketch) | Build-repo pieces | Exit |
|---|---|---|---|---|---|
| IP5-a | **W2 multi-ISP + S2 route-based (XFRM interfaces) + BGP over the tunnel** (`s2-w2-ss`) | Task 11 done | three FRR provider nodes; the strongSwan image carries no FRR, so S2's gateway is **two nodes** (strongSwan + an FRR router behind it) unless the build repo ships a combined image; `xfrm_interface` on the host (`r770-gns3-deploy.sh labnet` gains `/etc/modules-load.d/`, gated, rollback = remove the file); a second mirrored link needs **two more TAPs** — `GNS3_LAB_TAPS` default stays 4, the scenario asks for 4 via a `taps=4` conf key and the lint accepts two Cloud pairs; `rp_filter` note from spec §4 W2 | combined image, if wanted | underlay validation + `verify` of the route-withdrawal event |
| IP5-b | **W4 CGNAT + S3 NAT traversal** (`s3-w4-ss`) | IP5-a | NAT box = netshoot with `iptables -t nat MASQUERADE` (no appliance needed); `pcap-expect.txt`: `udp.port==4500` **>0**, NAT keepalives, mapping expiry under `lte-poor` | — | NAT-T rows PASS |
| IP6 | **Appliance variants** (`s1-w1-vy`, `-op`, `-mt`) and **S4 interop + F1–F7** | IP5; `r770-scenario.sh` can drive QEMU nodes (today: docker only — `container_of` dies for a qemu node; node config must go over the GNS3 console API or the appliance's own first-boot config file) | a `qemu` node kind in the driver; ground truth over the console (never a management segment on the mirrored bridge — it would pollute the outer view); per-run PSK rendered into the config (spec §5.6) | VyOS/OPNsense/CHR appliance files are already in the bundle; confirm versions carried | interop matrix in `cases/INDEX.md` |
| IP7 | **W3 MPLS L3VPN + S8**, **W6 dual transport + S9**, **S5 hub-and-spoke** | IP6 (CHR for P/PE unless O5 shows FRR LDP works in containers — a staging test: `mpls_router`, `mpls_iptunnel`, per-netns `net.mpls.platform_labels`) | labelled ESP capture on a core link (a third mirrored link); failover events (`link-down` on the MPLS TAP) with timing from `events.log` vs `gt/*/sa/` | O5 disposition | failover timing references |
| IP8 | **Lane B replay** (B1 through the inner side, B2 analysis-only) and **Lane C** physical ingress (`br-lab-ext`, a Slot-4 port) | Task 11 (B1: `tcpreplay` run *inside* the netshoot host node needs no host change); Lane C needs a netplan change (**gated**, `netplan try`, `optional: true`) and O7's port name from discovery | `r770-scenario.sh replay <name> <pcap>`: `tcprewrite` into the scenario's site ranges, `tcpreplay` inside `h-a`; `r770-gns3-deploy.sh extnet --port <name>` (gated) creating `br-lab-ext` with the port as member, no address, a kit TAP for a Cloud; `r770-validate.sh --area network` fails on an address or a capture-port membership | `tcpreplay` deb is in the apt set already; the Slot-4 port choice | replay and external-peer runs PASS |
| IP9 | **W5 satellite / W7 congested + S7 impairment stress**; **`cases/INDEX.md`** | IP5 | profiles `satellite`, `leo` (+ handover **events**: a short `wan-apply` burst profile), `congested-uplink` needs background flows (a second iperf3 pair in the scenario); MTU cases F7 (`ping -M do` sweeps in `traffic.sh`); `r770-scenario.sh index` writes `cases/INDEX.md` from every `run.conf` + `expected.md` | — | index: run → behaviours shown |

Open items the roadmap carries from the spec, with the kit's disposition path:
O2 (custom containers) → operator decision, each classified E or H before a scenario names it; O4 → measured in Task 11 (`docker inspect` of a GNS3 node: privileges, naming, when interfaces attach — `up` already waits for readiness); O6 (Malcolm's IKE/MPLS decode) → Task 11's X9 records what Arkime/Zeek show for IKE (`spicy_ipsec_ike_udp`, measured 2026-09-26) and IP7 records MPLS; O9 (CHR keys) → IP6; O10 (bundle delta) → **none for Part 1**: every image and deb Part 1 needs is already pinned; IP6+ list theirs in `docs/kit-sync.md` for the build repo.

---

## Self-review

**Spec coverage.** §0 principles: layered (scenario × `--impair` × `--events` × lane A — Tasks 4–7), ground truth with every run (6, 8), two views one clock (6), underlay before overlay (`s0-w1` first, Task 11), containers first (Part 1 is strongSwan only), one profile library (Task 3), air gap unchanged (no new pins), free platforms only. §2 open items: O1 closed for the kit (design note, Task 2), O3 discovered at run time (5, 8), O4/O6 measured in 11, O8 already settled (design note R1 row), O10 none for Part 1; O2/O5/O7/O9 → roadmap. §3 addressing: design note + Task 2. §4 W1 + validation: Task 4, Task 11. §5 endpoint contract: E2 (config over `docker exec`, not baked), E4 (`up` waits), E5 (`ready=` + SA check in Task 11), E6 (`/gt`, Task 8), E7 (no module loading in the node); E1/E3 (a kit-built image) deliberately **not** done — the bundled strongSwan image is used as `ipsec-ike` does; building `ipsec-ss` is a build-repo decision recorded in kit-sync. §5.6 per-run PSK → IP6. §6 impairment M1: Task 3; direction rule: Task 7 + H7. Profiles §6.2: Task 3. §7 lane A: Tasks 4–5; B/C → IP8. §8.1 run dir: Task 6 (names adapted: `run.conf`, `events.log`, `capture-stats.txt`, `expected.md` (Task 9), `sha256sums`). §8.2 manifest fields: all present except `nodes:` image references — a cheap addition to Task 6 (`image=<node>:<ref>` lines from `nodes.tsv` + the bundle's image list) if the reviewer wants them. §8.3 commands: mapped (design note). §8.4 ground truth: Task 8 (containers), appliances → IP6; decryption check → Task 9. §8.5 events: Task 7 (`gns3-link-suspend` → IP5 once O4 is measured). §9 host prep: R1 settled, modules → IP5-a when route-based needs `xfrm_interface`. §10 catalog: S0, S1 in Part 1; S2–S9 roadmap with F1–F7 under IP6. §11 templates: Tasks 4–5 verbatim with the kit's addresses and `mobike = no`. §12 risks: design note table. §13 H1–H6 (+H7): Task 11. §14 build order: IP0–IP4 = Part 1, IP5–IP9 = Part 2.

**Placeholder scan.** No TBD/TODO; every code step has its code; the roadmap is labelled as design-pending by construction, not as a placeholder inside a task.

**Type/name consistency.** `conf()` keys: `range inner_capture idle_secs gt gt_dirs` (Tasks 2, 4–6, 8); `run.conf` keys: `scenario run_id project taps tap_a tap_b secs idle_secs spec load_start outer inner start traffic_end idle_start keys load_end end impair events ingest` (Tasks 6, 7, 10); functions: `run_traffic`, `write_run_record`, `cases_gate`, `capture_start`, `capture_stop_all`, `record_cleanup`, `gt_snapshot`, `gt_collect`, `gt_keys_state`, `events_check`, `events_start`, `events_stop`, `event_run`, `impair_check`, `impair_apply`, `tap_of_role`, `rc_get`, `expected_row`, `pcap_file`, `pcap_check`, `decrypt_check`, `drops_check`, `ingest_views`, `cmd_record`, `cmd_verify`, `cmd_ingest`; globals `RUN_DIR RUN_ID RUN_DIR_ARG TAP_A_RUN TAP_B_RUN IMPAIRED_TAPS IMPAIR EVENTS_FILE EV_PID CAP_PIDS CAP_LABELS T_OK T_OKN T_BADN`. `r770-wan.sh` reads `WAN_PROFILE_DIR` and writes `/run/r770-wan/<tap>`; Task 7's `impair_check` reads the same profile-dir default.

**Review Focus coverage.** 1 → Task 6 trap test; 2 → Task 6 "outer alone"; 3 → Task 3 malformed-profile test; 4 → Task 7 bad-spec test; 5 → Task 10 empty-capture test.
