#!/bin/sh
# traffic.sh <node> <seconds> — gw-a renegotiates inside the window; h-b serves; h-a drives lane A.
node=$1 secs=$2
case "$node" in
    gw-a) swanctl --terminate --ike s1 >/dev/null 2>&1; swanctl --initiate --child s1-net >/dev/null ;;
    h-b)  pkill iperf3 2>/dev/null; iperf3 -s -D ;;
    h-a)  ping -c 20 -i 0.2 10.211.2.10 \
          && iperf3 -c 10.211.2.10 -b 20M -t "$((secs - 60))" -P 2 \
          && iperf3 -c 10.211.2.10 -u -b 5M -t 30 \
          && ping -c 20 -i 0.5 10.211.2.10 ;;
    *) echo "traffic.sh: no traffic role for node $node" >&2; exit 1 ;;
esac
