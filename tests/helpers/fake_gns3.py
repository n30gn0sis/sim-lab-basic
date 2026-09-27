#!/usr/bin/env python3
"""A fake GNS3 v3 controller that answers the kit's curl calls.

tests/scenario.bats installs `curl` as a stub that execs this file, so every
request r770-scenario.sh makes lands here instead of on a network. State is a
directory, $FAKE_GNS3:

  projects.json   the controller's projects (a list; topology kept inside)
  requests.log    one "METHOD PATH" line per request, in order
  down            if present: /version is unreachable (curl exit 7)
  login-refused   if present: the login fails
  import-fails    if present: the import fails
  never-starts    if present: docker nodes stay "stopped" after nodes/start
  projects-fail   if present: GET /projects fails (the login still works)

Only the calls the kit makes are implemented; anything else fails. Like
`curl --fail`, a failure prints nothing and exits 22.
"""
import io
import json
import os
import re
import sys
import urllib.parse
import zipfile

STATE = os.environ["FAKE_GNS3"]
TOKEN = "fixture-token"


def path(name):
    return os.path.join(STATE, name)


def flag(name):
    return os.path.exists(path(name))


def load():
    try:
        with open(path("projects.json")) as f:
            return json.load(f)
    except FileNotFoundError:
        return []


def save(projects):
    with open(path("projects.json"), "w") as f:
        json.dump(projects, f)


def reply(obj):
    sys.stdout.write(json.dumps(obj))
    return 0


def parse(argv):
    method, url, data, headers = "GET", None, None, []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "-X":
            method = argv[i + 1]
            i += 1
        elif a == "-H":
            headers.append(argv[i + 1])
            i += 1
        elif a in ("--data", "--data-binary", "-d"):
            data = argv[i + 1]
            i += 1
        elif a == "--max-time":
            i += 1
        elif "://" in a:
            url = a
        i += 1
    return method, url, data, headers


def header_lines(headers):
    out = []
    for h in headers:
        if h.startswith("@"):
            with open(h[1:]) as f:
                out += [line.strip() for line in f if line.strip()]
        else:
            out.append(h)
    return out


def body_of(data):
    if data is None:
        return b""
    if data.startswith("@"):
        with open(data[1:], "rb") as f:
            return f.read()
    return data.encode()


def public(p):
    return {k: v for k, v in p.items() if k != "topology"}


def node_view(n):
    props = dict(n.get("properties") or {})
    if n.get("node_type") == "docker":
        props["container_id"] = "cid-" + n["name"]
    return {"node_id": n["node_id"], "name": n["name"], "node_type": n["node_type"],
            "status": n.get("status", "stopped"), "properties": props}


def main():
    method, url, data, headers = parse(sys.argv[1:])
    route = re.sub(r"^https?://[^/]+", "", url or "")
    with open(path("requests.log"), "a") as f:
        f.write(f"{method} {route}\n")
    if route == "/v3/version":
        return 7 if flag("down") else reply({"version": "fixture"})
    # As the real controller: /login is OAuth2 and takes a FORM body (JSON gets
    # a 422); /authenticate takes the same credentials as JSON. Measured on
    # staging VM 9770 against the bundled gns3-server, 2026-09-26.
    if route in ("/v3/access/users/login", "/v3/access/users/authenticate") and method == "POST":
        json_body = any(h.lower().startswith("content-type: application/json") for h in header_lines(headers))
        raw = body_of(data)
        if route.endswith("/login"):
            if json_body:
                return 22
            creds = dict(urllib.parse.parse_qsl(raw.decode()))
        else:
            creds = json.loads(raw or b"{}") if json_body else {}
        if flag("login-refused") or not creds.get("username") or not creds.get("password"):
            return 22
        return reply({"access_token": TOKEN, "token_type": "bearer"})
    if f"Authorization: Bearer {TOKEN}" not in header_lines(headers):
        return 22
    projects = load()
    base, _, query = route.partition("?")
    m = re.fullmatch(r"/v3/projects(?:/([^/]+))?(/.*)?", base)
    if not m:
        return 22
    pid, rest = m.group(1), m.group(2) or ""
    if pid is None:
        if method != "GET" or flag("projects-fail"):
            return 22
        return reply([public(p) for p in projects])
    proj = next((p for p in projects if p["project_id"] == pid), None)
    if rest == "/import" and method == "POST":
        if flag("import-fails") or proj is not None:
            return 22
        name = dict(kv.split("=", 1) for kv in query.split("&") if "=" in kv).get("name", "")
        with zipfile.ZipFile(io.BytesIO(body_of(data))) as z:
            topo = json.loads(z.read("project.gns3"))
        projects.append({"project_id": pid, "name": name, "status": "closed",
                         "variables": topo.get("variables") or [],
                         "topology": topo["topology"]})
        save(projects)
        return reply(public(projects[-1]))
    if proj is None:
        return 22
    if rest == "/open" and method == "POST":
        proj["status"] = "opened"
        save(projects)
        return reply(public(proj))
    if rest == "/nodes" and method == "GET":
        if proj["status"] != "opened":
            return 22
        return reply([node_view(n) for n in proj["topology"]["nodes"]])
    if rest in ("/nodes/start", "/nodes/stop") and method == "POST":
        if proj["status"] != "opened":
            return 22
        state = "started" if rest.endswith("start") and not flag("never-starts") else "stopped"
        for n in proj["topology"]["nodes"]:
            if n.get("node_type") == "docker":
                n["status"] = state
        save(projects)
        return reply({})
    if rest == "" and method == "DELETE":
        projects.remove(proj)
        save(projects)
        return reply({})
    return 22


if __name__ == "__main__":
    sys.exit(main())
