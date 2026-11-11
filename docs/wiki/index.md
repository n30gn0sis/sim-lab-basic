# Analyst Guide — R770 Network Lab

New here? Start with [Getting started](getting-started.md).

## What this lab is

A single air-gapped Dell PowerEdge R770 running Ubuntu Server 24.04 that does four jobs at once:

1. **Full-packet capture and analysis** — the [Malcolm stack](malcolm.md) (Arkime, Zeek, OpenSearch Dashboards) ingests traffic from physical TAP/SPAN feeds and from imported PCAPs, indexes it, and lets you search sessions, read protocol logs, and pull packets back out for Wireshark.
2. **Network simulation** — [GNS3](gns3.md) runs virtual routers, firewalls, switches, and endpoints so you can build realistic topologies without touching production gear.
3. **WAN emulation** — [impairment profiles](wan.md) add latency, jitter, loss, and rate limits to lab links so topologies behave like real branch/satellite/broadband circuits.
4. **A workbench** — [host CLI tools](cli-tools.md) for spot captures, traffic replay, and throughput testing, plus per-analyst [workspace directories](access.md) for case artifacts and exports.

Everything runs offline. There is no internet on this box — software, IDS rules, and documentation all arrive via a curated offline bundle. What that means for you day-to-day is covered in [Access & housekeeping](access.md#air-gap-rules).

## Which tool, when

| You want to… | Use | Page |
|---|---|---|
| Search captured traffic by IP, port, protocol, URI, JA3, etc. | Arkime | [Malcolm](malcolm.md#arkime) |
| Read protocol metadata (DNS queries, TLS certs, HTTP requests, file transfers) | Zeek logs via Dashboards | [Malcolm](malcolm.md#zeek) |
| Get a visual overview of a time window (top talkers, protocols, trends) | OpenSearch Dashboards | [Malcolm](malcolm.md#dashboards) |
| Analyze a PCAP you brought from elsewhere | Malcolm upload via staging | [Malcolm](malcolm.md#importing-pcap) |
| Deep-dive individual packets | Export from Arkime → Wireshark on your workstation | [Malcolm](malcolm.md#exporting-to-wireshark) |
| Build a network topology to test or reproduce something | GNS3 | [GNS3](gns3.md) |
| Make a lab link behave like a bad WAN circuit | `r770-wan.sh` profiles (operator) | [WAN emulation](wan.md) |
| Find or produce a labelled IPsec/WAN reference PCAP | The scenario pack (`r770-scenario.sh`, operator), tagged Arkime sessions | [Scenarios](scenarios.md) |
| Capture and analyze traffic *from a lab topology* | Virtual mirror feed → Malcolm | [GNS3](gns3.md#analyzing-lab-traffic) |
| Quick spot-check that packets are flowing on an interface | `tcpdump` / `tshark` (pcapture group) | [CLI tools](cli-tools.md#spot-capture) |
| Replay a reference PCAP into a capture feed | `tcpreplay` | [CLI tools](cli-tools.md#tcpreplay) |
| Measure throughput or verify an impairment took effect | `iperf3`, `ping`, `mtr` | [CLI tools](cli-tools.md#throughput-and-path-testing) |

## The one rule that protects your evidence

Raw captured PCAP is **automatically deleted oldest-first** when the capture volume hits its free-space floor. If packets matter to a case, move or export them to a curated location (`cases/`, `archived/`, or your workspace) — those are never auto-deleted. Details in [Access & housekeeping](access.md#storage-and-retention).

## Pending items

These are the things this guide deliberately does *not* state, because they depend on hardware, build decisions, or measurement that hasn't happened:

- **Retention windows.** Usable disk is now known — **7.68 TB on one RAID-1 volume**, with **3.25 TiB allocated to PCAP** — but PCAP retention still depends on measured feed rates, so the windows below remain estimates until the build measures real feeds. Plan on **days, not weeks**.
- **Capture feed inventory.** Which physical ports carry which TAP/SPAN feeds, and their names, are set during build.
- **Account provisioning.** The lab has one shared analyst login (Malcolm and this wiki) and one GNS3 admin login. Whether you get your own, and how SSH keys are enrolled, is up to the lab operator.
- **Licensed GNS3 appliances.** Free/open-source appliances (VyOS, MikroTik CHR, OPNsense, FRR, etc.) are bundled; which licensed images (Cisco, Fortinet, Palo Alto) get staged depends on entitlement inventory, still open.
- **Suricata.** Present inside Malcolm but **disabled** at initial build. If it is enabled later, IDS alerts appear as an additional data source; the CPU budget must be re-checked first.
- **GeoIP.** Descoped — no MaxMind account. Geo fields (country, ASN maps) will be **absent** in Arkime and Dashboards unless this decision is reversed.
- **Windows endpoint VMs.** Not in the bundle (descoped). Lab endpoints are Linux (Ubuntu cloud image, Alpine, CirrOS, Docker nodes).
