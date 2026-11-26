#!/usr/bin/env bash
#
# harness/lib/ssh-config.sh — the per-run ssh config both Proxmox drivers
# (r770-proxmox-e2e.sh, r770-staging-vm.sh) write and then use with `ssh -F`.
# Sourced after scripts/lib/common.sh (it uses die and note); operator-side only.
#
# ssh_config_write <path> <writer> <pve-alias> <pve-host> <pve-user> <identity> [<guest-host> <guest-known-hosts>]
#
# Writes <path> from its arguments alone, every run (a file left on disk is
# never trusted), mode 0600, through a temporary file and mv:
#   Host <pve-alias>    HostName/User/IdentityFile from the arguments, key-only,
#                       StrictHostKeyChecking yes against the operator's own
#                       known_hosts: the hypervisor's key is trusted already,
#                       never accepted blind.
#   Host <guest-host>   (only when given) reached ONLY by ProxyJump through the
#                       alias, same key, its own known_hosts (accept-new).
# It names the key file and holds no secret. Every path in it must be made of
# [A-Za-z0-9._/-]: ssh_config cannot quote '"' or '%', and ProxyJump hands
# `-F <path>` to a shell unquoted, so a space or a `$ ; \`` would break or
# rewrite the jump. Such a directory is refused, never escaped.

SSH_CONFIG_SAFE='^[A-Za-z0-9._/-]+$'

ssh_config_write() {
    local path=$1 writer=$2 alias=$3 host=$4 user=$5 key=$6 guest=${7:-} kh=${8:-} f tmp
    for f in "$path" "$key" ${kh:+"$kh"}; do
        [[ "$f" =~ $SSH_CONFIG_SAFE ]] \
            || die "'$f' holds a character outside [A-Za-z0-9._/-]: ssh -F and ProxyJump cannot carry it safely — run from (or set KIT_EVIDENCE_DIR to) a plain path"
    done
    mkdir -p "$(dirname "$path")" || die "cannot create $(dirname "$path")"
    tmp="$path.tmp.$$"
    # The umask must hold where the file is OPENED: the redirection sits inside
    # the subshell, or the parent would create it with its own umask.
    if ! ( umask 077
           { printf '# Written by %s from its arguments on every run; read only\n' "$writer"
             printf '# through ssh -F. It names the key file and holds no secret.\n'
             printf 'Host %s\n' "$alias"
             printf '    HostName %s\n    User %s\n' "$host" "$user"
             printf '    IdentityFile "%s"\n    IdentitiesOnly yes\n' "$key"
             printf '    BatchMode yes\n    ConnectTimeout 10\n'
             printf '    StrictHostKeyChecking yes\n'
             if [ -n "$guest" ]; then
                 printf 'Host %s\n' "$guest"
                 printf '    ProxyJump %s\n' "$alias"
                 printf '    IdentityFile "%s"\n    IdentitiesOnly yes\n' "$key"
                 printf '    BatchMode yes\n    ConnectTimeout 10\n    ServerAliveInterval 30\n'
                 printf '    StrictHostKeyChecking accept-new\n'
                 printf '    UserKnownHostsFile "%s"\n' "$kh"
             fi
           } > "$tmp" ); then
        rm -f "$tmp"; die "cannot write the run's ssh config $path"
    fi
    if ! mv -f "$tmp" "$path"; then
        rm -f "$tmp"; die "cannot write the run's ssh config $path"
    fi
    note "ssh config for this run: $path"
}
