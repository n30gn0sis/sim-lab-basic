#!/bin/sh
# traffic.sh <node> <seconds> — runs inside one node (docker exec -i ... sh -s).
# cl pings the server, then fetches its page every half second for the window.
node=$1 secs=$2
case "$node" in
    cl)
        ping -c 3 10.205.0.20 || exit 1
        end=$(( $(date +%s) + secs ))
        while [ "$(date +%s)" -lt "$end" ]; do
            curl -sf -m 2 -o /dev/null http://10.205.0.20/ || exit 1
            sleep 0.5
        done ;;
    *) echo "traffic.sh: no traffic role for node $node" >&2; exit 1 ;;
esac
