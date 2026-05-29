# benchmark-setup

One-command setup to make a local PC an Ansible benchmark target. Works on Windows, CachyOS, and Bazzite.

## Setup

**Windows** — run in PowerShell as Administrator:
```powershell
irm https://raw.githubusercontent.com/treydoesdevops/benchmark-setup/main/setup_benchmark_target.ps1 | iex
```

**Linux (CachyOS / Bazzite)**:
```bash
curl -sL https://raw.githubusercontent.com/treydoesdevops/benchmark-setup/main/setup_benchmark_target.sh | sudo bash
```

The script will:
- Create a dedicated `benchmark-ansible` service account (SSH key auth only, no password login)
- Install and enable OpenSSH Server if not already present
- Open port 22 on the firewall restricted to your LAN subnet only
- Print the inventory line to add to the benchmark playbook

## Removal

**Windows** — run in PowerShell as Administrator:
```powershell
irm https://raw.githubusercontent.com/treydoesdevops/benchmark-setup/main/remove_benchmark_target.ps1 | iex
```

To also uninstall OpenSSH Server (only if it wasn't installed before setup):
```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/treydoesdevops/benchmark-setup/main/remove_benchmark_target.ps1))) -RemoveOpenSSH
```

**Linux**:
```bash
curl -sL https://raw.githubusercontent.com/treydoesdevops/benchmark-setup/main/remove_benchmark_target.sh | sudo bash
```

To also uninstall the SSH server:
```bash
curl -sL https://raw.githubusercontent.com/treydoesdevops/benchmark-setup/main/remove_benchmark_target.sh | sudo bash -s -- --remove-ssh
```

The removal script undoes everything: deletes the service account, removes the SSH key, and removes the firewall rule.
