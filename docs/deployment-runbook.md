# R770 Deployment Runbook — from verified bundle to running lab

**Companion to:** the build repo's `simlab-build/docs/plans/r770-install-runbook.md` (the hand-typed procedure this kit automates) · `docs/rollback.md` · `docs/validation.md`
**Date:** 2026-09-21
**Runs on:** the air-gapped R770, as root, from a copy of this kit sitting beside the bundle on the transfer media.

**Nothing here reaches the internet.** If a step appears to need the network,
the step is wrong — stop and fix the bundle, not the box.

**Owned facts are not restated here.** What the bundle carries is in its own
`BUNDLE_NOTES.md`; the hardware of record and the phase status are in the build
repo's `state/BUILD-STATE.md`. This runbook names no version and no measurement.

Malcolm, GNS3 and the offline analyst wiki are **three independent
pipelines**, each its own `... full` entry point in its own script — there
is no outer orchestrator. Run them in any order, or back to back on the same
box: the bundle-prep steps they share (`preflight gate copy apt phone-home
docker files`) are all idempotent, so a later pipeline's copy of them reports
"already done" and moves on (see `docs/CODEMAPS/architecture.md`). Once
Malcolm is up, an optional **front door** (one certificate, the three `.lab`
vhosts) is a separate, explicit sequence; it serves the wiki the docs
pipeline published at `docs.lab`.

---

## Where this runbook stops today

The install is **not** a single sitting.

| Steps | Build-repo phase | Blocked by |
|---|---|---|
| Bundle-in prep: `preflight` `gate` `copy` `apt` `phone-home` `docker` `files` (shared by all three pipelines) | 4, 6 | — ready (needs the Phase 3 volumes mounted) |
| GNS3 pipeline: `load` `venv` `secrets` `config` `service` `labnet` | 8 | needs Phase 8 built |
| Malcolm pipeline: `load` `unpack` `configure` `secrets` `auth` `rebind` `start` | 10 | needs Phase 10 built, capture-port prep (Phase 9) |
| Docs pipeline: `load` `build` | 13 | needs Phase 13 built (the docs site is part of it) |
| Front door: `ca` `cert` `htpasswd` `nginx` | 13 | needs Phase 13 built, and Malcolm's `auth` step already run |
| validate | 16 | runs at any point; SKIPs what is not built |

None of these steps touch a network interface, an IP address, or SSH — GNS3
and Malcolm bind to `127.0.0.1` only, the docs pipeline's build runs with
`--network none`, and the front door's nginx answers on `0.0.0.0:443` (from
the moment the package installs, with its stock default site until the
portal's `nginx` step removes it). Proving iDRAC as a recovery path is a
prerequisite for the build repo's **own** management-networking work, not for
anything these steps do — it does not gate the GNS3, Malcolm, docs or
front-door steps here. What still gates them is whether their own build-repo
phase (8, 9, 10, 13) is built; check `state/BUILD-STATE.md` in the build repo
before assuming one is ready. The shared bundle-prep steps can run now
regardless:
they are the long ones, and they prove the bundle before anything else
begins. Run any pipeline with `--to files` to stop there.

---

## Step 0 — On the media, before anything

- [ ] The bundle passed `r770-bundle.sh verify --strict` **on staging, from the media**
- [ ] This kit sits beside the bundle on the same media (not inside it — the manifest must not change)
- [ ] Site AV/content scan done per policy (the kit cannot check this; the gate step reminds you)

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT      # identify the media — never assume
```

---

## The short path: one command per pipeline

```bash
sudo ./scripts/r770-malcolm-deploy.sh full --bundle /mnt/bundle/bundle-YYYYMMDD \
    --media /mnt/bundle --device /dev/<discovered>

sudo ./scripts/r770-gns3-deploy.sh full --bundle /mnt/bundle/bundle-YYYYMMDD \
    --media /mnt/bundle --device /dev/<discovered>

sudo ./scripts/r770-docs-deploy.sh full --bundle /mnt/bundle/bundle-YYYYMMDD \
    --media /mnt/bundle --device /dev/<discovered>
```

Exit **0** every step clean · **2** finished with warnings to disposition ·
**1** a step refused — fix it, rerun with `--from <step>`. Each script's own
`--help` prints its step sequence. `--to files` stops after the bundle is in.
`--dry-run` prints every command a run would execute, including the gates'
current/proposed/rollback text, and executes none of it. The sections below
are the same three pipelines one step at a time, and remain the reference for
what each step does and why.

---

## Malcolm procedure

### Step M1 — preflight

```bash
sudo ./scripts/r770-import-bundle.sh preflight --bundle /mnt/bundle/bundle-YYYYMMDD
```

FAILs for every logical volume of the storage layout that is not its own
mount point. `docker load` into an unmounted `/var/lib/docker` writes onto
the root filesystem and fills it — that is the failure this step prevents.
WARNs when no previous bundle exists under `/srv/bundles`: this import then
has no bundle to roll back to.

### Step M2 — gate

```bash
sudo ./scripts/r770-import-bundle.sh gate --bundle /mnt/bundle/bundle-YYYYMMDD \
    --media /mnt/bundle --device /dev/<discovered>
```

Mounts the media **read-only** (a bundle that fails must not be writable by the
box that rejected it), then runs the verifier that travels in the bundle root:
`<bundle>/r770-bundle.sh verify`. Exit **0** PASS · **2** PASS WITH WARNINGS
(each needs a written disposition, and `--yes` to proceed unattended) · **1**
FAIL — **do not import**; the media is suspect, re-cut on staging.

Record the verifier's exact `RESULT:` line; the transcript under
`r770-evidence/` holds it.

### Step M3 — copy

```bash
sudo ./scripts/r770-import-bundle.sh copy --bundle /mnt/bundle/bundle-YYYYMMDD --media /mnt/bundle
```

`cp -a` to `/srv/bundles/`, then the verifier again **from the copy** (a
truncated or bit-flipped transfer costs minutes here and a bundle cycle if
found during a Malcolm deploy), then the media is unmounted. From here every
step takes `--bundle /srv/bundles/bundle-YYYYMMDD`; `full` switches by itself.
The previous bundle stays until this one validates end to end.

### Steps M4–M6 — apt, phone-home, docker  *(GATED)*

```bash
sudo ./scripts/r770-import-bundle.sh apt --bundle /srv/bundles/bundle-YYYYMMDD
sudo ./scripts/r770-import-bundle.sh phone-home
sudo ./scripts/r770-import-bundle.sh docker
```

`apt`'s gate shows the current `sources.list*`, the one proposed line
(`deb [trusted=yes] file:/srv/repo/apt ./`) and the rollback tarball
`/root/apt-sources-<date>.tar.gz`, written before anything moves. After the
rewrite, `apt-get update` must touch **only** `file:` — a surviving upstream
host FAILs the step and the old sources are restored automatically.

`phone-home` disables unattended-upgrades and the apt/pro/motd/fwupd timers,
purges snapd if present, silences motd-news. Updates now arrive only by
bundle — the accepted cost of the air gap. The rollback is per unit
(`docs/rollback.md`); snapd comes back only from a bundle that carries the
deb.

`docker` installs the engine from the local repo, then asserts: data root
`/var/lib/docker` **and** its own mount point, no registry mirrors, no daemon
proxy. There is no registry to reach.

- [ ] Disposition: every package the lab needs is in the curated set (an unplanned `apt install` will fail by design until the next bundle)

### Step M7 — files

```bash
sudo ./scripts/r770-import-bundle.sh files --bundle /srv/bundles/bundle-YYYYMMDD
```

| From the bundle | To | Note |
|---|---|---|
| `images/` | `/srv/vms/base` | `qemu-img info` once Phase 7 tools exist |
| `gns3/definitions/*.gns3a` | `/srv/gns3/appliances` | definitions are free even where images are licensed |
| `gns3/appliances/` | `/srv/gns3/images` (+ `checksums/`) | `README.txt` skipped; a definition with no image WARNs — it would appear in the GUI and fail at boot |
| `enrichment/` | `/opt/enrichment` (+ `rules/`) | staged only: Suricata is disabled by decision, GeoIP descoped |
| `docs/` | `/srv/docs` | best-effort mirrors; reading material only |

The GNS3 wheelhouse and the Malcolm/GNS3 image tarballs stay in the bundle;
each pipeline's own `load` step reads its list/payload pair straight off the
bundle root — `r770-import-bundle.sh` does no generic image loading.

**Stop here (`--to files`) until the GNS3, Malcolm and front-door steps' own
build-repo phases (8, 9, 10, 13) are built — none of them need iDRAC or
Phase 5 proven first.**

### Step M8 — load

```bash
sudo ./scripts/r770-malcolm-deploy.sh load --bundle /srv/bundles/bundle-YYYYMMDD
```

`docker load` of the Malcolm image tarball, then **every tag asserted
against the list that travelled with it** (`malcolm/image-list.txt`) —
`docker load` reports success even when the resulting tag set is incomplete.
A pair whose tags are already all present is skipped, so the step is safe to
rerun. A missing tag means the tarball is incomplete: re-cut; never patch by
hand.

### Steps M9–M14 — unpack, configure, secrets, auth, rebind, start

```bash
B=/srv/bundles/bundle-YYYYMMDD
sudo ./scripts/r770-malcolm-deploy.sh unpack --bundle $B       # needs python3-ruamel.yaml, python3-dotenv (apt/)
sudo ./scripts/r770-malcolm-deploy.sh configure --bundle $B    # renders the kit's config template, replays it through install.py
#   add --capture-ifs lab-mirror0 for live capture of the lab (run GNS3's labnet first)
sudo ./scripts/r770-malcolm-deploy.sh secrets                  # /etc/lab/secrets/malcolm-admin.pw, once
sudo ./scripts/r770-malcolm-deploy.sh auth --bundle $B         # auth_setup, hashes generated on the box
sudo ./scripts/r770-malcolm-deploy.sh rebind                   # 0.0.0.0:443 -> 127.0.0.1:8443, the front door owns 443
sudo ./scripts/r770-malcolm-deploy.sh start                    # Malcolm's ./scripts/start, then wait for health
```

`configure` asserts every flag it passes against the bundled installer's
`--help` and dies naming a missing one — a version bump fails by name, not by
surprise. The template pins PCAP to `/data/pcap/raw` and indexes to
`/data/index` (left at defaults, both land on the Docker volume and fill
`/var/lib/docker`), sizes the JVM heaps from this host, turns Suricata and the
Zeek feed pulls off. `--arkime-free-space-g N` turns on oldest-first deletion
of raw PCAP below N GB free; Phase 10 sets that from measured feed rates, so
the default is off. `--capture-ifs "<if ...>"` turns on live Arkime and Zeek
capture on those interfaces (each must exist and carry no address); without
it live capture stays off. `rebind` is re-applied after every installer run
because a compose override file is ignored. `start` refuses before `auth` and
before `rebind`. Arkime and logstash are the last to go healthy; `start` waits up to
`MALCOLM_WAIT_SECS` and can be rerun to keep waiting.

Once the stack is healthy, the lab's own saved objects and views go on top.
These are **not** part of `full`'s Malcolm sequence on purpose: they need a
started stack, and a dashboard that failed to import is not a reason to fail a
deployment that otherwise stood every service up.

```bash
sudo ./scripts/r770-malcolm-deploy.sh inventory                # read-only: what this Dashboards actually holds
sudo ./scripts/r770-malcolm-deploy.sh dashboards               # the lab's IPsec saved searches and dashboard
sudo ./scripts/r770-malcolm-deploy.sh arkime-views              # the same protocols, as Arkime views
```

`inventory` is the only honest answer to "what does this Malcolm ship?" — it
reads the saved objects off the running stack and prints them by type, and the
transcript is the record. Run it before the other two: `dashboards` attaches
the kit's objects to an index pattern it *reads* from the stack, and if the
stack carries more than one it refuses and lists them rather than choosing —
name the one you want with `--index-pattern <id|title>`.

`dashboards` then imports `config/malcolm/dashboards/ipsec.ndjson.template`
and **asserts every object id back**, because the import API reports success
for a partial import exactly as it reports a whole one — the same lie
`docker load` tells about tags. A `MISSING` line names the object that did not
land. `arkime-views` does the same for
`config/malcolm/arkime-views/ipsec.views`, reading each view back by name.

Both are idempotent: the import overwrites, and the views are posted by name.

#### Authoring a new dashboard

The kit cannot design a dashboard; OpenSearch Dashboards can. The loop:

1. Build it in the UI on the running stack.
2. Export it: **Stack Management → Saved Objects → Export**, with related
   objects included.
3. Strip the version fields (`coreMigrationVersion`, `migrationVersion`) and
   replace the index-pattern id in every `references` entry with
   `__NETWORK_INDEX_PATTERN_ID__`. Both matter: a literal version trips
   `tests/no-pins.bats`, and a literal index-pattern id imports broken on any
   other stack.
4. Put each object on one line, ordered `{"id":…,"type":…,…}` — the verify step
   refuses a line it cannot read, rather than skipping it silently.
5. Drop it in `config/malcolm/dashboards/`, commit, rerun `dashboards`.

### Malcolm — validate note

Once `start` is healthy, `r770-validate.sh --area capture` and, once the
front door is up, `--area portal` are the first honest checks of this
pipeline; see the "Front door" section below and `docs/validation.md`.

---

## GNS3 procedure

Steps G1–G4 (`preflight` `gate` `copy` `apt` `phone-home` `docker` `files`)
are identical to Malcolm's M1–M7 above, against the same
`r770-import-bundle.sh`, and are idempotent — if the Malcolm procedure has
already run on this box, GNS3's copy of them reports "already done" and
`full` moves straight on. What follows is GNS3-specific.

### Step G5 — load

```bash
sudo ./scripts/r770-gns3-deploy.sh load --bundle /srv/bundles/bundle-YYYYMMDD
```

`docker load` of the GNS3 docker-node images tarball, then **every tag
asserted against `gns3/docker-nodes/image-list.txt`** — the same
`docker load`-lies-by-omission check as Malcolm's `load`. Skipped, and safe
to rerun, once every tag is already present.

### Steps G6–G9 — venv, secrets, config, service  *(service is GATED)*

```bash
B=/srv/bundles/bundle-YYYYMMDD
sudo ./scripts/r770-gns3-deploy.sh venv --bundle $B      # pip --no-index --find-links <wheelhouse>
sudo ./scripts/r770-gns3-deploy.sh secrets               # /etc/lab/secrets/gns3-admin.pw, once
sudo ./scripts/r770-gns3-deploy.sh config                # user gns3, /etc/gns3 OWNED by it, /srv/gns3/*
sudo ./scripts/r770-gns3-deploy.sh service                # unit; asserts 127.0.0.1:3080 only
```

`venv` refuses without `python3-venv` (the rehearsal's venv came up with no
pip) and refuses while a pip index is configured. `config` chowns `/etc/gns3`
to the service user because GNS3 v3 writes its database and JWT key beside its
config — root-owned, it fails with "unable to open database file". `service`
FAILs if the server listens on anything but loopback.

### Step G10 — labnet  *(GATED)*

```bash
sudo ./scripts/r770-gns3-deploy.sh labnet     # br-lab (hub mode), lab-tap0..3, lab-mon0 <-> lab-mirror0
```

The lab bridge every scenario shares, mirrored into Malcolm by construction:
`br-lab` runs with `ageing_time 0`, so it floods every frame to every port —
including `lab-mon0`, whose veth peer `lab-mirror0` is what Malcolm captures.
A scenario puts a link on the bridge by binding a GNS3 Cloud node to a
`lab-tapN` (owned by the `gns3` user). The step installs
`/etc/systemd/network/05-*lab*` files and runs `networkctl reload`; it refuses
while systemd-networkd is inactive, before `config` has created the service
user, and when one of its names already belongs to something else. After the
reload it proves hub mode, the ports, that no physical interface joined the
bridge (rule 8), and that `lab-mirror0` is up, promiscuous and address-less.
`GNS3_LAB_TAPS` changes the TAP count (default 4). Nothing on `br-lab` is
bridged to a physical port or NATed: lab traffic cannot leave the box.

Then turn Malcolm's live capture on (Malcolm procedure, `configure`):
`r770-malcolm-deploy.sh configure --bundle $B --capture-ifs lab-mirror0`.

Evidence that the feed is live, once a scenario runs:
`tcpdump -c 5 -i lab-mirror0` shows frames; Arkime shows sessions from the
scenario's address range within about a minute, with matching Zeek logs;
`r770-validate.sh --area network --lab-bridge br-lab --capture-ifs lab-mirror0`
and `--area capture` report the wiring and `capture_loss`.

### GNS3 — validate note

Once `service` is up, `r770-validate.sh --area gns3` is the first honest
check of this pipeline (unit active, `/v3/version` answers, admin login
issues a token); once the front door is up, `--area portal` covers
`gns3.lab`. See `docs/validation.md`.

---

## Docs procedure

Steps D1–D4 (`preflight` `gate` `copy` `apt` `phone-home` `docker` `files`)
are identical to Malcolm's M1–M7 above, against the same
`r770-import-bundle.sh`, and are idempotent — if another pipeline has
already run on this box, the docs pipeline's copy of them reports "already
done" and `full` moves straight on. What follows is docs-specific.

### Step D5 — load

```bash
sudo ./scripts/r770-docs-deploy.sh load --bundle /srv/bundles/bundle-YYYYMMDD
```

`docker load` of `docker/monitoring-images.tar.gz`, then **every tag asserted
against `docker/monitoring-image-list.txt`** (the names predate the cut of the
monitoring stack; the pair now carries only the mkdocs-material build image).
Skipped, and safe to rerun, once every tag is already present.

### Step D6 — build

```bash
sudo ./scripts/r770-docs-deploy.sh build --bundle /srv/bundles/bundle-YYYYMMDD
```

The kit's `docs/wiki` (or `--wiki <dir>`) built with the bundled image under
`--network none`, then published to `/srv/www/docs` by staging beside the live
tree and swapping it in with two renames. A failed build, or a failed copy,
leaves the previous site live; a `docs.new` or `docs.prev` left by an
interrupted run is cleared by the next `build`. `build` does not load the
image itself (unlike the retired portal `docs` step); it refuses with "run
'load' first" if the image is absent. To rebuild after the wiki source
changes: `r770-docs-deploy.sh full --bundle <local bundle> --only build`.

### Docs — validate note

`r770-docs-deploy.sh status` shows the page count, the build time, whether
the image is loaded (with `--bundle`) and whether `docs.lab` is being served.
Once the front door is up, `r770-validate.sh --area portal` covers `docs.lab`.

---

## Front door (optional, after Malcolm)

The front door is the internal CA, one three-SAN certificate and the `.lab`
vhosts — a separate, explicit sequence, never part of any `full`. It serves
`docs.lab` from whatever the docs pipeline last published; before the first
`build`, `docs.lab` answers 401 (auth), then 404. Run it once Malcolm's
`auth` step has produced `/opt/malcolm/malcolm/nginx/htpasswd`: `htpasswd`
below has a **hard dependency** on that file and refuses without it.

```bash
sudo ./scripts/r770-portal-deploy.sh ca                        # easy-rsa CA under /etc/lab/ca, ca.crt to /etc/nginx/ssl
sudo ./scripts/r770-portal-deploy.sh cert                       # one cert: malcolm, gns3, docs .lab
sudo ./scripts/r770-portal-deploy.sh htpasswd                   # the analyst login, from Malcolm's auth material — needs `auth` already run
sudo ./scripts/r770-portal-deploy.sh nginx                      # vhosts; nginx -t BEFORE reload; every name probed after
```

The CA is generated here and never carried in. Distribute `/etc/nginx/ssl/ca.crt`
to analyst browsers. `nginx` removes the stock default site (it answered on
`0.0.0.0:443` since the package installed) and probes each name at `127.0.0.1`
after the reload settles — a probe that races the reload reads the old cert.

### Front door — validate note

Once `nginx` has settled, `r770-validate.sh --area portal` is the first
honest check: each `.lab` name answers over TLS with the lab CA, no redirect
escapes to a loopback port, and only nginx owns `0.0.0.0:443`. See
`docs/validation.md`.

---

## Step V — validate

```bash
sudo ./scripts/r770-airgap-check.sh --mgmt-cidr <management subnet>
sudo ./scripts/r770-validate.sh --expect-threads <n> --expect-ram-gb <n> \
    --mgmt-if <if> --capture-ifs "<if> <if> ..." --mgmt-cidr <subnet>
```

Every value is an argument taken from discovery; the kit never guesses one.
`docs/validation.md` lists the areas, the opt-in flags for the checks that
inject traffic or boot a guest, and what SKIPPED means.

---

## Re-entry

A step that refused prints the `--from <step>` to rerun `full` with. Every
step is idempotent: copies are stamped, loads skip present tags, secrets are
generated once, the rebind recognises itself, the CA and certificate are
reused. `--force` redoes a stamped or generated step.

## Record the cycle

- [ ] Copy `r770-evidence/` back to the build repo's `state/inventory/` (the transcripts and the validation report are the evidence)
- [ ] Append the cycle row in the build repo's `state/inventory/bundles.md`: verifier exit code and `RESULT:` line, WARN dispositions, courier, whether it imported
- [ ] Update the phase rows in the build repo's `state/BUILD-STATE.md`
- [ ] Keep the previous bundle under `/srv/bundles` until this one has validated end to end
- [ ] Commit, in the build repo

## If it goes wrong

| Symptom | First move |
|---|---|
| gate exits 1 | Do not import. Re-cut on staging; the media is suspect |
| apt step FAILs with an upstream host | The old sources were restored automatically; find the file that survived and remove it, rerun |
| a `load` step names a MISSING tag | The tarball is incomplete. Re-cut; do not patch by hand |
| `venv` dies naming `python3-venv` | The apt step did not run, or the curated set lacks it |
| `configure` dies naming a flag | The bundled installer's interface moved; read `BUNDLE_NOTES.md`, update the kit, then rerun |
| `start` FAILs on unready services | Rerun `start` to keep waiting; then `docker compose logs` in the stack directory |
| `service` FAILs on `0.0.0.0:3080` | The rendered config's host is not loopback; rerun `config` |
| `nginx -t` rejects | Nothing was reloaded; the previous config is live. Fix the vhost, rerun |
| `htpasswd` refuses, no source file | Malcolm's `auth` step has not run yet — run it, then rerun `htpasswd` |
| a vhost probes 502 | Its backend is down — Malcolm or GNS3 |
| SSH lost during a networking step | iDRAC is the recovery path — which is why Phase 5 is gated on proving it first (build repo) |

One change at a time: reproduce, read the transcript, one hypothesis, one
controlled change, `--from <step>`, then keep or revert.
