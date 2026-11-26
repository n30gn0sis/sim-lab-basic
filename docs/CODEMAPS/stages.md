<!-- Generated: 2026-11-20 | Files scanned: 15 scripts/, 34 config/ | Token estimate: ~1000 -->

# Pipelines → scripts → subcommands

There is no outer orchestrator. `r770-malcolm-deploy.sh full`,
`r770-gns3-deploy.sh full` and `r770-docs-deploy.sh full` are three
independent entry points, each printed by that script's own `--help`. Each
steps through its own `STEPS=(...)` array in order, stopping at the first
refusal; `--from/--to/--only` slice it. 🔒 = gated (prints current ·
proposed · rollback, needs `--yes` or a `y`).

| Pipeline | Script | `full` step sequence | Operator-invoked extras |
|---|---|---|---|
| Malcolm | `scripts/r770-malcolm-deploy.sh` | `preflight` `gate` `copy` `apt` 🔒 `phone-home` 🔒 `docker` 🔒 `files` `load` `unpack` `capture` 🔒 `configure` `secrets` `auth` 🔒 `rebind` `start` | `assert-tags`, `stop`, `status`, `inventory`, `dashboards`, `arkime-views` |
| GNS3 | `scripts/r770-gns3-deploy.sh` | `preflight` `gate` `copy` `apt` 🔒 `phone-home` 🔒 `docker` 🔒 `files` `load` `venv` `secrets` `config` `service` 🔒 `labnet` 🔒 | `assert-tags`, `status` |
| Docs | `scripts/r770-docs-deploy.sh` | `preflight` `gate` `copy` `apt` 🔒 `phone-home` 🔒 `docker` 🔒 `files` `load` `build` | `assert-tags`, `status` |
| Front door | `scripts/r770-portal-deploy.sh` | none — never part of a `full`; run by hand as `ca` `cert` `htpasswd` `nginx` 🔒, in that order, after Malcolm's `auth` step | `status`, `--print-sans` |

The first seven steps of each `full` (`preflight` through `files`) call
`scripts/r770-import-bundle.sh`'s own subcommands of the same names — every
one idempotent, so running more than one pipeline on the same box costs
nothing extra beyond an extra bundle re-verification at `gate` per pipeline.
From `load` on, each script runs its own commands; `r770-import-bundle.sh`
has no `load`/`images` subcommand of its own — Malcolm, GNS3 and docs each
load and tag-assert their own tarball.

Required arguments: `--bundle <dir>` always for `full`; `--media`/`--device`
for its `gate`/`copy` steps.

## The installer (optional)

`scripts/r770-install.sh` takes a bare Ubuntu 24.04 R770 plus the bundle media
to a proven lab in one re-enterable run. It is a thin sequencer: each step is
an existing entry point, called with arguments from `/etc/lab/install.conf`.

| Subcommand | Does |
|---|---|
| `discover` | prints disks, NICs, addresses, bridges, mounts; writes an empty `install.conf.template` |
| `wizard` | picks each value from numbered lists of what `discover` found |
| `plan` | checks `install.conf`, then every gated step under `--dry-run` |
| `run` | `import` `gns3` `malcolm` `docs` `portal` `dashboards` `validate` `e2e`, stopping at the first FAIL; `--from`/`--to` slice it |
| `status` | which of those steps this host has finished |

`run` exits `0` only when INSTALLED; `2` is finished with warnings, never
INSTALLED.

## Subcommands NOT in any `full`

Each script has more than `full` calls. These are operator-invoked:

| Script | Extra | Why it is not automatic |
|---|---|---|
| import-bundle | `status` | read-only |
| malcolm | `assert-tags` | the tag check alone |
| malcolm | `stop` `status` | lifecycle / read-only |
| malcolm | `inventory` | read-only; what Dashboards holds now |
| malcolm | `dashboards` `arkime-views` | need a started stack; a failed dashboard import must not fail a deployment that stood every service up |
| gns3 | `assert-tags` `status` | the tag check alone / read-only |
| docs | `assert-tags` `status` | the tag check alone / read-only |
| scenario | `list` `up` `traffic` `record` `verify` `ingest` `down` `status` `check` | an operator tool, not a deployment step: runs the scenario pack on a deployed GNS3 (after `labnet`); `record` captures a run, `verify` judges it with tshark, `ingest` drops its captures into Malcolm, `check` judges a live run in Arkime; not gated — it touches only the GNS3 projects it imported |
| e2e | (one command) | a test runner: `validate`, then every scenario `up` → `traffic` → `down`, then every `check`; one report, not gated |
| capture-ports | `apply` 🔒 `status` | Malcolm's `capture` step calls `apply`; standalone for re-checking physical capture ports |
| wan | `apply` `show` `clear` | an operator tool, not a deployment step: HTB rate plus netem from `config/wan/profiles/*.conf` on `lab-tapN` only, refusing any other name; not gated, it records what it applied under `/run/r770-wan/` |
| portal | `ca` `cert` `htpasswd` `nginx` | the whole front door is optional and hand-run — see above |
| portal | `status`, `--print-sans` | read-only |

## The gates

`apt` (sources rewrite) · `phone-home` (timers, snapd) · `docker` (engine
install) · `malcolm capture` (physical capture ports) · `gns3 service` (the unit) ·
`gns3 labnet` (the lab bridge) ·
`portal nginx` (the site set).
`--non-interactive` without `--yes` stops at the first one, on purpose.

## Config each pipeline installs

Config files are templates; `config/README.md` owns the token table and the
deltas from upstream defaults. Renderer → destination:

| Config | Installed by |
|---|---|
| `config/gns3/gns3_server.conf.template`, `config/systemd/gns3.service` | `gns3-deploy config` / `service` |
| `config/networkd/*` | `gns3-deploy labnet` |
| `config/malcolm/malcolm-config.json.template` | `malcolm-deploy configure` |
| `config/malcolm/dashboards/*.ndjson.template` | `malcolm-deploy dashboards` |
| `config/malcolm/arkime-views/*.views` | `malcolm-deploy arkime-views` |
| `config/nginx/*.lab.conf`, `config/nginx/snippets/*` | `portal-deploy nginx` |
| `config/docs/mkdocs.yml` | `docs-deploy build` |

`tests/references.bats` fails if a `config/` file no script installs.

## Secrets

Generated once on the box, mode 0600 in a 0700 directory, value never printed:
`/etc/lab/secrets/gns3-admin.pw`, `malcolm-admin.pw`, `restic.pw`. Locations
and modes are documented in `docs/secrets-locations.md`.

## Validation areas

`host cpu-ram storage network virtualization gns3 wan capture backup airgap
portal` — all by default, `--area` to select. Hardware expectations and
interfaces are **arguments** (`--expect-threads`, `--expect-ram-gb`,
`--mgmt-if`, `--capture-ifs`, `--mgmt-cidr`), never discovered by guessing. A
check that cannot run is `SKIP` with its reason and does not change the exit
code. See `docs/validation.md`.
