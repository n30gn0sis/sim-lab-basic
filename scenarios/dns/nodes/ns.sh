# ns: a small authoritative responder on br-lab through tap-b. The bundle has
# no DNS server image, so a python3 stdlib program answers A records under
# lab.scenario with 10.206.0.99 and everything else with NXDOMAIN: enough for
# Zeek's dns.log and Arkime's DNS parser to see both outcomes. Fully
# detached, so docker exec returns.
set -e
ip addr replace 10.206.0.53/24 dev eth0
ip link set dev eth0 up
cat > /tmp/lab-dns.py <<'PY'
import os, socket, struct
bind = os.environ.get("DNS_BIND", "10.206.0.53")
port = int(os.environ.get("DNS_PORT", "53"))
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((bind, port))
while True:
    q, peer = s.recvfrom(512)
    if len(q) < 17:
        continue
    i, labels = 12, []
    while i < len(q) and q[i]:
        n = q[i]
        labels.append(q[i + 1:i + 1 + n].decode("ascii", "replace").lower())
        i += 1 + n
    if i + 5 > len(q):
        continue
    qtype = struct.unpack(">H", q[i + 1:i + 3])[0]
    question = q[12:i + 5]
    name = ".".join(labels)
    if (name == "lab.scenario" or name.endswith(".lab.scenario")) and qtype == 1:
        head = q[:2] + b"\x81\x80" + struct.pack(">HHHH", 1, 1, 0, 0)
        answer = b"\xc0\x0c" + struct.pack(">HHIH", 1, 1, 60, 4) + socket.inet_aton("10.206.0.99")
    else:
        head = q[:2] + b"\x81\x83" + struct.pack(">HHHH", 1, 0, 0, 0)
        answer = b""
    s.sendto(head + question + answer, peer)
PY
(python3 /tmp/lab-dns.py) </dev/null >/dev/null 2>&1 &
