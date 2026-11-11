# Getting started

Read this first. It takes ten minutes and ends with you looking at real traffic.

## What this lab is

GNS3 is where networks are built: routers, firewalls and hosts running as software. One shared bridge in the lab, `br-lab`, mirrors the traffic of whatever is plugged into it. Malcolm captures that mirror and indexes it, so you can search it in Arkime, read protocol logs in Dashboards, and pull packets out for Wireshark. Everything you do happens in a browser.

## The three addresses

| Address | What it is | Login |
|---|---|---|
| `https://malcolm.lab` | Malcolm: Arkime and Dashboards | The shared analyst login |
| `https://docs.lab` | This guide | The shared analyst login |
| `https://gns3.lab` | GNS3 | The GNS3 admin login |

Ask the lab operator for both logins. The lab has its own certificate authority, so your browser warns on every address until it trusts the lab CA certificate; the operator gives you that file, and [Access & housekeeping](access.md#getting-in) says how to use it.

## See traffic in ten minutes

An operator brings up a small network, makes it talk, and tears it down again. In the kit's directory on the lab host (`<bundle>` is the bundle directory):

```bash
sudo ./scripts/r770-scenario.sh up client-server --bundle <bundle>
sudo ./scripts/r770-scenario.sh traffic client-server
sudo ./scripts/r770-scenario.sh down client-server
```

Then open Arkime at `https://malcolm.lab`, set the time range to the last 15 minutes, and search `ip == 10.205.0.20`. You will see the sessions between a client and a web server: pings and one web request every half second for a minute.

## Where to look next

- [Malcolm](malcolm.md): searching sessions, reading Zeek logs, importing your own PCAP.
- [GNS3](gns3.md): building a topology and feeding its traffic to Malcolm.
- [Scenarios](scenarios.md): the ten ready-made scenarios and how to find their traffic.

## What the lab does not have

- **No internet.** Nothing can be installed or looked up from the lab; software arrives in a bundle.
- **No GeoIP.** Country and ASN fields are empty, and map panels show nothing.
- **No IDS alerts.** Suricata is off, so no signature alerts exist.
- **Data only as fresh as the last bundle.** Reference data does not update itself.
