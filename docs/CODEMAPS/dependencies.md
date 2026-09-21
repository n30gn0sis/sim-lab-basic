<!-- Generated: 2026-09-21 | Files scanned: 8 scripts, 20 config files | Token estimate: ~650 -->

# Dependencies

**External services: none, by design.** The R770 has no route off the box.
`tests/no-internet.bats` fails on any URL in `scripts/` or `config/` outside
loopback, a `.lab` name, or a compose-internal service name; on a `pip`
without `--no-index`; on a `docker run` without `--network none`; and on any
`docker pull`, `add-apt-repository` or `snap install`.

**No version appears here.** Pins live once, in
`staging/r770-offline-fetch.sh`'s pin block. What a given bundle carries is in
its own `BUNDLE_NOTES.md`.

## Everything arrives in the bundle

```
bundle-YYYYMMDD/
  r770-bundle.sh          the verifier the R770 side runs (in the root, in the manifest)
  BUNDLE_NOTES.md         what this cut carries
  MANIFEST.sha256         what verify checks
  apt/                    the curated package set → /srv/repo/apt (flat local repo)
  docker/                 Docker Engine debs + monitoring images
  malcolm/                installer zip + image tarball
  gns3/wheelhouse/        pip wheels — installed with --no-index
  gns3/appliances/        licensed images (added by hand at the build pause)
  gns3/definitions/       .gns3a appliance definitions
  gns3/docker-nodes/      node images
  images/                 VM base images → /srv/vms/base
  enrichment/             staged only (Suricata disabled by decision)
  docs/                   offline reading material → /srv/docs
  dell/                   firmware (applied out-of-band via iDRAC)
```

**Each pipeline/script owns its own image loading** — `r770-import-bundle.sh`
has no generic `images`/`load` subcommand of its own. Every load is followed
by **asserting every tag** (`assert_image_tags`, because `docker load` reports
success on an incomplete tag set):

| List | Payload | Loaded by |
|---|---|---|
| `malcolm/image-list.txt` | `malcolm/malcolm-images-*.tar.gz` | `r770-malcolm-deploy.sh load` |
| `gns3/docker-nodes/image-list.txt` | `gns3/docker-nodes/gns3-node-images.tar.gz` | `r770-gns3-deploy.sh load` |
| `docker/monitoring-image-list.txt` | `docker/monitoring-images.tar.gz` | `r770-portal-deploy.sh docs` (self-load; the list keeps its build-repo name but now carries only `mkdocs-material`, the offline wiki's build image) |

A pair whose tags are already present is skipped, so the load step reruns
safely. A missing tag means the tarball is incomplete: re-cut, never patch by
hand.

## Packages the kit requires but never installs

`require_pkg` refuses with the package name and points at the `apt` stage —
software reaches the box through the bundle and nowhere else.

| Package | Needed by |
|---|---|
| `python3-venv` | `gns3-deploy venv` (the rehearsal's venv came up with no pip) |
| `python3-ruamel.yaml`, `python3-dotenv` | `malcolm-deploy unpack` / `configure` (Malcolm's installer) |
| `easy-rsa` | `portal-deploy ca` / `cert` |
| `nginx` | `portal-deploy nginx` |

## Runtime the kit itself assumes

`bash` (4.4+) and coreutils. **No `jq`** — every JSON response is read with
`sed`/`grep`, and a shape the kit was not written for is a refusal. Host tools
that touch state (`docker`, `apt-get`, `systemctl`, `nginx`, `unzip`,
`openssl`) are called through `run()` so `--dry-run` prints instead of
executing, and are stubbed in the suites.

Working on the kit needs `shellcheck` and `bats` — on any Linux box, never on
the R770.

## Services, all on loopback except the front door

The front door owns `0.0.0.0:443`; everything else answers only on
`127.0.0.1` and is reached through an nginx vhost.

| Port | Service | Reached as |
|---|---|---|
| 8443 | Malcolm's nginx-proxy (rebound from `0.0.0.0:443`) | `malcolm.lab` |
| 3080 | GNS3 server | `gns3.lab` |
| 443 (`0.0.0.0`) | the front door's nginx | `malcolm.lab`, `gns3.lab`, `docs.lab` |

The three `.lab` names — `malcolm.lab`, `gns3.lab`, `docs.lab` — are a
decision of record, literal in `config/nginx/`, and are exactly the SANs on
the one certificate (`portal-deploy --print-sans`, asserted by
`tests/portal-deploy.bats`).

## Cross-repo

The build repo (`simlab-build`) owns the design, the hardware of record, the
phase tracker, and the four files under `staging/`. `docs/kit-sync.md` has the
sync checklist; `docs/wiki/` is carried verbatim and is changed there, never
here.
