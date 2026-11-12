# Rollback — undoing each stage

**Companion to:** `docs/deployment-runbook.md`
**Date:** 2026-09-14

Every gated stage prints its rollback before asking for a decision; this page
collects them, and adds what is *not* reversible. The previous bundle under
`/srv/bundles` is the rollback for the bundle as a whole: never delete it
during an import.

| Stage | What changed | Where the backup is | Undo | Not reversible |
|---|---|---|---|---|
| copy | `/srv/bundles/bundle-YYYYMMDD` written | — (the media) | `rm -rf /srv/bundles/bundle-YYYYMMDD /srv/bundles/.kit-stamps/copied.*` | — |
| apt | `/srv/repo/apt`, `/etc/apt/sources.list` emptied, `sources.list.d/` moved to `sources.list.d.upstream/`, `r770-local.list` written | `/root/apt-sources-<date>.tar.gz` (written before the rewrite) | `tar xzf /root/apt-sources-<date>.tar.gz -C / && apt-get update` — the stage does this by itself when `apt-get update` reaches an upstream host | — |
| phone-home | timers/units disabled, snapd purged, motd-news off, `update-motd.d/*` non-executable | none (states are recorded in the transcript) | `systemctl enable --now <unit>` per unit; `chmod +x /etc/update-motd.d/*`; `ENABLED=1` in `/etc/default/motd-news` | **snapd**: comes back only from a bundle that carries the deb; nothing in this build needs it |
| docker | `docker-ce docker-ce-cli containerd.io docker-compose-plugin` installed, `docker.service` enabled | — | `apt-get purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin` | image store contents on `/var/lib/docker` go with it |
| load (malcolm, gns3, docs) | images in the docker store, loaded from each pipeline's own tarball | — | `docker image rm <tag>` per list line, or leave them (harmless) | — |
| files | files under `/srv/vms/base`, `/srv/gns3/{appliances,images}`, `/opt/enrichment`, `/srv/docs` | the bundle | remove the directories; `rm /srv/bundles/.kit-stamps/files.*` to let the stage recopy | — |
| gns3 | `/opt/gns3` venv, user `gns3`, `/etc/gns3`, `/srv/gns3/*`, `/var/log/gns3`, `/etc/systemd/system/gns3.service` | — | `systemctl disable --now gns3; rm /etc/systemd/system/gns3.service; systemctl daemon-reload; rm -rf /opt/gns3 /etc/gns3` | projects under `/srv/gns3/projects` are analyst data — do not remove |
| gns3 labnet | `/etc/systemd/network/05-*lab*`; interfaces `br-lab`, `lab-tap0..N-1`, `lab-mon0`/`lab_mirror0`; the boot-time offload unit `/etc/systemd/system/r770-capture-offloads@.service` installed and its instance `r770-capture-offloads@lab_mirror0.service` enabled | — | `rm /etc/systemd/network/05-*lab*; networkctl reload; ip link del br-lab; ip link del lab-mon0; systemctl disable r770-capture-offloads@lab_mirror0.service; ip link del lab-tap<i>` (each). The unit template stays: physical capture ports (malcolm capture) share it | a running scenario loses its link on the bridge |
| malcolm capture | per physical capture port: `/etc/systemd/network/05-capture-<if>.network` (no address, ARP off, promiscuous), `r770-capture-offloads@<if>.service` enabled (and the unit template installed if labnet had not); the live port promiscuous, ARP off, offloads off | — | per port: `rm /etc/systemd/network/05-capture-<if>.network; systemctl disable r770-capture-offloads@<if>.service`; then `networkctl reload; ip link set <if> promisc off arp on` (each), or reboot. The unit template stays: labnet's `lab_mirror0` instance shares it | offloads stay off on the live port until the next boot |
| malcolm auth: docker group | the stack's owner (the `PUID` user in `/opt/malcolm/malcolm/config/process.env`) added to the `docker` group (`usermod -aG docker <user>`) | — (the gate's current section, in the transcript, lists the groups before) | `gpasswd -d <user> docker` — then `start` and `stop` refuse, and `auth` asks at its gate again | while it lasted, membership was root-equivalent: anything run as that user could have run a container as root |
| malcolm live capture | `pcapIface` / `captureLiveNetworkTraffic` / `liveArkime` / `liveZeek` in the rendered config | the exported config `/opt/malcolm/malcolm-config.exported.json` | rerun `r770-malcolm-deploy.sh configure` without `--capture-ifs`, then restart the stack | — |
| malcolm | `/opt/malcolm` (installer + stack), auth material, `docker-compose.yml` rebind, running stack | the exported config `/opt/malcolm/malcolm-config.exported.json` | `r770-malcolm-deploy.sh stop`; to redo configure: rerun `configure` (the installer regenerates the stack and the rebind is re-applied); to remove: `cd /opt/malcolm/malcolm && ./scripts/wipe` then `rm -rf /opt/malcolm` | **`wipe` deletes indexes and PCAP under the stack's own paths**; `/data/pcap/raw` and `/data/index` are bind mounts — treat them as evidence |
| portal | `/etc/lab/ca` (PKI), `/etc/nginx/ssl/{ca.crt,lab.crt,lab.key}`, `/etc/nginx/lab.htpasswd`, vhosts + snippets, default site removed | — | `rm /etc/nginx/sites-enabled/*.lab.conf; ln -s ../sites-available/default /etc/nginx/sites-enabled/default; nginx -t && systemctl reload nginx` | rebuilding the CA (`ca --force`) invalidates every certificate issued from it and every browser that imported it |
| docs | `/srv/www/docs` (the built site) | the previous site survives a failed `build` (staged in `/srv/www/docs.new`, swapped by rename) | `rm -rf /srv/www/docs` — `docs.lab` then answers 404 behind auth | — |
| secrets (any) | files under `/etc/lab/secrets/` | — | a `secrets --force` regenerates; the dependent step (`auth`, `config`) must then rerun | the old value is gone; anyone holding it is locked out |

## Stamps

`/srv/bundles/.kit-stamps/` records idempotent steps (`copied.<bundle>`,
`files.<bundle>.<category>`). Removing a stamp makes the stage redo that step;
`--force` does the same for one run.

## What the kit never touches

RAID, partitions, filesystems, the bootloader, firmware, SSH configuration,
Netplan, the default route, the firewall policy. Those are outside this kit,
with their own procedures; if a kit script appears to need one of them, the script
is wrong.
