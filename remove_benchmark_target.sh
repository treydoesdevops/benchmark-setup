#!/usr/bin/env bash
# Reverses everything setup_benchmark_target.sh added to this machine.
# Run as root (or via sudo).
#
# Options:
#   --remove-ssh   Also remove the openssh-server package (only if you didn't
#                  have it before running setup_benchmark_target.sh)
set -euo pipefail

PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGuNmaD/FM1AvwzjRDnVdWRKdoZI53vg48mQg7O0ojoj benchmark-ansible'
SERVICE_USER='benchmark-ansible'
FIREWALL_RULE_NAME='benchmark-ansible-ssh'
REMOVE_SSH=false

for arg in "$@"; do
    [[ "$arg" == '--remove-ssh' ]] && REMOVE_SSH=true
done

if [[ $EUID -ne 0 ]]; then
    echo "Run as root:  sudo $0 $*" >&2
    exit 1
fi

done_() { printf '  \033[32m[+]\033[0m %s\n' "$*"; }
skip()  { printf '  \033[90m[-]\033[0m %s\n' "$*"; }

printf '\n  \033[1mRemoving Benchmark Ansible target configuration...\033[0m\n'
printf '  ────────────────────────────────────\n\n'

# ── Firewall ───────────────────────────────────────────────────────────────────
if systemctl is-active --quiet firewalld 2>/dev/null; then
    IFACE=$(ip route show default 2>/dev/null | awk '/default/ { print $5; exit }')
    IP_PREFIX=$(ip -4 addr show dev "$IFACE" 2>/dev/null | awk '/inet / { print $2; exit }')
    LAN_SUBNET=$(python3 -c \
        "import ipaddress; print(str(ipaddress.ip_interface('$IP_PREFIX').network))" 2>/dev/null || true)
    if [[ -n "$LAN_SUBNET" ]]; then
        firewall-cmd --quiet --permanent \
            --remove-rich-rule="rule family=ipv4 source address=\"$LAN_SUBNET\" service name=\"ssh\" accept" \
            2>/dev/null && done_ "firewalld rule removed." || skip "firewalld rule not found."
        firewall-cmd --quiet --reload
    else
        skip "Could not detect LAN subnet — firewall rule not removed."
    fi
elif command -v nft &>/dev/null; then
    # Remove any nftables rule with our comment tag
    HANDLE=$(nft -a list ruleset 2>/dev/null | awk "/$FIREWALL_RULE_NAME/ { print \$NF }")
    if [[ -n "$HANDLE" ]]; then
        TABLE=$(nft -a list ruleset 2>/dev/null | awk "/$FIREWALL_RULE_NAME/ { print prev } { prev=\$0 }" | \
            grep -oP 'inet \K\S+' | head -1 || true)
        CHAIN=$(nft -a list ruleset 2>/dev/null | awk "/$FIREWALL_RULE_NAME/ { print chain } /chain / { chain=\$2 }" | \
            tail -1 || true)
        nft delete rule inet "${TABLE:-filter}" "${CHAIN:-INPUT}" handle "$HANDLE" 2>/dev/null \
            && done_ "nftables rule removed." || skip "Could not remove nftables rule — remove manually."
    else
        skip "nftables rule not found."
    fi
else
    skip "No active firewall detected — nothing to remove."
fi

# ── SSH public key ─────────────────────────────────────────────────────────────
AUTH_KEYS="/home/$SERVICE_USER/.ssh/authorized_keys"
if [[ -f "$AUTH_KEYS" ]]; then
    if grep -qF "$PUBLIC_KEY" "$AUTH_KEYS"; then
        grep -vF "$PUBLIC_KEY" "$AUTH_KEYS" > "${AUTH_KEYS}.tmp" && mv "${AUTH_KEYS}.tmp" "$AUTH_KEYS"
        if [[ ! -s "$AUTH_KEYS" ]]; then
            rm -f "$AUTH_KEYS"
            done_ "authorized_keys removed (was the only entry)."
        else
            done_ "Public key removed from authorized_keys."
        fi
    else
        skip "Public key not found in authorized_keys."
    fi
else
    skip "authorized_keys not found."
fi

# ── Service account ────────────────────────────────────────────────────────────
if id "$SERVICE_USER" &>/dev/null; then
    userdel --remove "$SERVICE_USER" 2>/dev/null || userdel "$SERVICE_USER"
    done_ "User '$SERVICE_USER' and home directory removed."
else
    skip "User '$SERVICE_USER' not found."
fi

# ── SSH server (optional) ──────────────────────────────────────────────────────
if $REMOVE_SSH; then
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
    fi
    case "${ID:-unknown}" in
        arch|cachyos|endeavouros)
            pacman -Rs --noconfirm openssh 2>/dev/null && done_ "openssh removed." || skip "openssh not installed via pacman."
            ;;
        fedora|bazzite|nobara)
            rpm-ostree uninstall openssh-server 2>/dev/null \
                && done_ "openssh-server queued for removal (reboot to apply)." \
                || skip "openssh-server not installed via rpm-ostree."
            ;;
        *)
            skip "Unknown distro — remove SSH server manually."
            ;;
    esac
else
    skip "SSH server left in place. Pass --remove-ssh to uninstall it."
fi

printf '\n  Done. This machine is no longer a benchmark target.\n\n'
