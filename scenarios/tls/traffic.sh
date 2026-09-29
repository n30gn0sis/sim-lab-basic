#!/bin/sh
# traffic.sh <node> <seconds> — runs inside one node (docker exec -i ... sh -s).
# cl fetches the server's status page over TLS, by name (SNI), every half second.
node=$1 secs=$2
case "$node" in
    cl)
        end=$(( $(date +%s) + secs ))
        while [ "$(date +%s)" -lt "$end" ]; do
            curl -skf -m 2 -o /dev/null --resolve tls.scenario.lab:443:10.207.0.20 https://tls.scenario.lab/ || exit 1
            sleep 0.5
        done ;;
    *) echo "traffic.sh: no traffic role for node $node" >&2; exit 1 ;;
esac
