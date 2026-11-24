# tests/

One command: `./tests/run.sh`. shellcheck over every script with **no
exclusions**, then every bats suite. Everything is offline and read-only —
every host tool is a stub in a replacement PATH, every write lands in a fake
root under `KIT_ROOT`, every version is `0.0.0-fixture`. Never a real bundle,
never a daemon, never the R770.

Requires `shellcheck` and `bats` (>= 1.10): `sudo apt-get -y install shellcheck bats`.

## Suites

| Suite | Covers |
|---|---|
| `lint.bats` | shellcheck (no exclusions, `staging/` and `harness/` included) and `bash -n` over every script and helper, the PowerShell helper parsing (skipped without `pwsh`); scripts executable |
| `staging.bats` | staging/ runs as a set: the fetch's stages and `--list`, `--pack` (four scripts + kit), the verifier round trip with and without kit/; the pack output is gitignored |
| `common.bats` | the library's contract: `KIT_ROOT`, dry-run, gates, `render`, `assert_edit`, image lists, `bundle_verify` calling the bundle's own verifier, secrets |
| `import-bundle.bats` | gate on the bundle's verifier, refusals, the APT rewrite and its automatic restore, docker assertions, the incomplete-load regression, file routing |
| `malcolm-deploy.bats` | the seven load/assert-tags cases, plus flag assertion, rendered-config replay, the rebind's idempotence and drift refusal, secrets never printed, start via Malcolm's script |
| `gns3-deploy.bats` | `python3-venv` refusal, `--no-index`, pip-index refusal, the chown of the state dir, the unit gate, loopback assertion |
| `capture-ports.bats` | `r770-capture-ports.sh`: `--capture-ifs` required, the gate, one `.network` per port plus the offload unit enabled and the port proved, `lab_mirror0` passed over, every refusal (missing, non-physical, default route, address, master, networkd down) before any write, idempotence, FAILs on a port still not promiscuous or with offloads on, `--dry-run`, read-only `status` |
| `docs-deploy.bats` | load and the tag assertion, `--network none`, the atomic publish (a failed build leaves the live site; stale `docs.new`/`docs.prev` cleared), image-list refusals, `full` slicing and the warn contract |
| `scenario.bats` | `r770-scenario.sh` against a fake GNS3 controller (`helpers/fake_gns3.py`): list, login refusals, the credential kept out of argv, up (render, TAP choice, import/open/start order, node config, readiness), traffic (order, window, run record, WARN/FAIL), record (free-space gate, TAP_A from the Cloud named `tap-a` whatever GNS3's node order, outer and in-netns inner captures before traffic, run.conf with `result=` before `end=`, drop stats, a capture that exits mid-run FAILs as `exited early`, sha256sums, ground truth under `gt/` and `keys=`, a failed snapshot inside the event scheduler still a WARN, the EXIT trap stopping captures on a FAIL and mid-setup, a real SIGINT closing `run.conf` as `end=interrupted` with no `result=` and exiting 130, for record and traffic), verify (tshark rows, `__IDLE_START__`, X7 SKIP without keys, X8 drops / ended abnormally / no stats, refused when `expected.md` cannot be written, refusals), ingest (explicit names only, never `gt/`, nothing copied on a bad run, an interrupted run refused, `result=FAIL` a WARN, no PASS under `--dry-run`), down (ours only), status |
| `scenarios.bats` | the scenario pack's content via `helpers/lint_scenarios.py`: layout, project JSON and tokens, two TAP-type Cloud ports on Clouds named `tap-a` (`__TAP_A__`) and `tap-b` (`__TAP_B__`), images bundled, addresses inside each range, `expect.txt` shape, `events/*.txt` and `pcap-expect.txt` rows, shellcheck on node and traffic scripts |
| `wan.bats` | `r770-wan.sh` with `tc` stubbed: refusal of any name but a kit TAP before any `tc`, profile validation naming the key, HTB then netem, the recorded profile, `show`, idempotent `clear`, every shipped profile parses, no PASS under `--dry-run` |
| `proxmox-prep.bats` | `harness/r770-proxmox-prep.sh` with `qm`/`pvesh`/`pvesm`/`ip`/`ifup`/`sshd`/`iptables-save`/`nft` stubbed and every file under `KIT_ROOT`: arguments refused before anything runs, the wrong node refused, the host-only bridge stanza (forwarding off, IPv6 off) and its gate, a bridge with a physical port / an un-sourced `interfaces.d` refused, a subnet overlapping the host's address, a wider range of the host's, a route or a gateway refused (and a disjoint one accepted), sshd without TCP forwarding refused with nothing changed, a FAIL when forwarding stays on or a NAT rule names the bridge or covers its subnet, the ProxyJump `Host` patterns for a subnet wider than a /24, an existing host-only bridge left alone, the key installed once and never over a different file or from a private key, the template built in order and never booted (net1 the capture stand-in, no `ipconfig1`, `scsi9` free), the vendor data valid bash laying out every mount the import preflight's `LVS` demands, a taken or foreign VMID and a foreign snippet refused, `all --dry-run` changing nothing; `staging-vm` refusing any missing value, a taken or foreign VMID, an absent bridge and a missing or private key, building a plain stopped VM in order behind its gate (`--dry-run` and an unattended run without `--yes` change nothing), WARNing on a host-only bridge, a static address with no gateway and a small disk, and reporting its own earlier VM |
| `proxmox-e2e.bats` | `harness/r770-proxmox-e2e.sh` with `ssh` stubbed for the hypervisor and the guest: arguments refused before any ssh, `--nameserver` / `--searchdomain` required, shape-checked and passed to `qm set` (a resolver off `--guest-ip`'s subnet without `--guest-gw`, or `0.0.0.0`, refused), a taken VMID / wrong node / non-template / bridge with a physical port refused, the clone and destroy gates, the run marker written before the clone, teardown refusing a VM whose description is not exactly the marker's run id (a missing tag only WARNs, so a clone whose `qm set` failed stays removable), no unreferenced volume ever deleted (leftovers named), `all` never tearing down an earlier run's clone (stale marker), the media disk found by serial and never a foreign filesystem formatted, `install.conf`'s BUNDLE/MEDIA/DEVICE filled from the clone, plan/run/validate verdicts, `all` tearing down after every failure, and `all --dry-run` changing nothing |
| `harness.bats` | `harness/r770-staging-vm.sh` with `ssh` stubbed: required arguments and their shapes, the rollback gate, dry-run, idempotent start/stop, a snapshot never overwritten, no destroying command in the script, `airgap` proving the gap (the positive control before link_down, WARN when already link-down, probe exit codes 0/1/124 against every other code, the live `--current` read-back, an empty read-back), `status` and the rollback gate naming the VM, extra arguments refused, `wait-ssh` timing out, the tunnel bound to loopback |
| `portal-deploy.bats` | the SAN list, file modes, `nginx -t` before reload, gate, probe verdicts, `docs` retired |
| `airgap-check.bats` | every false-pass the posture check must not produce; SKIP vs FAIL |
| `validate.bats` | one row per check, SKIP with reason, FAIL diagnosis, arguments-not-facts, interfaces never guessed, indexing lag as WARN |
| `config.bats` | the config stays deployable as measured: http2 form, no staging leftovers, only tokens the kit renders (documented in `config/README.md`), the GNS3 template carries no `jwt_secret_key`, the Malcolm template pins storage and disables what an air gap cannot do |
| `no-pins.bats` | no version pin anywhere outside its one owner, `staging/r770-offline-fetch.sh` |
| `no-credentials.bats` | `.gitignore` covers evidence, secrets, bundles, the packed builder, `.claude/settings.local.json` and reference-run ground truth (`gt/`), judged by the file alone in a throwaway repo (a rule surviving only in `.git/info/exclude` does not count; runs without git history too); every rule committed in HEAD's `.gitignore` is still in the working tree's and no `!` negation was added beside them (a tool rewriting the file cannot silently drop or undo a rule; proven against a throwaway repo; SKIPped outside a git work tree); no credential-shaped string tracked |
| `no-legacy-manifest.bats` | no checksum gate of the kit's own; the bundle's verifier referenced by name and invoked from the library; `r770-bundle.sh` exists only under `staging/`, and `scripts/` never reaches for it |
| `no-internet.bats` | no external URL in scripts or config; `pip` always `--no-index`; `docker run` always `--network none` |
| `references.bats` | every kit path named in the docs exists; every `config/` file is installed by some script; every pipeline's `full` step resolves |

## The stub pattern

`tests/helpers/stubs.bash` — `kit_test_env` builds `$BIN` (stubs) and `$REAL`
(an explicit allowlist of harmless real tools, symlinked), and `kit_run`
executes the script under `PATH=$BIN:$REAL`. Inheriting the runner's PATH
would let a real `docker`, `apt-get` or `systemctl` on GitHub's ubuntu-latest
answer for the host under test — the leak the pattern exists to catch. `stub
<name> <body>` writes a stub; `stub_log <name> [rc]` writes one that records
its argv to `$STUB_LOG`.

`tests/helpers/fixtures.bash` — `make_bundle` (the fetch script's directory
shape with byte-sized payloads and a stub verifier in the root),
`stage_manual`, `make_root` (the fake `/etc /srv /opt /data /var` tree),
`make_malcolm_tree` (an unpacked installer and stack with stub
`install.py`, `auth_setup`, `start`, `stop`).

## Gotchas

- A comment beginning `# shellcheck ` is parsed as a directive, not prose.
- Ownership changes are always stubbed (the suite does not run as root in
  CI); the assertions are on the recorded argv, which is the honest limit.
- `run` in bats swallows a hung process only if you add `timeout`; the
  scripts' poll loops take their step from the `*_WAIT_SECS` seams, which the
  suites set to 1.
