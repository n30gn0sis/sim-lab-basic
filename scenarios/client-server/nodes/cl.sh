# cl: the client, on br-lab through tap-a
set -e
ip addr replace 10.205.0.10/24 dev eth0
ip link set dev eth0 up
