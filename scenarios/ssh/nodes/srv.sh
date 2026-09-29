# srv: sshd on br-lab through tap-b, key-only with no authorized keys, so
# every login fails authentication after a full handshake: Zeek's ssh.log
# records auth_success=F, the shape of password guessing. Host keys are
# generated here at up; sshd daemonizes itself, so docker exec returns.
set -e
ip addr replace 10.208.0.20/24 dev eth0
ip link set dev eth0 up
ssh-keygen -A >/dev/null
mkdir -p /run/sshd /var/empty
/usr/sbin/sshd -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o PermitRootLogin=prohibit-password
