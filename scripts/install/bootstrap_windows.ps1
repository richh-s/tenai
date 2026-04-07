# scripts/install/bootstrap_windows.ps1 — Windows bootstrap for tenai-infra
# Idempotent: safe to re-run. Run as Administrator for OpenSSH Server install.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts/install/bootstrap_windows.ps1

param(
    [switch]$SkipSSH,
    [switch]$SkipTailscale,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "── $msg ──" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "✓ $msg" -ForegroundColor Green }
function Write-Skip($msg) { Write-Host "⊘ $msg (skipped)" -ForegroundColor Yellow }

# ── Check admin privileges ────────────────────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warning "Some features require Administrator privileges (OpenSSH Server, sshd service)."
    Write-Warning "Re-run with: Start-Process powershell -Verb RunAs -ArgumentList '-File $PSCommandPath'"
}

# ── Install winget packages ──────────────────────────────────────────────────
Write-Step "Checking winget packages"

$packages = @(
    @{ Name = "Git";       Id = "Git.Git";           Cmd = "git" },
    @{ Name = "Python";    Id = "Python.Python.3.12"; Cmd = "python" },
    @{ Name = "Node.js";   Id = "OpenJS.NodeJS.LTS";  Cmd = "node" },
    @{ Name = "curl";      Id = "cURL.cURL";          Cmd = "curl" },
    @{ Name = "jq";        Id = "jqlang.jq";          Cmd = "jq" }
)

foreach ($pkg in $packages) {
    if (Get-Command $pkg.Cmd -ErrorAction SilentlyContinue) {
        Write-OK "$($pkg.Name) already installed"
    } else {
        if ($DryRun) {
            Write-Host "  [DRY-RUN] Would install: $($pkg.Id)" -ForegroundColor Magenta
        } else {
            Write-Host "  → Installing $($pkg.Name)..."
            winget install --id $pkg.Id --accept-source-agreements --accept-package-agreements -e
        }
    }
}

# ── Tailscale ────────────────────────────────────────────────────────────────
if ($SkipTailscale) {
    Write-Skip "Tailscale"
} else {
    Write-Step "Checking Tailscale"
    if (Get-Command tailscale -ErrorAction SilentlyContinue) {
        Write-OK "Tailscale already installed"
    } elseif (Test-Path "C:\Program Files\Tailscale\tailscale.exe") {
        Write-OK "Tailscale found at Program Files"
    } else {
        if ($DryRun) {
            Write-Host "  [DRY-RUN] Would install Tailscale" -ForegroundColor Magenta
        } else {
            Write-Host "  → Installing Tailscale..."
            winget install --id Tailscale.Tailscale --accept-source-agreements --accept-package-agreements -e
        }
    }
}

# ── OpenSSH Server ───────────────────────────────────────────────────────────
if ($SkipSSH) {
    Write-Skip "OpenSSH Server"
} else {
    Write-Step "Checking OpenSSH Server"
    $sshCapability = Get-WindowsCapability -Online -Name "OpenSSH.Server*" -ErrorAction SilentlyContinue

    if ($sshCapability -and $sshCapability.State -eq "Installed") {
        Write-OK "OpenSSH Server already installed"
    } else {
        if (-not $isAdmin) {
            Write-Warning "OpenSSH Server requires Administrator. Skipping."
        } elseif ($DryRun) {
            Write-Host "  [DRY-RUN] Would install OpenSSH Server" -ForegroundColor Magenta
        } else {
            Write-Host "  → Installing OpenSSH Server..."
            Add-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0"
            Write-OK "OpenSSH Server installed"
        }
    }

    # Configure and start sshd service
    if ($isAdmin -and -not $DryRun) {
        $svc = Get-Service sshd -ErrorAction SilentlyContinue
        if ($svc) {
            if ($svc.Status -ne "Running") {
                Start-Service sshd
                Write-OK "sshd service started"
            }
            Set-Service -Name sshd -StartupType Automatic
            Write-OK "sshd set to auto-start"
        }
    }
}

# ── SSH key generation ───────────────────────────────────────────────────────
Write-Step "Checking SSH key"
$sshKeyPath = "$env:USERPROFILE\.ssh\id_ed25519"

if (Test-Path $sshKeyPath) {
    Write-OK "SSH key exists: $sshKeyPath"
} else {
    if ($DryRun) {
        Write-Host "  [DRY-RUN] Would generate SSH key" -ForegroundColor Magenta
    } else {
        Write-Host "  → Generating SSH key..."
        $sshDir = "$env:USERPROFILE\.ssh"
        if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir | Out-Null }
        ssh-keygen -t ed25519 -C "tenai-infra-$env:COMPUTERNAME" -f $sshKeyPath -N '""'
        Write-OK "SSH key generated: $sshKeyPath"
        Write-Host "  Public key:"
        Get-Content "$sshKeyPath.pub"
    }
}

# ── AI CLI tools (npm-based) ─────────────────────────────────────────────────
Write-Step "Checking AI CLI tools"

$npmTools = @(
    @{ Name = "Claude Code"; Pkg = "@anthropic-ai/claude-code"; Cmd = "claude" },
    @{ Name = "Gemini CLI";  Pkg = "@google/gemini-cli";        Cmd = "gemini" },
    @{ Name = "Codex CLI";   Pkg = "@openai/codex";             Cmd = "codex" }
)

if (Get-Command npm -ErrorAction SilentlyContinue) {
    foreach ($tool in $npmTools) {
        if (Get-Command $tool.Cmd -ErrorAction SilentlyContinue) {
            Write-OK "$($tool.Name) already installed"
        } else {
            if ($DryRun) {
                Write-Host "  [DRY-RUN] Would install $($tool.Name)" -ForegroundColor Magenta
            } else {
                Write-Host "  → Installing $($tool.Name)..."
                npm install -g $tool.Pkg 2>$null
            }
        }
    }
} else {
    Write-Warning "npm not found — skipping AI CLI tools. Install Node.js first."
}

# ── Summary ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Step "Bootstrap complete"
Write-Host "  Next steps:"
Write-Host "    1. Ensure Tailscale is connected to your tailnet"
Write-Host "    2. Add this device to config/defaults.yaml with its Tailscale IP"
Write-Host "    3. Run 'make configure-aliases' on your other devices"
Write-Host ""
if ($DryRun) {
    Write-Host "  [DRY-RUN mode — no changes were made]" -ForegroundColor Magenta
}
