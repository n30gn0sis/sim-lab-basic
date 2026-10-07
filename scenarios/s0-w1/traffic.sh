#!/bin/sh
# traffic.sh <node> <seconds> — W1 plain-transport validation from site A, then lane-A traffic.
node=$1 secs=$2
case "$node" in
    h-b) pkill iperf3 2>/dev/null; iperf3 -s -D -1 ;;
    h-a) ping -c 20 -i 0.2 198.18.10.6 \
         && traceroute -n -m 5 198.18.10.6 \
         && ping -M "do" -s 1472 -c 5 198.18.10.6 \
         && ping -c 10 -i 0.2 10.210.2.10 \
         && iperf3 -c 10.210.2.10 -b 50M -t "$((secs - 20))" -P 2 ;;
    *) echo "traffic.sh: no traffic role for node $node" >&2; exit 1 ;;
esac
