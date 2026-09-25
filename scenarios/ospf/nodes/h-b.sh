# h-b: host behind r3
set -e
ip addr replace 10.203.3.10/24 dev eth0
ip link set dev eth0 up
ip route replace default via 10.203.3.1
