# Access & Housekeeping

How you reach the lab, where your files live, what gets deleted automatically, and the rules an air-gapped box imposes.

## Getting in

All analyst access happens over the **management network**. The capture side of the box is invisible to you by design — capture ports have no IP addresses and cannot be reached.

| Access | Mechanism | Notes |
|---|---|---|
| Web services | HTTPS through the Nginx front door | Three addresses: `https://malcolm.lab` (Malcolm: Arkime, Dashboards), `https://gns3.lab` (GNS3) and `https://docs.lab` (this guide). They are `.lab` names, so your workstation must resolve them to the lab server (ask the operator) |
| Shell | SSH, **key-only** (no passwords, no root login) | Management IP only. Send your public key to the lab operator to be enrolled |
| PCAP drop-off | SFTP to the staging area | Scoped account; see [Importing PCAP](malcolm.md#importing-pcap) |
| GNS3 desktop client | Connects to the GNS3 server API at `gns3.lab` | Same credentials as the GNS3 web UI |

**TLS certificates:** the lab has no public CA. Services present certificates from the lab's **internal CA** — you will need to trust the internal CA certificate on your workstation once (browser + OS store), or you'll see warnings on every service. Get the CA certificate (`ca.crt`) from the lab operator; once your workstation trusts it, `malcolm.lab`, `gns3.lab` and `docs.lab` open without warnings.

**Logins:** there are two. One shared analyst login opens Malcolm (`malcolm.lab`) and this guide (`docs.lab`); GNS3 (`gns3.lab`) has its own admin login. Ask the lab operator for them.

## Storage and retention

The disk layout separates evidence, scratch, and infrastructure so that nothing can starve anything else. What you need to know as an analyst:

| Path | What it's for | Deletion policy |
|---|---|---|
| `/data/pcap/raw/` | Live capture written by Arkime | **Auto-deleted oldest-first** when the volume hits its free-space floor. Never store anything here yourself |
| `/data/pcap/cases/` | PCAPs promoted to a case | **Never auto-deleted.** Operator-curated |
| `/data/pcap/archived/` | Long-term keeps | **Never auto-deleted** |
| `/data/pcap/temporary/` | Short-lived scratch captures | Treat as expendable |
| `/data/staging/` | SFTP upload area for imported PCAPs | Working area — clean up after Malcolm ingests your file |
| `/srv/work/` | Per-analyst workspaces: exports, reports, case artifacts | **Never auto-deleted** |

The practical rule: **`raw/` is a conveyor belt, not a shelf.** How long the belt is depends on total ingest rate. Against the **3.25 TiB** allocated to PCAP: roughly **3 days** at a sustained 100 Mbps across all feeds, about **16 hours** at 500 Mbps, and **8 hours** at 1 Gbps. (An earlier version of this page said "two weeks" — that came from a decimal error in the design doc's retention table and was ten times too optimistic.) Real numbers come after the build measures real feeds — until then assume raw retention is **short**, and promote anything that matters the day you find it.

Zeek/Arkime *metadata* (the searchable index) has its own longer retention, managed by index lifecycle policies — so you will often still be able to *find* a session in Arkime after its packets have rolled off. You get the session record and protocol logs, but not the payload.

**Backups:** configs, GNS3 projects, curated case artifacts, and workspace selections are backed up nightly. Raw PCAP and search indexes are **not** backed up, by policy. If it only exists in `raw/`, it isn't protected.

## Air-gap rules

This server has **no internet access, ever**. Consequences:

- **You cannot install software on it.** `apt install`, `pip install`, and `docker pull` all fail by design. If a tool you need is missing, request it — it gets added to the next offline bundle. There is no workaround, and attempting one is a policy violation.
- **IDS rules and enrichment data are only as fresh as the last bundle.** The Suricata ET Open ruleset, OUI vendor list, and similar data update only when a new bundle is cut.
- **No geo lookups.** GeoIP was descoped; country/ASN fields are absent in Arkime and Dashboards.
- **Bringing data in:** PCAPs and files come in via SFTP to `/data/staging/` over the management network, or via approved removable media per site policy.
- **Taking data out:** exports leave via SFTP from `/srv/work/`, subject to site data-handling policy. Nothing on this box syncs anywhere automatically.
- **Time:** the lab keeps its own clock (chrony serves the lab). Timestamps are consistent *within* the lab; verify offset against your evidence source before correlating with external logs.
