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
| `nginx/{docs,gns3}.lab.conf` | same path | none | proven vhosts |
| `nginx/malcolm.lab.conf` | same path | comments reworded (no version numbers, names the rebind subcommand) | no-pins rule |
| `nginx/snippets/lab-tls.conf` | same path | comment no longer names the staging VM's CA path | the R770 issues its own CA |
| `nginx/snippets/lab-auth.conf` | same path | none | |
| `gns3/gns3_server.conf.template` | same path | `__PASSWORD__` → `__ADMIN_PW__`; `jwt_secret_key` line dropped (measured: not honoured) | fewer lies in the template |
| `systemd/gns3.service` | new | — | a server started from a shell outlived its tmux session |
| `networkd/{br-lab,lab-mirror}.netdev`, `networkd/{br-lab,lab-mon0,lab_mirror0}.network`, `networkd/lab_mirror0.link`, `networkd/lab-tap.{netdev,network}.template` | new | — | Phase 11 live mirror: a hub-mode lab bridge (no MAC learning, no multicast snooping) whose veth peer Malcolm captures, with offloads off on that capture end (installed as `/etc/systemd/network/05-*` by `r770-gns3-deploy.sh labnet`) |
| `config/docs/mkdocs.yml` | `config/docs/mkdocs.yml` | header comment names the kit's build path | built on the R770, not the VM |
| `malcolm/dashboards/ipsec.ndjson.template` | new | — | IPsec saved searches and a dashboard for server-bound and GNS3 traffic. Queries are built from IANA protocol numbers and the registered IKE ports, so they do not drift when the bundled Malcolm moves; the index pattern is a token read off the running stack |
| `malcolm/arkime-views/ipsec.views` | new | — | the packet-side counterpart, as Arkime expressions. `<name>\|<expression>` per line, not JSON: there is no `jq` on the R770 |
| `malcolm/malcolm-config.json.template` | `malcolm/malcolm-config-rehearsal.json` | `pcapDir=/data/pcap/raw`, `indexDir=/data/index`, `useDefaultStorageLocations=false`, `autoSuricata=false`, `zeekPullIntelligenceFeeds=false`, `zeekIntelOnStartup=false`; tokens `__PCAP_NODE_NAME__ __OS_MEMORY__ __LS_MEMORY__ __ARKIME_MANAGE_PCAP__ __ARKIME_FREE_SPACE_G__ __MALCOLM_VER__ __PCAP_IFACE__ __CAPTURE_LIVE__ __LIVE_ARKIME__ __LIVE_ZEEK__ __CAPTURE_STATS__` | R770 storage layout; Suricata disabled by decision; no feed pulls on an air gap; heaps sized from the host; live capture opt-in via `--capture-ifs`, with Zeek's `capture_loss.log`/`stats.log` on alongside it (`r770-validate.sh --area capture` reads capture_loss) |

Tokens the kit knows how to render (any other `__TOKEN__` fails the render):

| Token | Rendered by | From |
|---|---|---|
| `__ADMIN_PW__` | `r770-gns3-deploy.sh config` | `/etc/lab/secrets/gns3-admin.pw` |
| `__TAP_NAME__`, `__TAP_USER__` | `r770-gns3-deploy.sh labnet` | `lab-tap0`…`lab-tap<N-1>` (`GNS3_LAB_TAPS`, default 4) and the GNS3 service user |
| `__PCAP_NODE_NAME__` | `r770-malcolm-deploy.sh configure` | `hostname -s` |
| `__OS_MEMORY__`, `__LS_MEMORY__` | `r770-malcolm-deploy.sh configure` | computed from `free -g` (OpenSearch capped at 31g) |
| `__ARKIME_MANAGE_PCAP__`, `__ARKIME_FREE_SPACE_G__` | `r770-malcolm-deploy.sh configure` | `--arkime-free-space-g N` (else `false` / none: Phase 10 sets the floor from measured feed rates) |
| `__MALCOLM_VER__` | `r770-malcolm-deploy.sh configure` | the bundled `malcolm-<ver>-docker_install.zip` filename |
| `__PCAP_IFACE__`, `__CAPTURE_LIVE__`, `__LIVE_ARKIME__`, `__LIVE_ZEEK__`, `__CAPTURE_STATS__` | `r770-malcolm-deploy.sh configure` | `--capture-ifs "<if ...>"`: the JSON list of those interfaces and `true`; without it `[]` and `false` (live capture off) |
| `__NETWORK_INDEX_PATTERN_ID__` | `r770-malcolm-deploy.sh dashboards` | read off the running stack: the index pattern Dashboards actually holds, or `--index-pattern <id\|title>` when there is more than one (never guessed) |

## Keeping it in step with the build repo

See `docs/kit-sync.md`. Short form: on the staging host, `diff -r
<simlab-build>/config config/` — every hunk must be either a delta listed
above or a change to port; nothing else.
