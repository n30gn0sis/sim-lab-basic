#!/bin/sh
# traffic.sh <node> <seconds> — runs inside one node (docker exec -i ... sh -s).
# h-b serves one iperf3 run; h-a pings across the OSPF path, then pushes iperf3.
node=$1 secs=$2
case "$node" in
    h-b) pkill iperf3 2>/dev/null; iperf3 -s -D -1 ;;
    h-a) ping -c 5 -i 0.2 10.203.3.10 && iperf3 -c 10.203.3.10 -t "$secs" ;;
    *) echo "traffic.sh: no traffic role for node $node" >&2; exit 1 ;;
esac
