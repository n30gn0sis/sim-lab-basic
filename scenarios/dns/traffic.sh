#!/bin/sh
# traffic.sh <node> <seconds> — runs inside one node (docker exec -i ... sh -s).
# cl resolves a rotating set of names for the window: names under
# scenario.lab (answered) and names outside it (NXDOMAIN).
node=$1 secs=$2
case "$node" in
    cl)
        dig +short +time=1 +tries=1 @10.206.0.53 www.scenario.lab | grep -qx 10.206.0.99 || exit 1
        end=$(( $(date +%s) + secs ))
        while [ "$(date +%s)" -lt "$end" ]; do
            for n in www.scenario.lab mail.scenario.lab files.scenario.lab nothere.example; do
                dig +time=1 +tries=1 @10.206.0.53 "$n" >/dev/null 2>&1 || true
            done
            sleep 1
        done ;;
    *) echo "traffic.sh: no traffic role for node $node" >&2; exit 1 ;;
esac
