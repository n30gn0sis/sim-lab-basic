# h-a: host behind r1 (AS 64601)
set -e
ip addr replace 10.204.1.10/24 dev eth0
ip link set dev eth0 up
ip route replace default via 10.204.1.1
