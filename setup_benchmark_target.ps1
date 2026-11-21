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
$route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Sort-Object -Property RouteMetric |
    Select-Object -First 1
if (-not $route) {
    throw "Could not detect a default route — check network connectivity and re-run."
}

$localIP = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $localIP) {
    throw "Could not determine a local IPv4 address on interface $($route.InterfaceIndex)."
}

$prefLen = [int]$localIP.PrefixLength
$ipBytes = [System.Net.IPAddress]::Parse($localIP.IPAddress).GetAddressBytes()

# Per-octet network calculation via floor division — avoids PowerShell's
# bitwise operators, which threw 'op_bitwiseand' when the 32-bit pack/shift
# chain below hit a non-scalar operand on some hardware.
$netBytes = for ($i = 0; $i -lt 4; $i++) {
    $bits = [Math]::Min(8, [Math]::Max(0, $prefLen - ($i * 8)))
    if ($bits -eq 8) {
        $ipBytes[$i]
    } elseif ($bits -eq 0) {
        0
    } else {
        $blockSize = [Math]::Pow(2, 8 - $bits)
        [byte]([Math]::Floor($ipBytes[$i] / $blockSize) * $blockSize)
    }
}
$LanSubnet = "$($netBytes -join '.')/$prefLen"
Write-Done "LAN subnet: $LanSubnet"

# ── Service account ────────────────────────────────────────────────────────────
Write-Step "Configuring service account '$ServiceUser'..."

if (-not (Get-LocalUser -Name $ServiceUser -ErrorAction SilentlyContinue)) {
    $randBytes = New-Object byte[] 32
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($randBytes)
    $secPw = ConvertTo-SecureString ([Convert]::ToBase64String($randBytes)) -AsPlainText -Force
    $newUserParams = @{
        Name                     = $ServiceUser
        Password                 = $secPw
        PasswordNeverExpires     = $true
        UserMayNotChangePassword = $true
        Description              = 'Benchmark Ansible - SSH key auth only'
    }
    New-LocalUser @newUserParams | Out-Null
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

# Add-WindowsCapability fetches OpenSSH Server as a Feature-on-Demand from
# Windows Update under the hood - on a freshly-set-up PC that call is known to
# hang indefinitely (stale/not-yet-synced WU metadata, a slow first contact
# with the update servers) with no error, no progress, nothing to catch.
# Confirmed for real 2026-11-21: took 4 manual re-runs of this whole script on
# a brand new PC before it went through. Bound each attempt with a timeout
# (background job, same idea as Invoke-Bounded in the benchmark repo's
# run_benchmarks_windows.ps1) and retry automatically instead of making that
# the user's problem to notice and fix by hand every time.
function Install-OpenSshCapability {
    param([int]$TimeoutSec = 90, [int]$MaxAttempts = 5)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Step "Installing OpenSSH Server, attempt $attempt/$MaxAttempts (may take a moment)..."
        $job = Start-Job -ScriptBlock { Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 }
        if (Wait-Job $job -Timeout $TimeoutSec) {
            Receive-Job $job -ErrorAction SilentlyContinue -ErrorVariable jobErr | Out-Null
            Remove-Job $job -Force
            if (-not $jobErr) { return $true }
            Write-Skip "Attempt $attempt failed: $jobErr"
        } else {
            Write-Skip "Attempt $attempt timed out after ${TimeoutSec}s waiting on Windows Update - retrying."
            Stop-Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
        if ($attempt -lt $MaxAttempts) { Start-Sleep -Seconds 5 }
    }
    return $false
}

$cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*'
if ($cap.State -ne 'Installed') {
    if (-not (Install-OpenSshCapability)) {
        throw "Failed to install OpenSSH Server after several attempts - this is a known Windows Update flakiness issue with Add-WindowsCapability, not necessarily this script. Wait a minute and re-run."
    }
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

$fwParams = @{
    DisplayName   = $FirewallRule
    Direction     = 'Inbound'
    Action        = 'Allow'
    Protocol      = 'TCP'
    LocalPort     = 22
    RemoteAddress = $LanSubnet
}
New-NetFirewallRule @fwParams | Out-Null

Write-Done "Port 22 open to $LanSubnet only."

# ── Windows Defender exclusion for benchmark tools ───────────────────────────
# Benchmark worker binaries (e.g. GeekBench's geekbench_avx2.exe, re-extracted
# fresh each run) are unsigned and unrecognised by Defender's reputation
# cache. Confirmed via CPU-time sampling on a real run: GeekBench's worker did
# ~20s of real computation, then flatlined at the exact same CPU-time value
# indefinitely - consistent with Defender's real-time scan holding/locking a
# freshly-launched unsigned executable, a documented Defender behavior.
# Excluding the tools directory from real-time scanning is standard practice
# for any dedicated benchmark/performance-test machine (it also keeps AV scan
# overhead from skewing CPU scores below the hardware's real capability) - not
# a blanket AV change, just this one folder on a non-production test box.
# Keep in sync with benchmark_install_dir in benchmark/defaults/main.yml.
Write-Step "Adding Windows Defender exclusion for benchmark tools..."
$BenchmarkToolsDir = 'C:\benchmark_tools'
if ((Get-MpPreference).ExclusionPath -notcontains $BenchmarkToolsDir) {
    Add-MpPreference -ExclusionPath $BenchmarkToolsDir
    Write-Done "Defender exclusion added for $BenchmarkToolsDir."
} else {
    Write-Skip "Defender exclusion already present for $BenchmarkToolsDir."
}

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
