#!/bin/sh
# traffic.sh <node> <seconds> — runs inside one node (docker exec -i ... sh -s).
# cl opens an SSH session every second and fails authentication each time
# (no key the server accepts). A failed login is the point, so its exit is
# ignored; the server must still answer, or the window is not traffic.
node=$1 secs=$2
case "$node" in
    cl)
        nc -z -w 2 10.208.0.20 22 || exit 1
        end=$(( $(date +%s) + secs ))
        while [ "$(date +%s)" -lt "$end" ]; do
            ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                -o ConnectTimeout=3 labuser@10.208.0.20 true >/dev/null 2>&1 || true
            sleep 1
        done ;;
    *) echo "traffic.sh: no traffic role for node $node" >&2; exit 1 ;;
esac
