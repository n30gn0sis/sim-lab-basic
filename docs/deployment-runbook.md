# R770 Deployment Runbook — from verified bundle to running lab

**Companion to:** the build repo's `simlab-build/docs/plans/r770-install-runbook.md` (the hand-typed procedure this kit automates) · `docs/rollback.md` · `docs/validation.md`
**Date:** 2026-09-14
**Runs on:** the air-gapped R770, as root, from a copy of this kit sitting beside the bundle on the transfer media.

**Nothing here reaches the internet.** If a step appears to need the network,
the step is wrong — stop and fix the bundle, not the box.

**Owned facts are not restated here.** What the bundle carries is in its own
`BUNDLE_NOTES.md`; the hardware of record and the phase status are in the build
repo's `state/BUILD-STATE.md`. This runbook names no version and no measurement.

---

## Where this runbook stops today

The install is **not** a single sitting.

| Stages | Build-repo phase | Blocked by |
|---|---|---|
| 1–3 preflight, gate, copy | 4 | — ready (needs the Phase 3 volumes mounted) |
| 4–8 apt, phone-home, docker, images, files | 4, 6 | needs stages 1–3 |
| 9 gns3 | 8 | **Phase 5** (management networking) |
| 10 malcolm | 10 | **Phase 5**, capture-port prep (Phase 9) |
| 11–12 portal, monitoring | 13, 14 | **Phase 5** |
| 13 validate | 16 | runs at any point; SKIPs what is not built |

Phase 5 is BLOCKED in the build repo until iDRAC is proven as a recovery path.
Stages 1–8 can run now and are worth running now: they are the long ones, and
they prove the bundle before the networking work begins. Run them with
`--to files`.

---

## Step 0 — On the media, before anything

- [ ] The bundle passed `r770-bundle.sh verify --strict` **on staging, from the media**
- [ ] This kit sits beside the bundle on the same media (not inside it — the manifest must not change)
- [ ] Site AV/content scan done per policy (the kit cannot check this; the gate stage reminds you)
- [ ] You know the management address you will give `--mgmt-ip`, from discovery, not from memory

```bash
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT      # identify the media — never assume
```

---

## The short path: one command

```bash
sudo ./scripts/r770-deploy.sh --bundle /mnt/bundle/bundle-YYYYMMDD \
    --media /mnt/bundle --device /dev/<discovered> --mgmt-ip <address>
```

Exit **0** every stage clean · **2** finished with warnings to disposition ·
**1** a stage refused — fix it, rerun with `--from <stage>`.

`--list` prints the stages. `--to files` stops after the bundle is in.
`--dry-run` prints every command a run would execute, including the gates'
current/proposed/rollback text, and executes none of it. The steps below are
the same pipeline one stage at a time, and remain the reference for what each
stage does and why.

---

## Step 1 — preflight

```bash
sudo ./scripts/r770-import-bundle.sh preflight --bundle /mnt/bundle/bundle-YYYYMMDD
```

FAILs for every logical volume of the storage layout that is not its own
mount point. `docker load` into an unmounted `/var/lib/docker` writes onto
the root filesystem and fills it — that is the failure this step prevents.
WARNs when no previous bundle exists under `/srv/bundles`: this import then
has no bundle to roll back to.

## Step 2 — gate

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

## Step 3 — copy

```bash
sudo ./scripts/r770-import-bundle.sh copy --bundle /mnt/bundle/bundle-YYYYMMDD --media /mnt/bundle
```

`cp -a` to `/srv/bundles/`, then the verifier again **from the copy** (a
truncated or bit-flipped transfer costs minutes here and a bundle cycle if
found during a Malcolm deploy), then the media is unmounted. From here every
stage takes `--bundle /srv/bundles/bundle-YYYYMMDD`; the runner switches by
itself. The previous bundle stays until this one validates end to end.

---

## Step 4 — apt  *(GATED)*

```bash
sudo ./scripts/r770-import-bundle.sh apt --bundle /srv/bundles/bundle-YYYYMMDD
```

The gate shows the current `sources.list*`, the one proposed line
(`deb [trusted=yes] file:/srv/repo/apt ./`) and the rollback tarball
`/root/apt-sources-<date>.tar.gz`, written before anything moves. After the
rewrite, `apt-get update` must touch **only** `file:` — a surviving upstream
host FAILs the stage and the old sources are restored automatically.

- [ ] Disposition: every package the lab needs is in the curated set (an unplanned `apt install` will fail by design until the next bundle)

## Step 5 — phone-home  *(GATED)*

```bash
sudo ./scripts/r770-import-bundle.sh phone-home
```

Disables unattended-upgrades and the apt/pro/motd/fwupd timers, purges snapd
if present, silences motd-news. Updates now arrive only by bundle — the
accepted cost of the air gap. The rollback is per unit (`docs/rollback.md`);
snapd comes back only from a bundle that carries the deb.

## Step 6 — docker  *(GATED)*

```bash
sudo ./scripts/r770-import-bundle.sh docker
```

Installs the engine from the local repo, then asserts: data root
`/var/lib/docker` **and** its own mount point, no registry mirrors, no daemon
proxy. There is no registry to reach.

## Step 7 — images

```bash
sudo ./scripts/r770-import-bundle.sh images --bundle /srv/bundles/bundle-YYYYMMDD
```

Three list/payload pairs (Malcolm, monitoring, GNS3 docker nodes). Each tarball
is loaded and then **every tag asserted against the list that travelled with
it** — `docker load` reports success even when the resulting tag set is
incomplete. A pair whose tags are already all present is skipped, so the stage
is safe to rerun. A missing tag means the tarball is incomplete: re-cut; never
patch by hand.

## Step 8 — files

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

The GNS3 wheelhouse stays in the bundle; Step 9 reads it from there.

**Stop here (`--to files`) until Phase 5 is VERIFIED in the build repo.**

---

## Step 9 — gns3  *(GATED)*

```bash
B=/srv/bundles/bundle-YYYYMMDD
sudo ./scripts/r770-gns3-deploy.sh venv --bundle $B      # pip --no-index --find-links <wheelhouse>
sudo ./scripts/r770-gns3-deploy.sh secrets               # /etc/lab/secrets/gns3-admin.pw, once
sudo ./scripts/r770-gns3-deploy.sh config                # user gns3, /etc/gns3 OWNED by it, /srv/gns3/*
sudo ./scripts/r770-gns3-deploy.sh service               # unit; asserts 127.0.0.1:3080 only
```

`venv` refuses without `python3-venv` (the rehearsal's venv came up with no
pip) and refuses while a pip index is configured. `config` chowns `/etc/gns3`
to the service user because GNS3 v3 writes its database and JWT key beside its
config — root-owned, it fails with "unable to open database file". `service`
FAILs if the server listens on anything but loopback.

## Step 10 — malcolm

```bash
sudo ./scripts/r770-malcolm-deploy.sh load --bundle $B         # docker load + assert every tag
sudo ./scripts/r770-malcolm-deploy.sh unpack --bundle $B       # needs python3-ruamel.yaml, python3-dotenv (apt/)
sudo ./scripts/r770-malcolm-deploy.sh configure --bundle $B    # renders the kit's config template, replays it through install.py
sudo ./scripts/r770-malcolm-deploy.sh secrets                  # /etc/lab/secrets/malcolm-admin.pw, once
sudo ./scripts/r770-malcolm-deploy.sh auth --bundle $B         # auth_setup, hashes generated on the box
sudo ./scripts/r770-malcolm-deploy.sh rebind                   # 0.0.0.0:443 -> 127.0.0.1:8443, the portal owns 443
sudo ./scripts/r770-malcolm-deploy.sh start                    # Malcolm's ./scripts/start, then wait for health
```

`configure` asserts every flag it passes against the bundled installer's
`--help` and dies naming a missing one — a version bump fails by name, not by
surprise. The template pins PCAP to `/data/pcap/raw` and indexes to
`/data/index` (left at defaults, both land on the Docker volume and fill
`/var/lib/docker`), sizes the JVM heaps from this host, turns Suricata and the
Zeek feed pulls off. `--arkime-free-space-g N` turns on oldest-first deletion
of raw PCAP below N GB free; Phase 10 sets that from measured feed rates, so
the default is off. `rebind` is re-applied after every installer run because a
compose override file is ignored. `start` refuses before `auth` and before
`rebind`. Arkime and logstash are the last to go healthy; `start` waits up to
`MALCOLM_WAIT_SECS` and can be rerun to keep waiting.

## Step 11 — portal  *(GATED)*

```bash
sudo ./scripts/r770-portal-deploy.sh ca                        # easy-rsa CA under /etc/lab/ca, ca.crt to /etc/nginx/ssl
sudo ./scripts/r770-portal-deploy.sh cert                      # one cert: portal, malcolm, gns3, monitoring, docs .lab
sudo ./scripts/r770-portal-deploy.sh htpasswd                  # the analyst login, from Malcolm's auth material
sudo ./scripts/r770-portal-deploy.sh nginx                     # vhosts; nginx -t BEFORE reload; every name probed after
sudo ./scripts/r770-portal-deploy.sh portal --mgmt-ip <address>
sudo ./scripts/r770-portal-deploy.sh docs --bundle $B          # wiki built with the bundled mkdocs image, --network none
```

The CA is generated here and never carried in. Distribute `/etc/nginx/ssl/ca.crt`
to analyst browsers. `nginx` removes the stock default site (it answered on
`0.0.0.0:443` since the package installed) and probes each name at `127.0.0.1`
after the reload settles — a probe that races the reload reads the old cert.

## Step 12 — monitoring

```bash
sudo ./scripts/r770-monitoring-deploy.sh env --bundle $B       # .env from the image list, by repository name
sudo ./scripts/r770-monitoring-deploy.sh up                    # compose up -d --pull never; loopback ports; targets up
```

Grafana's admin password is generated once under `/etc/lab/secrets/` and
never printed. Every port is asserted on `127.0.0.1`; `monitoring.lab` is the
way in.

## Step 13 — validate

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

A stage that refused prints the `--from <stage>` to rerun with. Every stage is
idempotent: copies are stamped, loads skip present tags, secrets are generated
once, the rebind recognises itself, the CA and certificate are reused. `--force`
redoes a stamped or generated step.

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
| apt stage FAILs with an upstream host | The old sources were restored automatically; find the file that survived and remove it, rerun |
| images stage names a MISSING tag | The tarball is incomplete. Re-cut; do not patch by hand |
| `venv` dies naming `python3-venv` | The apt stage did not run, or the curated set lacks it |
| `configure` dies naming a flag | The bundled installer's interface moved; read `BUNDLE_NOTES.md`, update the kit, then rerun |
| `start` FAILs on unready services | Rerun `start` to keep waiting; then `docker compose logs` in the stack directory |
| `service` FAILs on `0.0.0.0:3080` | The rendered config's host is not loopback; rerun `config` |
| `nginx -t` rejects | Nothing was reloaded; the previous config is live. Fix the vhost, rerun |
| a vhost probes 502 | Its backend is down — Malcolm, GNS3 or the monitoring stack |
| SSH lost during a networking step | iDRAC is the recovery path — which is why Phase 5 is gated on proving it first (build repo) |

One change at a time: reproduce, read the transcript, one hypothesis, one
controlled change, `--from <stage>`, then keep or revert.
