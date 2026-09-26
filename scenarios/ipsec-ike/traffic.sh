#!/bin/sh
# traffic.sh <node> <seconds> — runs inside one node (docker exec -i ... sh -s).
# gw-a drops the IKE SA so cl-a's first ping makes the trap negotiate afresh inside the
# window (IKE_SA_INIT on udp/500, IKE_AUTH on 4500); cl-b serves one iperf3 run; cl-a
# pings through the IKE-keyed tunnel, then iperf3.
node=$1 secs=$2
case "$node" in
    gw-a) swanctl --terminate --ike lab >/dev/null ;;
    cl-b) pkill iperf3 2>/dev/null; iperf3 -s -D -1 ;;
    cl-a) ping -c 5 -i 0.2 10.202.2.10 && iperf3 -c 10.202.2.10 -b 50M -t "$secs" ;;
    *) echo "traffic.sh: no traffic role for node $node" >&2; exit 1 ;;
esac
