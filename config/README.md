# config/ — what the kit installs onto the R770

Every file here was carried over from the build repo (`simlab-build`, under its
`config/`) where it was proven on the staging rehearsal of 2026-09-12, then
altered only where a value was staging-specific. The kit renders `__TOKEN__`
placeholders at deploy time; `.lab` names stay literal because they are a
decision of record, not a variable.

Nothing here carries a version pin. Image tags come from the bundle's own
`*/image-list.txt` files; the Malcolm config `version` is derived from the
bundled installer's filename. `tests/no-pins.bats` enforces this.

| Kit file | Build-repo source | Delta in the kit | Why |
|---|---|---|---|
| `nginx/{portal,docs,gns3,monitoring}.lab.conf` | same path | none | proven vhosts |
| `nginx/malcolm.lab.conf` | same path | comments reworded (no version numbers, names the rebind subcommand) | no-pins rule |
| `nginx/snippets/lab-tls.conf` | same path | comment no longer names the staging VM's CA path | the R770 issues its own CA |
| `nginx/snippets/lab-auth.conf` | same path | none | |
| `monitoring/docker-compose.yml` | same path | `env_file` → `__SECRETS_DIR__/grafana-admin.env`; Prometheus retention 30d (buildout §10; rehearsal ran 7d on a small VM); cAdvisor `--docker_only --housekeeping_interval=30s` | staging path removed; measured 1.3 GiB cAdvisor cost |
| `monitoring/{prometheus,alertmanager,blackbox}.yml`, `grafana/provisioning/datasources/prometheus.yml` | same paths | none | |
| `gns3/gns3_server.conf.template` | same path | `__PASSWORD__` → `__ADMIN_PW__`; `jwt_secret_key` line dropped (measured: not honoured) | fewer lies in the template |
| `systemd/gns3.service` | new | — | a server started from a shell outlived its tmux session |
| `config/docs/mkdocs.yml` | `config/docs/mkdocs.yml` | header comment names the kit's build path | built on the R770, not the VM |
| `portal/index.html.template` | `portal/index.html` | `(staging rehearsal)` title removed; staging IP → `__MGMT_IP__`; staging password paths → "issued by the operator" | host-specific |
| `malcolm/malcolm-config.json.template` | `malcolm/malcolm-config-rehearsal.json` | `pcapDir=/data/pcap/raw`, `indexDir=/data/index`, `useDefaultStorageLocations=false`, `autoSuricata=false`, `zeekPullIntelligenceFeeds=false`, `zeekIntelOnStartup=false`; tokens `__PCAP_NODE_NAME__ __OS_MEMORY__ __LS_MEMORY__ __ARKIME_MANAGE_PCAP__ __ARKIME_FREE_SPACE_G__ __MALCOLM_VER__` | R770 storage layout; Suricata disabled by decision; no feed pulls on an air gap; heaps sized from the host |

Tokens the kit knows how to render (any other `__TOKEN__` fails the render):

| Token | Rendered by | From |
|---|---|---|
| `__MGMT_IP__` | `r770-portal-deploy.sh portal` | `--mgmt-ip` (required; never discovered by guessing) |
| `__SECRETS_DIR__` | `r770-monitoring-deploy.sh env` | `/etc/lab/secrets` |
| `__ADMIN_PW__` | `r770-gns3-deploy.sh config` | `/etc/lab/secrets/gns3-admin.pw` |
| `__PCAP_NODE_NAME__` | `r770-malcolm-deploy.sh configure` | `hostname -s` |
| `__OS_MEMORY__`, `__LS_MEMORY__` | `r770-malcolm-deploy.sh configure` | computed from `free -g` (OpenSearch capped at 31g) |
| `__ARKIME_MANAGE_PCAP__`, `__ARKIME_FREE_SPACE_G__` | `r770-malcolm-deploy.sh configure` | `--arkime-free-space-g N` (else `false` / none: Phase 10 sets the floor from measured feed rates) |
| `__MALCOLM_VER__` | `r770-malcolm-deploy.sh configure` | the bundled `malcolm-<ver>-docker_install.zip` filename |

## Keeping it in step with the build repo

See `docs/kit-sync.md`. Short form: on the staging host, `diff -r
<simlab-build>/config config/` — every hunk must be either a delta listed
above or a change to port; nothing else.
