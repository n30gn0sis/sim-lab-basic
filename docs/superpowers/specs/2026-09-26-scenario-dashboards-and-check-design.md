# Scenario dashboards and the end-to-end check — design

**Date:** 2026-09-26 · **Sub-projects:** 4 (dashboards) and 5 (automated end-to-end check) of "test out the dashboards and network scenarios"
**Builds on:** `docs/superpowers/specs/2026-09-24-scenario-pack-design.md`, `docs/superpowers/specs/2026-09-24-lab-mirror-feed-design.md`, the 2026-09-26 staging rehearsal (kit PR #5)

## Goal

An analyst can open Malcolm and find each scenario's traffic without typing a query. An operator can prove that a scenario's run reached Malcolm with one command: every flow its `expect.txt` promises is judged PASS or FAIL for that run's window. Both use the same query for the same row, by construction.

## Decisions (from brainstorming)

| # | Decision |
|---|---|
| D1 | One "Lab scenarios" overview dashboard, plus a saved search and an Arkime view per scenario (option A) |
| D2 | Objects are **generated from `scenarios/`** at deploy time. The ranges live once, in `scenario.conf`, and are never restated in `config/` |
| D3 | Sub-projects 4 and 5 share **one translator** from an `expect.txt` row to queries |
| D4 | Dashboard panels are **saved searches** (a table of sessions), not visualizations. A search's saved-object format is stable across Malcolm versions and a visualization's `visState` is not, and the kit has never shipped a visualization |
| D5 | The check queries Arkime's session API with `bounding=either` (the session overlaps the window) |

## Evidence behind D5 (VM 9770, 2026-09-26)

Queries were made to `GET https://127.0.0.1:8443/arkime/api/sessions` as the kit's `analyst` user, with `expression`, `startTime`, `stopTime` and `length=1`, reading `recordsFiltered`:

| Query | Window | Sessions |
|---|---|---|
| `ip.protocol == 89 && ip.dst == 224.0.0.5` | ospf run 00:57:46–00:58:47Z | 16 |
| `ip.protocol == icmp && ip.src == 10.203.1.0/24 && ip.dst == 10.203.3.0/24` | same | 2 |
| `ip.protocol == tcp && port.dst == 5201 && …` | same | 33 |
| `ip.src == 10.203.0.0/16` | control, 00:10–00:11Z | 0 |
| `ip.protocol == tcp && port == 179 && ip == 10.204.0.0/24` | bgp run 00:43:14–00:43:35Z, default bounding | **0** |
| same | same, `bounding=either` | **2** |

- **Both providers counted.** The counts include Arkime and Zeek records (`event.provider`), which Malcolm keeps in one index.
- **Why `either`.** A long-lived control-plane session (BGP, and an IKE SA that survives a window) starts before the window, and Arkime saves it after the window. The default bounding (last packet in range) misses it; `either` (overlaps) does not.
- **Credentials.** `date=-1` means "all time" and must never be sent with a window. The user is `MALCOLM_ADMIN_USER` (default `analyst`), and the password comes from `/etc/lab/secrets/malcolm-admin.pw`.

## Evidence behind the views API (VM 9770, measured during the final review)

The kit first modelled Arkime's pre-5 views API. These are the live answers from Malcolm's Arkime, through `https://127.0.0.1:8443` as the kit's `analyst` user; the kit and its test stubs are built to them:

| Request | Live answer |
|---|---|
| `GET /arkime/api/user/views` | 404, body `Old API` (the pre-5 path is a catch-all) |
| `GET /arkime/api/views` | 200, `{"data":[{"name":…,"expression":…,"user":"analyst","id":…},…]}` |
| `GET /arkime/api/user` | 200, the logged-in user (the check's reachability probe) |
| `GET /arkime/api/sessions?…` | 200 with `recordsFiltered`, unchanged |
| `POST /arkime/api/view` without `x-arkime-cookie` | 500, `{"success":false,"text":"Missing token"}` |
| Token source | `GET /arkime/sessions` (the HTML page) sets the cookie `ARKIME-COOKIE`; `GET /arkime/api/user` sets none. The header value is the cookie's value URL-decoded |
| `POST /arkime/api/view` with the token | 200, `"Created view!"`, but the name is stripped to `[-a-zA-Z0-9_: ]` (`tcp/179 10.0.0.0/24 -> …` came back as `tcp179 1000024 - …`) |
| The same POST twice | two views with the same name: no duplicate refusal |
| `DELETE /arkime/api/view/<id>` with the token | 200, `"Deleted view successfully"` |

## Units

### 1. `scripts/lib/expect.sh` — the translator (new, sourced)

It has no I/O of its own, and exposes:

| Function | Output |
|---|---|
| `expect_rows <scenario-dir>` | `<n>|<proto>|<port>|<src>|<dst>` (`|`, not a tab: bash `read` collapses an empty field between tabs, and the port is often empty) per data line of `expect.txt`; `n` is the row's ordinal among data lines (comments and blank lines skipped) |
| `expect_arkime <proto> <port> <src> <dst>` | the Arkime expression |
| `expect_kql <proto> <port> <src> <dst>` | the Dashboards query in KQL (`"language":"kuery"`, as the IPsec searches use) |
| `expect_label <proto> <port> <src> <dst>` | a human label, e.g. `tcp/179 10.204.0.0/24 -> 10.204.0.0/24` (ASCII `->`, so names survive grep and sed) |

Translation rules:

| Field | Arkime | KQL |
|---|---|---|
| proto `tcp` `udp` `icmp` | `ip.protocol == tcp` (by name) | `network.transport:tcp` |
| proto `esp` / `ah` / `ospf` | `ip.protocol == 50` / `51` / `89` | `network.iana_number:50` / `51` / `89` |
| port `N` (may be empty) | `port == N`: either side, since IKE is 500↔500 | `(source.port:N or destination.port:N)` |
| src CIDR | `ip.src == <cidr>` | `source.ip:"<cidr>"` |
| dst CIDR | `ip.dst == <cidr>` | `destination.ip:"<cidr>"` |

Clauses are joined with `&&` in Arkime and with `and` in KQL.

**Refusals, each naming the row:** an unknown protocol; a port on `esp`/`ah`/`ospf`/`icmp`; a port outside 1–65535; a src/dst that is not an IPv4 CIDR. The protocol set is closed on purpose: a new protocol is a one-line table change with a test, never a guess.

### 2. The Malcolm login moves into a sourced helper

`r770-malcolm-deploy.sh`'s `OSD_NETRC` setup, `osd_api`, `arkime_api` and `osd_reachable` move to `scripts/lib/malcolm-api.sh`, sourced by `r770-malcolm-deploy.sh` and `r770-scenario.sh`. There is no behaviour change for `r770-malcolm-deploy.sh`, and its existing tests must pass untouched. The password goes only into the 0600 netrc and never into argv or the transcript (existing tests plus a new one for `check`).

### 3. Generated objects — `r770-malcolm-deploy.sh dashboards` and `arkime-views`

For every `scenarios/<s>/` (discovered by glob, the same way `r770-scenario.sh` does), the step emits the objects below.

| Object | Id | Title | Query |
|---|---|---|---|
| saved search (range) | `lab-scenario-<s>` | `Scenario <s> - all traffic (lab)` | `source.ip:"<range>" or destination.ip:"<range>"` |
| saved search (per row) | `lab-scenario-<s>-row-<n>` | `Scenario <s> - <label> (lab)` | `expect_kql` |
| Arkime view (range) | — | `Scenario <s> - all traffic` | `ip == <range>` |
| Arkime view (per row) | — | `Scenario <s> - row <n> <proto>[ <port>]`, e.g. `Scenario bgp - row 1 tcp 179` (Arkime keeps only `[-a-zA-Z0-9_: ]` of a name, so the label cannot be used) | `expect_arkime` |
| dashboard | `lab-scenarios-overview` | `Lab scenarios - Overview (lab)` | one panel per range search, in `scenarios/` order |

- **Shape.** Same line shape and field set as `config/malcolm/dashboards/ipsec.ndjson.template`: one object per line, `{"id":…,"type":…,…}` first, no version fields, and the index pattern as `__NETWORK_INDEX_PATTERN_ID__`, rendered by the existing mechanism.
- **Columns.** Every search gets the columns `source.ip`, `destination.ip`, `destination.port`, `network.transport`, `network.protocol` and `event.provider`.
- **Idempotent.** Ids are stable, so a re-run overwrites (`overwrite=true`).
- **Read back.** The scenario ndjson is written to the kit's scratch space, imported as a second file after the IPsec one, and read back id by id through the same assert-every-object path. A missing object prints `MISSING` with its id, and the step FAILs.
- **Views.** The step lists the views Arkime holds (`GET /api/views`) once, posts (`POST /api/view`, with the `x-arkime-cookie` token) each IPsec and scenario view whose name is not already present, and reads them all back by name. A name outside `[-a-zA-Z0-9_: ]` is refused before anything is posted. A view already present is left as it is, so a changed expression needs the old view deleted in Arkime first.
- **Refusals.** A translation refusal stops the step **before any import**, naming `scenarios/<s>/expect.txt` and the row.
- **What the kit source holds.** No new file under `config/` carries a range. The generator's JSON skeletons (the saved-search line and the dashboard panel) live in the generator function itself, with a test pinning their shape against the IPsec template's lines.

### 4. `r770-scenario.sh check <name> [--run <file>]` (new subcommand)

- **The run.** It takes the newest `scenario-<name>-*.run` under the evidence directory, or `--run`, and refuses a record whose `scenario=` is not `<name>`, or which lacks `start=`/`end=`. It needs root (to read the secret), like the other subcommands.
- **Reachability.** It probes `GET /api/user` and SKIPs with the reason "Arkime did not answer on 127.0.0.1:8443 — start Malcolm" when the API does not answer, and "no run record — run r770-scenario.sh traffic <name> first" when there is no run.
- **Per row.** For each row it `GET`s `/arkime/api/sessions` with `expression=expect_arkime`, `startTime`/`stopTime` from the record, `bounding=either` and `length=1`, and reads `recordsFiltered`.
- **Polling.** It polls every 10 s until every row is above 0 or `SCENARIO_CHECK_WAIT_SECS` (default 180) passes. Arkime writes a session when it closes or at a periodic save, so an immediate check can be early.
- **PASS:** `PASS  <s> row <n> <label>: <count> session(s) in <start>–<end>`.
- **FAIL:** `FAIL  <s> row <n> <label>: 0 sessions after <wait>s`, followed by a diagnosis. The diagnosis says to first confirm the flow is on the mirror (`tcpdump -ni lab_mirror0` with a filter built from the row), then check Malcolm's live capture (`r770-validate.sh --area capture`).
- **API errors.** An API answer that is not JSON with `recordsFiltered` is a FAIL naming the HTTP status, never a 0.
- **Output.** The footer uses the usual 0/2/1 exit, and the transcript is in `r770-evidence/`. The run record is never modified.
- **Listings.** `check` joins `list`, `up`, `traffic`, `status` and `down` in the usage header and in `docs/deployment-runbook.md`'s scenarios section.

## Testing (offline, `./tests/run.sh`)

- **`tests/expect.bats`:**
  - every row of the pack, table-driven, to both queries;
  - refusals for an unknown protocol, a port on `ospf`, port 0 and 70000, and a non-CIDR;
  - the ordinals of `expect_rows` skip comments and blank lines.
- **`tests/malcolm-deploy.bats`:**
  - the rendered scenario ndjson has one range search per scenario, one search per row, and one dashboard referencing exactly the range searches;
  - ids are stable across two runs;
  - a row that fails translation stops the step with no import call;
  - the views file gains the range and row views;
  - the existing IPsec tests pass unchanged after the move to the shared helper.
- **`tests/scenario.bats`:**
  - `check` against a stubbed `curl` answering per expression: all PASS; one row FAIL;
  - a row whose count appears on the second poll (with `sleep` stubbed);
  - `bounding=either` on every call, and `date=` never sent;
  - the password in neither argv nor the transcript;
  - SKIP when the API is unreachable, SKIP with no run record;
  - refusal of a record for another scenario;
  - `--run` picking a named record.
- **`tests/scenarios.bats`:** every `expect.txt` row in the pack translates (the lint calls the translator).
- **`tests/no-internet.bats`:** unchanged, and still green. The only URL is `127.0.0.1:8443`.

## Staging proof (not bats)

On VM 9770, after `dashboards`, `arkime-views` and a `traffic` run of each scenario:
- `r770-scenario.sh check <s>` PASSes every row of all five;
- the Lab scenarios dashboard shows each scenario's sessions;
- the per-row Arkime views return that run's sessions.

The transcripts join the rehearsal evidence.

## Out of scope

- charts and visualizations (D4);
- alerting;
- running `check` automatically after `traffic`, which stays generation-only;
- Suricata;
- checking negative expectations (flows that must *not* appear).

The IPsec objects are unchanged.

## Documentation

- `docs/deployment-runbook.md`: `check` in the scenarios section, and the generated objects in the dashboards section.
- `config/README.md`: a note that scenario objects are generated, not carried.
- `README.md`: the `scripts/lib/` row names the two new helpers.
