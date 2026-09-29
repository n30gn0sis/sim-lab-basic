# cl: the TLS client, on br-lab through tap-a
set -e
ip addr replace 10.207.0.10/24 dev eth0
ip link set dev eth0 up
