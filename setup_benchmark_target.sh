#!/usr/bin/env bash
# Run as root (or via sudo) on the Linux target.
# Idempotent — safe to re-run.
# Tested on: CachyOS (Arch-based), Bazzite (Fedora/rpm-ostree-based).
set -euo pipefail

PUBLIC_KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGuNmaD/FM1AvwzjRDnVdWRKdoZI53vg48mQg7O0ojoj benchmark-ansible'
SERVICE_USER='benchmark-ansible'
FIREWALL_RULE_NAME='benchmark-ansible-ssh'

if [[ $EUID -ne 0 ]]; then
    echo "Run as root:  sudo $0" >&2
    exit 1
fi

step() { printf '\n  \033[36m%s\033[0m\n' "$*"; }
done_() { printf '  \033[32m[+]\033[0m %s\n' "$*"; }
skip() { printf '  \033[90m[-]\033[0m %s\n' "$*"; }

printf '\n  \033[1mBenchmark Ansible Target Setup\033[0m\n'
printf '  ────────────────────────────────────\n'

# ── Detect LAN subnet ─────────────────────────────────────────────────────────
step "Detecting LAN subnet..."
IFACE=$(ip route get 8.8.8.8 2>/dev/null | awk 'NR==1 { for(i=1;i<=NF;i++) if($i=="dev") { print $(i+1); exit } }')
if [[ -z "$IFACE" ]]; then
    echo "  [!] Could not detect default network interface — firewall rule will be skipped." >&2
    LAN_SUBNET=''
else
    IP_PREFIX=$(ip -4 addr show dev "$IFACE" | awk '/inet / { print $2; exit }')
    LAN_SUBNET=$(python3 -c \
        "import ipaddress; print(str(ipaddress.ip_interface('$IP_PREFIX').network))" 2>/dev/null || true)
fi

if [[ -n "$LAN_SUBNET" ]]; then
    done_ "LAN subnet: $LAN_SUBNET"
else
    echo "  [!] Could not determine LAN subnet — firewall rule will be skipped."
fi

# ── Service account ────────────────────────────────────────────────────────────
step "Configuring service account '$SERVICE_USER'..."

if ! id "$SERVICE_USER" &>/dev/null; then
    useradd --create-home --shell /bin/bash \
        --comment 'Benchmark Ansible — SSH key auth only' "$SERVICE_USER"
    done_ "User '$SERVICE_USER' created."
else
    skip "User '$SERVICE_USER' already exists."
fi

# Lock the password — SSH key auth only, no password login
passwd --lock "$SERVICE_USER" &>/dev/null
done_ "Password login disabled (key-only)."

# ── SSH authorized key ─────────────────────────────────────────────────────────
step "Installing SSH public key..."

SSH_DIR="/home/$SERVICE_USER/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

install -d -m 700 -o "$SERVICE_USER" -g "$SERVICE_USER" "$SSH_DIR"

if [[ -f "$AUTH_KEYS" ]] && grep -qF "$PUBLIC_KEY" "$AUTH_KEYS"; then
    skip "Public key already present."
else
    printf '%s\n' "$PUBLIC_KEY" >> "$AUTH_KEYS"
    done_ "Public key added."
fi

chmod 600 "$AUTH_KEYS"
chown "$SERVICE_USER:$SERVICE_USER" "$AUTH_KEYS"
done_ "Permissions set (700/600)."

# ── SSH service ────────────────────────────────────────────────────────────────
step "Checking SSH service..."

if ! systemctl is-active --quiet sshd 2>/dev/null && ! systemctl is-active --quiet ssh 2>/dev/null; then
    # Try both common service names
    if systemctl enable --now sshd 2>/dev/null; then
        done_ "sshd enabled and started."
    elif systemctl enable --now ssh 2>/dev/null; then
        done_ "ssh enabled and started."
    else
        echo "  [!] Could not start SSH service — install openssh manually." >&2
    fi
else
    skip "SSH service already running."
fi

# ── Firewall ───────────────────────────────────────────────────────────────────
step "Configuring firewall..."

if [[ -z "$LAN_SUBNET" ]]; then
    skip "No LAN subnet detected — skipping firewall rule."
elif systemctl is-active --quiet firewalld 2>/dev/null; then
    # firewalld (Bazzite, Fedora, and some CachyOS setups)
    #
    # If the zone already has the unrestricted 'ssh' service open (common on
    # Bazzite/Fedora), our LAN-restricted rich rule would be redundant — the
    # broader service rule would still allow anyone in. Remove it first.
    if firewall-cmd --quiet --query-service=ssh 2>/dev/null; then
        firewall-cmd --quiet --permanent --remove-service=ssh
        done_ "Removed unrestricted SSH service from active zone."
    fi
    # Remove any previous LAN rule we added, then add a fresh one
    firewall-cmd --quiet --permanent \
        --remove-rich-rule="rule family=ipv4 source address=\"$LAN_SUBNET\" service name=\"ssh\" accept" \
        2>/dev/null || true
    firewall-cmd --quiet --permanent \
        --add-rich-rule="rule family=ipv4 source address=\"$LAN_SUBNET\" service name=\"ssh\" accept"
    firewall-cmd --quiet --reload
    done_ "firewalld: SSH open to $LAN_SUBNET only."
elif command -v nft &>/dev/null && nft list tables 2>/dev/null | grep -q .; then
    # nftables present and has tables — add a rule to the input chain
    TABLE='filter'
    CHAIN='INPUT'
    COMMENT="$FIREWALL_RULE_NAME"
    # Remove existing rule with our comment if present
    nft list ruleset 2>/dev/null | grep -q "$COMMENT" && \
        nft delete rule inet "$TABLE" "$CHAIN" handle \
            "$(nft -a list chain inet "$TABLE" "$CHAIN" 2>/dev/null | awk "/$COMMENT/ { print \$NF }")" \
            2>/dev/null || true
    nft add rule inet "$TABLE" "$CHAIN" \
        ip saddr "$LAN_SUBNET" tcp dport 22 accept comment "\"$COMMENT\""
    done_ "nftables: SSH open to $LAN_SUBNET only."
    echo "  [!] nftables rules are not persistent — add to your nftables config file to survive reboots."
else
    skip "No active firewall detected — SSH is unrestricted. Consider enabling firewalld."
fi

# ── Summary ────────────────────────────────────────────────────────────────────
LOCAL_IP=$(ip -4 addr show dev "$IFACE" 2>/dev/null | awk '/inet / { sub(/\/.*/, "", $2); print $2; exit }')
HOSTNAME_SHORT=$(hostname -s)

printf '\n  ────────────────────────────────────\n'
printf '  \033[1mDone.\033[0m Add to benchmark/ansible/inventory.ini:\n\n'
printf '  \033[90m[benchmark_linux]\033[0m\n'
printf '  \033[33m%s   ansible_host=%s\033[0m\n' "$HOSTNAME_SHORT" "$LOCAL_IP"
printf '\n  To remove:  sudo bash remove_benchmark_target.sh\n\n'
