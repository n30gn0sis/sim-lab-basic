# h-a: host behind r1
set -e
ip addr replace 10.203.1.10/24 dev eth0
ip link set dev eth0 up
ip route replace default via 10.203.1.1
