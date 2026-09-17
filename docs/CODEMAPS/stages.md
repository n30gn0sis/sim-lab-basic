<!-- Generated: 2026-09-17 | Files scanned: 9 scripts, 20 config files | Token estimate: ~850 -->

# Stages → scripts → subcommands

`r770-deploy.sh --list` prints these 13 in order. `--from/--to/--only` slice
them; the run stops at the first refusal. 🔒 = gated (prints current ·
proposed · rollback, needs `--yes` or a `y`).

| # | Stage | Script | Subcommand(s) the runner calls | Lands in |
|---|---|---|---|---|
| 1 | preflight | import-bundle | `preflight` | — (read-only checks) |
| 2 | gate | import-bundle | `gate` | mounts `--media` read-only |
| 3 | copy | import-bundle | `copy` | `/srv/bundles/` |
| 4 | apt 🔒 | import-bundle | `apt` | `/srv/repo/apt`, `/etc/apt/sources.list*` |
| 5 | phone-home 🔒 | import-bundle | `phone-home` | systemd timers, snapd, motd |
| 6 | docker 🔒 | import-bundle | `docker` | Docker Engine from the local repo |
| 7 | images | import-bundle | `images` | the Docker image store |
| 8 | files | import-bundle | `files` | `/srv/vms/base`, `/srv/gns3`, `/opt/enrichment`, `/srv/docs` |
| 9 | gns3 🔒 | gns3-deploy | `venv` `secrets` `config` `service` | `/etc/gns3`, `/srv/gns3`, systemd unit |
| 10 | malcolm | malcolm-deploy | `load` `unpack` `configure` `secrets` `auth` `rebind` `start` | `/opt/malcolm` |
| 11 | portal 🔒 | portal-deploy | `ca` `cert` `htpasswd` `nginx` `portal` `docs` | `/etc/lab/ca`, `/etc/nginx`, `/srv/docs` |
| 12 | monitoring | monitoring-deploy | `env` `up` | the monitoring stack directory |
| 13 | validate | airgap-check, then validate | `--area airgap host storage portal monitoring gns3` | writes a report |

Required arguments: `--bundle <dir>` always; `--media`/`--device` for stages
2–3; `--mgmt-ip` for stage 11 (the runner refuses rather than guess it).

## Subcommands NOT in the runner

Each script has more than the runner calls. These are operator-invoked:

| Script | Extra | Why it is not automatic |
|---|---|---|
| import-bundle | `status` | read-only |
| gns3 | `status` | read-only |
| malcolm | `assert-tags` | the tag check alone |
| malcolm | `stop` `status` | lifecycle / read-only |
| malcolm | `inventory` | read-only; what Dashboards holds now |
| malcolm | `dashboards` `arkime-views` | need a started stack; a failed dashboard import must not fail a deployment that stood every service up |
| portal | `status`, `--print-sans` | read-only |
| monitoring | `down` (`--purge-volumes` 🔒) | destructive |

## The six gates

`apt` (sources rewrite) · `phone-home` (timers, snapd) · `docker` (engine
install) · `gns3 service` (the unit) · `portal nginx` (the site set) ·
`monitoring down --purge-volumes` (the data volumes). `--non-interactive`
without `--yes` stops at the first one, on purpose.

## Config each stage installs

Config files are templates; `config/README.md` owns the token table and the
deltas from the build repo. Renderer → destination:

| Config | Installed by |
|---|---|
| `config/gns3/gns3_server.conf.template`, `config/systemd/gns3.service` | `gns3-deploy config` / `service` |
| `config/malcolm/malcolm-config.json.template` | `malcolm-deploy configure` |
| `config/malcolm/dashboards/*.ndjson.template` | `malcolm-deploy dashboards` |
| `config/malcolm/arkime-views/*.views` | `malcolm-deploy arkime-views` |
| `config/nginx/*.lab.conf`, `config/nginx/snippets/*` | `portal-deploy nginx` |
| `config/portal/index.html.template` | `portal-deploy portal` |
| `config/docs/mkdocs.yml` | `portal-deploy docs` |
| `config/monitoring/*` | `monitoring-deploy env` / `up` |

`tests/references.bats` fails if a `config/` file no script installs.

## Secrets

Generated once on the box, mode 0600 in a 0700 directory, value never printed:
`/etc/lab/secrets/gns3-admin.pw`, `malcolm-admin.pw`, `restic.pw`. Locations
and modes are documented in `docs/secrets-locations.md`.

## Validation areas

`host cpu-ram storage network virtualization gns3 wan capture monitoring
backup airgap portal` — all by default, `--area` to select. Hardware
expectations and interfaces are **arguments** (`--expect-threads`,
`--expect-ram-gb`, `--mgmt-if`, `--capture-ifs`, `--mgmt-cidr`), never
discovered by guessing. A check that cannot run is `SKIP` with its reason and
does not change the exit code. See `docs/validation.md`.
