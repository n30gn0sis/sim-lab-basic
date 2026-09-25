#!/usr/bin/env python3
"""Lint the kit's scenario pack (scenarios/<name>/...). Usage: lint_scenarios.py <check>

Checks: layout json topology images addresses expect. Prints one line per
problem and exits 1 if there are any. Run from the repo root.
"""
import ipaddress
import json
import os
import re
import sys

ROOT = "scenarios"
KEYS = ["name", "description", "range", "images", "traffic_secs", "ready", "traffic_nodes"]
UPSTREAM_PENDING = {"strongswan"}  # added to the build repo's pin block, not yet in a bundle
PROTOS = {"tcp", "udp", "icmp", "esp", "ospf"}


def scenarios():
    return sorted(d for d in os.listdir(ROOT) if os.path.isfile(os.path.join(ROOT, d, "scenario.conf")))


def conf(s):
    out = {}
    with open(os.path.join(ROOT, s, "scenario.conf")) as f:
        for line in f:
            if "=" in line:
                k, v = line.rstrip("\n").split("=", 1)
                out.setdefault(k, v)
    return out


def project(s):
    with open(os.path.join(ROOT, s, "project", s + ".gns3")) as f:
        return json.load(f)


def bundled_images():
    names = set()
    with open("staging/r770-offline-fetch.sh") as f:
        text = f.read()
    block = re.search(r"GNS3_NODE_IMAGES=\((.*?)\)", text, re.S).group(1)
    for ref in re.findall(r'"([^"]+)"', block):
        if ref.startswith("$"):
            ref = re.search(r'FRR_IMG="\$\{FRR_IMG:-([^}]+)\}"', text).group(1)
        names.add(ref.split("/")[-1].split(":")[0])
    return names


def check_layout(s, c, errs):
    for k in KEYS:
        if not c.get(k):
            errs.append(f"{s}: scenario.conf lacks {k}=")
    if c.get("name") != s:
        errs.append(f"{s}: name= is {c.get('name')!r}, not the directory name")
    for f in ("traffic.sh", "expect.txt", os.path.join("project", s + ".gns3")):
        if not os.path.isfile(os.path.join(ROOT, s, f)):
            errs.append(f"{s}: missing {f}")
    if "|" not in c.get("ready", ""):
        errs.append(f"{s}: ready= must be <node>|<command>")
    if not c.get("traffic_secs", "").isdigit():
        errs.append(f"{s}: traffic_secs= must be whole seconds")


def check_json(s, c, errs):
    try:
        p = project(s)
    except (OSError, ValueError) as e:
        errs.append(f"{s}: project does not parse: {e}")
        return
    if p.get("name") != "__PROJECT_NAME__" or p.get("project_id") != "__PROJECT_ID__":
        errs.append(f"{s}: project name/project_id must be __PROJECT_NAME__/__PROJECT_ID__")
    if {"name": "r770_scenario", "value": "__SCENARIO__"} not in (p.get("variables") or []):
        errs.append(f"{s}: project lacks the r770_scenario=__SCENARIO__ variable")
    if "version" in p:
        errs.append(f"{s}: project carries a version field (no pins; revision identifies the format)")


def check_topology(s, c, errs):
    p = project(s)
    nodes = p["topology"]["nodes"]
    clouds = [n for n in nodes if n["node_type"] == "cloud"]
    ports = sorted(m.get("interface") for n in clouds for m in n["properties"].get("ports_mapping", []))
    if ports != ["__TAP_A__", "__TAP_B__"]:
        errs.append(f"{s}: Cloud ports must be exactly __TAP_A__ and __TAP_B__ (got {ports})")
    for n in clouds:
        for m in n["properties"].get("ports_mapping", []):
            if m.get("type") != "tap":
                errs.append(f"{s}: Cloud {n['name']} port {m.get('interface')} is not \"type\": \"tap\"")
    ids = {n["node_id"] for n in nodes}
    cloud_ids = {n["node_id"] for n in clouds}
    on_clouds = 0
    for link in p["topology"]["links"]:
        ends = [e["node_id"] for e in link["nodes"]]
        if any(e not in ids for e in ends):
            errs.append(f"{s}: link {link['link_id']} names an unknown node")
        on_clouds += any(e in cloud_ids for e in ends)
    if on_clouds != 2:
        errs.append(f"{s}: exactly two links attach to the Clouds (got {on_clouds})")
    docker = {n["name"] for n in nodes if n["node_type"] == "docker"}
    named = {c["ready"].split("|", 1)[0]} | set(c["traffic_nodes"].split())
    for f in os.listdir(os.path.join(ROOT, s, "nodes")) if os.path.isdir(os.path.join(ROOT, s, "nodes")) else []:
        named.add(f.split(".", 1)[0])
    for n in sorted(named - docker):
        errs.append(f"{s}: {n} is named in the scenario but is not a docker node of the project")


def check_images(s, c, errs):
    known = bundled_images() | UPSTREAM_PENDING
    listed = c.get("images", "").split()
    for i in listed:
        if i not in known:
            errs.append(f"{s}: image {i} is neither bundled (GNS3_NODE_IMAGES) nor upstream-pending")
    want = {"__IMG_" + i.upper().replace("-", "_") + "__" for i in listed}
    for n in project(s)["topology"]["nodes"]:
        if n["node_type"] == "docker" and n["properties"].get("image") not in want:
            errs.append(f"{s}: node {n['name']} image {n['properties'].get('image')!r} is not one of {sorted(want)}")


def check_addresses(s, c, errs):
    net = ipaddress.ip_network(c["range"])
    files = ["traffic.sh", "expect.txt", "scenario.conf"]
    nd = os.path.join(ROOT, s, "nodes")
    if os.path.isdir(nd):
        files += [os.path.join("nodes", f) for f in os.listdir(nd)]
    for f in files:
        with open(os.path.join(ROOT, s, f)) as fh:
            text = fh.read()
        for a in re.findall(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", text):
            ip = ipaddress.ip_address(a)
            if ip in net or ip.is_multicast or ip == ipaddress.ip_address("0.0.0.0"):
                continue
            errs.append(f"{s}: {f} names {a}, outside {net}")


def check_expect(s, c, errs):
    net = ipaddress.ip_network(c["range"])
    with open(os.path.join(ROOT, s, "expect.txt")) as f:
        lines = [line.strip() for line in f if line.strip() and not line.startswith("#")]
    if not lines:
        errs.append(f"{s}: expect.txt is empty")
    for line in lines:
        parts = line.split("|")
        if len(parts) != 4:
            errs.append(f"{s}: expect.txt line {line!r} is not proto|port|src|dst")
            continue
        proto, port, src, dst = parts
        if proto not in PROTOS:
            errs.append(f"{s}: expect.txt proto {proto!r} not in {sorted(PROTOS)}")
        if port and not port.isdigit():
            errs.append(f"{s}: expect.txt port {port!r} is not a number")
        for r in (src, dst):
            n = ipaddress.ip_network(r)
            if not (n.subnet_of(net) or n.is_multicast):
                errs.append(f"{s}: expect.txt range {r} is outside {net}")


def main():
    check = sys.argv[1]
    errs = []
    names = scenarios()
    if check == "layout" and not names:
        errs.append("no scenarios under scenarios/")
    ranges = {}
    for s in names:
        c = conf(s)
        if check == "layout":
            check_layout(s, c, errs)
            ranges.setdefault(c.get("range"), []).append(s)
        else:
            globals()["check_" + check](s, c, errs)
    for r, ss in ranges.items():
        if len(ss) > 1:
            errs.append(f"range {r} is shared by {ss}")
    for e in errs:
        print(e)
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
