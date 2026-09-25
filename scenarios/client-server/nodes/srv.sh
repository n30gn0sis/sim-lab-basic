# srv: busybox httpd serving one page, on br-lab through tap-b
set -e
ip addr replace 10.205.0.20/24 dev eth0
ip link set dev eth0 up
mkdir -p /www
echo "lab-scenario client-server" > /www/index.html
httpd -p 80 -h /www
