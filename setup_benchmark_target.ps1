#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Makes a Windows PC an Ansible benchmark target via SSH.

.DESCRIPTION
    Idempotent — safe to re-run. Creates a dedicated service account,
    installs OpenSSH Server, authorises the benchmark SSH key, and opens
    port 22 on the firewall restricted to the local LAN subnet only.

    To remove everything this script added, run remove_benchmark_target.ps1.

.EXAMPLE
    .\setup_benchmark_target.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$PublicKey       = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGuNmaD/FM1AvwzjRDnVdWRKdoZI53vg48mQg7O0ojoj benchmark-ansible'
$ServiceUser     = 'benchmark-ansible'
$FirewallRule    = 'SSH - Benchmark Ansible (LAN only)'
$AuthKeysFile    = 'C:\ProgramData\ssh\administrators_authorized_keys'

function Write-Step { param([string]$M) Write-Host "  $M"    -ForegroundColor Cyan  }
function Write-Done { param([string]$M) Write-Host "  [+] $M" -ForegroundColor Green }
function Write-Skip { param([string]$M) Write-Host "  [-] $M" -ForegroundColor DarkGray }

Write-Host ""
Write-Host "  Benchmark Ansible Target Setup" -ForegroundColor White
Write-Host "  ────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

# ── Detect LAN subnet ─────────────────────────────────────────────────────────
Write-Step "Detecting LAN subnet..."
$route    = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1
$localIP  = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 | Select-Object -First 1
$prefLen  = $localIP.PrefixLength
$ipBytes  = [System.Net.IPAddress]::Parse($localIP.IPAddress).GetAddressBytes()
$mask     = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $prefLen))
$ipInt    = [uint32](($ipBytes[0] -shl 24) -bor ($ipBytes[1] -shl 16) -bor ($ipBytes[2] -shl 8) -bor $ipBytes[3])
$netInt   = $ipInt -band $mask
$netBytes = [byte[]]@(($netInt -shr 24) -band 0xFF, ($netInt -shr 16) -band 0xFF, ($netInt -shr 8) -band 0xFF, $netInt -band 0xFF)
$LanSubnet = "$($netBytes -join '.')/$prefLen"
Write-Done "LAN subnet: $LanSubnet"

# ── Service account ────────────────────────────────────────────────────────────
Write-Step "Configuring service account '$ServiceUser'..."

if (-not (Get-LocalUser -Name $ServiceUser -ErrorAction SilentlyContinue)) {
    $randBytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($randBytes)
    $secPw = ConvertTo-SecureString ([Convert]::ToBase64String($randBytes)) -AsPlainText -Force
    New-LocalUser `
        -Name                     $ServiceUser `
        -Password                 $secPw `
        -PasswordNeverExpires      $true `
        -UserMayNotChangePassword  $true `
        -Description              'Benchmark Ansible — SSH key auth only' | Out-Null
    Write-Done "User '$ServiceUser' created (random password — key auth only)."
} else {
    Write-Skip "User '$ServiceUser' already exists."
}

$inAdmins = (Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue) |
    Where-Object { $_.Name -match "\\$ServiceUser$" }
if (-not $inAdmins) {
    Add-LocalGroupMember -Group 'Administrators' -Member $ServiceUser
    Write-Done "Added '$ServiceUser' to Administrators."
} else {
    Write-Skip "'$ServiceUser' already in Administrators."
}

# ── OpenSSH Server ────────────────────────────────────────────────────────────
Write-Step "Checking OpenSSH Server..."

$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*'
if ($cap.State -ne 'Installed') {
    Write-Step "Installing OpenSSH Server (may take a moment)..."
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 | Out-Null
    Write-Done "OpenSSH Server installed."
} else {
    Write-Skip "OpenSSH Server already installed."
}

Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
Write-Done "sshd running (auto-start enabled)."

# PowerShell as the default SSH shell
$regPath = 'HKLM:\SOFTWARE\OpenSSH'
if (-not (Test-Path $regPath)) { New-Item $regPath | Out-Null }
Set-ItemProperty $regPath -Name DefaultShell -Value (Get-Command powershell.exe).Source
Write-Done "Default SSH shell: PowerShell."

# ── Authorized key ────────────────────────────────────────────────────────────
Write-Step "Installing SSH public key..."

New-Item -ItemType Directory -Force -Path (Split-Path $AuthKeysFile) | Out-Null

$keyPresent = (Test-Path $AuthKeysFile) -and
    (Select-String -Path $AuthKeysFile -Pattern ([regex]::Escape($PublicKey)) -Quiet)

if (-not $keyPresent) {
    # Use no-BOM UTF-8 — PowerShell 5's Add-Content -Encoding UTF8 writes a BOM
    # which some OpenSSH builds handle poorly.
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::AppendAllText($AuthKeysFile, "$PublicKey`n", $utf8NoBom)
    Write-Done "Public key added."
} else {
    Write-Skip "Public key already present."
}

# Windows OpenSSH ignores administrators_authorized_keys if it has inherited
# permissions — must be owned by SYSTEM/Administrators with no inheritance.
$acl = Get-Acl $AuthKeysFile
$acl.SetAccessRuleProtection($true, $false)
$acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('SYSTEM',         'FullControl', 'Allow')))
$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule('Administrators', 'FullControl', 'Allow')))
Set-Acl $AuthKeysFile $acl
Write-Done "Permissions set (SYSTEM + Administrators, no inheritance)."

# ── Firewall: port 22 restricted to LAN ──────────────────────────────────────
Write-Step "Configuring firewall..."

if (Get-NetFirewallRule -DisplayName $FirewallRule -ErrorAction SilentlyContinue) {
    Remove-NetFirewallRule -DisplayName $FirewallRule
}

New-NetFirewallRule `
    -DisplayName   $FirewallRule `
    -Direction     Inbound `
    -Action        Allow `
    -Protocol      TCP `
    -LocalPort     22 `
    -RemoteAddress $LanSubnet | Out-Null

Write-Done "Port 22 open to $LanSubnet only."

# ── Restart sshd to pick up all changes ──────────────────────────────────────
Restart-Service sshd
Write-Done "sshd restarted."

# ── Summary ───────────────────────────────────────────────────────────────────
$ip = $localIP.IPAddress
Write-Host ""
Write-Host "  ────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  Done. Add to benchmark/ansible/inventory.ini:" -ForegroundColor White
Write-Host ""
Write-Host "  [benchmark_windows]" -ForegroundColor DarkGray
Write-Host "  $($env:COMPUTERNAME.ToLower())   ansible_host=$ip" -ForegroundColor Yellow
Write-Host ""
Write-Host "  To remove:  .\remove_benchmark_target.ps1" -ForegroundColor DarkGray
Write-Host ""
