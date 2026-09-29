# srv: sshd on br-lab through tap-b, key-only with no authorized keys, so
# every login fails authentication after a full handshake: repeated SSH
# sessions from one client, the shape of password guessing. Zeek's ssh.log
# records each with the client banner; it leaves auth_success unset (-),
# since a fast public-key refusal gives it nothing to infer from (measured
# on staging VM 9770, 2026-09-29). Host keys are
# generated here at up; sshd daemonizes itself, so docker exec returns.
set -e
ip addr replace 10.208.0.20/24 dev eth0
ip link set dev eth0 up
ssh-keygen -A >/dev/null
mkdir -p /run/sshd /var/empty
/usr/sbin/sshd -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o PermitRootLogin=prohibit-password
