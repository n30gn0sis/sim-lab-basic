# Reference PCAPs and Scenarios

A **reference PCAP with ground truth** is a capture of traffic whose cause is known in advance: we built the topology, chose the impairment, ran the traffic, and recorded what we did and when. When you open one you are not guessing what a retransmission burst or a rekey means. The run tells you, and a checklist says what the capture should show.

This is how the lab produces teaching and comparison captures: routing (OSPF, BGP), DNS, TLS, SSH, and IPsec over a simulated WAN. The lab operator runs a scenario; you find its traffic in Malcolm.

## Where runs live

A recorded run (the two WAN scenarios, `s0-w1` and `s1-w1-ss`) gets its own directory on the capture volume:

```
/data/pcap/cases/<scenario>/<run-id>/
```

Inside you will find the captures, `run.conf` (what was run, which TAPs, when), an `expected.md` listing the observations the run should show (each marked PASS, FAIL or SKIP by the automated checks), and a `gt/` folder.

## Finding a run in Arkime

Runs are uploaded to [Malcolm](malcolm.md) with tags, so a run appears as two views of the same traffic:

| Tag | What it is |
|---|---|
| `outer` | The traffic as the network saw it: IKE, ESP, NAT-T encapsulation. The payload is encrypted. |
| `inner-<node>` | The traffic as one site's gateway saw it, captured inside that node |

Every upload also carries the run's own tag, `<run-id>`. In Arkime, search on it (for example `tags == <run-id> && tags == outer`) and compare the views side by side. See [Malcolm](malcolm.md#arkime) for searching.

Every scenario in the pack, recorded or not, also has a saved search named `Scenario <name> - all traffic`, in Dashboards and in Arkime's view picker, that selects its address range.

## What `gt/` is, and why it is not in Malcolm

`gt/` is the ground truth: the session keys exported by the endpoints (when the gateway software can export them), security-association dumps, and the event log. It is what lets Wireshark decrypt the outer capture and lets the checks prove what happened. It is deliberately **never** uploaded to Malcolm. Key material does not belong in an analysis stack that many people can search, and the ingest step is built to copy only the tagged PCAPs. To decrypt in Wireshark, work from the run directory on the lab host.

## Scenario catalog

| Scenario | What it shows | Address range |
|---|---|---|
| `client-server` | A client fetching a web page from a server | 10.205.0.0/16 |
| `dns` | A client resolving names against a DNS responder | 10.206.0.0/16 |
| `tls` | A client fetching over TLS (self-signed certificate, name `tls.scenario.lab`) | 10.207.0.0/16 |
| `ssh` | A client failing key-only SSH logins, the shape of a password-guessing attack | 10.208.0.0/16 |
| `ospf` | Three routers in a line running OSPF; one hop crosses the lab bridge | 10.203.0.0/16 |
| `bgp` | eBGP between two routers in different autonomous systems | 10.204.0.0/16 |
| `ipsec-esp` | A static ESP tunnel between two gateways | 10.201.0.0/16 |
| `ipsec-ike` | IKEv2 negotiation and ESP between two strongSwan gateways | 10.202.0.0/16 |
| `s0-w1` | S0, the plaintext baseline over a simulated ISP: the comparison for everything else | 198.18.10.0/24 and 10.210.0.0/16 |
| `s1-w1-ss` | S1, site-to-site IKEv2 with a pre-shared key over the same ISP, strongSwan at both ends | 198.18.11.0/24 and 10.211.0.0/16 |

Underlay circuits for the two WAN scenarios come from the [WAN profiles](wan.md).

## How to run one

The operator runs these on the lab host, with `sudo` from the kit's directory (`B` is the bundle directory):

```bash
sudo ./scripts/r770-scenario.sh up s1-w1-ss --bundle $B      # import the project, start it, configure it, wait until ready
sudo ./scripts/r770-scenario.sh record s1-w1-ss              # captures plus traffic, with ground truth in a run directory
sudo ./scripts/r770-scenario.sh verify /data/pcap/cases/s1-w1-ss/<run-id>   # checks fill in expected.md
sudo ./scripts/r770-scenario.sh ingest /data/pcap/cases/s1-w1-ss/<run-id>   # tagged upload of the PCAPs to Malcolm (never gt/)
sudo ./scripts/r770-scenario.sh down s1-w1-ss                # stop and delete the project
```

The other scenarios use `up`, then `traffic <name>` (known traffic for a fixed window), then `down`; `check <name>` counts each expected flow as Arkime sessions in that window. Impairments and scenario traffic only ever touch lab bridges, never the management NIC or the capture ports.
