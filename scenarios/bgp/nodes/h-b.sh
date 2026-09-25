# h-b: host behind r2 (AS 64602)
set -e
ip addr replace 10.204.2.10/24 dev eth0
ip link set dev eth0 up
ip route replace default via 10.204.2.1
