#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Reverses everything setup_benchmark_target.ps1 added to this machine.

.PARAMETER RemoveOpenSSH
    Also uninstall OpenSSH Server. Only use this if the machine didn't have it
    before you ran setup_benchmark_target.ps1.

.EXAMPLE
    .\remove_benchmark_target.ps1
    .\remove_benchmark_target.ps1 -RemoveOpenSSH
#>
param([switch]$RemoveOpenSSH)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PublicKey    = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGuNmaD/FM1AvwzjRDnVdWRKdoZI53vg48mQg7O0ojoj benchmark-ansible'
$ServiceUser  = 'benchmark-ansible'
$FirewallRule = 'SSH - Benchmark Ansible (LAN only)'
$AuthKeysFile = 'C:\ProgramData\ssh\administrators_authorized_keys'

function Write-Done { param([string]$M) Write-Host "  [+] $M" -ForegroundColor Green }
function Write-Skip { param([string]$M) Write-Host "  [-] $M" -ForegroundColor DarkGray }

Write-Host ""
Write-Host "  Removing Benchmark Ansible target configuration..." -ForegroundColor White
Write-Host "  ────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

# ── Firewall rule ─────────────────────────────────────────────────────────────
if (Get-NetFirewallRule -DisplayName $FirewallRule -ErrorAction SilentlyContinue) {
    Remove-NetFirewallRule -DisplayName $FirewallRule
    Write-Done "Firewall rule removed."
} else {
    Write-Skip "Firewall rule not found."
}

# ── SSH public key ────────────────────────────────────────────────────────────
if (Test-Path $AuthKeysFile) {
    $lines    = Get-Content $AuthKeysFile -Encoding UTF8
    $filtered = $lines | Where-Object { $_.Trim() -ne $PublicKey }
    if ($filtered.Count -lt $lines.Count) {
        if ($filtered.Count -eq 0) {
            Remove-Item $AuthKeysFile -Force
            Write-Done "Removed authorized_keys (was the only entry)."
        } else {
            Set-Content $AuthKeysFile -Value $filtered -Encoding UTF8
            Write-Done "Public key removed from authorized_keys."
        }
    } else {
        Write-Skip "Public key not found in authorized_keys."
    }
} else {
    Write-Skip "authorized_keys file not found."
}

# ── Service account ────────────────────────────────────────────────────────────
if (Get-LocalUser -Name $ServiceUser -ErrorAction SilentlyContinue) {
    Remove-LocalUser -Name $ServiceUser
    Write-Done "User '$ServiceUser' removed."
} else {
    Write-Skip "User '$ServiceUser' not found."
}

# ── OpenSSH Server (optional) ─────────────────────────────────────────────────
if ($RemoveOpenSSH) {
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*'
    if ($cap.State -eq 'Installed') {
        Stop-Service sshd -ErrorAction SilentlyContinue
        Remove-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
        Write-Done "OpenSSH Server uninstalled."
    } else {
        Write-Skip "OpenSSH Server was not installed."
    }
} else {
    Write-Skip "OpenSSH Server left in place. Pass -RemoveOpenSSH to uninstall it."
}

Write-Host ""
Write-Host "  Done. This machine is no longer a benchmark target." -ForegroundColor White
Write-Host ""
