# ===========================================================
# Servy Full-Stack Deployment Manager
# Interactive CLI menu: install / update / rollback / uninstall / start / stop /
# status-check components, change install path, check prereqs.
#
# Usage:
#   .\deploy.ps1                          # Interactive menu
#   .\deploy.ps1 -Force                   # Non-interactive full deploy
#   .\deploy.ps1 -Force -Components frontend,backend  # Non-interactive, selective
#   .\deploy.ps1 -DryRun                  # Preview only, no changes
#   .\deploy.ps1 -DryRun -Components frontend,caddy   # Preview specific components
#
# Files created next to this script:
#   deploy.config.json          - non-secret settings (install path, ports, repos)
#   deploy.secrets.json         - DB credentials (auto-added to .gitignore)
#   deploy.secrets.example.json - template with placeholder values
# Runtime deployment state:
#   <InstallRoot>\deployment-state.json - last two known-good deployment versions
# Runtime folders created by default:
#   <drive>:\ESS\Ess_Face              - app services and runtime
#   <drive>:\ESS\storage\face-images   - persistent face profile images
# ===========================================================

# BUILD: ESS-FACE-PS51-ASCII-20260923-01
#Requires -Version 5.1
#Requires -RunAsAdministrator

param(
    [switch]$DryRun,
    [switch]$Force,
    [ValidateSet("frontend", "backend", "caddy")]
    [string[]]$Components = @()
)

$ErrorActionPreference = "Continue"

# ===========================================================
# EXECUTION POLICY - auto-bypass if policy blocks unsigned scripts
# This lets users run .\deploy.ps1 without manually setting
# Set-ExecutionPolicy or using the -ExecutionPolicy flag.
# ===========================================================
# Get-ExecutionPolicy (no scope) returns the *effective* policy for this session.
# If run via -ExecutionPolicy Bypass it returns Bypass, so we won't loop infinitely.
$effectivePolicy = Get-ExecutionPolicy -ErrorAction SilentlyContinue
if ($effectivePolicy -in @('Restricted', 'AllSigned')) {
    Write-Host "    [!] Windows restricts running unsigned scripts here." -ForegroundColor Yellow
    Write-Host "    [!] Automatically re-launching with -ExecutionPolicy Bypass ..." -ForegroundColor Yellow
    $self = $MyInvocation.MyCommand.Path
    $bypassArgs = @("-ExecutionPolicy", "Bypass", "-File", $self) + $args
    & powershell.exe $bypassArgs
    exit $LASTEXITCODE
}

# ---------- PATHS ----------
$ScriptRoot   = $PSScriptRoot
$ConfigPath   = Join-Path $ScriptRoot "deploy.config.json"
$SecretsPath  = Join-Path $ScriptRoot "deploy.secrets.json"
$SecretsExamplePath = Join-Path $ScriptRoot "deploy.secrets.example.json"

# ---------- DEFAULT CONFIG ----------
$DefaultConfig = @{
    Environment = "production"
    FrontendRepo = "https://github.com/Posuza/ESS-Face-Frontend.git"
    FrontendBranch = "main"
    BackendRepo  = "https://github.com/Posuza/ESS-Face-Backend.git"
    BackendBranch = "main"
    FrontendPort = 3110
    BackendPort  = 8110
    CaddyPort    = 9110
    CaddyAdminPort = 2110
    ApiPrefix    = "/api/v1"
    FrontendPublicUrl = $null
    MediaStoragePath = "E:\\ESS\\storage\\face-images"
    InstallRoot  = "C:\\ESS\\Ess_Face"
}

# ---------- GLOBAL STATE ----------
$script:installedComponents = @()   # Track for rollback
$script:startTime = $null
$script:logFile = $null
$script:dryRun = $DryRun
$script:hasErrors = $false
$script:headless = $Force -or ($Components.Count -gt 0)
$script:deploymentTransaction = $false
$script:deploymentCandidates = @{}
$script:deploymentStateBeforeRun = $null
$script:liveComponentsChanged = @()
$script:deploymentConfigChanged = $false

# ===========================================================
# ENVIRONMENT-SPECIFIC NAMES
# ===========================================================
function Get-DeployEnvironment {
    param($Config)
    return ("$($Config.Environment)").Trim().ToLowerInvariant()
}

function Get-InstallFolderName {
    param($Config)
    if ((Get-DeployEnvironment -Config $Config) -eq "development") {
        return "Ess_Face_dev"
    }
    return "Ess_Face"
}

function Get-ServicePrefix {
    param($Config)
    if ((Get-DeployEnvironment -Config $Config) -eq "development") {
        return "ess-face-dev"
    }
    return "ess-face"
}

function Get-DeployServiceName {
    param($Config, [Parameter(Mandatory=$true)][string]$Component)
    return "$(Get-ServicePrefix -Config $Config)-$Component"
}

# ===========================================================
# LOGGING
# ===========================================================
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    if ($script:logFile) {
        Add-Content -Path $script:logFile -Value $line -ErrorAction SilentlyContinue
    }
}

function Write-FileLog {
    param([string]$Path, [string]$Text)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$ts] $Text" | Out-File -FilePath $Path -Append -Encoding utf8
}

filter Add-FileLog {
    param([string]$Path)
    # Display command output without returning it to the caller's success stream.
    # Installer functions must return only their final $true/$false result.
    Write-Host "$_"
    if ($null -ne $_ -and "$_" -ne '') {
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "[$ts] $_" | Out-File -FilePath $Path -Append -Encoding utf8
    }
}

function Initialize-Logger {
    param($Config)
    $logsDir = Join-Path $Config.InstallRoot "logs"
    if (-not (Test-Path $logsDir)) {
        New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
    }
    $script:startTime = Get-Date
    $timestamp = $script:startTime.ToString("yyyyMMdd-HHmmss")
    $script:logFile = Join-Path $logsDir "deploy-$timestamp.log"
    Write-Log "=== Deployment started ===" -Level "START"
    Write-Log "Script: $PSCommandPath" -Level "INFO"
    Write-Log "Environment: $(Get-DeployEnvironment -Config $Config)" -Level "INFO"
    Write-Log "Config: $ConfigPath" -Level "INFO"
    Write-Log "Install root: $($Config.InstallRoot)" -Level "INFO"
    if ($script:dryRun) {
        Write-Log "DRY RUN MODE - no changes will be made" -Level "WARN"
    }
}

# ===========================================================
# OUTPUT HELPERS
# ===========================================================
function Write-Step    ($msg) { Write-Host "`n[*] $msg" -ForegroundColor Yellow; Write-Log "STEP: $msg" }
function Write-Success ($msg) { Write-Host "    $msg"   -ForegroundColor Green;   Write-Log "OK: $msg" }
function Write-Err     ($msg) { Write-Host "    $msg"   -ForegroundColor Red;     Write-Log "ERROR: $msg"; $script:hasErrors = $true }
function Write-Warn    ($msg) { Write-Host "    $msg"   -ForegroundColor DarkYellow; Write-Log "WARN: $msg" }

function Edit-WithDefault {
    param([string]$Default, [string]$Prompt)
    # Writes $Prompt, then $Default as pre-filled editable text.
    # Closing `"` is appended after Enter so the line reads cleanly.
    # Arrows/Home/End supported; Backspace deletes; Enter confirms.
    # Ctrl+V / Shift+Insert paste from clipboard.
    Write-Host -NoNewline $Prompt
    $buf = [System.Collections.Generic.List[char]]($Default.ToCharArray())
    Write-Host -NoNewline ($buf -join '')
    $pos = $buf.Count
    $plen = $Prompt.Length
    while ($true) {
        $ki = [System.Console]::ReadKey($true)
        switch ($ki.Key) {
            Enter   { break }
            BackSpace {
                if ($pos -gt 0) {
                    $pos--; $buf.RemoveAt($pos)
                    [System.Console]::CursorLeft = $plen
                    Write-Host -NoNewline (($buf -join '') + ' ')
                    [System.Console]::CursorLeft = $plen + $pos
                }
            }
            LeftArrow  { if ($pos -gt 0) { $pos--; [Console]::CursorLeft = $plen + $pos } }
            RightArrow { if ($pos -lt $buf.Count) { $pos++; [Console]::CursorLeft = $plen + $pos } }
            Home       { $pos = 0; [Console]::CursorLeft = $plen }
            End        { $pos = $buf.Count; [Console]::CursorLeft = $plen + $pos }
            Delete {
                if ($pos -lt $buf.Count) {
                    $buf.RemoveAt($pos)
                    [System.Console]::CursorLeft = $plen
                    Write-Host -NoNewline (($buf -join '') + ' ')
                    [System.Console]::CursorLeft = $plen + $pos
                }
            }
            default {
                # --- Paste: Ctrl+V or Shift+Insert ---
                if (($ki.Modifiers -band [System.ConsoleModifiers]::Control) -and $ki.Key -eq [System.ConsoleKey]::V) {
                    $pasteText = Get-Clipboard -ErrorAction SilentlyContinue
                    if ($pasteText) {
                        # Strip newlines (single-line field)
                        $pasteText = $pasteText -replace "`r`n", '' -replace "`n", '' -replace "`r", ''
                        foreach ($ch in $pasteText.ToCharArray()) {
                            if ($ch -ge 32) {
                                $buf.Insert($pos, $ch)
                                $pos++
                            }
                        }
                        [System.Console]::CursorLeft = $plen
                        Write-Host -NoNewline (($buf -join '') + ' ')
                        [System.Console]::CursorLeft = $plen + $pos
                    }
                    break
                }
                if (($ki.Modifiers -band [System.ConsoleModifiers]::Shift) -and $ki.Key -eq [System.ConsoleKey]::Insert) {
                    $pasteText = Get-Clipboard -ErrorAction SilentlyContinue
                    if ($pasteText) {
                        $pasteText = $pasteText -replace "`r`n", '' -replace "`n", '' -replace "`r", ''
                        foreach ($ch in $pasteText.ToCharArray()) {
                            if ($ch -ge 32) {
                                $buf.Insert($pos, $ch)
                                $pos++
                            }
                        }
                        [System.Console]::CursorLeft = $plen
                        Write-Host -NoNewline (($buf -join '') + ' ')
                        [System.Console]::CursorLeft = $plen + $pos
                    }
                    break
                }
                # --- Normal character input ---
                if ($ki.KeyChar -ge 32) {
                    $buf.Insert($pos, $ki.KeyChar)
                    $pos++
                    Write-Host -NoNewline $ki.KeyChar
                }
            }
        }
    }
    Write-Host '"'
    if ($buf.Count -eq 0) { return $Default }
    return ($buf -join '')
}

# ===========================================================
# SPINNER - rotating stick animation during long operations
# ===========================================================
function Start-Spinner {
    param([string]$Message)
    if ($script:headless -or $script:dryRun) { return }

    # Use a runspace so the spinner runs in a separate thread
    $script:spinnerPS = [PowerShell]::Create()
    $null = $script:spinnerPS.AddScript({
        param($msg)
        $chars = @('|', '/', '-', '\')
        $i = 0
        try {
            while ($true) {
                [System.Console]::Write("`r $($chars[$i % 4]) $msg ")
                Start-Sleep -Milliseconds 200
                $i++
            }
        } catch {
            # Expected when the spinner is stopped
        }
    }).AddArgument($Message)

    $script:spinnerAsync = $script:spinnerPS.BeginInvoke()
}

function Stop-Spinner {
    if ($null -eq $script:spinnerPS) { return }
    try {
        $script:spinnerPS.Stop()
        Start-Sleep -Milliseconds 150  # Let the thread settle
        $script:spinnerPS.Dispose()
    } catch {}
    # Clear the spinner line
    [System.Console]::Write("`r" + " " * 70 + "`r")
    $script:spinnerPS = $null
    $script:spinnerAsync = $null
}

# Y/n confirmation prompt. Pressing Enter alone accepts the default.
function Confirm-Step {
    param([string]$Message, [bool]$DefaultYes = $true)
    if ($script:headless) { return $DefaultYes }
    $suffix = if ($DefaultYes) { "(Y/n)" } else { "(y/N)" }
    $resp = Read-Host "$Message $suffix"
    if ([string]::IsNullOrWhiteSpace($resp)) { return $DefaultYes }
    return $resp -match '^[Yy]'
}

# ===========================================================
# CONFIG (non-secret settings)
# ===========================================================
function Get-DeployConfig {
    if (Test-Path $ConfigPath) {
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        # Ensure all fields exist (may be missing from older config files)
        @(
            'Environment',
            'InstallRoot',
            'FrontendBranch',
            'BackendBranch',
            'CaddyPort',
            'CaddyAdminPort',
            'FrontendPort',
            'BackendPort',
            'FrontendPublicUrl',
            'MediaStoragePath'
        ) | ForEach-Object {
            if (-not ($cfg | Get-Member -Name $_ -ErrorAction SilentlyContinue)) {
                Add-Member -InputObject $cfg -NotePropertyName $_ -NotePropertyValue $DefaultConfig[$_]
            }
        }
        $cfg.Environment = Get-DeployEnvironment -Config $cfg
        if ($cfg.Environment -notin @('production', 'development')) {
            throw "Invalid Environment '$($cfg.Environment)'. Use 'production' or 'development'."
        }
        return $cfg
    }
    Write-Warn "Config file not found, creating default at $ConfigPath"
    $cfg = [PSCustomObject]$DefaultConfig
    $cfg | ConvertTo-Json | Set-Content $ConfigPath
    return $cfg
}

function Save-DeployConfig {
    param($Config)
    $Config | ConvertTo-Json -Depth 5 | Set-Content $ConfigPath
    Write-Log "Config saved to $ConfigPath"
}

function Select-InstallDrive {
    param($Config)

    $installFolder = Get-InstallFolderName -Config $Config

    # Collect all available drives (any letter that physically exists)
    $availDrives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^[A-Z]$' -and (Test-Path "$($_.Name):\") } |
        ForEach-Object { $_.Name.ToUpper() } |
        Sort-Object

    if ($availDrives.Count -eq 0) {
        Write-Err "No valid drive found. Cannot proceed."
        Write-Log "No valid drives detected" -Level "ERROR"
        return $null
    }

    if ($script:headless) {
        # Headless mode: must have InstallRoot set in config
        if ([string]::IsNullOrWhiteSpace($Config.InstallRoot)) {
            Write-Err "InstallRoot not set in deploy.config.json. Run interactively first or set a path."
            Write-Log "InstallRoot missing in headless mode" -Level "ERROR"
            return $null
        }
        $drive = [System.IO.Path]::GetPathRoot($Config.InstallRoot)
        $driveLetter = $drive.TrimEnd('\').TrimEnd(':')
        if ($driveLetter -notin $availDrives) {
            Write-Err "Drive $drive does not exist. Available: $($availDrives -join ', ')"
            Write-Log "Configured drive $drive not found among available drives" -Level "ERROR"
            return $null
        }
        $newRoot = "$driveLetter`:\ESS\$installFolder"
        if ($Config.InstallRoot -ne $newRoot) {
            $Config.InstallRoot = $newRoot
            Save-DeployConfig -Config $Config
        }
        return $newRoot
    }

    # Show what's available
    $hasCurrent = -not [string]::IsNullOrWhiteSpace($Config.InstallRoot)
    $currentLetter = if ($hasCurrent) { ([System.IO.Path]::GetPathRoot($Config.InstallRoot).TrimEnd('\')).TrimEnd(':') } else { $availDrives[0] }
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " Install Location" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    if ($hasCurrent) {
        Write-Host " Current: $($Config.InstallRoot)" -ForegroundColor Gray
    }
    Write-Host " Available drives: $($availDrives -join ', ')" -ForegroundColor Gray
    Write-Host ""

    $driveList = $availDrives -join ', or '
    $valid = $false
    do {
        if ($hasCurrent) {
            $prompt = "Select install drive: $driveList (or press Enter for current)"
        } else {
            $prompt = "Select install drive: $driveList"
        }
        $choice = Read-Host $prompt
        if ([string]::IsNullOrWhiteSpace($choice)) {
            if ($hasCurrent) {
                $choice = $currentLetter
            } else {
                Write-Err "Please select a drive."
                continue
            }
        }
        $choice = $choice.ToUpper().TrimEnd('\').TrimEnd(':')

        if ($choice -notin $availDrives) {
            Write-Err "Only available drives: $($availDrives -join ', ')"
            continue
        }

        $valid = $true
    } while (-not $valid)

    $newRoot = "$choice`:\ESS\$installFolder"

    if (-not $hasCurrent -or $newRoot -ne $Config.InstallRoot) {
        $Config.InstallRoot = $newRoot
        Save-DeployConfig -Config $Config
        Write-Success "Install path set to: $newRoot"
        Write-Log "Install path changed to: $newRoot"
    }

    return $Config.InstallRoot
}

function Select-CaddyPort {
    param($Config)

    if ($script:headless) {
        # Headless: use whatever is in config or default
        if (-not $Config.CaddyPort -or $Config.CaddyPort -eq 0) {
            $Config.CaddyPort = 9110
        }
        return $Config.CaddyPort
    }

    $hasCurrent = ($Config.CaddyPort -and $Config.CaddyPort -ne 0)

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " Caddy Proxy Port" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " Caddy is the reverse proxy that exposes the app to the network." -ForegroundColor Gray
    if ($hasCurrent) {
        Write-Host " Current: $($Config.CaddyPort)" -ForegroundColor Gray
    }
    Write-Host ""

    if ($hasCurrent) {
        $confirm = Read-Host "Change port? (y/N)"
        if ($confirm -notmatch '^[Yy]') {
            Write-Success "Caddy port kept at $($Config.CaddyPort)"
            return $Config.CaddyPort
        }
    }

    $defaultPort = if ($hasCurrent) { $Config.CaddyPort } else { 9110 }
    $valid = $false
    do {
        $prompt = "Enter new Caddy port [$defaultPort]"
        $choice = Read-Host $prompt
        if ([string]::IsNullOrWhiteSpace($choice)) {
            $choice = $defaultPort
        }

        # Validate it's a number between 1 and 65535
        if (-not ($choice -match '^\d+$') -or [int]$choice -lt 1 -or [int]$choice -gt 65535) {
            Write-Err "Enter a valid port number (1-65535)."
            continue
        }

        $valid = $true
    } while (-not $valid)

    $newPort = [int]$choice

    if ($newPort -ne $Config.CaddyPort) {
        $Config.CaddyPort = $newPort
        Save-DeployConfig -Config $Config
        Write-Success "Caddy port changed to: $newPort"
        Write-Log "Caddy port changed to: $newPort"
    } else {
        Write-Success "Caddy port kept at $($Config.CaddyPort)"
    }

    return $Config.CaddyPort
}

function Initialize-InstallRoot {
    param($Config)
    if ($script:dryRun) { Write-Warn "[DRY-RUN] Would create: $($Config.InstallRoot)"; return }
    New-Item -Path $Config.InstallRoot -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $Config.InstallRoot "logs") -ItemType Directory -Force | Out-Null
    Write-Log "Install root created at $($Config.InstallRoot)"
}

function Test-AppInstallRoot {
    param($Config)
    $installRoot = "$($Config.InstallRoot)"
    if ([string]::IsNullOrWhiteSpace($installRoot)) {
        return $false
    }
    $leaf = Split-Path -Path $installRoot -Leaf
    $parent = Split-Path -Path $installRoot -Parent
    $parentLeaf = Split-Path -Path $parent -Leaf
    return ($leaf -eq (Get-InstallFolderName -Config $Config) -and $parentLeaf -eq "ESS")
}

function Get-EssRootPath {
    param($Config)
    $installRoot = "$($Config.InstallRoot)"
    if ([string]::IsNullOrWhiteSpace($installRoot)) {
        return "C:\ESS"
    }
    return (Split-Path -Path $installRoot -Parent)
}

function Get-MediaStoragePath {
    param($Config)
    $configuredPath = $null
    if ($Config | Get-Member -Name "MediaStoragePath" -ErrorAction SilentlyContinue) {
        $configuredPath = "$($Config.MediaStoragePath)"
    }
    if ([string]::IsNullOrWhiteSpace($configuredPath)) {
        return (Join-Path (Join-Path (Get-EssRootPath -Config $Config) "storage") "face-images")
    }
    $expandedPath = [Environment]::ExpandEnvironmentVariables($configuredPath.Trim())
    if ($expandedPath -match '^/') {
        throw "MediaStoragePath '$configuredPath' looks like a macOS/Linux path. Use a Windows path like C:\ESS\storage\face-images, or a relative path from the ESS root."
    }
    if ([System.IO.Path]::IsPathRooted($expandedPath)) {
        return $expandedPath
    }
    return (Join-Path (Get-EssRootPath -Config $Config) $expandedPath)
}

function Convert-ToEnvPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    return ($Path -replace '\\', '/')
}

function Get-FaceImagesDirectory {
    param([Parameter(Mandatory=$true)][string]$MediaRoot)
    return $MediaRoot
}

function Get-FrontendPublicUrl {
    param($Config)
    if ($Config | Get-Member -Name "FrontendPublicUrl" -ErrorAction SilentlyContinue) {
        $configuredUrl = "$($Config.FrontendPublicUrl)"
        if (-not [string]::IsNullOrWhiteSpace($configuredUrl)) {
            return $configuredUrl.Trim().TrimEnd('/')
        }
    }
    return "http://localhost:$($Config.CaddyPort)"
}

function Initialize-MediaStorage {
    param($Config)
    $mediaRoot = Get-MediaStoragePath -Config $Config
    $facesDir = Get-FaceImagesDirectory -MediaRoot $mediaRoot
    if ($script:dryRun) {
        Write-Warn "[DRY-RUN] Would create media storage: $facesDir"
        return $mediaRoot
    }
    New-Item -Path $facesDir -ItemType Directory -Force | Out-Null
    $probeFile = Join-Path $facesDir ".deploy-write-test"
    try {
        "ok" | Set-Content -Path $probeFile -Encoding ASCII -Force -ErrorAction Stop
        Remove-Item -Path $probeFile -Force -ErrorAction SilentlyContinue
    } catch {
        throw "Media storage is not writable: $facesDir. Check folder permissions or choose another MediaStoragePath. $_"
    }
    Write-Log "Media storage ready and writable: $mediaRoot (face images: $facesDir)"
    return $mediaRoot
}



# ===========================================================
# COMPONENT CONFIG FINGERPRINTS
# Used so config/secrets changes are applied even when Git HEAD did not change.
# Only SHA-256 hashes are written; DB passwords are never stored in these files.
# ===========================================================
function Get-TextSha256 {
    param([Parameter(Mandatory=$true)][string]$Text)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-FrontendDeploymentFingerprint {
    param($Config)

    $payload = [ordered]@{
        repo         = "$($Config.FrontendRepo)"
        branch       = "$($Config.FrontendBranch)"
        frontendPort = [int]$Config.FrontendPort
        apiPrefix    = "$($Config.ApiPrefix)"
    } | ConvertTo-Json -Compress

    return (Get-TextSha256 -Text $payload)
}

function Get-BackendDeploymentFingerprint {
    param($Config, $Secrets)

    $payload = [ordered]@{
        repo              = "$($Config.BackendRepo)"
        branch            = "$($Config.BackendBranch)"
        backendPort       = [int]$Config.BackendPort
        apiPrefix         = "$($Config.ApiPrefix)"
        frontendPublicUrl = "$(Get-FrontendPublicUrl -Config $Config)"
        mediaStoragePath  = "$(Get-MediaStoragePath -Config $Config)"
        dbHost            = "$($Secrets.db.host)"
        dbPort            = [int]$Secrets.db.port
        dbName            = "$($Secrets.db.name)"
        dbUser            = "$($Secrets.db.user)"
        dbPassword        = "$($Secrets.db.password)"
    } | ConvertTo-Json -Compress

    return (Get-TextSha256 -Text $payload)
}

function Get-SavedComponentFingerprint {
    param($Config, [Parameter(Mandatory=$true)][string]$Component)

    $path = Join-Path (Join-Path $Config.InstallRoot $Component) "deployment-config.sha256"
    if (-not (Test-Path $path)) { return $null }
    return ("$(Get-Content $path -Raw -ErrorAction SilentlyContinue)").Trim()
}

function Save-ComponentFingerprint {
    param(
        $Config,
        [Parameter(Mandatory=$true)][string]$Component,
        [Parameter(Mandatory=$true)][string]$Fingerprint
    )

    if ($script:dryRun) { return }
    $dir = Join-Path $Config.InstallRoot $Component
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
    Set-Content -Path (Join-Path $dir "deployment-config.sha256") -Value $Fingerprint -Encoding ASCII -Force
}

# ===========================================================
# DEPLOYMENT STATE
# One file at <InstallRoot>\deployment-state.json.
# Keeps at most two full deployment versions.
# Each component keeps current + previous known-good Git commit.
# The file is updated ONLY after health verification succeeds.
# ===========================================================
function Get-DeploymentStatePath {
    param($Config)
    return (Join-Path $Config.InstallRoot "deployment-state.json")
}

function New-EmptyDeploymentComponents {
    return [PSCustomObject]@{
        frontend = [PSCustomObject]@{ current = $null; previous = $null }
        backend  = [PSCustomObject]@{ current = $null; previous = $null }
        caddy    = [PSCustomObject]@{ current = $null; previous = $null }
    }
}

function Get-DeploymentState {
    param($Config)
    $path = Get-DeploymentStatePath -Config $Config
    if (-not (Test-Path $path)) { return $null }
    try {
        return Get-Content -Path $path -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        Write-Warn "Could not read deployment state: $path"
        Write-Log "Could not read deployment state $path : $_" -Level "ERROR"
        return $null
    }
}

function Save-DeploymentState {
    param($Config, [Parameter(Mandatory=$true)]$State)
    if ($script:dryRun) { return }
    $path = Get-DeploymentStatePath -Config $Config
    $tmp = "$path.tmp"
    $State | ConvertTo-Json -Depth 10 | Set-Content -Path $tmp -Encoding UTF8 -Force
    Move-Item -Path $tmp -Destination $path -Force
    Write-Log "Deployment state saved: $path"
}

function Get-CurrentDeploymentVersion {
    param($Config)
    $state = Get-DeploymentState -Config $Config
    if (-not $state -or -not $state.deploymentVersions -or @($state.deploymentVersions).Count -eq 0) {
        return $null
    }
    return @($state.deploymentVersions)[0]
}

function Get-DeploymentComponentState {
    param($Config, [Parameter(Mandatory=$true)][string]$Component)
    $version = Get-CurrentDeploymentVersion -Config $Config
    if (-not $version -or -not $version.components) { return $null }
    return $version.components.$Component
}

function Get-DeploymentComponentCurrent {
    param($Config, [Parameter(Mandatory=$true)][string]$Component)
    $componentState = Get-DeploymentComponentState -Config $Config -Component $Component
    if (-not $componentState) { return $null }
    return "$($componentState.current)".Trim()
}

function Test-ComponentInstalled {
    param($Config, [Parameter(Mandatory=$true)][string]$Component)
    $svcName = Get-DeployServiceName -Config $Config -Component $Component
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    $base = Join-Path $Config.InstallRoot $Component

    switch ($Component) {
        "frontend" { return [bool]($svc -and (Test-Path (Join-Path $base "repo\.git"))) }
        "backend"  { return [bool]($svc -and (Test-Path (Join-Path $base "repo\.git"))) }
        "caddy"    { return [bool]($svc -and (Test-Path (Join-Path $base "caddy.exe"))) }
    }
    return $false
}

function Test-AnyComponentInstalled {
    param($Config)
    foreach ($key in @("frontend","backend","caddy")) {
        if (Test-ComponentInstalled -Config $Config -Component $key) { return $true }
    }
    return $false
}

function Test-AllComponentsInstalled {
    param($Config)
    foreach ($key in @("frontend","backend","caddy")) {
        if (-not (Test-ComponentInstalled -Config $Config -Component $key)) { return $false }
    }
    return $true
}

function Test-DeploymentRollbackAvailable {
    param($Config)
    $state = Get-DeploymentState -Config $Config
    if (-not $state -or -not $state.deploymentVersions) { return $false }
    return (@($state.deploymentVersions).Count -ge 2)
}

function Get-NextDeploymentVersionName {
    param($State)
    $max = 0
    if ($State -and $State.deploymentVersions) {
        foreach ($v in @($State.deploymentVersions)) {
            if ("$($v.versionName)" -match '^v(\d+)$') {
                $n = [int]$Matches[1]
                if ($n -gt $max) { $max = $n }
            }
        }
    }
    return "v$($max + 1)"
}

function Copy-ObjectDeep {
    param($Object)
    if ($null -eq $Object) { return $null }
    return ($Object | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
}

function Ensure-DeploymentStateForFirstSuccess {
    param($Config)
    $state = Get-DeploymentState -Config $Config
    if ($state -and $state.deploymentVersions -and @($state.deploymentVersions).Count -gt 0) {
        return $state
    }

    $state = [PSCustomObject]@{
        deploymentVersions = @(
            [PSCustomObject]@{
                versionName = "v1"
                components  = New-EmptyDeploymentComponents
            }
        )
    }
    return $state
}

function Register-SuccessfulComponentDeployment {
    param(
        $Config,
        [Parameter(Mandatory=$true)][string]$Component,
        [Parameter(Mandatory=$true)][string]$Commit
    )

    if ($script:deploymentTransaction) {
        $script:deploymentCandidates[$Component] = $Commit
        Write-Log "Candidate recorded for full deployment: $Component=$Commit"
        return
    }

    $state = Ensure-DeploymentStateForFirstSuccess -Config $Config
    $currentVersion = @($state.deploymentVersions)[0]
    $componentState = $currentVersion.components.$Component

    if (-not $componentState) {
        $componentState = [PSCustomObject]@{ current = $null; previous = $null }
        $currentVersion.components | Add-Member -NotePropertyName $Component -NotePropertyValue $componentState -Force
    }

    $oldCurrent = "$($componentState.current)".Trim()
    if ($oldCurrent -eq $Commit) {
        Write-Log "Deployment state unchanged for $Component; commit already current: $Commit"
        if (-not (Test-Path (Get-DeploymentStatePath -Config $Config))) {
            Save-DeploymentState -Config $Config -State $state
        }
        return
    }

    $componentState.previous = if ([string]::IsNullOrWhiteSpace($oldCurrent)) { $null } else { $oldCurrent }
    $componentState.current = $Commit

    Save-DeploymentState -Config $Config -State $state
    Write-Success "$Component known-good commit: $Commit"
}


function Test-FullDeploymentHasChanges {
    param($Config)

    if ($script:deploymentConfigChanged) {
        return $true
    }

    $state = Get-DeploymentState -Config $Config
    if (-not $state -or -not $state.deploymentVersions -or @($state.deploymentVersions).Count -eq 0) {
        return $true
    }

    $current = @($state.deploymentVersions)[0]
    foreach ($key in @("frontend","backend","caddy")) {
        if (-not $script:deploymentCandidates.ContainsKey($key)) { continue }
        $candidate = "$($script:deploymentCandidates[$key])".Trim()
        $old = "$($current.components.$key.current)".Trim()
        if ($candidate -ne $old) { return $true }
    }

    return $false
}

function Complete-FullDeploymentState {
    param($Config)

    $state = Get-DeploymentState -Config $Config
    $existing = $state -and $state.deploymentVersions -and @($state.deploymentVersions).Count -gt 0

    if (-not $existing) {
        $components = New-EmptyDeploymentComponents
        foreach ($key in @("frontend","backend","caddy")) {
            if ($script:deploymentCandidates.ContainsKey($key)) {
                $components.$key.current = "$($script:deploymentCandidates[$key])"
            }
        }

        $state = [PSCustomObject]@{
            deploymentVersions = @(
                [PSCustomObject]@{
                    versionName = "v1"
                    components = $components
                }
            )
        }

        Save-DeploymentState -Config $Config -State $state
        Write-Success "Deployment version created automatically: v1"
        return
    }

    if (-not (Test-FullDeploymentHasChanges -Config $Config)) {
        Write-Success "All components are already current. No new deployment version created."
        return
    }

    $oldVersion = @($state.deploymentVersions)[0]
    $newVersion = Copy-ObjectDeep -Object $oldVersion
    $newVersion.versionName = Get-NextDeploymentVersionName -State $state

    foreach ($key in @("frontend","backend","caddy")) {
        if (-not $script:deploymentCandidates.ContainsKey($key)) { continue }

        $candidate = "$($script:deploymentCandidates[$key])".Trim()
        $cs = $newVersion.components.$key

        if (-not $cs) {
            $cs = [PSCustomObject]@{ current = $null; previous = $null }
            $newVersion.components | Add-Member -NotePropertyName $key -NotePropertyValue $cs -Force
        }

        $oldCurrent = "$($oldVersion.components.$key.current)".Trim()

        if ($candidate -ne $oldCurrent) {
            $cs.previous = if ([string]::IsNullOrWhiteSpace($oldCurrent)) { $null } else { $oldCurrent }
            $cs.current = $candidate
        }
    }

    # Keep only current + previous full deployment versions.
    $state.deploymentVersions = @($newVersion, $oldVersion)
    Save-DeploymentState -Config $Config -State $state
    Write-Success "Deployment version promoted automatically: $($newVersion.versionName)"
}

function Get-GitHead {
    param([Parameter(Mandatory=$true)][string]$RepoDir)
    if (-not (Test-Path (Join-Path $RepoDir ".git"))) { return $null }
    $head = (& git -C $RepoDir rev-parse HEAD 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace("$head")) { return $null }
    return "$head".Trim()
}

function Ensure-GitCommitAvailable {
    param(
        [Parameter(Mandatory=$true)][string]$RepoDir,
        [Parameter(Mandatory=$true)][string]$Commit
    )
    & git -C $RepoDir cat-file -e "$Commit^{commit}" 2>$null
    if ($LASTEXITCODE -eq 0) { return $true }

    & git -C $RepoDir fetch origin $Commit 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }

    & git -C $RepoDir cat-file -e "$Commit^{commit}" 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Initialize-CaddyLocalGit {
    param($Config)
    $caddyDir = Join-Path $Config.InstallRoot "caddy"
    New-Item -Path $caddyDir -ItemType Directory -Force | Out-Null

    $gitDir = Join-Path $caddyDir ".git"
    if (-not (Test-Path $gitDir)) {
        & git -C $caddyDir init | Out-Null
        & git -C $caddyDir config user.name "ESS Deployment Manager"
        & git -C $caddyDir config user.email "deployment@localhost"
    }

    $ignore = @"
caddy.exe
caddy-ports.json
*.log
"@
    Set-Content -Path (Join-Path $caddyDir ".gitignore") -Value $ignore -Encoding UTF8 -Force
}

function Commit-CaddyLocalVersion {
    param($Config, [string]$Message = "Known-good Caddy configuration")
    $caddyDir = Join-Path $Config.InstallRoot "caddy"
    Initialize-CaddyLocalGit -Config $Config

    & git -C $caddyDir add Caddyfile caddy-run.ps1 .gitignore 2>$null
    & git -C $caddyDir diff --cached --quiet 2>$null
    if ($LASTEXITCODE -ne 0) {
        & git -C $caddyDir commit -m $Message | Out-Null
    }
    return (Get-GitHead -RepoDir $caddyDir)
}

function Get-RollbackRoot {
    param($Config)
    return (Join-Path $Config.InstallRoot "rollback")
}

function Get-RollbackStatePath {
    param($Config, [Parameter(Mandatory=$true)][string]$Key)
    return (Join-Path (Get-RollbackRoot -Config $Config) "${Key}.json")
}

function Save-RollbackState {
    param($Config, [Parameter(Mandatory=$true)][string]$Key, [Parameter(Mandatory=$true)]$State)
    if ($script:dryRun) { return }
    $rollbackRoot = Get-RollbackRoot -Config $Config
    New-Item -Path $rollbackRoot -ItemType Directory -Force | Out-Null
    $State | ConvertTo-Json -Depth 6 | Set-Content -Path (Get-RollbackStatePath -Config $Config -Key $Key) -Force -Encoding UTF8
}

function Get-RollbackState {
    param($Config, [Parameter(Mandatory=$true)][string]$Key)
    $path = Get-RollbackStatePath -Config $Config -Key $Key
    if (-not (Test-Path $path)) { return $null }
    try {
        return Get-Content $path -Raw -ErrorAction Stop | ConvertFrom-Json
    } catch {
        Write-Warn "Could not read rollback state: $path"
        return $null
    }
}

function Save-BackendRollbackPoint {
    param($Config, [string]$LogPath = $null)
    if ($script:dryRun) { return }

    $appDir = Join-Path $Config.InstallRoot "backend"
    $repoDir = Join-Path $appDir "repo"
    if (-not (Test-Path (Join-Path $repoDir ".git"))) { return }

    $head = (& git -C $repoDir rev-parse HEAD 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($head)) { return }
    $branch = (& git -C $repoDir rev-parse --abbrev-ref HEAD 2>$null | Select-Object -First 1)

    $svcName = Get-DeployServiceName -Config $Config -Component "backend"
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue

    $rollbackRoot = Get-RollbackRoot -Config $Config
    New-Item -Path $rollbackRoot -ItemType Directory -Force | Out-Null

    # Keep at most two known-good backend rollback snapshots.
    $slot1State = Get-RollbackStatePath -Config $Config -Key "backend"
    $slot2State = Get-RollbackStatePath -Config $Config -Key "backend-previous"
    $slot1Env = Join-Path $rollbackRoot "backend.env.rollback"
    $slot2Env = Join-Path $rollbackRoot "backend.previous.env.rollback"

    if (Test-Path $slot1State) {
        Copy-Item -Path $slot1State -Destination $slot2State -Force
    }
    if (Test-Path $slot1Env) {
        Copy-Item -Path $slot1Env -Destination $slot2Env -Force
    }

    $envPath = Join-Path $repoDir ".env"
    $envBackup = $null
    if (Test-Path $envPath) {
        $envBackup = $slot1Env
        Copy-Item -Path $envPath -Destination $envBackup -Force
    }

    $state = [PSCustomObject]@{
        Key = "backend"
        SavedAt = (Get-Date).ToString("o")
        RepoDir = $repoDir
        AppDir = $appDir
        Commit = "$head"
        Branch = "$branch"
        ServiceName = $svcName
        ServiceExisted = [bool]($null -ne $svc)
        ServiceWasRunning = [bool]($svc -and $svc.Status -eq 'Running')
        EnvBackup = $envBackup
    }

    Save-RollbackState -Config $Config -Key "backend" -State $state

    if ($LogPath) {
        Write-FileLog -Path $LogPath -Text "Backend rollback snapshot saved: commit=$head"
        Write-FileLog -Path $LogPath -Text "Backend retention: 2 known-good rollback snapshots maximum"
    }
}
function Save-CaddyRollbackPoint {
    param($Config, [string]$LogPath = $null)
    if ($script:dryRun) { return }
    $caddyDir = Join-Path $Config.InstallRoot "caddy"
    if (-not (Test-Path $caddyDir)) { return }

    $filesToBackup = @("Caddyfile", "caddy-run.ps1")
    $existingFiles = @($filesToBackup | Where-Object { Test-Path (Join-Path $caddyDir $_) })
    if ($existingFiles.Count -eq 0) { return }

    $ts = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $backupDir = Join-Path (Get-RollbackRoot -Config $Config) "caddy-$ts"
    New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
    foreach ($file in $existingFiles) {
        Copy-Item -Path (Join-Path $caddyDir $file) -Destination (Join-Path $backupDir $file) -Force
    }

    $state = [PSCustomObject]@{
        Key = "caddy"
        SavedAt = (Get-Date).ToString("o")
        CaddyDir = $caddyDir
        BackupDir = $backupDir
        Files = $existingFiles
    }
    Save-RollbackState -Config $Config -Key "caddy" -State $state
    if ($LogPath) { Write-FileLog -Path $LogPath -Text "Caddy rollback point saved: $backupDir" }
}

# ===========================================================
# SECRETS (DB credentials, stored outside the script)
# Nested structure: db.host, db.port, db.name, db.user, db.password
# ===========================================================
function Protect-SecretsFile {
    param([string]$Path = $SecretsPath)
    $gitignore = Join-Path $PSScriptRoot ".gitignore"
    $entry = Split-Path $Path -Leaf
    if (-not (Test-Path $gitignore)) {
        Set-Content -Path $gitignore -Value $entry
        Write-Log "Created .gitignore with $entry"
    } elseif (-not (Select-String -Path $gitignore -Pattern ([regex]::Escape($entry)) -Quiet)) {
        Add-Content -Path $gitignore -Value $entry
        Write-Log "Added $entry to .gitignore"
    }
}

function Get-SecretsDefaults {
    <#
    .SYNOPSIS
      Returns a secrets object with sensible default/example values.
      These let the install proceed without real credentials;
      the user can update them later in deploy.secrets.json or the generated .env.
    #>
    Write-Log "Using default secrets (not production-ready)" -Level "WARN"
    return [PSCustomObject]@{
        db = [PSCustomObject]@{
            host     = "localhost"
            port     = 3306
            name     = "ess_face"
            user     = "root"
            password = ""
        }
    }
}

function Invoke-SecretsPrompt {
    <#
    .SYNOPSIS
      Interactively prompt the user for each field in deploy.secrets.json.
      Uses plain Read-Host (PSReadLine) so Ctrl+V paste and Ctrl+C work natively.
    #>
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Secrets,
        [Parameter(Mandatory)]
        [string]$SecretsPath
    )

    function Read-WithDefault {
        param([string]$Default, [string]$Prompt, [switch]$Mask)
        $fullPrompt = "$Prompt [$Default]: "
        if ($Mask) {
            $raw = Read-Host -Prompt $fullPrompt -AsSecureString
            if ($null -eq $raw -or $raw.Length -eq 0) { return $Default }
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($raw)
            $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            return $plain
        }
        $input = Read-Host -Prompt $fullPrompt
        if ([string]::IsNullOrWhiteSpace($input)) { return $Default }
        return $input
    }

    Write-Host ""
    Write-Host " Enter your credentials. Press Enter to keep the value in [brackets]." -ForegroundColor Cyan
    Write-Host " You can paste with Ctrl+V (right-click paste also works)." -ForegroundColor Cyan
    Write-Host ""

    # --- DB section ---
    Write-Host " [Database]" -ForegroundColor Magenta
    $Secrets.db.host = Read-WithDefault -Default $Secrets.db.host -Prompt "  DB host"
    $val = Read-WithDefault -Default $Secrets.db.port -Prompt "  DB port"
    $Secrets.db.port = [int]$val
    $Secrets.db.name = Read-WithDefault -Default $Secrets.db.name -Prompt "  DB name"
    $Secrets.db.user = Read-WithDefault -Default $Secrets.db.user -Prompt "  DB user"
    $Secrets.db.password = Read-WithDefault -Default $Secrets.db.password -Prompt "  DB password" -Mask

    # Save back to JSON
    $json = $Secrets | ConvertTo-Json -Depth 4
    Set-Content -Path $SecretsPath -Value $json -Force
    Write-Host ""
    Write-Success "Credentials saved to $SecretsPath"
    Write-Host ""

    return $Secrets
}

function Get-SecretsOrInitialize {
    <#
    .SYNOPSIS
      Load secrets from deploy.secrets.json.
      If missing or placeholders found, offers interactive fill.
      If placeholders remain, backend deployment is cancelled until the file is updated.
    #>

    $s = $null
    if (Test-Path $SecretsPath) {
        try {
            $s = Get-Content $SecretsPath -Raw -ErrorAction Stop | ConvertFrom-Json
        } catch {
            Write-Warn "Could not read $SecretsPath - will recreate."
            Write-Log "Failed to read $SecretsPath : $_" -Level "WARN"
            $s = $null
        }
    }

    $placeholderPattern = 'REPLACE_WITH_|YOUR_|CHANGE_THIS|PLACEHOLDER'

    if ($s) {
        # File exists - check for placeholder values
        $placeholders = @()
        if ($s.db.host     -match $placeholderPattern) { $placeholders += '  db.host (e.g. "localhost" or your MySQL server address)' }
        if ($s.db.user     -match $placeholderPattern) { $placeholders += '  db.user (e.g. "root")' }
        if ($s.db.name     -match $placeholderPattern) { $placeholders += '  db.name (e.g. "ess_face")' }
        if ($s.db.password -match $placeholderPattern) { $placeholders += '  db.password (your MySQL password)' }

        if ($placeholders.Count -gt 0) {
            Write-Host ""
            Write-Host " [!] deploy.secrets.json has placeholder values:" -ForegroundColor Yellow
            foreach ($p in $placeholders) {
                Write-Host "    $p" -ForegroundColor Yellow
            }
            Write-Host ""

            Write-Host " Edit this file with your real credentials before continuing:" -ForegroundColor Cyan
            Write-Host "     $SecretsPath" -ForegroundColor White
            Write-Host ""
            Write-Host " Required fields:" -ForegroundColor Gray
            Write-Host "  db.host     (your MySQL server address)" -ForegroundColor Gray
            Write-Host "  db.user     (your MySQL user)" -ForegroundColor Gray
            Write-Host "  db.name     (your MySQL database name)" -ForegroundColor Gray
            Write-Host "  db.password (your MySQL password)" -ForegroundColor Gray
            Write-Host ""

            if (-not $script:headless) {
                if (Confirm-Step "Have you updated deploy.secrets.json?" -DefaultYes:$false) {
                    # Reload the file after user edit
                    try {
                        Write-Host "    Reloading $SecretsPath ..." -ForegroundColor Gray
                        $s = Get-Content $SecretsPath -Raw -ErrorAction Stop | ConvertFrom-Json
                        Write-Log "Secrets reloaded from $SecretsPath"
                        Write-Host ""
                        return $s
                    } catch {
                        Write-Warn "Could not read $SecretsPath after edit: $_"
                        Write-Log "Failed to reload ${SecretsPath}: $_" -Level "WARN"
                    }
                }
            }

            # User declined - cancel deployment
            Write-Warn "Deployment cancelled. Edit $SecretsPath first, then re-run."
            Write-Host ""
            return $null
        }

        # All values are real - happy path
        Write-Log "Secrets loaded from $SecretsPath"
        return $s
    }

    # --- File missing entirely ---
    Write-Host ""
    Write-Host " [!] deploy.secrets.json not found." -ForegroundColor Yellow
    Write-Host " Creating a template file for you to edit..." -ForegroundColor Gray

    $s = Get-SecretsDefaults
    $json = $s | ConvertTo-Json -Depth 4
    Set-Content -Path $SecretsPath -Value $json -Force
    Protect-SecretsFile

    Write-Host ""
    Write-Host " Edit this file with your real credentials:" -ForegroundColor Cyan
    Write-Host "     $SecretsPath" -ForegroundColor White
    Write-Host ""
    Write-Host " Required fields:" -ForegroundColor Gray
    Write-Host "  db.host     (your MySQL server address)" -ForegroundColor Gray
    Write-Host "  db.user     (your MySQL user)" -ForegroundColor Gray
    Write-Host "  db.name     (your MySQL database name)" -ForegroundColor Gray
    Write-Host "  db.password (your MySQL password)" -ForegroundColor Gray
    Write-Host ""

    if (-not $script:headless) {
        if (Confirm-Step "Have you updated deploy.secrets.json?" -DefaultYes:$false) {
            try {
                Write-Host "    Reloading $SecretsPath ..." -ForegroundColor Gray
                $s = Get-Content $SecretsPath -Raw -ErrorAction Stop | ConvertFrom-Json
                Write-Log "Secrets reloaded from $SecretsPath"
                Write-Host ""
                return $s
            } catch {
                Write-Warn "Could not read $SecretsPath after edit: $_"
                Write-Log "Failed to reload ${SecretsPath}: $_" -Level "WARN"
            }
        }
    }

    Write-Warn "Deployment cancelled. Edit $SecretsPath first, then re-run."
    Write-Host ""
    return $null
}

<#
function Get-OrCreateSecrets {
    if ($script:headless) {
        if (Test-Path $SecretsPath) {
            Write-Log "Secrets loaded from $SecretsPath"
            return Get-Content $SecretsPath -Raw | ConvertFrom-Json
        }
        Write-Err "No secrets file found and running in headless mode. Create deploy.secrets.json first."
        Write-Host "  Template: $SecretsExamplePath" -ForegroundColor Gray
        exit 1
    }

    # If file exists, show current values and ask to edit or use as-is
    $existing = $null
    if (Test-Path $SecretsPath) {
        $existing = Get-Content $SecretsPath -Raw | ConvertFrom-Json
        Write-Host "`nCurrent secrets from $SecretsPath :" -ForegroundColor Cyan
        Write-Host ($existing | ConvertTo-Json) -ForegroundColor Gray
        Write-Host ""
        $useExisting = Read-Host "Use these existing values? (Y/n)"
        if ($useExisting -eq '' -or $useExisting -match '^[Yy]') {
            Write-Success "Using existing secrets."
            return $existing
        }
    }

    Write-Host "These are saved locally only and used to generate the backend's .env file.`n" -ForegroundColor Gray

    # Set defaults from existing file if available
    $defDbHost   = if ($existing) { $existing.db.host } else { "192.168.1.140" }
    $defDbUser   = if ($existing) { $existing.db.user } else { "root" }
    $defDbName   = if ($existing) { $existing.db.name } else { "ess" }
    $defDbPass   = if ($existing) { $existing.db.password } else { "" }

    # Database settings
    Write-Host "-- Database --" -ForegroundColor Cyan
    $dbHostIn = Edit-WithDefault -Default $defDbHost -Prompt "#Edit or Skip for default > `"host`": `""
    Write-Host "    `"host`": `"$dbHostIn`"" -ForegroundColor Green

    $dbUser = Edit-WithDefault -Default $defDbUser -Prompt "#Edit or Skip for default > `"user`": `""

    $dbName = Edit-WithDefault -Default $defDbName -Prompt "#Edit or Skip for default > `"name`": `""
    Write-Host "    `"name`": `"$dbName`"" -ForegroundColor Green

    $dbPassword = Edit-WithDefault -Default $defDbPass -Prompt "#Edit or Skip for default > `"password`": `""
    Write-Host "    `"password`": `"$dbPassword`"" -ForegroundColor Green

    # SMTP settings

    $emailFrom = Edit-WithDefault -Default $defSmtpFrom -Prompt "#Edit or Skip for default > `"from`": `""

    $secrets = [PSCustomObject]@{
        db = [PSCustomObject]@{
            host     = $dbHostIn
            user     = $dbUser
            name     = $dbName
            password = $dbPassword
        }
        smtp = [PSCustomObject]@{
            user = $smtpUser
            pass = $smtpPassword
            from = $emailFrom
        }
    }
    $secrets | ConvertTo-Json | Set-Content $SecretsPath
    Protect-SecretsFile
    Write-Success "Saved to $SecretsPath (excluded from git via .gitignore)."
    Write-Log "Secrets created at $SecretsPath"
    return $secrets
}
#>


# ===========================================================
# DEPLOYMENT CREDENTIAL CONFIRMATION
# Always shown for interactive first install and updates after
# deploy.secrets.json has been loaded successfully.
# Never prints actual passwords or SECRET_KEY values.
# ===========================================================
function Confirm-DeploymentCredentials {
    param($Config, $Secrets)

    if ($script:headless) {
        return $true
    }

    $dbConfigured = (
        $Secrets -and $Secrets.db -and
        -not [string]::IsNullOrWhiteSpace("$($Secrets.db.host)") -and
        -not [string]::IsNullOrWhiteSpace("$($Secrets.db.name)") -and
        -not [string]::IsNullOrWhiteSpace("$($Secrets.db.user)")
    )


    $backendEnv = Join-Path (Join-Path (Join-Path $Config.InstallRoot "backend") "repo") ".env"
    $secretKeyStatus = "will be generated on first successful backend install"

    if (Test-Path $backendEnv) {
        $secretLine = Get-Content $backendEnv -ErrorAction SilentlyContinue |
            Where-Object { $_ -match '^\s*SECRET_KEY\s*=' } |
            Select-Object -First 1

        if ($secretLine) {
            $secretValue = (($secretLine -split '=', 2)[1]).Trim().Trim('"').Trim("'")
            if (-not [string]::IsNullOrWhiteSpace($secretValue)) {
                $secretKeyStatus = "existing / preserved"
            }
        }
    }

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " Deployment Credentials" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host (" DB configuration   : " + $(if ($dbConfigured) { "configured" } else { "incomplete" })) `
        -ForegroundColor $(if ($dbConfigured) { "Green" } else { "Yellow" })
    Write-Host " SECRET_KEY         : $secretKeyStatus" -ForegroundColor Green
    Write-Host ""
    Write-Host " Source: $SecretsPath" -ForegroundColor Gray
    Write-Host ""

    if (-not (Confirm-Step "Continue deployment?" -DefaultYes:$true)) {
        Write-Warn "Deployment cancelled by user."
        Write-Log "Deployment cancelled at credential confirmation; no component update started" -Level "WARN"
        return $false
    }

    Write-Success "Deployment credentials confirmed."
    return $true
}

# ===========================================================
# PREREQUISITES
# ===========================================================
function Test-VCRedistX64Installed {
    # Primary check: Microsoft VC++ Runtime registry registration.
    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x64"
    )

    foreach ($path in $registryPaths) {
        try {
            $runtime = Get-ItemProperty -Path $path -ErrorAction Stop
            if ($runtime.Installed -eq 1) {
                return $true
            }
        } catch { }
    }

    # Fallback check for the native DLLs ONNX Runtime needs on Windows.
    $requiredDlls = @(
        "$env:WINDIR\System32\vcruntime140.dll",
        "$env:WINDIR\System32\vcruntime140_1.dll",
        "$env:WINDIR\System32\msvcp140.dll"
    )

    foreach ($dll in $requiredDlls) {
        if (-not (Test-Path $dll)) {
            return $false
        }
    }

    return $true
}

function Test-Prerequisites {
    param([switch]$CheckOnly)
    Write-Step "Checking prerequisites"
    $ok = $true
    $missing = @()

    $tools = @(
        @{ Cmd = "git";    Name = "Git";          WingetId = "Git.Git";           Url = "https://git-scm.com" },
        @{ Cmd = "node";   Name = "Node.js 22+";  WingetId = "OpenJS.NodeJS.LTS"; Url = "https://nodejs.org" },
        @{ Cmd = "python"; Name = "Python 3.13+"; WingetId = "Python.Python.3.13"; Url = "https://python.org" }
    )

    # Pass 1: check everything and report
    Write-Host ""
    foreach ($tool in $tools) {
        if (Get-Command $tool.Cmd -ErrorAction SilentlyContinue) {
            Write-Host "    $($tool.Name): OK" -ForegroundColor Green
        } else {
            Write-Host "    $($tool.Name): MISSING" -ForegroundColor Red
            $missing += $tool
        }
    }

    # Microsoft Visual C++ Redistributable x64 check.
    # ONNX Runtime native Windows DLLs require this runtime.
    if (Test-VCRedistX64Installed) {
        Write-Host "    Microsoft Visual C++ Redistributable x64: OK" -ForegroundColor Green
    } else {
        Write-Host "    Microsoft Visual C++ Redistributable x64: MISSING" -ForegroundColor Red
        $missing += @{
            Cmd = "__vcredist_x64__"
            Name = "Microsoft Visual C++ Redistributable x64"
            WingetId = "Microsoft.VCRedist.2015+.x64"
            Url = "https://aka.ms/vs/17/release/vc_redist.x64.exe"
        }
    }

    # Servy check
    if (Get-Command servy-cli -ErrorAction SilentlyContinue) {
        Write-Host "    Servy: OK" -ForegroundColor Green
    } else {
        Write-Host "    Servy: MISSING" -ForegroundColor Red
        $missing += @{ Cmd = "servy-cli"; Name = "Servy CLI"; WingetId = "servy"; Url = "https://github.com/servy-community/servy" }
    }

    Write-Host ""

    # Pass 2: install all missing at once (skip if CheckOnly)
    if ($missing.Count -gt 0) {
        $missingNames = ($missing | ForEach-Object { $_.Name }) -join ', '
        if ($script:headless -or $CheckOnly) {
            Write-Err "Missing prerequisites: $missingNames"
            if ($CheckOnly) {
                Write-Host "    Run option 1 from the main menu to install them." -ForegroundColor Gray
            }
            Write-Log "Missing prerequisites: $missingNames" -Level "ERROR"
            return $false
        }
        if (Confirm-Step "Install missing prerequisites: $missingNames?" -DefaultYes:$true) {
            $allSucceeded = $true
            foreach ($tool in $missing) {
                Write-Host "    Installing $($tool.Name)..." -ForegroundColor Gray
                Write-Log "Installing $($tool.Name) via winget ($($tool.WingetId))"

                if ($tool.Cmd -eq "__vcredist_x64__") {
                    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
                        Write-Err "    Winget is required to install Microsoft Visual C++ Redistributable automatically."
                        Write-Host "    Install manually: $($tool.Url)" -ForegroundColor Gray
                        $allSucceeded = $false
                        continue
                    }

                    winget install --id $tool.WingetId --exact --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null

                    if (Test-VCRedistX64Installed) {
                        Write-Success "    $($tool.Name): installed"
                        Write-Log "$($tool.Name) verified after installation"
                    } else {
                        Write-Err "    $($tool.Name) installation/verification failed."
                        Write-Host "    Install manually: $($tool.Url)" -ForegroundColor Gray
                        $allSucceeded = $false
                    }
                    continue
                }

                if ($tool.WingetId -and (Get-Command winget -ErrorAction SilentlyContinue)) {
                    winget install $tool.WingetId --accept-package-agreements --silent 2>&1 | Out-Null
                }

                # Refresh PATH and verify command-based prerequisites.
                $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")

                if (-not (Get-Command $tool.Cmd -ErrorAction SilentlyContinue)) {
                    Write-Err "    $($tool.Name) install may have failed."
                    Write-Host "    Install manually: $($tool.Url)" -ForegroundColor Gray
                    $allSucceeded = $false
                } else {
                    Write-Success "    $($tool.Name): installed"
                }
            }
            # Refresh PATH once more after all installs
            $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
            if ($allSucceeded) { Write-Success "All prerequisites installed." }
        } else {
            Write-Warn "Skipping installation. Deployment may fail."
            $ok = $false
        }
    } else {
        Write-Success "All prerequisites are already installed."
    }

    if (-not $ok) { return $false }
    return $true
}

# ===========================================================
# PORT AVAILABILITY CHECK
# ===========================================================
function Test-PortInUse {
    param([int]$Port)
    # Returns $true if the port is already in use (TCP) on localhost
    # Uses TcpClient instead of netstat for reliability across locales/Windows versions
    $tcp = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect('127.0.0.1', $Port, $null, $null)
        $connected = $iar.AsyncWaitHandle.WaitOne(500)
        if ($connected -and $tcp.Connected) {
            $tcp.EndConnect($iar)
            return $true
        }
    } catch {
        Write-Log "Could not check port $Port availability: $_" -Level "WARN"
    } finally {
        if ($tcp) { $tcp.Close() }
    }
    return $false
}

# ===========================================================
# HEALTH VERIFICATION
# ===========================================================
function Get-CaddyActualPorts {
    param($Config)
    <#
    .SYNOPSIS
      Reads caddy-ports.json (written by the runner script at each start)
      and returns the actual proxy and admin ports Caddy is using.
      Returns a hashtable with keys: proxy, admin
    #>
    $caddyDir = Join-Path $Config.InstallRoot "caddy"
    $portsFile = Join-Path $caddyDir "caddy-ports.json"
    $result = @{ proxy = $Config.CaddyPort; admin = $Config.CaddyAdminPort }
    if (Test-Path $portsFile) {
        try {
            $portsData = Get-Content $portsFile -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($portsData.proxy -and $portsData.proxy -gt 0) {
                $result.proxy = [int]$portsData.proxy
            }
            if ($portsData.admin -and $portsData.admin -gt 0) {
                $result.admin = [int]$portsData.admin
            }
        } catch {
            Write-Log "Could not read $portsFile : $_" -Level "WARN"
        }
    }
    return $result
}

function Test-Endpoint {
    param([string]$Url, [string]$Name, [int]$TimeoutSec = 5, [int]$Retries = 7, [int]$RetryDelaySec = 3)
    $attempts = $Retries + 1
    for ($i = 1; $i -le $attempts; $i++) {
        try {
            Invoke-RestMethod -Uri $Url -TimeoutSec $TimeoutSec -ErrorAction Stop | Out-Null
            if ($i -gt 1) {
                Write-Success "$Name ($Url): responding"
                Write-Log "Health check passed: $Name ($Url) (after $($i-1) retries)"
            } else {
                Write-Success "$Name ($Url): responding"
                Write-Log "Health check passed: $Name ($Url)"
            }
            return $true
        } catch {
            if ($i -lt $attempts) {
                Write-Warn "$Name ($Url): waiting ($i/$Retries)..."
                Start-Sleep -Seconds $RetryDelaySec
            } else {
                Write-Err "$Name ($Url): not responding"
                Write-Log "Health check failed: $Name ($Url) - $_" -Level "ERROR"
                return $false
            }
        }
    }
}

function Verify-Health {
    param($Config)
    $allOk = $true
    $backendSvcName = Get-DeployServiceName -Config $Config -Component "backend"
    $frontendSvcName = Get-DeployServiceName -Config $Config -Component "frontend"
    $caddySvcName = Get-DeployServiceName -Config $Config -Component "caddy"
    Write-Step "Verifying service health"

    if (Get-Service -Name $backendSvcName -ErrorAction SilentlyContinue) {
        if (-not (Test-Endpoint -Url "http://localhost:$($Config.BackendPort)$($Config.ApiPrefix)/health" -Name "Backend API")) { $allOk = $false }
    }
    if (Get-Service -Name $frontendSvcName -ErrorAction SilentlyContinue) {
        if (-not (Test-Endpoint -Url "http://localhost:$($Config.FrontendPort)" -Name "Frontend")) { $allOk = $false }
    }
    if (Get-Service -Name $caddySvcName -ErrorAction SilentlyContinue) {
        $caddyPorts = Get-CaddyActualPorts -Config $Config
        $caddyProxyPort = $caddyPorts.proxy
        if (-not (Test-Endpoint -Url "http://localhost:${caddyProxyPort}$($Config.ApiPrefix)/health" -Name "Caddy proxy")) { $allOk = $false }
    }

    # Show port summary after health checks
    Write-Host ""
    Write-Host " -- Ports --" -ForegroundColor Cyan
    Write-Host "  Frontend : $($Config.FrontendPort)" -ForegroundColor Green
    Write-Host "  Backend  : $($Config.BackendPort)" -ForegroundColor Green
    if (Get-Service -Name $caddySvcName -ErrorAction SilentlyContinue) {
        $caddyPorts = Get-CaddyActualPorts -Config $Config
        Write-Host "  Caddy proxy : $($caddyPorts.proxy)" -ForegroundColor Green
        if ($caddyPorts.admin) {
            Write-Host "  Caddy admin : $($caddyPorts.admin)" -ForegroundColor Gray
        } else {
            Write-Host "  Caddy admin : (not available yet - service may still be starting)" -ForegroundColor DarkYellow
        }
    }
    Write-Host ""

    return $allOk
}

# ===========================================================
# COMPONENT INSTALLERS
# Existing component => update in place; missing component => first install.
# ===========================================================
function Install-Frontend {
    param($Config)
    Initialize-InstallRoot -Config $Config

    $appDir  = Join-Path $Config.InstallRoot "frontend"
    $repoDir = Join-Path $appDir "repo"
    $svcName = Get-DeployServiceName -Config $Config -Component "frontend"
    $appPort = $Config.FrontendPort
    $logsDir = Join-Path (Join-Path $Config.InstallRoot "logs") "frontend"
    New-Item -Path $logsDir -ItemType Directory -Force | Out-Null

    $wasInstalled = Test-ComponentInstalled -Config $Config -Component "frontend"
    $action = if ($wasInstalled) { "Updating" } else { "Installing" }
    Write-Step "$action Frontend"

    if ($script:dryRun) {
        Write-Warn "[DRY-RUN] Would $($action.ToLower()) Frontend from $($Config.FrontendRepo), branch $($Config.FrontendBranch)"
        return $true
    }

    $ts = (Get-Date).ToString("yyyyMMdd-HHmmss")
    $installLog = Join-Path $logsDir "frontend_${ts}.log"
    $oldGood = Get-DeploymentComponentCurrent -Config $Config -Component "frontend"
    if ([string]::IsNullOrWhiteSpace($oldGood) -and (Test-Path (Join-Path $repoDir ".git"))) {
        $oldGood = Get-GitHead -RepoDir $repoDir
    }

    $liveFrontendChanged = $false
    $frontendFingerprint = Get-FrontendDeploymentFingerprint -Config $Config
    $savedFrontendFingerprint = Get-SavedComponentFingerprint -Config $Config -Component "frontend"
    $frontendConfigChanged = ($savedFrontendFingerprint -ne $frontendFingerprint)

    try {
        New-Item -Path $appDir -ItemType Directory -Force | Out-Null

        if (Test-Path (Join-Path $repoDir ".git")) {
            Write-Host "    Checking Git/config for frontend update..." -ForegroundColor Gray

            $currentOrigin = (& git -C $repoDir remote get-url origin 2>$null | Select-Object -First 1)
            if ("$currentOrigin".Trim() -ne "$($Config.FrontendRepo)".Trim()) {
                Write-Host "    Frontend repository URL changed; updating Git origin..." -ForegroundColor Gray
                & git -C $repoDir remote set-url origin $Config.FrontendRepo
                if ($LASTEXITCODE -ne 0) { throw "Could not update frontend Git origin URL." }
                $frontendConfigChanged = $true
            }

            git -C $repoDir fetch --prune origin "+refs/heads/$($Config.FrontendBranch):refs/remotes/origin/$($Config.FrontendBranch)" 2>&1 | Add-FileLog -Path $installLog
            if ($LASTEXITCODE -ne 0) {
                throw "Frontend branch '$($Config.FrontendBranch)' could not be fetched. Check FrontendBranch in deploy.config.json. Live frontend was not changed."
            }

            $remoteHead = (& git -C $repoDir rev-parse "origin/$($Config.FrontendBranch)" 2>$null | Select-Object -First 1).Trim()
            $localHead = (Get-GitHead -RepoDir $repoDir)

            if ($wasInstalled -and $localHead -eq $remoteHead -and -not $frontendConfigChanged) {
                Write-Success "Frontend code and deployment configuration are already current: $localHead"
                Register-SuccessfulComponentDeployment -Config $Config -Component "frontend" -Commit $localHead
                return $true
            }

            if ($wasInstalled -and $localHead -eq $remoteHead -and $frontendConfigChanged) {
                Write-Host "    Frontend Git is unchanged, but deployment configuration changed; rebuilding/restarting frontend." -ForegroundColor Cyan
                $script:deploymentConfigChanged = $true
            }

            if ($wasInstalled) {
                $candidateDir = Join-Path $appDir "_candidate_frontend"
                Write-Host "    Validating frontend candidate before changing the active version..." -ForegroundColor Cyan

                & git -C $repoDir worktree remove --force $candidateDir 2>$null | Out-Null
                if (Test-Path $candidateDir) {
                    Remove-Item -Path $candidateDir -Recurse -Force -ErrorAction SilentlyContinue
                }
                & git -C $repoDir worktree prune 2>$null | Out-Null

                try {
                    & git -C $repoDir worktree add --detach $candidateDir $remoteHead 2>&1 | Add-FileLog -Path $installLog
                    if ($LASTEXITCODE -ne 0) { throw "Could not create frontend candidate worktree." }

                    Push-Location $candidateDir
                    try {
                        npm install --legacy-peer-deps 2>&1 | Add-FileLog -Path $installLog
                        if ($LASTEXITCODE -ne 0) { throw "Frontend candidate npm install failed." }

                        $env:VITE_API_URL = $Config.ApiPrefix
                        npm run build 2>&1 | Add-FileLog -Path $installLog
                        if ($LASTEXITCODE -ne 0) { throw "Frontend candidate build failed. Live frontend was not changed." }

                        if (-not (Test-Path (Join-Path $candidateDir "dist"))) {
                            throw "Frontend candidate build did not create dist. Live frontend was not changed."
                        }
                    }
                    finally {
                        Pop-Location
                    }

                    Write-Success "Frontend candidate validation passed: $remoteHead"
                }
                finally {
                    & git -C $repoDir worktree remove --force $candidateDir 2>$null | Out-Null
                    if (Test-Path $candidateDir) {
                        Remove-Item -Path $candidateDir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    & git -C $repoDir worktree prune 2>$null | Out-Null
                }
            }

            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -ne 'Stopped') {
                Stop-Service -Name $svcName -ErrorAction Stop
                Start-Sleep -Seconds 2
            }

            $liveFrontendChanged = $true
            $script:liveComponentsChanged += "frontend"
            git -C $repoDir reset --hard "origin/$($Config.FrontendBranch)" 2>&1 | Add-FileLog -Path $installLog
            if ($LASTEXITCODE -ne 0) { throw "Frontend git reset failed." }

            # -fd does not remove ignored node_modules/.env. Never use git clean -fdx here.
            git -C $repoDir clean -fd 2>&1 | Add-FileLog -Path $installLog
            if ($LASTEXITCODE -ne 0) { throw "Frontend git clean failed." }
        }
        else {
            Write-Host "    First install: cloning frontend..." -ForegroundColor Gray
            if (Test-Path $repoDir) { Remove-Item -Path $repoDir -Recurse -Force }
            git clone --branch $Config.FrontendBranch $Config.FrontendRepo $repoDir 2>&1 | Add-FileLog -Path $installLog
            if ($LASTEXITCODE -ne 0) { throw "Frontend git clone failed." }
        }

        $candidate = Get-GitHead -RepoDir $repoDir
        if ([string]::IsNullOrWhiteSpace($candidate)) { throw "Could not determine frontend Git HEAD." }

        Write-Host "    Synchronizing frontend dependencies (node_modules is kept)..." -ForegroundColor Gray
        Push-Location $repoDir
        try {
            npm install --legacy-peer-deps 2>&1 | Add-FileLog -Path $installLog
            if ($LASTEXITCODE -ne 0) { throw "npm install failed." }

            $serveMain = Join-Path $repoDir "node_modules\serve\build\main.js"
            if (-not (Test-Path $serveMain)) {
                npm install --no-save serve --legacy-peer-deps 2>&1 | Add-FileLog -Path $installLog
                if ($LASTEXITCODE -ne 0) { throw "npm install serve failed." }
            }

            $env:VITE_API_URL = $Config.ApiPrefix
            npm run build 2>&1 | Add-FileLog -Path $installLog
            if ($LASTEXITCODE -ne 0) { throw "npm run build failed." }
        }
        finally {
            Pop-Location
        }

        $distDir = Join-Path $repoDir "dist"
        if (-not (Test-Path $distDir)) { throw "Frontend dist folder was not created." }

        $runnerScript = Join-Path $appDir "frontend-run.ps1"
        $runnerContent = @'
$ErrorActionPreference = "Stop"
$frontendDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir = Join-Path $frontendDir "repo"
$distDir = Join-Path $repoDir "dist"
$serveMain = Join-Path $repoDir "node_modules\serve\build\main.js"
$logsDir = Join-Path (Join-Path (Split-Path $frontendDir -Parent) "logs") "frontend"
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }
$serviceLog = Join-Path $logsDir ("frontend_service_{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
function Log([string]$m) { "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),$m | Add-Content -Path $serviceLog }
try {
    if (-not (Test-Path $distDir)) { throw "dist not found: $distDir" }
    if (-not (Test-Path $serveMain)) { throw "serve not found: $serveMain" }
    $node = (Get-Command node.exe -ErrorAction Stop).Source
    Log "Serving $distDir on __FRONTEND_PORT__"
    & $node $serveMain -s $distDir -l "__FRONTEND_PORT__" 2>&1 | ForEach-Object { Log "$_" }
    exit $LASTEXITCODE
} catch {
    Log "ERROR: $($_.Exception.Message)"
    exit 1
}
'@
        $runnerContent = $runnerContent.Replace('__FRONTEND_PORT__', "$appPort")
        Set-Content -Path $runnerScript -Value $runnerContent -Encoding UTF8 -Force

        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if (-not $svc) {
            $powershellExe = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
            $paramStr = "-ExecutionPolicy Bypass -File `"$runnerScript`""
            servy-cli install --name="$svcName" --path="$powershellExe" --params="$paramStr" 2>&1 | Add-FileLog -Path $installLog
            if (-not (Get-Service -Name $svcName -ErrorAction SilentlyContinue)) { throw "Frontend service creation failed." }
            sc.exe config "$svcName" start= delayed-auto | Out-Null
            sc.exe failure "$svcName" reset= 86400 actions= restart/5000/restart/15000/restart/60000 | Out-Null
            sc.exe failureflag "$svcName" 1 | Out-Null
            Write-Success "Frontend service created"
        }
        else {
            Write-Success "Frontend service registration kept"
        }

        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Stopped') { Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 1 }
        Start-Service -Name $svcName -ErrorAction Stop

        $healthOk = Test-Endpoint -Url "http://127.0.0.1:$appPort" -Name "Frontend" -TimeoutSec 5 -Retries 7 -RetryDelaySec 2
        if (-not $healthOk) { throw "Frontend candidate did not pass health check." }

        Register-SuccessfulComponentDeployment -Config $Config -Component "frontend" -Commit $candidate
        Save-ComponentFingerprint -Config $Config -Component "frontend" -Fingerprint $frontendFingerprint
        if ($frontendConfigChanged) { $script:deploymentConfigChanged = $true }
        $script:installedComponents += "frontend"
        Write-Success "Frontend update successful: $candidate"
        return $true
    }
    catch {
        Write-Err "Frontend setup failed: $_"

        if (-not $liveFrontendChanged -and $wasInstalled) {
            Write-Warn "Frontend update failed before live promotion."
            Write-Success "Active frontend remains unchanged at: $oldGood"
            Write-Log "Frontend update failed before live promotion; no service or repo restore required" -Level "WARN"
        }
        elseif ($liveFrontendChanged -and -not [string]::IsNullOrWhiteSpace($oldGood) -and (Test-Path (Join-Path $repoDir ".git"))) {
            Write-Warn "Frontend live promotion failed. Automatically restoring known-good commit: $oldGood"
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -ne 'Stopped') { Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue }

            if (-not (Ensure-GitCommitAvailable -RepoDir $repoDir -Commit $oldGood)) {
                Write-Err "Could not make previous frontend commit available locally: $oldGood"
                return $false
            }

            git -C $repoDir reset --hard $oldGood | Out-Null
            Push-Location $repoDir
            try {
                npm install --legacy-peer-deps | Out-Null
                $env:VITE_API_URL = $Config.ApiPrefix
                npm run build | Out-Null
            } finally { Pop-Location }

            Start-Service -Name $svcName -ErrorAction SilentlyContinue
            if (Test-Endpoint -Url "http://127.0.0.1:$appPort" -Name "Frontend restored" -TimeoutSec 5 -Retries 5 -RetryDelaySec 2) {
                Write-Success "Frontend restored to known-good commit: $oldGood"
            } else {
                Write-Err "Frontend rollback health check failed."
            }
        }
        elseif (-not $wasInstalled) {
            # Failed first install never becomes deployment state.
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($svc) {
                Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
                servy-cli uninstall --name="$svcName" --quiet | Out-Null
            }
            Write-Warn "Failed first frontend install was not recorded as a deployment version."
        }
        return $false
    }
}


function Install-Backend {
    param($Config, $Secrets)
    Initialize-InstallRoot -Config $Config
    Write-Step "Installing / Updating Backend"

    if (-not (Test-VCRedistX64Installed)) {
        Write-Err "Microsoft Visual C++ Redistributable x64 is missing. Run prerequisite check/install first."
        Write-Log "Backend install blocked: Microsoft Visual C++ Redistributable x64 missing" -Level "ERROR"
        return $false
    }

    if ($script:dryRun) {
        Write-Warn "[DRY-RUN] Would install Backend from $($Config.BackendRepo), branch $($Config.BackendBranch), on port $($Config.BackendPort)"
        return $true
    }

    $logsDir  = Join-Path (Join-Path $Config.InstallRoot "logs") "backend"
    New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
    $appDir   = Join-Path $Config.InstallRoot "backend"
    $repoDir  = Join-Path $appDir "repo"
    $svcName  = Get-DeployServiceName -Config $Config -Component "backend"
    $appPort  = $Config.BackendPort

    function Invoke-BackendLoggedCommand {
        param(
            [Parameter(Mandatory=$true)][string]$LogPath,
            [Parameter(Mandatory=$true)][string]$StepName,
            [Parameter(Mandatory=$true)][scriptblock]$Command
        )

        Write-FileLog -Path $LogPath -Text "--- $StepName ---"
        $commandOutput = @(& $Command 2>&1)
        $exitCode = $LASTEXITCODE
        foreach ($line in $commandOutput) {
            Write-Host "$line"
            Write-FileLog -Path $LogPath -Text "$line"
        }
        Write-FileLog -Path $LogPath -Text "$StepName exit code: $exitCode"
        if ($exitCode -ne 0) {
            $detail = (($commandOutput | Select-Object -Last 10) -join " | ").Trim()
            if ([string]::IsNullOrWhiteSpace($detail)) {
                $detail = "Git returned no error text"
            }
            throw "$StepName failed with exit code $exitCode. Detail: $detail"
        }
    }

    function Stop-BackendRuntime {
        param(
            [Parameter(Mandatory=$true)][string[]]$ServiceNames,
            [Parameter(Mandatory=$true)][string]$AppDir,
            [Parameter(Mandatory=$true)][string]$RepoDir,
            [Parameter(Mandatory=$true)][string]$LogPath
        )

        $runnerScript = Join-Path $AppDir "backend-run.ps1"

        foreach ($serviceName in $ServiceNames) {
            $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($svc) {
                Write-Host "    Existing service found: $serviceName ($($svc.Status))" -ForegroundColor Gray
                Write-FileLog -Path $LogPath -Text "Existing service found: $serviceName status=$($svc.Status)"

                if ($svc.Status -ne 'Stopped') {
                    Write-Host "    Stopping service $serviceName..." -ForegroundColor Gray
                    Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Seconds 3
                }

                Write-Host "    Keeping existing service registration for update: $serviceName" -ForegroundColor Gray
                Write-FileLog -Path $LogPath -Text "Update mode: service registration preserved for $serviceName"
            }
        }

        Write-Host "    Checking for stale backend processes that may lock venv files..." -ForegroundColor Gray
        $staleProcesses = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                $_.CommandLine -and
                ($_.ProcessId -ne $PID) -and
                (
                    $_.CommandLine -like "*$RepoDir*" -or
                    $_.CommandLine -like "*$runnerScript*"
                )
            }

        foreach ($proc in $staleProcesses) {
            Write-Host "    Killing stale process PID $($proc.ProcessId): $($proc.Name)" -ForegroundColor Yellow
            Write-FileLog -Path $LogPath -Text "Killing stale process PID $($proc.ProcessId): $($proc.Name) :: $($proc.CommandLine)"
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        }

        Start-Sleep -Seconds 2
    }

    function Remove-PathStrict {
        param(
            [Parameter(Mandatory=$true)][string]$Path,
            [Parameter(Mandatory=$true)][string]$LogPath,
            [int]$Attempts = 5
        )

        if (-not (Test-Path $Path)) { return }

        for ($i = 1; $i -le $Attempts; $i++) {
            try {
                Write-FileLog -Path $LogPath -Text "Removing path attempt $i/${Attempts}: $Path"
                Remove-Item $Path -Recurse -Force -ErrorAction Stop
                Start-Sleep -Milliseconds 500
                if (-not (Test-Path $Path)) {
                    Write-FileLog -Path $LogPath -Text "Removed path successfully: $Path"
                    return
                }
            } catch {
                Write-FileLog -Path $LogPath -Text "Remove path failed attempt $i/${Attempts}: $Path :: $_"
                Start-Sleep -Seconds 2
            }
        }

        throw "Failed to remove path after $Attempts attempts: $Path. A service/process may still be locking files."
    }

    function Get-BackendPythonCreator {
        param([Parameter(Mandatory=$true)][string]$LogPath)

        # The face backend uses native ONNX Runtime wheels. Keep production on
        # Python 3.13 where native Windows dependencies are more predictable.
        # Do not silently pick a newer generic "py -3" interpreter such as 3.14.
        $preferredVersions = @("3.13", "3.12", "3.11")

        $py = Get-Command py -ErrorAction SilentlyContinue

        function Test-PythonLauncherVersion {
            param([string]$Version)
            if (-not $py) { return $null }

            $check = & py "-$Version" -c "import sys; print(sys.version); print(sys.executable)" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-FileLog -Path $LogPath -Text "Using Python launcher: py -$Version ($($check -join ' | '))"
                return @{ File = "py"; Args = @("-$Version"); Version = $Version }
            }
            return $null
        }

        foreach ($version in $preferredVersions) {
            $candidate = Test-PythonLauncherVersion -Version $version
            if ($candidate) { return $candidate }
        }

        # If Python 3.13 is not installed, try to install it automatically.
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Host "    Python 3.13 not found. Installing Python 3.13 for backend compatibility..." -ForegroundColor Yellow
            Write-FileLog -Path $LogPath -Text "Python 3.13 not found; attempting winget install Python.Python.3.13"

            winget install --id Python.Python.3.13 --exact --silent --accept-package-agreements --accept-source-agreements 2>&1 |
                Add-FileLog -Path $LogPath

            $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                        [Environment]::GetEnvironmentVariable("Path", "User")

            $py = Get-Command py -ErrorAction SilentlyContinue
            $candidate = Test-PythonLauncherVersion -Version "3.13"
            if ($candidate) { return $candidate }
        }

        throw "Python 3.13, 3.12, or 3.11 is required for the backend. Python 3.14 is intentionally not selected for this ONNX Runtime deployment."
    }

    function Repair-OnnxWindowsRuntime {
        param(
            [Parameter(Mandatory=$true)][string]$PythonExe,
            [Parameter(Mandatory=$true)][string]$LogPath
        )

        Write-FileLog -Path $LogPath -Text "--- ONNX Runtime native import check ---"
        $ortCheck = @(& $PythonExe -c "import onnxruntime as ort; print('ORT_OK'); print(ort.__version__)" 2>&1)
        $ortExit = $LASTEXITCODE
        foreach ($line in $ortCheck) {
            Write-Host "$line"
            Write-FileLog -Path $LogPath -Text "$line"
        }

        if ($ortExit -eq 0 -and (($ortCheck -join " | ") -match "ORT_OK")) {
            Write-FileLog -Path $LogPath -Text "ONNX Runtime native import check passed"
            return
        }

        $detail = $ortCheck -join " | "
        Write-Warn "ONNX Runtime native import failed. Installing/updating Microsoft Visual C++ x64 runtime..."
        Write-FileLog -Path $LogPath -Text "ONNX Runtime import failed before VC++ repair: $detail"

        $redistPath = Join-Path $env:TEMP "vc_redist.x64.exe"
        try {
            Invoke-WebRequest `
                -Uri "https://aka.ms/vs/17/release/vc_redist.x64.exe" `
                -OutFile $redistPath `
                -UseBasicParsing `
                -ErrorAction Stop

            $proc = Start-Process `
                -FilePath $redistPath `
                -ArgumentList @("/install", "/quiet", "/norestart") `
                -Wait `
                -PassThru

            # 0 = success, 1638 = another/newer version installed, 3010 = success/reboot required.
            if ($proc.ExitCode -notin @(0, 1638, 3010)) {
                throw "Visual C++ Redistributable installer exited with code $($proc.ExitCode)"
            }

            Write-FileLog -Path $LogPath -Text "VC++ x64 runtime install/repair exit code: $($proc.ExitCode)"
        }
        finally {
            Remove-Item $redistPath -Force -ErrorAction SilentlyContinue
        }

        # Retry the exact native import after the runtime repair.
        $ortRetry = @(& $PythonExe -c "import onnxruntime as ort; print('ORT_OK'); print(ort.__version__)" 2>&1)
        $ortRetryExit = $LASTEXITCODE
        foreach ($line in $ortRetry) {
            Write-Host "$line"
            Write-FileLog -Path $LogPath -Text "$line"
        }

        if ($ortRetryExit -ne 0 -or (($ortRetry -join " | ") -notmatch "ORT_OK")) {
            throw "ONNX Runtime still cannot load after installing the Microsoft Visual C++ x64 runtime. Detail: $($ortRetry -join ' | ')"
        }

        Write-Success "ONNX Runtime native import passed"
        Write-FileLog -Path $LogPath -Text "ONNX Runtime native import passed after VC++ runtime repair"
    }

    try {
        $ts = (Get-Date).ToString("yyyyMMdd-HHmmss")
        $installLog = Join-Path $logsDir "backend_install_${ts}.log"
        Write-FileLog -Path $installLog -Text "========== Backend install/update started =========="
        Write-FileLog -Path $installLog -Text "Repo: $($Config.BackendRepo)"
        Write-FileLog -Path $installLog -Text "Branch: $($Config.BackendBranch)"
        Write-FileLog -Path $installLog -Text "RepoDir: $repoDir"
        Write-FileLog -Path $installLog -Text "Port: $appPort"
        $oldGoodBackend = Get-DeploymentComponentCurrent -Config $Config -Component "backend"
        if ([string]::IsNullOrWhiteSpace($oldGoodBackend) -and (Test-Path (Join-Path $repoDir ".git"))) {
            $oldGoodBackend = Get-GitHead -RepoDir $repoDir
        }

        $backendFingerprint = Get-BackendDeploymentFingerprint -Config $Config -Secrets $Secrets
        $savedBackendFingerprint = Get-SavedComponentFingerprint -Config $Config -Component "backend"
        $backendConfigChanged = ($savedBackendFingerprint -ne $backendFingerprint)

        # --- 0. Check Git before stopping a healthy existing service ---
        # Service is stopped only when a real backend update is required.

        # --- 1. Clone or hard-reset backend repo ---
        if (Test-Path (Join-Path $repoDir ".git")) {
            Write-Host "    Checking Git/config for backend update..." -ForegroundColor Gray
            Write-FileLog -Path $installLog -Text "Repo exists, checking remote HEAD and deployment configuration"
            Push-Location $repoDir
            try {
                $currentOrigin = (& git remote get-url origin 2>$null | Select-Object -First 1)
                if ("$currentOrigin".Trim() -ne "$($Config.BackendRepo)".Trim()) {
                    Write-Host "    Backend repository URL changed; updating Git origin..." -ForegroundColor Gray
                    Invoke-BackendLoggedCommand -LogPath $installLog -StepName "git remote set-url" -Command { git remote set-url origin $Config.BackendRepo }
                    $backendConfigChanged = $true
                }

                Invoke-BackendLoggedCommand -LogPath $installLog -StepName "git fetch" -Command { git fetch --prune origin "+refs/heads/$($Config.BackendBranch):refs/remotes/origin/$($Config.BackendBranch)" }

                $localHead = (& git rev-parse HEAD 2>$null | Select-Object -First 1).Trim()
                $remoteHead = (& git rev-parse "origin/$($Config.BackendBranch)" 2>$null | Select-Object -First 1).Trim()

                if ($localHead -eq $remoteHead -and (Test-ComponentInstalled -Config $Config -Component "backend") -and -not $backendConfigChanged) {
                    Write-Success "Backend code and deployment configuration are already current: $localHead"
                    Register-SuccessfulComponentDeployment -Config $Config -Component "backend" -Commit $localHead

                    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
                    if ($svc -and $svc.Status -eq 'Stopped') {
                        Start-Service -Name $svcName -ErrorAction SilentlyContinue
                    }
                    return $true
                }

                if ($localHead -eq $remoteHead -and $backendConfigChanged) {
                    Write-Host "    Backend Git is unchanged, but DB/runtime configuration changed; regenerating .env and restarting backend." -ForegroundColor Cyan
                    $script:deploymentConfigChanged = $true
                }

                Invoke-BackendLoggedCommand -LogPath $installLog -StepName "git reset" -Command { git reset --hard "origin/$($Config.BackendBranch)" }
                Invoke-BackendLoggedCommand -LogPath $installLog -StepName "git clean" -Command { git clean -fd }
            } finally {
                Pop-Location
            }
        } else {
            Write-Host "    Cloning repo..." -ForegroundColor Gray
            Write-FileLog -Path $installLog -Text "Repo missing or incomplete, cloning fresh"
            if (Test-Path $repoDir) {
                Remove-PathStrict -Path $repoDir -LogPath $installLog
            }
            New-Item -Path $appDir -ItemType Directory -Force | Out-Null
            Invoke-BackendLoggedCommand -LogPath $installLog -StepName "git clone" -Command { git clone --branch $Config.BackendBranch $Config.BackendRepo $repoDir }
            if (-not (Test-Path (Join-Path $repoDir ".git"))) {
                throw "Git clone completed but .git folder is missing: $repoDir"
            }
        }

        # A real backend change is being applied; now stop its runtime.
        Stop-BackendRuntime -ServiceNames @($svcName) -AppDir $appDir -RepoDir $repoDir -LogPath $installLog

        # --- 2. Reuse virtual environment on update; create only when missing ---
        $venvDir = Join-Path $repoDir "venv"
        $pythonExe = Join-Path $venvDir "Scripts\python.exe"

        if (-not (Test-Path $pythonExe)) {
            Write-Host "    Backend venv not found. Creating virtual environment..." -ForegroundColor Gray
            $creator = Get-BackendPythonCreator -LogPath $installLog
            Push-Location $repoDir
            try {
                $creatorFile = $creator.File
                $creatorArgs = @()
                $creatorArgs += $creator.Args
                $creatorArgs += @("-m", "venv", "venv")
                Write-FileLog -Path $installLog -Text "Creating venv command: $creatorFile $($creatorArgs -join ' ')"
                & $creatorFile @creatorArgs 2>&1 | Add-FileLog -Path $installLog
                if ($LASTEXITCODE -ne 0) {
                    throw "Virtual environment creation failed with exit code $LASTEXITCODE"
                }
            } finally {
                Pop-Location
            }
        }
        else {
            Write-Success "Backend update mode: existing venv kept"
            Write-FileLog -Path $installLog -Text "Existing backend venv reused"
        }

        if (-not (Test-Path $pythonExe)) {
            throw "Virtual environment is unavailable: $pythonExe"
        }

        # --- 3. Verify venv python and install dependencies ---
        Write-Host "    Verifying venv python.exe..." -ForegroundColor Gray
        $venvCheck = & $pythonExe -c "import sys; print('VENV_OK'); print(sys.executable); print(sys.version)" 2>&1
        Write-FileLog -Path $installLog -Text "Venv check output: $($venvCheck -join ' | ')"
        $venvCheckText = $venvCheck -join " | "
        if ($LASTEXITCODE -ne 0 -or $venvCheckText -notmatch "VENV_OK") {
            throw "Venv python.exe check failed: $venvCheckText"
        }

        Write-Host "    Installing dependencies..." -ForegroundColor Gray
        Invoke-BackendLoggedCommand -LogPath $installLog -StepName "pip bootstrap" -Command { & $pythonExe -m pip install --upgrade pip setuptools wheel }
        Invoke-BackendLoggedCommand -LogPath $installLog -StepName "pip install requirements" -Command { & $pythonExe -m pip install --no-cache-dir -r (Join-Path $repoDir "requirements.txt") }

        # Native ONNX Runtime on Windows requires the Microsoft Visual C++ runtime.
        # Verify it now, repair the runtime automatically if needed, and fail before service creation if it still cannot load.
        Repair-OnnxWindowsRuntime -PythonExe $pythonExe -LogPath $installLog

        # --- 4. Generate .env file before app import verification ---
        Write-Host "    Generating .env file..." -ForegroundColor Gray
        $mediaStoragePath = Initialize-MediaStorage -Config $Config
        $envMediaStoragePath = Convert-ToEnvPath -Path $mediaStoragePath
        Write-Host "    Media storage: $mediaStoragePath" -ForegroundColor Gray
        Write-FileLog -Path $installLog -Text "Media storage path: $mediaStoragePath"
        # Preserve SECRET_KEY directly from the persistent .env on updates/rollbacks.
        $generatedKey = $null
        $existingEnvPath = Join-Path $repoDir ".env"
        if (Test-Path $existingEnvPath) {
            $oldSecretLine = Get-Content $existingEnvPath -ErrorAction SilentlyContinue |
                Where-Object { $_ -match '^\s*SECRET_KEY\s*=' } |
                Select-Object -First 1
            if ($oldSecretLine) {
                $generatedKey = (($oldSecretLine -split '=', 2)[1]).Trim().Trim('"').Trim("'")
                if (-not [string]::IsNullOrWhiteSpace($generatedKey)) {
                    Write-FileLog -Path $installLog -Text "SECRET_KEY preserved from persistent backend .env"
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($generatedKey)) {
            $rawKey = & $pythonExe -c "import secrets; print(secrets.token_hex(32))" 2>&1
            $generatedKey = ($rawKey | Select-Object -Last 1).Trim()
            if ([string]::IsNullOrWhiteSpace($generatedKey) -or $generatedKey.Length -lt 16) {
                $generatedKey = [System.Guid]::NewGuid().ToString("N") + [System.Guid]::NewGuid().ToString("N")
            }
            Write-FileLog -Path $installLog -Text "SECRET_KEY generated for first backend install"
        }

        $envDbUser   = $Secrets.db.user.Replace('\', '\\').Replace('"', '\"')
        $envDbPass   = $Secrets.db.password.Replace('\', '\\').Replace('"', '\"')
        $envDbHost   = $Secrets.db.host.Replace('\', '\\').Replace('"', '\"')
        $envDbName   = $Secrets.db.name.Replace('\', '\\').Replace('"', '\"')
        $envDbPort   = [int]$Secrets.db.port
        $envFrontendUrl = (Get-FrontendPublicUrl -Config $Config).Replace('\', '\\').Replace('"', '\"')

        $envContent = @"
DB_ENGINE=mysql
DB_HOST=$envDbHost
DB_PORT=$envDbPort
DB_USER="$envDbUser"
DB_PASSWORD="$envDbPass"
DB_NAME=$envDbName

SECRET_KEY=$generatedKey
ALGORITHM=HS256
ACCESS_TOKEN_EXPIRE_MINUTES=30

FRONTEND_URL="$envFrontendUrl"
RESET_EXPIRE_MINUTES=15
MFA_ISSUER_NAME="ESS Face"

MEDIA_STORAGE_PATH="$envMediaStoragePath"
"@
        Set-Content -Path (Join-Path $repoDir ".env") -Value $envContent -Force -Encoding UTF8
        Write-FileLog -Path $installLog -Text ".env generated with SECRET_KEY ($($generatedKey.Length) chars)"

        # --- 5. Verify dependencies and app import before creating service ---
        Write-Host "    Verifying backend dependencies..." -ForegroundColor Gray
        $dependencyCheck = & $pythonExe -X faulthandler -c "import fastapi, uvicorn, sqlalchemy, pymysql; print('BACKEND_DEPS_OK')" 2>&1
        Write-FileLog -Path $installLog -Text "Dependency check output: $($dependencyCheck -join ' | ')"
        $dependencyCheckText = $dependencyCheck -join " | "
        if ($LASTEXITCODE -ne 0 -or $dependencyCheckText -notmatch "BACKEND_DEPS_OK") {
            throw "Backend dependency verification failed: $dependencyCheckText"
        }

        Write-Host "    Verifying FastAPI app import..." -ForegroundColor Gray
        Push-Location $repoDir
        try {
            $appImportCheck = & $pythonExe -X faulthandler -c "import app.main; print('APP_IMPORT_OK')" 2>&1
            Write-FileLog -Path $installLog -Text "App import check output: $($appImportCheck -join ' | ')"
            $appImportCheckText = $appImportCheck -join " | "
            if ($LASTEXITCODE -ne 0 -or $appImportCheckText -notmatch "APP_IMPORT_OK") {
                throw "FastAPI app import verification failed: $appImportCheckText"
            }
        } finally {
            Pop-Location
        }

        # --- 6. Create service runner ---
        $runnerScript = Join-Path $appDir "backend-run.ps1"
        $runnerContent = @'
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
$env:PYTHONUNBUFFERED = "1"
$env:PYTHONFAULTHANDLER = "1"

$backendDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoDir    = Join-Path $backendDir "repo"
$venvDir    = Join-Path $repoDir "venv"
$pythonExe  = Join-Path $venvDir "Scripts\python.exe"
$logsDir    = Join-Path (Join-Path (Split-Path $backendDir -Parent) "logs") "backend"
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }

$svcTs = (Get-Date).ToString("yyyyMMdd-HHmmss")
$serviceLog = Join-Path $logsDir "backend_service_${svcTs}.log"
$stdoutLog = Join-Path $logsDir "backend_stdout_${svcTs}.log"
$stderrLog = Join-Path $logsDir "backend_stderr_${svcTs}.log"

"========== Service started at $(Get-Date) ==========" | Out-File -FilePath $serviceLog -Encoding ASCII

if (-not (Test-Path $pythonExe)) {
    "FATAL: python.exe not found at $pythonExe" | Out-File -FilePath $serviceLog -Append
    Start-Sleep -Seconds 5
    exit 1
}

try {
    Set-Location -Path $repoDir -ErrorAction Stop
} catch {
    "FATAL: could not cd to $repoDir : $_" | Out-File -FilePath $serviceLog -Append
    Start-Sleep -Seconds 5
    exit 1
}

"    Working directory: $(Get-Location)" | Out-File -FilePath $serviceLog -Append
"    Starting Python: $pythonExe" | Out-File -FilePath $serviceLog -Append
"    Uvicorn: -X faulthandler -u -m uvicorn app.main:app --host 0.0.0.0 --port __BACKEND_PORT__ --no-use-colors" | Out-File -FilePath $serviceLog -Append
"    Stdout log: $stdoutLog" | Out-File -FilePath $serviceLog -Append
"    Stderr log: $stderrLog" | Out-File -FilePath $serviceLog -Append

$importCheck = & $pythonExe -X faulthandler -c "import uvicorn; print('UVICORN_OK')" 2>&1
"    Import check: $($importCheck -join ' | ')" | Out-File -FilePath $serviceLog -Append
$importCheckText = $importCheck -join " | "
if ($LASTEXITCODE -ne 0 -or $importCheckText -notmatch "UVICORN_OK") {
    "FATAL: uvicorn import failed: $importCheckText" | Out-File -FilePath $serviceLog -Append
    Start-Sleep -Seconds 5
    exit 1
}

try {
    $p = Start-Process -FilePath $pythonExe `
        -ArgumentList @("-X", "faulthandler", "-u", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "__BACKEND_PORT__", "--no-use-colors") `
        -WorkingDirectory $repoDir `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog `
        -NoNewWindow -Wait -PassThru
    "    Uvicorn exit code: $($p.ExitCode)" | Out-File -FilePath $serviceLog -Append
}
catch {
    "FATAL: uvicorn launch threw: $_" | Out-File -FilePath $serviceLog -Append
}

"========== Service STOPPED at $(Get-Date) ==========" | Out-File -FilePath $serviceLog -Append
'@
        $runnerContent = $runnerContent.Replace('__BACKEND_PORT__', $appPort)
        Set-Content -Path $runnerScript -Value $runnerContent -Force -Encoding UTF8
        Write-FileLog -Path $installLog -Text "Runner script written to $runnerScript"

        # --- 7. Create backend service only on first install; reuse it on update ---
        $powershellExe = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
        $paramStr = "-ExecutionPolicy Bypass -File `"$runnerScript`""

        Write-FileLog -Path $installLog -Text "--- Service registration check ---"
        Write-FileLog -Path $installLog -Text "Service name: $svcName"

        $existingBackendSvc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($existingBackendSvc) {
            Write-Success "Backend update mode: existing service registration kept"
            Write-FileLog -Path $installLog -Text "Backend update mode: existing service registration preserved"
        }
        else {
            Write-Host "    Backend service not found. First-install mode: creating service..." -ForegroundColor Gray
            servy-cli install --name="$svcName" --path="$powershellExe" --params="$paramStr" 2>&1 | Add-FileLog -Path $installLog
            if ($LASTEXITCODE -ne 0) {
                throw "servy-cli install failed with exit code $LASTEXITCODE"
            }

            if (-not (Get-Service -Name $svcName -ErrorAction SilentlyContinue)) {
                throw "Service '$svcName' was not created by servy-cli"
            }

            sc.exe config "$svcName" start= delayed-auto 2>&1 | Add-FileLog -Path $installLog
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to configure service '$svcName' for automatic startup"
            }
            sc.exe failure "$svcName" reset= 86400 actions= restart/5000/restart/15000/restart/60000 2>&1 | Add-FileLog -Path $installLog
            sc.exe failureflag "$svcName" 1 2>&1 | Add-FileLog -Path $installLog

            Write-Success "Backend install mode: service created"
        }

        # --- 8. Start service and verify health endpoint ---
        Write-Host "    Starting backend service to verify..." -ForegroundColor Gray
        Write-FileLog -Path $installLog -Text "Starting backend service..."
        Start-Service -Name $svcName -ErrorAction Stop
        Write-FileLog -Path $installLog -Text "Start-Service command issued"

        $healthUrl = "http://127.0.0.1:$appPort/api/v1/health"
        $healthOk = $false
        for ($i = 1; $i -le 15; $i++) {
            Start-Sleep -Seconds 2
            $svcStatus = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            Write-FileLog -Path $installLog -Text "Health poll $i/15: service status=$($svcStatus.Status) url=$healthUrl"

            if (-not $svcStatus -or $svcStatus.Status -ne 'Running') {
                continue
            }

            try {
                $healthResponse = Invoke-WebRequest -Uri $healthUrl -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
                if ($healthResponse.StatusCode -eq 200) {
                    $healthOk = $true
                    Write-Success "Backend health check passed (HTTP 200)"
                    Write-FileLog -Path $installLog -Text "Health check OK: status=$($healthResponse.StatusCode) body=$($healthResponse.Content)"
                    break
                }
            } catch {
                Write-FileLog -Path $installLog -Text "Health poll $i failed: $_"
            }
        }

        if (-not $healthOk) {
            Write-FileLog -Path $installLog -Text "Backend health check failed after polling"

            foreach ($pattern in @("backend_service_*.log", "backend_stdout_*.log", "backend_stderr_*.log")) {
                $latest = Get-ChildItem -Path $logsDir -Filter $pattern -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($latest) {
                    Write-FileLog -Path $installLog -Text "--- Last 80 lines of $($latest.Name) ---"
                    Get-Content $latest.FullName -ErrorAction SilentlyContinue | Select-Object -Last 80 | ForEach-Object {
                        Write-FileLog -Path $installLog -Text $_
                    }
                    Write-FileLog -Path $installLog -Text "--- end $($latest.Name) ---"
                }
            }

            throw "Backend service did not pass health check: $healthUrl"
        }

        Write-Host "    Backend service verified" -ForegroundColor Gray
        Write-FileLog -Path $installLog -Text "Backend verification complete"

        $activeBackendCommit = (& git -C $repoDir rev-parse HEAD 2>$null | Select-Object -First 1)
        if ($activeBackendCommit) {
            $activeBackendCommit = "$activeBackendCommit".Trim()
            Register-SuccessfulComponentDeployment -Config $Config -Component "backend" -Commit $activeBackendCommit
            Write-Success "Backend active version: $activeBackendCommit"
            Write-FileLog -Path $installLog -Text "Backend active version: $activeBackendCommit"
        }

        Save-ComponentFingerprint -Config $Config -Component "backend" -Fingerprint $backendFingerprint
        if ($backendConfigChanged) { $script:deploymentConfigChanged = $true }
        $script:installedComponents += "backend"
        Write-Log "Backend installed/updated successfully on port $appPort"
        return $true

    } catch {
        $backendInstallError = $_
        Write-Err "Backend setup failed: $backendInstallError"
        Write-Log "Backend installation failed: $backendInstallError" -Level "ERROR"
        if (-not [string]::IsNullOrWhiteSpace($oldGoodBackend)) {
            Write-Warn "Backend candidate failed. Restoring known-good commit: $oldGoodBackend"
            Invoke-BackendRollbackToCommit -Config $Config -Commit $oldGoodBackend | Out-Null
        } else {
            Write-Warn "Failed first backend install was not recorded as a deployment version."
        }
        return $false
    }
}

function Install-Caddy {
    param($Config)
    Initialize-InstallRoot -Config $Config
    $caddySvcName = Get-DeployServiceName -Config $Config -Component "caddy"
    Write-Step "Installing Caddy"

    if ($script:dryRun) {
        Write-Warn "[DRY-RUN] Would install Caddy proxy on port $($Config.CaddyPort)"
        return $true
    }

    try {
        $logsDir = Join-Path (Join-Path $Config.InstallRoot "logs") "caddy"
        New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
        $ts = (Get-Date).ToString("yyyyMMdd-HHmmss")
        $caddyInstallLog = Join-Path $logsDir "caddy_install_${ts}.log"

        Write-Host "    Target port: $($Config.CaddyPort)" -ForegroundColor Gray
        Write-Host "    Install log: $caddyInstallLog" -ForegroundColor Gray
        Write-FileLog -Path $caddyInstallLog -Text "========== Caddy install started =========="
        Write-FileLog -Path $caddyInstallLog -Text "Target port: $($Config.CaddyPort)"
        Write-FileLog -Path $caddyInstallLog -Text "Timestamp: $ts"

        # Both Caddy ports are fixed. Availability is checked after the old
        # service is stopped so an existing deployment does not block itself.
        Write-Host "      Admin API: $($Config.CaddyAdminPort) (fixed)" -ForegroundColor Green
        Write-FileLog -Path $caddyInstallLog -Text "Fixed admin port: $($Config.CaddyAdminPort)"
        Write-Host "      Proxy:      $($Config.CaddyPort) (fixed)" -ForegroundColor Green
        Write-FileLog -Path $caddyInstallLog -Text "Fixed proxy port: $($Config.CaddyPort)"

        # -- Port summary --
        $adminDisplay = $Config.CaddyAdminPort
        $proxyDisplay = $Config.CaddyPort
        Write-Host ""
        Write-Host "    +----------------------------------+" -ForegroundColor Cyan
        Write-Host "    |  Caddy service ports:             |" -ForegroundColor Cyan
        Write-Host "    |    Proxy  (users visit this): $proxyDisplay" -ForegroundColor Green
        Write-Host "    |    Admin  (Caddy internal): $adminDisplay" -ForegroundColor Gray
        Write-Host "    +----------------------------------+" -ForegroundColor Cyan
        Write-Host ""
        Write-FileLog -Path $caddyInstallLog -Text "Ports: proxy=$proxyDisplay, admin=$adminDisplay"

        $caddyDir = Join-Path $Config.InstallRoot "caddy"
        New-Item -Path $caddyDir -ItemType Directory -Force | Out-Null
        $caddyExe = Join-Path $caddyDir "caddy.exe"
        Initialize-CaddyLocalGit -Config $Config
        $oldGoodCaddy = Get-DeploymentComponentCurrent -Config $Config -Component "caddy"
        if ([string]::IsNullOrWhiteSpace($oldGoodCaddy)) {
            $oldGoodCaddy = Get-GitHead -RepoDir $caddyDir
        }

        if (-not (Test-Path $caddyExe)) {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Write-Host "    Downloading Caddy..." -ForegroundColor Gray
            Invoke-WebRequest -Uri "https://caddyserver.com/api/download?os=windows&arch=amd64" -OutFile $caddyExe -UseBasicParsing 2>&1 |
                Add-FileLog -Path $caddyInstallLog
            if (-not (Test-Path $caddyExe)) { throw "Caddy download failed" }
            Write-Log "Caddy downloaded from caddyserver.com"
        } else {
            Write-Host "    Caddy already downloaded, skipping." -ForegroundColor Gray
        }

        # Use custom routes from config if available, otherwise defaults
        $caddyRoutes = @()
        if ($Config.CaddyRoutes -and @($Config.CaddyRoutes).Count -gt 0) {
            $caddyRoutes = @($Config.CaddyRoutes)
        } else {
            $caddyRoutes = @(
                [PSCustomObject]@{ Path = "$($Config.ApiPrefix)/*"; Target = "127.0.0.1:$($Config.BackendPort)" }
                [PSCustomObject]@{ Path = "/*";                    Target = "127.0.0.1:$($Config.FrontendPort)" }
            )
        }

        $caddyfilePath = Join-Path $caddyDir "Caddyfile"
        $caddyfileLines = @()
        $caddyfileLines += ":`{`$CADDY_PORT`} {"
        foreach ($r in $caddyRoutes) {
            $caddyfileLines += "    handle $($r.Path) {"
            $caddyfileLines += "        reverse_proxy $($r.Target)"
            $caddyfileLines += "    }"
        }
        $caddyfileLines += "    header {"
        $caddyfileLines += '        X-Frame-Options "SAMEORIGIN"'
        $caddyfileLines += '        X-Content-Type-Options "nosniff"'
        $caddyfileLines += '        X-XSS-Protection "1; mode=block"'
        $caddyfileLines += "    }"
        $caddyfileLines += "}"
        $caddyfileContent = $caddyfileLines -join "`n"
        Set-Content -Path $caddyfilePath -Value $caddyfileContent -Force
        # Log the full Caddyfile so you can verify port and routes
        Write-FileLog -Path $caddyInstallLog -Text "Caddyfile written to $caddyfilePath"
        Write-FileLog -Path $caddyInstallLog -Text "--- Caddyfile content (port via `$CADDY_PORT env var) ---"
        foreach ($_line in $caddyfileLines) {
            Write-FileLog -Path $caddyInstallLog -Text $_line
        }
        Write-FileLog -Path $caddyInstallLog -Text "--- end Caddyfile ---"

        # -- Write runner script --
        $runnerScript = Join-Path $caddyDir "caddy-run.ps1"
        $defaultProxyPort = $Config.CaddyPort
        $adminPort = $Config.CaddyAdminPort
        # Windows PowerShell 5.1-safe embedded Caddy runner template.
        # The runner body is Base64-encoded so the outer deployment script
        # does not need nested here-strings or quoted code arrays.
        $runnerTemplateBase64 = "JGNhZGR5RGlyID0gU3BsaXQtUGF0aCAtUGFyZW50ICRNeUludm9jYXRpb24uTXlDb21tYW5kLlBhdGgKJGNhZGR5RXhlID0gSm9pbi1QYXRoICRjYWRkeURpciAiY2FkZHkuZXhlIgokY2FkZHlmaWxlID0gSm9pbi1QYXRoICRjYWRkeURpciAiQ2FkZHlmaWxlIgokbG9nc0RpciA9IEpvaW4tUGF0aCAoSm9pbi1QYXRoIChTcGxpdC1QYXRoICRjYWRkeURpciAtUGFyZW50KSAibG9ncyIpICJjYWRkeSIKaWYgKC1ub3QgKFRlc3QtUGF0aCAkbG9nc0RpcikpIHsKICAgIE5ldy1JdGVtIC1JdGVtVHlwZSBEaXJlY3RvcnkgLVBhdGggJGxvZ3NEaXIgLUZvcmNlIHwgT3V0LU51bGwKfQoKJHN2Y1RzID0gKEdldC1EYXRlKS5Ub1N0cmluZygieXl5eU1NZGQtSEhtbXNzIikKJGNhZGR5TG9nID0gSm9pbi1QYXRoICRsb2dzRGlyICJjYWRkeV9zZXJ2aWNlXyR7c3ZjVHN9LmxvZyIKJHN0YXR1c0ZpbGUgPSBKb2luLVBhdGggJGNhZGR5RGlyICJjYWRkeS1wb3J0cy5qc29uIgpSZW1vdmUtSXRlbSAtUGF0aCAkc3RhdHVzRmlsZSAtRm9yY2UgLUVycm9yQWN0aW9uIFNpbGVudGx5Q29udGludWUKCmZ1bmN0aW9uIFRlc3QtUG9ydEluVXNlIHsKICAgIHBhcmFtKFtpbnRdJFBvcnQpCgogICAgJHRjcCA9ICRudWxsCiAgICB0cnkgewogICAgICAgICR0Y3AgPSBOZXctT2JqZWN0IFN5c3RlbS5OZXQuU29ja2V0cy5UY3BDbGllbnQKICAgICAgICAkaWFyID0gJHRjcC5CZWdpbkNvbm5lY3QoIjEyNy4wLjAuMSIsICRQb3J0LCAkbnVsbCwgJG51bGwpCiAgICAgICAgJGNvbm5lY3RlZCA9ICRpYXIuQXN5bmNXYWl0SGFuZGxlLldhaXRPbmUoNTAwKQoKICAgICAgICBpZiAoJGNvbm5lY3RlZCAtYW5kICR0Y3AuQ29ubmVjdGVkKSB7CiAgICAgICAgICAgICR0Y3AuRW5kQ29ubmVjdCgkaWFyKQogICAgICAgICAgICByZXR1cm4gJHRydWUKICAgICAgICB9CiAgICB9CiAgICBjYXRjaCB7CiAgICB9CiAgICBmaW5hbGx5IHsKICAgICAgICBpZiAoJHRjcCkgewogICAgICAgICAgICAkdGNwLkNsb3NlKCkKICAgICAgICB9CiAgICB9CgogICAgcmV0dXJuICRmYWxzZQp9CgoiPT09PT09PT09PSBTZXJ2aWNlIHN0YXJ0ZWQgYXQgJChHZXQtRGF0ZSkgPT09PT09PT09PSIgfCBPdXQtRmlsZSAtRmlsZVBhdGggJGNhZGR5TG9nIC1FbmNvZGluZyBBU0NJSQoKJGFkbWluUG9ydCA9IF9fQ0FERFlfQURNSU5fUE9SVF9fCmlmIChUZXN0LVBvcnRJblVzZSAtUG9ydCAkYWRtaW5Qb3J0KSB7CiAgICAiRkFUQUw6IENhZGR5IGFkbWluIEFQSSBwb3J0ICRhZG1pblBvcnQgaXMgYWxyZWFkeSBpbiB1c2UuIFNlcnZpY2UgY2Fubm90IHN0YXJ0LiIgfCBPdXQtRmlsZSAtRmlsZVBhdGggJGNhZGR5TG9nIC1BcHBlbmQKICAgIGV4aXQgMQp9CgokZW52OkNBRERZX0FETUlOID0gIjEyNy4wLjAuMTokYWRtaW5Qb3J0IgoiQWRtaW4gcG9ydDogJGFkbWluUG9ydCIgfCBPdXQtRmlsZSAtRmlsZVBhdGggJGNhZGR5TG9nIC1BcHBlbmQKCiRwcm94eVBvcnQgPSBfX0RFRkFVTFRfUFJPWFlfUE9SVF9fCmlmIChUZXN0LVBvcnRJblVzZSAtUG9ydCAkcHJveHlQb3J0KSB7CiAgICAiRkFUQUw6IENhZGR5IHByb3h5IHBvcnQgJHByb3h5UG9ydCBpcyBhbHJlYWR5IGluIHVzZS4gU2VydmljZSBjYW5ub3Qgc3RhcnQuIiB8IE91dC1GaWxlIC1GaWxlUGF0aCAkY2FkZHlMb2cgLUFwcGVuZAogICAgZXhpdCAxCn0KCiRlbnY6Q0FERFlfUE9SVCA9ICIkcHJveHlQb3J0IgoiUHJveHkgcG9ydDogJHByb3h5UG9ydCIgfCBPdXQtRmlsZSAtRmlsZVBhdGggJGNhZGR5TG9nIC1BcHBlbmQKCkB7CiAgICBhZG1pbiA9ICRhZG1pblBvcnQKICAgIHByb3h5ID0gJHByb3h5UG9ydAp9IHwgQ29udmVydFRvLUpzb24gfCBPdXQtRmlsZSAtRmlsZVBhdGggJHN0YXR1c0ZpbGUgLUZvcmNlCgoiU3RhcnRpbmcgQ2FkZHkuLi4iIHwgT3V0LUZpbGUgLUZpbGVQYXRoICRjYWRkeUxvZyAtQXBwZW5kCiYgJGNhZGR5RXhlIHJ1biAtLWNvbmZpZyAkY2FkZHlmaWxlIDI+JjEgfCBPdXQtRmlsZSAtRmlsZVBhdGggJGNhZGR5TG9nIC1BcHBlbmQKIj09PT09PT09PT0gU2VydmljZSBTVE9QUEVEIGF0ICQoR2V0LURhdGUpID09PT09PT09PT0iIHwgT3V0LUZpbGUgLUZpbGVQYXRoICRjYWRkeUxvZyAtQXBwZW5kCg=="
        $runnerContent = [System.Text.Encoding]::UTF8.GetString(
            [System.Convert]::FromBase64String($runnerTemplateBase64)
        )
        $runnerContent = $runnerContent.Replace("__DEFAULT_PROXY_PORT__", [string]$defaultProxyPort)
        $runnerContent = $runnerContent.Replace("__CADDY_ADMIN_PORT__", [string]$adminPort)
        Set-Content -Path $runnerScript -Value $runnerContent -Force
        Write-FileLog -Path $caddyInstallLog -Text "Runner script written to $runnerScript"
        Write-FileLog -Path $caddyInstallLog -Text "--- runner script (default proxy port: $defaultProxyPort) ---"
        Write-FileLog -Path $caddyInstallLog -Text $runnerContent
        Write-FileLog -Path $caddyInstallLog -Text "--- end runner script ---"

        # Log Caddy version (helps diagnose --admin / admin off support)
        try {
            $versionOutput = & $caddyExe version 2>&1 | Out-String
            Write-FileLog -Path $caddyInstallLog -Text "Caddy version: $versionOutput"
            Write-Host "    Caddy version: $($versionOutput.Trim())" -ForegroundColor Gray
        } catch {
            Write-FileLog -Path $caddyInstallLog -Text "Could not get Caddy version"
        }

        # ---- Validate Caddyfile syntax BEFORE creating the service ----
        # Set env vars so Caddy can resolve {$CADDY_PORT} and {$CADDY_ADMIN}
        $env:CADDY_PORT = "$($Config.CaddyPort)"
        $env:CADDY_ADMIN = "127.0.0.1:$($Config.CaddyAdminPort)"
        Write-Host "    Validating Caddyfile syntax..." -ForegroundColor Gray
        Write-FileLog -Path $caddyInstallLog -Text "--- Caddyfile validation (CADDY_PORT=$env:CADDY_PORT, CADDY_ADMIN=$env:CADDY_ADMIN) ---"
        try {
            $validationOutput = & $caddyExe validate --config "$caddyfilePath" 2>&1 | Out-String
            Write-FileLog -Path $caddyInstallLog -Text "Validation result: $validationOutput"
            Write-Host "    Caddyfile validation: OK" -ForegroundColor Green
        } catch {
            $validationError = $_
            $validationDetail = & $caddyExe validate --config "$caddyfilePath" 2>&1 | Out-String
            Write-FileLog -Path $caddyInstallLog -Text "VALIDATION FAILED: $validationError"
            Write-FileLog -Path $caddyInstallLog -Text "Validation stderr: $validationDetail"
            Write-Err "Caddyfile validation FAILED:"
            Write-Host "    $validationDetail" -ForegroundColor Red
        }
        Remove-Item Env:\CADDY_PORT -ErrorAction SilentlyContinue
        Remove-Item Env:\CADDY_ADMIN -ErrorAction SilentlyContinue
        Write-FileLog -Path $caddyInstallLog -Text "--- end validation ---"

        # Stop only OUR Caddy service to release its ports.
        # This does NOT affect other Caddy instances from other deployments/apps
        Write-Host "    Stopping old $caddySvcName service (if any)..." -ForegroundColor Gray
        Write-FileLog -Path $caddyInstallLog -Text "Stopping old $caddySvcName service..."
        Stop-Service -Name $caddySvcName -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        # Verify it stopped
        $oldSvc = Get-Service -Name $caddySvcName -ErrorAction SilentlyContinue
        if ($oldSvc -and $oldSvc.Status -ne 'Stopped') {
            Write-Warn "Old $caddySvcName service did not stop gracefully. Forcing..."
            Write-FileLog -Path $caddyInstallLog -Text "WARN: Old service not stopped, status=$($oldSvc.Status)"
            Stop-Service -Name $caddySvcName -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 3
        }
        Write-FileLog -Path $caddyInstallLog -Text "Old service stopped."

        # ---- Fixed port checks after stopping our existing Caddy service ----
        Start-Sleep -Seconds 1
        $fixedPortsAvailable = $true
        foreach ($portCheck in @(
            [PSCustomObject]@{ Name = "Caddy proxy"; Port = [int]$Config.CaddyPort }
            [PSCustomObject]@{ Name = "Caddy admin API"; Port = [int]$Config.CaddyAdminPort }
        )) {
            if (Test-PortInUse -Port $portCheck.Port) {
                $msg = "$($portCheck.Name) port $($portCheck.Port) is already in use. Caddy installation cannot continue."
                Write-Err $msg
                Write-FileLog -Path $caddyInstallLog -Text "ERROR: $msg"
                $fixedPortsAvailable = $false
            }
        }
        if (-not $fixedPortsAvailable) {
            throw "One or more fixed Caddy ports are already in use."
        }
        Write-Success "Fixed Caddy ports are available: proxy=$($Config.CaddyPort), admin=$($Config.CaddyAdminPort)"
        Write-FileLog -Path $caddyInstallLog -Text "Fixed ports available: proxy=$($Config.CaddyPort), admin=$($Config.CaddyAdminPort)"

        # Runtime log is generated by the runner script at each start
        Write-Host "    Runner script: $runnerScript" -ForegroundColor Gray
        Write-FileLog -Path $caddyInstallLog -Text "Runner script: $runnerScript"

        # Build the PowerShell runner command that uses the configured fixed
        # proxy/admin ports and creates a timestamped log file.
        $powershellExe = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
        $paramStr = "-ExecutionPolicy Bypass -File `"$runnerScript`""

        # Log the FULL service command for debugging
        Write-FileLog -Path $caddyInstallLog -Text "--- Service creation ---"
        Write-FileLog -Path $caddyInstallLog -Text "Service name: $caddySvcName"
        Write-FileLog -Path $caddyInstallLog -Text "Executable: $powershellExe"
        Write-FileLog -Path $caddyInstallLog -Text "Parameters: $paramStr"
        Write-FileLog -Path $caddyInstallLog -Text "Runner script: $runnerScript"
        Write-FileLog -Path $caddyInstallLog -Text "Caddyfile: $caddyfilePath"

        # Keep the same service registration on update.
        $existingCaddySvc = Get-Service -Name $caddySvcName -ErrorAction SilentlyContinue
        if (-not $existingCaddySvc) {
            Write-Host "    First install: registering Caddy service..." -ForegroundColor Gray
            $installResult = servy-cli install --name="$caddySvcName" --path="$powershellExe" --params="$paramStr" 2>&1
            Write-FileLog -Path $caddyInstallLog -Text "servy-cli install output: $installResult"
            if (-not (Get-Service -Name $caddySvcName -ErrorAction SilentlyContinue)) {
                throw "Service '$caddySvcName' was not created by servy-cli"
            }
            sc.exe config $caddySvcName start= delayed-auto | Out-Null
            sc.exe failure $caddySvcName reset= 86400 actions= restart/5000/restart/15000/restart/60000 | Out-Null
            sc.exe failureflag $caddySvcName 1 | Out-Null
            Write-Success "Caddy service created"
        } else {
            Write-Success "Caddy update mode: existing service registration kept"
        }

        # ---- Start the Caddy service and verify it runs ----
        Write-Host "    Starting Caddy service..." -ForegroundColor Gray
        Write-FileLog -Path $caddyInstallLog -Text "Starting Caddy service..."
        try {
            Start-Service -Name $caddySvcName -ErrorAction Stop
            Write-Host "    Caddy service start command issued, waiting 5s for startup..." -ForegroundColor Gray
            Write-FileLog -Path $caddyInstallLog -Text "Start-Service command issued"
            Start-Sleep -Seconds 5

            $svcStatus = Get-Service -Name $caddySvcName -ErrorAction SilentlyContinue
            Write-FileLog -Path $caddyInstallLog -Text "Service status after 5s: $($svcStatus.Status)"

            if ($svcStatus.Status -eq 'Running') {
                Write-Success "Caddy service is RUNNING"
                Write-FileLog -Path $caddyInstallLog -Text "Caddy service is RUNNING"
            } else {
                Write-Warn "Caddy service status: $($svcStatus.Status) (not Running yet)"
                Write-FileLog -Path $caddyInstallLog -Text "WARN: Service status is $($svcStatus.Status)"
            }

            # ---- Check the runtime log for startup errors ----
            Start-Sleep -Seconds 2
            $latestLog = Get-ChildItem -Path $logsDir -Filter "caddy_service_*.log" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latestLog) {
                $logContent = Get-Content $latestLog.FullName -ErrorAction SilentlyContinue
                Write-FileLog -Path $caddyInstallLog -Text "--- Runtime log content (first 30 lines) ---"
                $lineCount = 0
                foreach ($_logLine in $logContent) {
                    $lineCount++
                    if ($lineCount -gt 30) {
                        Write-FileLog -Path $caddyInstallLog -Text "... (truncated, full log at $($latestLog.FullName))"
                        break
                    }
                    Write-FileLog -Path $caddyInstallLog -Text $_logLine
                    if ($_logLine -match '(?i)(error|fail|panic|refused|cannot|unable|conflict|bind)') {
                        Write-Host "    [LOG] $_logLine" -ForegroundColor Red
                    }
                }
                Write-FileLog -Path $caddyInstallLog -Text "--- end runtime log ---"
            } else {
                Write-Warn "Caddy runtime log not found yet"
                Write-FileLog -Path $caddyInstallLog -Text "WARN: No runtime log found in $logsDir"
            }

            # ---- Final fixed-port verification ----
            Start-Sleep -Seconds 3
            $portsFile = Join-Path $caddyDir "caddy-ports.json"
            $pollAttempts = 0
            while ($pollAttempts -lt 5 -and -not (Test-Path $portsFile)) {
                Start-Sleep -Seconds 2
                $pollAttempts++
            }
            if (Test-Path $portsFile) {
                try {
                    $portsData = Get-Content $portsFile -Raw -ErrorAction Stop | ConvertFrom-Json
                    Write-FileLog -Path $caddyInstallLog -Text "caddy-ports.json: proxy=$($portsData.proxy), admin=$($portsData.admin)"
                    if ([int]$portsData.proxy -ne [int]$Config.CaddyPort -or [int]$portsData.admin -ne [int]$Config.CaddyAdminPort) {
                        throw "Caddy reported unexpected ports: proxy=$($portsData.proxy), admin=$($portsData.admin)"
                    }
                } catch {
                    throw "Could not verify fixed Caddy ports from ${portsFile}: $_"
                }
            }

            if (-not (Test-PortInUse -Port $Config.CaddyPort)) {
                throw "Caddy proxy port $($Config.CaddyPort) is not listening after startup."
            }
            if (-not (Test-PortInUse -Port $Config.CaddyAdminPort)) {
                throw "Caddy admin API port $($Config.CaddyAdminPort) is not listening after startup."
            }

            Write-Success "Caddy is listening on fixed ports: proxy=$($Config.CaddyPort), admin=$($Config.CaddyAdminPort)"
            Write-FileLog -Path $caddyInstallLog -Text "VERIFIED: Caddy fixed ports proxy=$($Config.CaddyPort), admin=$($Config.CaddyAdminPort)"

            Write-Host "    Caddy is running (proxy=$($Config.CaddyPort), admin=$($Config.CaddyAdminPort))" -ForegroundColor Gray
        } catch {
            $startError = $_
            Write-Err "Failed to start Caddy service: $startError"
            Write-FileLog -Path $caddyInstallLog -Text "ERROR starting service: $startError"
            # Try to dump service status
            try {
                $svcInfo = sc.exe query $caddySvcName 2>&1 | Out-String
                Write-FileLog -Path $caddyInstallLog -Text "Service query: $svcInfo"
            } catch { }
            # Try to dump runtime log if it exists
            $latestErrLog = Get-ChildItem -Path $logsDir -Filter "caddy_service_*.log" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if ($latestErrLog) {
                $errLog = Get-Content $latestErrLog.FullName -ErrorAction SilentlyContinue | Select-Object -Last 20
                Write-FileLog -Path $caddyInstallLog -Text "--- Last 20 lines of runtime log ($($latestErrLog.Name)) ---"
                foreach ($_errLine in $errLog) {
                    Write-FileLog -Path $caddyInstallLog -Text $_errLine
                }
                Write-FileLog -Path $caddyInstallLog -Text "--- end ---"
            }
            throw $startError
        }

        $caddyCommit = Commit-CaddyLocalVersion -Config $Config -Message "Known-good Caddy configuration $ts"
        if ([string]::IsNullOrWhiteSpace($caddyCommit)) { throw "Could not create/read local Caddy Git commit." }
        Register-SuccessfulComponentDeployment -Config $Config -Component "caddy" -Commit $caddyCommit

        $script:installedComponents += "caddy"
        Write-Success "Caddy installed: proxy=$($Config.CaddyPort), admin=$($Config.CaddyAdminPort)"
        Write-Log "Caddy installed successfully: proxy=$($Config.CaddyPort), admin=$($Config.CaddyAdminPort)"
        return $true
    } catch {
        $caddyInstallError = $_
        Write-Err "Caddy setup failed: $caddyInstallError"
        Write-Log "Caddy installation failed: $caddyInstallError" -Level "ERROR"
        if (-not [string]::IsNullOrWhiteSpace($oldGoodCaddy)) {
            Write-Warn "Caddy candidate failed. Restoring known-good local Git commit: $oldGoodCaddy"
            Invoke-CaddyRollbackToCommit -Config $Config -Commit $oldGoodCaddy | Out-Null
        } else {
            Write-Warn "Failed first Caddy install was not recorded as a deployment version."
        }
        return $false
    }
}

# ===========================================================
# GIT COMMIT ROLLBACK
# ===========================================================

function Invoke-FrontendRollbackToCommit {
    param($Config, [Parameter(Mandatory=$true)][string]$Commit)

    $appDir = Join-Path $Config.InstallRoot "frontend"
    $repoDir = Join-Path $appDir "repo"
    $svcName = Get-DeployServiceName -Config $Config -Component "frontend"

    if (-not (Test-Path (Join-Path $repoDir ".git"))) {
        Write-Warn "Frontend repo not found."
        return $false
    }

    try {
        $currentCommit = Get-GitHead -RepoDir $repoDir
        if ($currentCommit -eq $Commit) {
            Write-Success "Frontend already at rollback target: $Commit"
        }

        $dependencyChanged = $true
        if (-not [string]::IsNullOrWhiteSpace($currentCommit)) {
            & git -C $repoDir diff --quiet $currentCommit $Commit -- package.json package-lock.json 2>$null
            $dependencyChanged = ($LASTEXITCODE -ne 0)
        }

        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Stopped') {
            Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
        }

        if (-not (Ensure-GitCommitAvailable -RepoDir $repoDir -Commit $Commit)) {
            throw "Frontend rollback commit is not available locally and could not be fetched: $Commit"
        }

        Write-Host "    Resetting frontend Git to: $Commit" -ForegroundColor Gray
        git -C $repoDir reset --hard $Commit | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Frontend git reset failed." }

        Push-Location $repoDir
        try {
            if ($dependencyChanged) {
                Write-Host "    Frontend dependency files changed; synchronizing node_modules..." -ForegroundColor Gray
                npm install --legacy-peer-deps
                if ($LASTEXITCODE -ne 0) { throw "Frontend rollback npm dependency sync failed." }
            } else {
                Write-Success "Frontend dependencies unchanged; keeping existing node_modules"
            }

            $serveMain = Join-Path $repoDir "node_modules\serve\build\main.js"
            if (-not (Test-Path $serveMain)) {
                Write-Host "    Local serve package missing; installing it..." -ForegroundColor Gray
                npm install --no-save serve --legacy-peer-deps
                if ($LASTEXITCODE -ne 0) { throw "Could not install frontend serve package." }
            }

            # dist is a generated build artifact, so rebuild it for the target Git commit.
            $distDir = Join-Path $repoDir "dist"
            if (Test-Path $distDir) {
                Remove-Item -Path $distDir -Recurse -Force -ErrorAction SilentlyContinue
            }

            $env:VITE_API_URL = $Config.ApiPrefix
            Write-Host "    Rebuilding frontend for rollback target..." -ForegroundColor Gray
            npm run build
            if ($LASTEXITCODE -ne 0) { throw "Frontend rollback build failed." }
        }
        finally {
            Pop-Location
        }

        $distDir = Join-Path $repoDir "dist"
        if (-not (Test-Path $distDir)) {
            throw "Frontend rollback build completed without creating dist."
        }

        Start-Service -Name $svcName -ErrorAction Stop

        $ok = Test-Endpoint `
            -Url "http://127.0.0.1:$($Config.FrontendPort)" `
            -Name "Frontend" `
            -TimeoutSec 5 `
            -Retries 10 `
            -RetryDelaySec 2

        if (-not $ok) {
            $logsDir = Join-Path (Join-Path $Config.InstallRoot "logs") "frontend"
            $latest = Get-ChildItem -Path $logsDir -Filter "frontend_service_*.log" -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1

            if ($latest) {
                Write-Host ""
                Write-Host "    --- Frontend service log ---" -ForegroundColor Yellow
                Get-Content $latest.FullName -ErrorAction SilentlyContinue |
                    Select-Object -Last 30 |
                    ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
                Write-Host "    --- end log ---" -ForegroundColor Yellow
            }

            throw "Frontend rollback health check failed."
        }

        Write-Success "Frontend restored to local Git commit: $Commit"
        return $true
    }
    catch {
        Write-Err "Frontend rollback failed: $_"
        return $false
    }
}

function Invoke-BackendRollbackToCommit {
    param($Config, [Parameter(Mandatory=$true)][string]$Commit)

    $appDir = Join-Path $Config.InstallRoot "backend"
    $repoDir = Join-Path $appDir "repo"
    $svcName = Get-DeployServiceName -Config $Config -Component "backend"

    if (-not (Test-Path (Join-Path $repoDir ".git"))) {
        Write-Warn "Backend repo not found."
        return $false
    }

    try {
        $currentCommit = Get-GitHead -RepoDir $repoDir

        if ($currentCommit -eq $Commit) {
            Write-Success "Backend already at rollback target: $Commit"
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Stopped') {
                Start-Service -Name $svcName -ErrorAction SilentlyContinue
            }

            $ok = Test-Endpoint `
                -Url "http://127.0.0.1:$($Config.BackendPort)$($Config.ApiPrefix)/health" `
                -Name "Backend API" `
                -TimeoutSec 5 `
                -Retries 5 `
                -RetryDelaySec 2

            if ($ok) { return $true }
        }

        $requirementsChanged = $true
        if (-not [string]::IsNullOrWhiteSpace($currentCommit)) {
            & git -C $repoDir diff --quiet $currentCommit $Commit -- requirements.txt 2>$null
            $requirementsChanged = ($LASTEXITCODE -ne 0)
        }

        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Stopped') {
            Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }

        if (-not (Ensure-GitCommitAvailable -RepoDir $repoDir -Commit $Commit)) {
            throw "Backend rollback commit is not available locally and could not be fetched: $Commit"
        }

        Write-Host "    Resetting backend Git to: $Commit" -ForegroundColor Gray
        git -C $repoDir reset --hard $Commit | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Backend git reset failed." }

        $pythonExe = Join-Path $repoDir "venv\Scripts\python.exe"
        if (-not (Test-Path $pythonExe)) {
            throw "Backend venv is missing. Run Install / Update to repair it."
        }

        if ($requirementsChanged) {
            $requirements = Join-Path $repoDir "requirements.txt"
            if (Test-Path $requirements) {
                Write-Host "    requirements.txt changed; synchronizing backend packages..." -ForegroundColor Gray
                & $pythonExe -m pip install --no-cache-dir -r $requirements
                if ($LASTEXITCODE -ne 0) { throw "Backend rollback dependency sync failed." }
            }
        } else {
            Write-Success "Backend requirements unchanged; keeping existing venv packages"
        }

        Push-Location $repoDir
        try {
            & $pythonExe -c "import app.main; print('APP_IMPORT_OK')" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Backend rollback app import failed." }
        }
        finally {
            Pop-Location
        }

        Start-Service -Name $svcName -ErrorAction Stop

        $ok = Test-Endpoint `
            -Url "http://127.0.0.1:$($Config.BackendPort)$($Config.ApiPrefix)/health" `
            -Name "Backend API" `
            -TimeoutSec 5 `
            -Retries 7 `
            -RetryDelaySec 2

        if (-not $ok) { throw "Backend rollback health check failed." }

        Write-Success "Backend restored to local Git commit: $Commit"
        return $true
    }
    catch {
        Write-Err "Backend rollback failed: $_"
        return $false
    }
}

function Invoke-CaddyRollbackToCommit {
    param($Config, [Parameter(Mandatory=$true)][string]$Commit)

    $caddyDir = Join-Path $Config.InstallRoot "caddy"
    $svcName = Get-DeployServiceName -Config $Config -Component "caddy"
    if (-not (Test-Path (Join-Path $caddyDir ".git"))) { Write-Warn "Caddy local Git repo not found."; return $false }

    try {
        $currentCommit = Get-GitHead -RepoDir $caddyDir
        if ($currentCommit -eq $Commit) {
            Write-Success "Caddy already at rollback target: $Commit"
            $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
            if ($svc -and $svc.Status -eq 'Stopped') {
                Start-Service -Name $svcName -ErrorAction SilentlyContinue
            }
            $ok = Test-Endpoint -Url "http://127.0.0.1:$($Config.CaddyPort)$($Config.ApiPrefix)/health" -Name "Caddy proxy" -TimeoutSec 5 -Retries 5 -RetryDelaySec 2
            if ($ok) { return $true }
        }

        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Stopped') { Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }

        & git -C $caddyDir cat-file -e "$Commit^{commit}" 2>$null
        if ($LASTEXITCODE -ne 0) { throw "Caddy local rollback commit not found: $Commit" }

        git -C $caddyDir reset --hard $Commit | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Caddy git reset failed." }

        $caddyExe = Join-Path $caddyDir "caddy.exe"
        $caddyfile = Join-Path $caddyDir "Caddyfile"
        $env:CADDY_PORT = "$($Config.CaddyPort)"
        $env:CADDY_ADMIN = "127.0.0.1:$($Config.CaddyAdminPort)"
        & $caddyExe validate --config $caddyfile | Out-Null
        $valid = $LASTEXITCODE
        Remove-Item Env:\CADDY_PORT -ErrorAction SilentlyContinue
        Remove-Item Env:\CADDY_ADMIN -ErrorAction SilentlyContinue
        if ($valid -ne 0) { throw "Rolled-back Caddyfile is invalid." }

        Start-Service -Name $svcName -ErrorAction Stop
        $ok = Test-Endpoint -Url "http://127.0.0.1:$($Config.CaddyPort)$($Config.ApiPrefix)/health" -Name "Caddy proxy" -TimeoutSec 5 -Retries 7 -RetryDelaySec 2
        if (-not $ok) { throw "Caddy rollback health check failed." }

        Write-Success "Caddy restored to local Git commit: $Commit"
        return $true
    } catch {
        Write-Err "Caddy rollback failed: $_"
        return $false
    }
}

function Invoke-SelectedRollback {
    param(
        $Config,
        [Parameter(Mandatory=$true)][string]$Key,
        [Parameter(Mandatory=$true)][string]$Commit
    )
    switch ($Key) {
        "frontend" { return Invoke-FrontendRollbackToCommit -Config $Config -Commit $Commit }
        "backend"  { return Invoke-BackendRollbackToCommit -Config $Config -Commit $Commit }
        "caddy"    { return Invoke-CaddyRollbackToCommit -Config $Config -Commit $Commit }
        default    { Write-Warn "Unknown rollback component: $Key"; return $false }
    }
}

function Show-RollbackMenu {
    param($Config)

    $state = Get-DeploymentState -Config $Config
    if (-not $state -or -not $state.deploymentVersions -or @($state.deploymentVersions).Count -lt 2) {
        Write-Warn "No previous complete deployment version is available yet."
        return
    }

    $versions = @($state.deploymentVersions)
    $current = $versions[0]
    $target = $versions[1]

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " Rollback Complete Deployment" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " Current : $($current.versionName)" -ForegroundColor Green
    Write-Host " Previous: $($target.versionName)" -ForegroundColor Gray
    Write-Host ""

    foreach ($key in @("frontend","backend","caddy")) {
        Write-Host " $key" -ForegroundColor White
        Write-Host "   current target : $($current.components.$key.current)" -ForegroundColor Green
        Write-Host "   rollback target: $($target.components.$key.current)" -ForegroundColor Gray
    }

    Write-Host ""
    if (-not (Confirm-Step "Rollback complete deployment $($current.versionName) -> $($target.versionName)?" -DefaultYes:$false)) {
        return
    }

    $restored = @()
    $ok = $true

    foreach ($key in @("caddy","backend","frontend")) {
        $commit = "$($target.components.$key.current)".Trim()
        if ([string]::IsNullOrWhiteSpace($commit)) { continue }

        if (Invoke-SelectedRollback -Config $Config -Key $key -Commit $commit) {
            $restored += $key
        } else {
            $ok = $false
            break
        }
    }

    if (-not $ok) {
        Write-Warn "Rollback did not complete. Restoring the original current deployment where possible..."
        foreach ($key in @("caddy","backend","frontend")) {
            if ($restored -notcontains $key) { continue }
            $commit = "$($current.components.$key.current)".Trim()
            if (-not [string]::IsNullOrWhiteSpace($commit)) {
                Invoke-SelectedRollback -Config $Config -Key $key -Commit $commit | Out-Null
            }
        }
        Write-Err "Complete deployment rollback failed. Deployment state file was not changed."
        return
    }

    # Swap current/previous full deployments so rollback can be undone.
    $state.deploymentVersions = @($target, $current)
    Save-DeploymentState -Config $Config -State $state
    Write-Success "Complete deployment rollback successful. Current: $($target.versionName)"
}

function Invoke-Rollback {
    param($Config)

    if (-not $script:deploymentStateBeforeRun) {
        Write-Warn "No previous successful deployment state exists for transactional rollback."
        return $false
    }

    $previous = @($script:deploymentStateBeforeRun.deploymentVersions)[0]
    if (-not $previous) { return $false }

    Write-Step "RESTORING previous known-good deployment"
    $ok = $true
    foreach ($key in @("caddy","backend","frontend")) {
        $commit = "$($previous.components.$key.current)".Trim()
        if ([string]::IsNullOrWhiteSpace($commit)) { continue }
        if (-not (Invoke-SelectedRollback -Config $Config -Key $key -Commit $commit)) { $ok = $false }
    }

    if ($ok) {
        Save-DeploymentState -Config $Config -State $script:deploymentStateBeforeRun
        Write-Success "Previous known-good deployment restored."
    }
    return $ok
}

function Get-Components {
    param($Config)
    return @(
        [PSCustomObject]@{ Num = 1; Key = "frontend"; Service = (Get-DeployServiceName -Config $Config -Component "frontend"); Display = "Frontend (Node / Vite)" }
        [PSCustomObject]@{ Num = 2; Key = "backend";  Service = (Get-DeployServiceName -Config $Config -Component "backend");  Display = "Backend (FastAPI)" }
        [PSCustomObject]@{ Num = 3; Key = "caddy";    Service = (Get-DeployServiceName -Config $Config -Component "caddy");    Display = "Caddy reverse proxy" }
    )
}

function Get-ServiceComponents {
    param($Config)
    return Get-Components -Config $Config
}

function Invoke-ComponentInstall {
    param($Key, $Config)
    $result = $false
    switch ($Key) {
        "frontend"   { $result = Install-Frontend -Config $Config }
        "backend"    {
            Write-Step "Checking deployment credentials"
            $secrets = Get-SecretsOrInitialize
            if (-not $secrets) {
                Write-Warn "Backend installation cancelled - no valid credentials."
                Write-Log "Backend install cancelled: no secrets" -Level "WARN"
                return $false
            }
            if (-not (Confirm-DeploymentCredentials -Config $Config -Secrets $secrets)) {
                return $false
            }
            $result = Install-Backend -Config $Config -Secrets $secrets
        }
        "caddy"      { $result = Install-Caddy -Config $Config }
    }
    if (-not $result -and -not $script:dryRun) {
        Write-Err "Component '$Key' failed to install."
        Write-Log "Component install failed: $Key" -Level "ERROR"
        return $false
    }
    return $result
}

function Remove-Component {
    param(
        [string]$Key,
        $Config,
        [switch]$DeleteFiles
    )

    $svcName = Get-DeployServiceName -Config $Config -Component $Key
    Write-Step "Removing $Key"

    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $logsRoot = Join-Path $Config.InstallRoot "logs"

    if (-not (Test-Path $logsRoot)) {
        New-Item -Path $logsRoot -ItemType Directory -Force | Out-Null
    }

    $uninstallLog = Join-Path $logsRoot ($Key + "_uninstall_" + $ts + ".log")
    Write-FileLog -Path $uninstallLog -Text ("========== Uninstalling " + $Key + " ==========")

    if ($script:dryRun) {
        $fileAction = "keep"
        if ($DeleteFiles) {
            $fileAction = "delete"
        }

        Write-Warn ("[DRY-RUN] Would remove " + $Key + " service and " + $fileAction + " its files")
        Write-FileLog -Path $uninstallLog -Text ("[DRY-RUN] Would uninstall " + $Key)
        return
    }

    # Step 1: stop the service.
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue

    if ($svc) {
        if ($svc.Status -ne "Stopped") {
            Write-Host ("    Stopping service " + $svcName + "...") -ForegroundColor Gray
            Write-FileLog -Path $uninstallLog -Text ("Stopping service " + $svcName)

            Stop-Service -Name $svcName -Force -ErrorAction SilentlyContinue

            $waited = 0
            $maxChecks = 10
            $stopped = $false

            while ($waited -lt $maxChecks) {
                Start-Sleep -Seconds 3
                $waited = $waited + 1
                $check = Get-Service -Name $svcName -ErrorAction SilentlyContinue

                if (-not $check) {
                    $stopped = $true
                    break
                }

                if ($check.Status -eq "Stopped") {
                    $stopped = $true
                    break
                }

                Write-Host ("      Check " + $waited + "/" + $maxChecks + " - service still " + $check.Status + "...") -ForegroundColor Gray
            }

            if (-not $stopped) {
                Write-Err ("Service '" + $svcName + "' did not stop.")
                Write-FileLog -Path $uninstallLog -Text ("ERROR: Service " + $svcName + " did not stop.")
                return
            }

            Write-Success "Service stopped"
            Write-FileLog -Path $uninstallLog -Text "Service stopped successfully"
        }
        else {
            Write-Host "    Service already stopped." -ForegroundColor Gray
            Write-FileLog -Path $uninstallLog -Text "Service already stopped"
        }
    }
    else {
        Write-Host "    Service not found, nothing to stop." -ForegroundColor Gray
        Write-FileLog -Path $uninstallLog -Text "Service not found"
    }

    # Step 2: unregister service.
    if (Get-Service -Name $svcName -ErrorAction SilentlyContinue) {
        Write-Host "    Unregistering service..." -ForegroundColor Gray
        Write-FileLog -Path $uninstallLog -Text "Unregistering service via servy-cli"

        & servy-cli uninstall --name="$svcName" --quiet 2>&1 | Add-FileLog -Path $uninstallLog
        Start-Sleep -Milliseconds 500

        if (Get-Service -Name $svcName -ErrorAction SilentlyContinue) {
            Write-Warn ($svcName + " is still registered. Restart Windows and run uninstall again if necessary.")
            Write-FileLog -Path $uninstallLog -Text ("WARN: " + $svcName + " still registered after servy-cli uninstall")
        }
        else {
            Write-Success ($svcName + " service removed.")
            Write-FileLog -Path $uninstallLog -Text ("OK: " + $svcName + " removed")
        }
    }

    # Step 3: optionally delete component files.
    if ($DeleteFiles) {
        $componentPath = Join-Path $Config.InstallRoot $Key

        if (Test-Path $componentPath) {
            Write-Host ("    Deleting " + $componentPath + "...") -ForegroundColor Gray
            Remove-Item -Path $componentPath -Recurse -Force -ErrorAction SilentlyContinue

            if (Test-Path $componentPath) {
                Write-Err ("Could not delete '" + $componentPath + "'. A process may still have files locked.")
                Write-FileLog -Path $uninstallLog -Text ("ERROR: Could not delete " + $componentPath)
                return
            }

            Write-Success ("Deleted " + $componentPath)
            Write-FileLog -Path $uninstallLog -Text ("OK: Deleted " + $componentPath)
        }

        $logSubDir = Join-Path $logsRoot $Key
        if (Test-Path $logSubDir) {
            Remove-Item -Path $logSubDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        # Remove deleted component from deployment-state.json.
        $state = Get-DeploymentState -Config $Config

        if ($state) {
            if ($state.deploymentVersions) {
                if (@($state.deploymentVersions).Count -gt 0) {
                    $current = @($state.deploymentVersions)[0]

                    if ($current.components) {
                        $componentState = $current.components.$Key

                        if ($componentState) {
                            $componentState.current = $null
                            $componentState.previous = $null
                            Save-DeploymentState -Config $Config -State $state
                        }
                    }
                }
            }
        }
    }

    Write-Log ("Component removed: " + $Key)
}

# ===========================================================
# SERVICE CONTROL / STATUS
# ===========================================================
function Start-AllServices {
    param($Config)
    $caddySvcName = Get-DeployServiceName -Config $Config -Component "caddy"
    Write-Step "Starting services"
    if ($script:dryRun) {
        Write-Warn "[DRY-RUN] Would start all installed services"
        return
    }
    foreach ($c in Get-Components -Config $Config) {
        if (-not (Get-Service -Name $c.Service -ErrorAction SilentlyContinue)) {
            Write-Host "    Skipping $($c.Display) (not installed)" -ForegroundColor Gray
            continue
        }
        try {
            Start-Service -Name $c.Service -ErrorAction Stop
            Write-Success "Started $($c.Display)"
            # Show address for each service
            switch ($c.Key) {
                "frontend" { Write-Host "    Address: http://localhost:$($Config.FrontendPort)" -ForegroundColor Gray }
                "backend"  { Write-Host "    Address: http://localhost:$($Config.BackendPort)$($Config.ApiPrefix)" -ForegroundColor Gray }
            }
            Write-Log "Service started: $($c.Service)"
        } catch {
            Write-Err "Failed to start $($c.Display): $_"
            Write-Log "Failed to start $($c.Service): $_" -Level "ERROR"
        }
    }
    # Show ports after Caddy starts (give runner time to write status file)
    if (Get-Service -Name $caddySvcName -ErrorAction SilentlyContinue) {
        Start-Sleep -Seconds 3
        $caddyPorts = Get-CaddyActualPorts -Config $Config
        Write-Host ""
        Write-Host " -- Caddy Ports --" -ForegroundColor Cyan
        Write-Host "  Proxy : $($caddyPorts.proxy)" -ForegroundColor Green
        if ($caddyPorts.admin) {
            Write-Host "  Admin : $($caddyPorts.admin)" -ForegroundColor Gray
        } else {
            Write-Host "  Admin : (not yet available)" -ForegroundColor DarkYellow
        }
    }
}

function Stop-AllServices {
    param($Config)
    Write-Step "Stopping services"
    if ($script:dryRun) {
        Write-Warn "[DRY-RUN] Would stop all running services"
        return
    }
    foreach ($c in Get-Components -Config $Config) {
        if (-not (Get-Service -Name $c.Service -ErrorAction SilentlyContinue)) { continue }
        Stop-Service -Name $c.Service -ErrorAction SilentlyContinue
        Write-Success "Stopped $($c.Display)"
        Write-Log "Service stopped: $($c.Service)"
    }
}

function Show-Status {
    param($Config)
    $caddySvcName = Get-DeployServiceName -Config $Config -Component "caddy"
    Write-Step "Service status"
    $rows = foreach ($c in Get-Components -Config $Config) {
        $svc = Get-Service -Name $c.Service -ErrorAction SilentlyContinue
        [PSCustomObject]@{
            Component = $c.Display
            Service   = $c.Service
            State     = if ($svc) { $svc.Status } else { "Not installed" }
        }
    }
    $rows | Format-Table -AutoSize | Out-Host

    # Show port summary alongside health
    Write-Host " -- Addresses --" -ForegroundColor Cyan
    Write-Host "  Frontend : http://localhost:$($Config.FrontendPort)" -ForegroundColor Green
    Write-Host "  Backend  : http://localhost:$($Config.BackendPort)$($Config.ApiPrefix)" -ForegroundColor Green
    if (Get-Service -Name $caddySvcName -ErrorAction SilentlyContinue) {
        $caddyPorts = Get-CaddyActualPorts -Config $Config
        Write-Host "  Caddy proxy : http://localhost:$($caddyPorts.proxy)" -ForegroundColor Green
        if ($caddyPorts.admin) {
            Write-Host "  Caddy admin : http://localhost:$($caddyPorts.admin)" -ForegroundColor Gray
        } else {
            Write-Host "  Caddy admin : (not yet available)" -ForegroundColor DarkYellow
        }
    }
    Write-Host ""

    # Health checks
    Verify-Health -Config $Config

    Write-Log "Status check completed"
}

# ===========================================================
# FULL DEPLOYMENT (shared between interactive and headless)
# ===========================================================
function Invoke-FullDeploy {
    param($Config)

    $script:deploymentTransaction = $true
    $script:deploymentCandidates = @{}
    $script:liveComponentsChanged = @()
    $script:deploymentConfigChanged = $false
    $script:deploymentStateBeforeRun = Copy-ObjectDeep -Object (Get-DeploymentState -Config $Config)

    # 1. Validate install drive exists (prompt already happened at entry)
    $drive = [System.IO.Path]::GetPathRoot($Config.InstallRoot)
    if (-not (Test-Path $drive)) {
        Write-Err "Drive $drive does not exist. Select a valid drive from the menu (option 10)."
        Write-Log "Install drive $drive not found" -Level "ERROR"
        return
    }

    Initialize-Logger -Config $Config

    # 2. Quick connectivity check (git repos, npm, pip all need internet)
    Write-Step "Checking network access"
    try {
        $testResult = Invoke-WebRequest -Uri "https://github.com" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
        Write-Success "Internet: OK"
        Write-Log "Internet connectivity verified"
    } catch {
        Write-Warn "Internet: unreachable - git clone, npm install, and pip install will fail."
        Write-Log "Internet check failed" -Level "WARN"
        if (-not $script:headless) {
            if (-not (Confirm-Step "Continue without internet?" -DefaultYes:$false)) {
                Write-Warn "Deployment cancelled."
                return
            }
        }
    }

    # 3. Check prerequisites (check-only: no install prompts)
    $prereqResult = Test-Prerequisites -CheckOnly
    if ("BACK" -eq $prereqResult -or -not $prereqResult) {
        if ("BACK" -eq $prereqResult) {
            Write-Warn "Returning to menu."
        } else {
            Write-Err "Resolve missing prerequisites first."
        }
        return
    }
    # Determine which components to deploy
    $targetComponents = if ($script:headless -and $Components.Count -gt 0) {
        $Components
    } else {
        @("frontend", "backend", "caddy")
    }
    $allSucceeded = $true

    # --- Credentials: resolve once upfront ---
    # This happens before any component Git/service changes.
    $secrets = $null
    if ($targetComponents -contains "backend") {
        Write-Step "Checking deployment credentials"
        $secrets = Get-SecretsOrInitialize
        if (-not $secrets) {
            Write-Warn "Deployment cancelled before component update started."
            $script:deploymentTransaction = $false
            return
        }

        if (-not (Confirm-DeploymentCredentials -Config $Config -Secrets $secrets)) {
            $script:deploymentTransaction = $false
            return
        }
    }

    Write-Step "Installing / updating selected components"

    if ($targetComponents -contains "frontend") {
        Write-Host "  Frontend (port $($Config.FrontendPort))..." -ForegroundColor Gray
        Start-Spinner "Frontend deployment ..."
        $frontendOk = Install-Frontend -Config $Config
        Stop-Spinner
        if ($frontendOk) {
            Write-Success "Frontend ready on port $($Config.FrontendPort)"
            Write-Log "Frontend installed on port $($Config.FrontendPort)"
        } else {
            Write-Err "Frontend installation FAILED - skipping remaining components"
            $allSucceeded = $false
        }
    }

    if ($allSucceeded -and $targetComponents -contains "backend") {
        # Backend install function now safely stops/uninstalls any existing backend service
        # and kills stale backend Python processes before replacing repo/venv.
        Write-Host "  Backend (port $($Config.BackendPort))..." -ForegroundColor Gray
        Start-Spinner "Backend deployment ..."
        $backendOk = Install-Backend -Config $Config -Secrets $secrets
        Stop-Spinner
        if ($backendOk) {
            Write-Success "Backend ready on port $($Config.BackendPort)"
            Write-Log "Backend installed on port $($Config.BackendPort)"
        } else {
            Write-Err "Backend installation FAILED - skipping remaining components"
            $allSucceeded = $false
        }
    }

    if ($allSucceeded -and $targetComponents -contains "caddy") {
        Write-Host "  Caddy reverse proxy (port $($Config.CaddyPort))..." -ForegroundColor Gray
        Start-Spinner "Caddy deployment ..."
        $caddyOk = Install-Caddy -Config $Config
        Stop-Spinner
        if ($caddyOk) {
            Write-Success "Caddy ready on port $($Config.CaddyPort)"
            Write-Log "Caddy installed on port $($Config.CaddyPort)"
        } else {
            Write-Err "Caddy installation FAILED - skipping remaining components"
            $allSucceeded = $false
        }
    }

    # Automatic transactional recovery on failure.
    # If failure happened before any live component changed, do NOT touch services.
    if (-not $allSucceeded -and -not $script:dryRun) {
        Write-Host ""
        Write-Err "UPDATE FAILED"

        if (@($script:liveComponentsChanged).Count -eq 0) {
            Write-Success "No live component was changed."
            Write-Success "Current known-good deployment remains active."
            Write-Success "No failed candidate was saved as a deployment version."
            Write-Log "Deployment failed before live promotion; no rollback required" -Level "ERROR"
        }
        else {
            Write-Warn "A live component had already changed. Automatically restoring the saved current known-good deployment..."
            $restoreOk = Invoke-Rollback -Config $Config

            if ($restoreOk) {
                $active = Get-CurrentDeploymentVersion -Config $Config
                if ($active) {
                    Write-Success "Active deployment restored: $($active.versionName)"
                } else {
                    Write-Success "Previous known-good deployment restored."
                }
                Write-Success "No failed candidate was saved as a deployment version."
                Write-Log "Deployment failed after live promotion; previous known-good deployment restored automatically" -Level "ERROR"
            } else {
                Write-Err "Automatic recovery could not fully verify the previous deployment."
                Write-Warn "deployment-state.json was not promoted to the failed candidate."
                Write-Log "Deployment failed after live promotion; automatic recovery was incomplete" -Level "ERROR"
            }
        }

        $script:deploymentTransaction = $false
        return
    }

    # Each component already starts and health-checks itself.
    # Promote the full deployment only after every selected component succeeded.
    if ($allSucceeded -and -not $script:dryRun) {
        Complete-FullDeploymentState -Config $Config
    }

    $script:deploymentTransaction = $false

    # Summary
    if ($script:dryRun) {
        Write-Step "DRY RUN COMPLETE - No changes were made"
    } elseif ($allSucceeded) {
        Write-Step "DEPLOYMENT COMPLETE"
        $duration = (Get-Date) - $script:startTime
        Write-Success "Duration: $($duration.Minutes)m $($duration.Seconds)s"
        Write-Success "Log: $($script:logFile)"

        # Read actual Caddy port from status file (if available)
        $displayCaddyPort = $Config.CaddyPort
        $caddyPortsFile = Join-Path (Join-Path $Config.InstallRoot "caddy") "caddy-ports.json"
        if (Test-Path $caddyPortsFile) {
            try {
                $portsData = Get-Content $caddyPortsFile -Raw -ErrorAction Stop | ConvertFrom-Json
                if ($portsData.proxy -and $portsData.proxy -gt 0) {
                    $displayCaddyPort = [int]$portsData.proxy
                }
            } catch { }
        }

        # Architecture diagram
        Write-Host ""
        Write-Host "  Local access: http://localhost:${displayCaddyPort}" -ForegroundColor Green
        Write-Host "  +--------------------------------------------------+" -ForegroundColor Cyan
        Write-Host "  |                   CADDY                         |" -ForegroundColor Cyan
        Write-Host "  |             (port ${displayCaddyPort})                |" -ForegroundColor Cyan
        Write-Host "  +--------+-------------------------+---------------+" -ForegroundColor Cyan
        Write-Host "           |                         |" -ForegroundColor Cyan
        Write-Host "           v                         v" -ForegroundColor Cyan
        Write-Host "  +----------------+        +------------------+" -ForegroundColor Cyan
        Write-Host "  |   FRONTEND     |        |     BACKEND      |" -ForegroundColor Cyan
        Write-Host "  |  (port $($Config.FrontendPort))    |        |    (port $($Config.BackendPort))     |" -ForegroundColor Cyan
        Write-Host "  +----------------+        +------------------+" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Browser -> http://localhost:${displayCaddyPort}  ->  Caddy routes:" -ForegroundColor White
        Write-Host "    $($Config.ApiPrefix)/*  ->  Backend  (:$($Config.BackendPort))" -ForegroundColor Gray
        Write-Host "    /*               ->  Frontend (:$($Config.FrontendPort))" -ForegroundColor Gray
    } else {
        Write-Warn "Deployment finished with errors. Check log: $($script:logFile)"
    }
}

# ===========================================================
# MENU
# ===========================================================
function Show-MainMenu {
    param($Config)
    Clear-Host

    $anyInstalled = Test-AnyComponentInstalled -Config $Config
    $allInstalled = Test-AllComponentsInstalled -Config $Config
    $installUpdateLabel = if (-not $anyInstalled) {
        "Install complete deployment"
    } else {
        "Update complete deployment"
    }

    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " Servy Full-Stack Deployment Manager" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " Environment: $(Get-DeployEnvironment -Config $Config)" -ForegroundColor Gray
    if (-not [string]::IsNullOrWhiteSpace($Config.InstallRoot)) {
        Write-Host " Install path: $($Config.InstallRoot)" -ForegroundColor Gray
    }

    $currentVersion = Get-CurrentDeploymentVersion -Config $Config
    if ($currentVersion) {
        Write-Host " Deployment: $($currentVersion.versionName)" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "  1) Check prerequisites" -ForegroundColor White
    Write-Host "  2) $installUpdateLabel" -ForegroundColor White
    Write-Host "  3) Uninstall complete deployment" -ForegroundColor White
    Write-Host "  4) Service status / health check" -ForegroundColor White
    Write-Host "  5) Start services" -ForegroundColor White
    Write-Host "  6) Stop services" -ForegroundColor White
    Write-Host "  7) Caddy network config" -ForegroundColor White
    Write-Host "  8) Open logs folder" -ForegroundColor White
    if (Test-DeploymentRollbackAvailable -Config $Config) {
        Write-Host "  9) Rollback deployment" -ForegroundColor White
    }
    Write-Host "  Q) Quit" -ForegroundColor White
    Write-Host ""
}

function Show-CaddyConfig {
    param($Config)
    $caddySvcName = Get-DeployServiceName -Config $Config -Component "caddy"
    do {
        $changed = $false

        # Available targets (services that Caddy can proxy to)
        $targets = @(
            [PSCustomObject]@{ Name = "Frontend (Node / Vite)"; Target = "127.0.0.1:$($Config.FrontendPort)"; DefaultPath = "/*" }
            [PSCustomObject]@{ Name = "Backend (FastAPI)";      Target = "127.0.0.1:$($Config.BackendPort)"; DefaultPath = "$($Config.ApiPrefix)/*" }
        )

        # Current Caddy routes from config (or defaults)
        $routes = @()
        if ($Config.CaddyRoutes -and @($Config.CaddyRoutes).Count -gt 0) {
            $routes = @($Config.CaddyRoutes)
        } else {
            $routes = @(
                [PSCustomObject]@{ Path = "/*";                    Target = "127.0.0.1:$($Config.FrontendPort)"; Label = "Frontend" }
                [PSCustomObject]@{ Path = "$($Config.ApiPrefix)/*"; Target = "127.0.0.1:$($Config.BackendPort)";  Label = "Backend" }
            )
        }

        # Determine which targets are NOT yet registered as routes
        $routedTargets = @($routes | ForEach-Object { $_.Target })
        $availableTargets = @($targets | Where-Object { $_.Target -notin $routedTargets })

        Write-Host ""
        Write-Host "============================================" -ForegroundColor Cyan
        Write-Host " Caddy Reverse Proxy Configuration" -ForegroundColor Cyan
        Write-Host "============================================" -ForegroundColor Cyan
        Write-Host ""
        $caddyPorts = Get-CaddyActualPorts -Config $Config
        Write-Host " Caddy proxy : $($caddyPorts.proxy)" -ForegroundColor Green
        if ($caddyPorts.admin) {
            Write-Host " Caddy admin : $($caddyPorts.admin)" -ForegroundColor Gray
        } else {
            Write-Host " Caddy admin : (not yet available)" -ForegroundColor DarkYellow
        }
        Write-Host ""
        Write-Host " Available targets:" -ForegroundColor White
        if ($availableTargets.Count -gt 0) {
            $i = 1
            foreach ($t in $availableTargets) {
                Write-Host ("   " + $i + ") " + $t.Name + " -> " + $t.Target) -ForegroundColor Gray
                $i++
            }
        } else {
            Write-Host "   (all targets already registered)" -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host " Caddy routes:" -ForegroundColor White
        for ($i = 0; $i -lt $routes.Count; $i++) {
            Write-Host ("   " + ($i + 1) + ") " + $routes[$i].Path + " -> " + $routes[$i].Target + "  [" + $routes[$i].Label + "]") -ForegroundColor Gray
        }
        Write-Host ""
        Write-Host " 1) Add route to Caddy" -ForegroundColor Gray
        Write-Host " 2) Remove route from Caddy" -ForegroundColor Gray
        Write-Host " 3) Change Caddy listening port  [$($Config.CaddyPort)]" -ForegroundColor Gray
        Write-Host " B) Back to main menu" -ForegroundColor Gray
        Write-Host ""
        $sub = Read-Host "Select option"

        switch ($sub) {
            "1" {
                # --- Add route ---
                $addOptions = @()
                $optNum = 1
                foreach ($t in $availableTargets) {
                    $addOptions += [PSCustomObject]@{ OptNum = $optNum; Name = $t.Name; Target = $t.Target; DefaultPath = $t.DefaultPath }
                    $optNum++
                }
                $addOptions += [PSCustomObject]@{ OptNum = $optNum; Name = "Custom target (enter your own)"; Target = $null; DefaultPath = "" }

                Write-Host ""
                Write-Host "--- Add Route ---" -ForegroundColor Cyan
                foreach ($o in $addOptions) {
                    if ($o.Target) {
                        Write-Host " $($o.OptNum)) $($o.Name)  ->  $($o.Target)" -ForegroundColor Gray
                    } else {
                        Write-Host " $($o.OptNum)) $($o.Name)" -ForegroundColor Gray
                    }
                }
                Write-Host " B) Back" -ForegroundColor Gray
                $pick = Read-Host "`nSelect target"
                if ($pick -match '^[Bb]$') { break }

                $targetAddr = $null
                $defaultPath = $null
                $label = $null

                if ($pick -match '^\d+$') {
                    $selected = $addOptions | Where-Object { $_.OptNum -eq [int]$pick } | Select-Object -First 1
                    if ($selected) {
                        if (-not $selected.Target) {
                            # Custom target
                            $targetAddr = Read-Host "Enter target address (e.g. 127.0.0.1:9090)"
                            if (-not $targetAddr) { break }
                            $label = Read-Host "Enter label/name for this route"
                            if (-not $label) { $label = "Custom" }
                        } else {
                            $targetAddr = $selected.Target
                            $defaultPath = $selected.DefaultPath
                            $label = $selected.Name
                        }
                    }
                }

                if ($targetAddr) {
                    $path = Read-Host "Path prefix (e.g. /custom/*) [$defaultPath]"
                    if (-not $path) { $path = $defaultPath }
                    if ($path -and $path.StartsWith('/')) {
                        $routes += [PSCustomObject]@{ Path = $path; Target = $targetAddr; Label = $label }
                        $Config | Add-Member -NotePropertyName 'CaddyRoutes' -NotePropertyValue $routes -Force
                        Save-DeployConfig -Config $Config
                        $changed = $true
                        Write-Success "Route added: $path -> $targetAddr"
                    } else {
                        Write-Err "Path must start with /"
                    }
                }
            }
            "2" {
                # --- Remove route ---
                if ($routes.Count -eq 0) {
                    Write-Warn "No routes to remove."
                    break
                }
                Write-Host ""
                Write-Host "--- Remove Route ---" -ForegroundColor Cyan
                for ($i = 0; $i -lt $routes.Count; $i++) {
                    Write-Host " $($i+1)) $($routes[$i].Path) -> $($routes[$i].Target)  [$($routes[$i].Label)]" -ForegroundColor Gray
                }
                Write-Host " B) Back" -ForegroundColor Gray
                $pick = Read-Host "`nSelect route to remove"
                if ($pick -match '^[Bb]$') { break }
                if ($pick -match '^\d+$') {
                    $idx = [int]$pick - 1
                    if ($idx -ge 0 -and $idx -lt $routes.Count) {
                        if (Confirm-Step "Remove route '$($routes[$idx].Path) -> $($routes[$idx].Target)'?" -DefaultYes:$false) {
                            $routes = @($routes | Where-Object { $_ -ne $routes[$idx] })
                            if ($routes.Count -gt 0) {
                                $Config | Add-Member -NotePropertyName 'CaddyRoutes' -NotePropertyValue $routes -Force
                            } else {
                                $Config.PSObject.Properties.Remove('CaddyRoutes')
                            }
                            Save-DeployConfig -Config $Config
                            $changed = $true
                            Write-Success "Route removed."
                        }
                    } else {
                        Write-Err "Invalid route number."
                    }
                }
            }
            "3" {
                Select-CaddyPort -Config $Config | Out-Null
                $changed = $true
            }
            "[Bb]" { break }
            default { Write-Warn "Unknown option." }
        }

        # If Caddy is installed and something changed, regenerate Caddyfile and restart
        if ($changed -and (Get-Service -Name $caddySvcName -ErrorAction SilentlyContinue)) {
            if (Confirm-Step "Regenerate Caddyfile and restart Caddy?" -DefaultYes:$true) {
                $caddyDir = Join-Path $Config.InstallRoot "caddy"
                $caddyfilePath = Join-Path $caddyDir "Caddyfile"

                # Get final routes for Caddyfile
                $finalRoutes = @()
                if ($Config.CaddyRoutes -and @($Config.CaddyRoutes).Count -gt 0) {
                    $finalRoutes = @($Config.CaddyRoutes)
                } else {
                    $finalRoutes = @(
                        [PSCustomObject]@{ Path = "$($Config.ApiPrefix)/*"; Target = "127.0.0.1:$($Config.BackendPort)" }
                        [PSCustomObject]@{ Path = "/*";                    Target = "127.0.0.1:$($Config.FrontendPort)" }
                    )
                }

                $caddyfileLines = @()
                $caddyfileLines += ":`{`$CADDY_PORT`} {"
                foreach ($r in $finalRoutes) {
                    $caddyfileLines += "    handle $($r.Path) {"
                    $caddyfileLines += "        reverse_proxy $($r.Target)"
                    $caddyfileLines += "    }"
                }
                $caddyfileLines += "    header {"
                $caddyfileLines += '        X-Frame-Options "SAMEORIGIN"'
                $caddyfileLines += '        X-Content-Type-Options "nosniff"'
                $caddyfileLines += '        X-XSS-Protection "1; mode=block"'
                $caddyfileLines += "    }"
                $caddyfileLines += "}"
                $caddyfileContent = $caddyfileLines -join "`n"

                Set-Content -Path $caddyfilePath -Value $caddyfileContent -Force

                # Also regenerate the runner script so it picks up latest config
                $runnerScript = Join-Path $caddyDir "caddy-run.ps1"
                $defaultProxyPort = $Config.CaddyPort
                $adminPort = $Config.CaddyAdminPort
                $runnerContent = @'
$caddyDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$caddyExe = Join-Path $caddyDir "caddy.exe"
$caddyfile = Join-Path $caddyDir "Caddyfile"
$logsDir   = Join-Path (Join-Path (Split-Path $caddyDir -Parent) "logs") "caddy"
if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }

$svcTs = (Get-Date).ToString("yyyyMMdd-HHmmss")
$caddyLog = Join-Path $logsDir "caddy_service_${svcTs}.log"
$statusFile = Join-Path $caddyDir "caddy-ports.json"
Remove-Item -Path $statusFile -Force -ErrorAction SilentlyContinue

# Use TcpClient instead of netstat for port checking (reliable across locales/Windows versions)
function Test-PortInUse {
    param([int]$Port)
    $tcp = $null
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect("127.0.0.1", $Port, $null, $null)
        $connected = $iar.AsyncWaitHandle.WaitOne(500)
        if ($connected -and $tcp.Connected) {
            $tcp.EndConnect($iar)
            return $true
        }
    } catch { }
    finally { if ($tcp) { $tcp.Close() } }
    return $false
}

"========== Service started at $(Get-Date) ==========" | Out-File -FilePath $caddyLog -Encoding ASCII

# Use the configured fixed admin API port.
$adminPort = __CADDY_ADMIN_PORT__
if (Test-PortInUse -Port $adminPort) {
    "FATAL: Caddy admin API port $adminPort is already in use. Service cannot start." | Out-File -FilePath $caddyLog -Append
    exit 1
}
$env:CADDY_ADMIN = "127.0.0.1:$adminPort"
"    Admin port (fixed): $adminPort" | Out-File -FilePath $caddyLog -Append

# Use the configured fixed proxy port.
$proxyPort = __DEFAULT_PROXY_PORT__
if (Test-PortInUse -Port $proxyPort) {
    "FATAL: Caddy proxy port $proxyPort is already in use. Service cannot start." | Out-File -FilePath $caddyLog -Append
    exit 1
}
$env:CADDY_PORT = "$proxyPort"
"    Proxy port: $proxyPort" | Out-File -FilePath $caddyLog -Append

# Write the fixed ports to a status file so health checks can find Caddy.
@{admin = $adminPort; proxy = $proxyPort} | ConvertTo-Json | Out-File -FilePath $statusFile -Force
"    Ports status: $statusFile" | Out-File -FilePath $caddyLog -Append

"    Starting Caddy..." | Out-File -FilePath $caddyLog -Append
& $caddyExe run --config $caddyfile 2>&1 | Out-File -FilePath $caddyLog -Append
"========== Service STOPPED at $(Get-Date) ==========" | Out-File -FilePath $caddyLog -Append
'@
                $runnerContent = $runnerContent.Replace('__DEFAULT_PROXY_PORT__', $defaultProxyPort)
                $runnerContent = $runnerContent.Replace('__CADDY_ADMIN_PORT__', $adminPort)
                Set-Content -Path $runnerScript -Value $runnerContent -Force

                Restart-Service -Name $caddySvcName -ErrorAction SilentlyContinue
                Write-Success "Caddy restarted with new config"
                Write-Host "    Caddyfile and runner script regenerated" -ForegroundColor Gray
            }
        }
    } while ($sub -notmatch '^[Bb]$')
}



function Select-Component {
    param([string]$ActionLabel, $Config)
    $compList = Get-Components -Config $Config
    Write-Host ""
    foreach ($c in $compList) {
        $svc = Get-Service -Name $c.Service -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') {
            Write-Host " $($c.Num)) $($c.Display)" -ForegroundColor Green -NoNewline
            Write-Host "  [RUNNING]" -ForegroundColor Green
        } elseif ($svc) {
            Write-Host " $($c.Num)) $($c.Display)" -ForegroundColor Gray -NoNewline
            Write-Host "  [STOPPED]" -ForegroundColor DarkYellow
        } else {
            Write-Host " $($c.Num)) $($c.Display)" -ForegroundColor DarkGray -NoNewline
            Write-Host "  [NOT INSTALLED]" -ForegroundColor DarkGray
        }
    }
    Write-Host " B) Back" -ForegroundColor Gray
    $sel = Read-Host "`nSelect a component to $ActionLabel"
    if ($sel -match '^[Bb]$') { return $null }
    return $compList | Where-Object { "$($_.Num)" -eq $sel } | Select-Object -First 1
}

# ===========================================================
# ENTRY POINT
# ===========================================================
$Config = Get-DeployConfig

if ($script:headless) {
    # Non-interactive mode - validate drive then run
    $installRoot = Select-InstallDrive -Config $Config
    if (-not $installRoot) { exit 1 }
    $Config.InstallRoot = $installRoot
    Invoke-FullDeploy -Config $Config
    if ($script:hasErrors) {
        exit 1
    }
    exit 0
}

# Interactive menu mode - prompt for install drive at start
$installRoot = Select-InstallDrive -Config $Config
if ($installRoot) { $Config.InstallRoot = $installRoot }
do {
    Show-MainMenu -Config $Config
    $choice = Read-Host "Select an option"

    switch -Regex ($choice) {
        "^1$" {
            # Check prerequisites
            Initialize-Logger -Config $Config
            Test-Prerequisites | Out-Null
        }
        "^2$" {
            $state = Get-DeploymentState -Config $Config
            $currentVersion = $null
            $nextVersion = "v1"

            if ($state -and $state.deploymentVersions -and @($state.deploymentVersions).Count -gt 0) {
                $currentVersion = @($state.deploymentVersions)[0].versionName
                $nextVersion = Get-NextDeploymentVersionName -State $state
            }

            Write-Host ""
            if ($currentVersion) {
                Write-Host " Current deployment: $currentVersion" -ForegroundColor Green
                Write-Host " Next deployment:    $nextVersion" -ForegroundColor Cyan
                Write-Host " Checking all component Git repositories..." -ForegroundColor Gray
            } else {
                Write-Host " First deployment: v1" -ForegroundColor Cyan
                Write-Host " Installing complete deployment..." -ForegroundColor Gray
            }

            Invoke-FullDeploy -Config $Config
        }
        "^3$" {
            # Complete uninstall only.
            # Install/update/rollback/uninstall all operate on the whole deployment.
            $compList = Get-Components -Config $Config

            Write-Host ""
            Write-Host "============================================" -ForegroundColor Cyan
            Write-Host " Uninstall Complete Deployment" -ForegroundColor Cyan
            Write-Host "============================================" -ForegroundColor Cyan
            Write-Host " This will remove:" -ForegroundColor Gray
            Write-Host "   - Frontend service and files" -ForegroundColor Gray
            Write-Host "   - Backend service and files" -ForegroundColor Gray
            Write-Host "   - Caddy service and files" -ForegroundColor Gray
            Write-Host "   - Logs" -ForegroundColor Gray
            Write-Host "   - deployment-state.json" -ForegroundColor Gray
            Write-Host "   - $($Config.InstallRoot)" -ForegroundColor Gray
            Write-Host ""
            Write-Host " Persistent face-image storage will be preserved:" -ForegroundColor Green
            Write-Host "   $(Get-MediaStoragePath -Config $Config)" -ForegroundColor Green
            Write-Host ""

            $confirm = Read-Host "Type YES to uninstall the complete deployment"
            if ($confirm -ne "YES") {
                Write-Warn "Uninstall cancelled."
                break
            }

            Initialize-Logger -Config $Config

            # Remove all services + component folders.
            foreach ($c in $compList) {
                Remove-Component -Key $c.Key -Config $Config -DeleteFiles
            }

            # Final cleanup of deployment state/logs/install root.
            if (-not (Test-AppInstallRoot -Config $Config)) {
                Write-Warn "InstallRoot does not look like an ESS app folder. Skipping root-folder deletion: $($Config.InstallRoot)"
                break
            }

            $statePath = Get-DeploymentStatePath -Config $Config
            if (Test-Path $statePath) {
                Remove-Item -Path $statePath -Force -ErrorAction SilentlyContinue
                Write-Success "Deleted deployment-state.json"
            }

            $logsPath = Join-Path $Config.InstallRoot "logs"
            if (Test-Path $logsPath) {
                Remove-Item -Path $logsPath -Recurse -Force -ErrorAction SilentlyContinue
                Write-Success "Deleted logs/ folder"
            }

            if (Test-Path $Config.InstallRoot) {
                try {
                    Remove-Item -Path $Config.InstallRoot -Recurse -Force -ErrorAction Stop
                    Write-Success "Deleted app folder: $($Config.InstallRoot)"
                }
                catch {
                    Write-Err "Could not fully delete app folder: $($Config.InstallRoot)"
                    $remaining = Get-ChildItem -Path $Config.InstallRoot -Force -ErrorAction SilentlyContinue
                    if ($remaining) {
                        Write-Host "    Remaining items: $($remaining.Name -join ', ')" -ForegroundColor Yellow
                    }
                }
            }

            Write-Success "Complete deployment uninstalled."
            Write-Success "Persistent storage preserved: $(Get-MediaStoragePath -Config $Config)"
        }
        "^4$" {
            # Service status / health check
            Initialize-Logger -Config $Config
            Show-Status -Config $Config
        }
        "^5$" {
            # Start services - sub-prompt
            Initialize-Logger -Config $Config
            Write-Host ""
            Write-Host " A) Start all services" -ForegroundColor White
            foreach ($c in Get-ServiceComponents -Config $Config) {
                $svc = Get-Service -Name $c.Service -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -eq 'Running') {
                    Write-Host " $($c.Num)) $($c.Display)" -ForegroundColor Green -NoNewline
                    Write-Host "  [ALREADY RUNNING]" -ForegroundColor Green
                } elseif ($svc) {
                    Write-Host " $($c.Num)) $($c.Display)" -ForegroundColor DarkYellow -NoNewline
                    Write-Host "  [STOPPED]" -ForegroundColor DarkYellow
                } else {
                    Write-Host " $($c.Num)) $($c.Display)" -ForegroundColor DarkGray -NoNewline
                    Write-Host "  [NOT INSTALLED]" -ForegroundColor DarkGray
                }
            }
            Write-Host " B) Back" -ForegroundColor Gray
            $sub = Read-Host "`nSelect to start"
            if ($sub -match '^[Aa]$') {
                Start-AllServices -Config $Config
            } elseif ($sub -match '^\d+$') {
                $c = Get-ServiceComponents -Config $Config | Where-Object { "$($_.Num)" -eq $sub } | Select-Object -First 1
                if ($c) {
                    $svc = Get-Service -Name $c.Service -ErrorAction SilentlyContinue
                    if (-not $svc) {
                        Write-Warn "$($c.Display) is not installed."
                        Write-Log "Start failed: $($c.Display) not installed" -Level "WARN"
                    } elseif ($svc.Status -eq 'Running') {
                        Write-Warn "$($c.Display) is already running."
                        Write-Log "Start skipped: $($c.Display) already running" -Level "INFO"
                    } else {
                        Start-Service -Name $c.Service -ErrorAction Stop
                        Write-Success "Started $($c.Display)"
                        # Show address information for the started service
                        switch ($c.Key) {
                            "frontend" { Write-Host "    Address: http://localhost:$($Config.FrontendPort)" -ForegroundColor Gray }
                            "backend"  { Write-Host "    Address: http://localhost:$($Config.BackendPort)$($Config.ApiPrefix)" -ForegroundColor Gray }
                            "caddy"    {
                                Start-Sleep -Seconds 2
                                $caddyPorts = Get-CaddyActualPorts -Config $Config
                                Write-Host "    Proxy: http://localhost:$($caddyPorts.proxy)" -ForegroundColor Gray
                                if ($caddyPorts.admin) {
                                    Write-Host "    Admin API: http://localhost:$($caddyPorts.admin)" -ForegroundColor Gray
                                }
                            }
                        }
                        Write-Log "Started $($c.Display)"
                    }
                }
            }
        }
        "^6$" {
            # Stop services - sub-prompt
            Initialize-Logger -Config $Config
            Write-Host ""
            Write-Host " A) Stop all services" -ForegroundColor White
            foreach ($c in Get-ServiceComponents -Config $Config) {
                $svc = Get-Service -Name $c.Service -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -eq 'Running') {
                    Write-Host " $($c.Num)) $($c.Display)" -ForegroundColor Green -NoNewline
                    Write-Host "  [RUNNING]" -ForegroundColor Green
                } elseif ($svc) {
                    Write-Host " $($c.Num)) $($c.Display)" -ForegroundColor DarkYellow -NoNewline
                    Write-Host "  [STOPPED]" -ForegroundColor DarkYellow
                } else {
                    Write-Host " $($c.Num)) $($c.Display)" -ForegroundColor DarkGray -NoNewline
                    Write-Host "  [NOT INSTALLED]" -ForegroundColor DarkGray
                }
            }
            Write-Host " B) Back" -ForegroundColor Gray
            $sub = Read-Host "`nSelect to stop"
            if ($sub -match '^[Aa]$') {
                Stop-AllServices -Config $Config
            } elseif ($sub -match '^\d+$') {
                $c = Get-ServiceComponents -Config $Config | Where-Object { "$($_.Num)" -eq $sub } | Select-Object -First 1
                if ($c) {
                    $svc = Get-Service -Name $c.Service -ErrorAction SilentlyContinue
                    if (-not $svc) {
                        Write-Warn "$($c.Display) is not installed."
                        Write-Log "Stop failed: $($c.Display) not installed" -Level "WARN"
                    } elseif ($svc.Status -ne 'Running') {
                        Write-Warn "$($c.Display) is already stopped."
                        Write-Log "Stop skipped: $($c.Display) already stopped" -Level "INFO"
                    } else {
                        Stop-Service -Name $c.Service -ErrorAction Stop
                        Write-Success "Stopped $($c.Display)"
                        Write-Log "Stopped $($c.Display)"
                    }
                }
            }
        }
        "^7$" {
            # Caddy network config
            Initialize-Logger -Config $Config
            Show-CaddyConfig -Config $Config
        }
        "^8$" {
            # Open logs folder
            $logsPath = Join-Path $Config.InstallRoot "logs"
            if (Test-Path $logsPath) { Invoke-Item $logsPath } else { Write-Warn "No logs folder yet." }
        }
        "^9$" {
            if (Test-DeploymentRollbackAvailable -Config $Config) {
                Initialize-Logger -Config $Config
                Show-RollbackMenu -Config $Config
            } else {
                Write-Warn "No previous successful deployment is available yet."
            }
        }
        "^[Qq]$" { Write-Host "`nBye." -ForegroundColor Cyan }
        default  { Write-Warn "Unknown option." }
    }

    if ($choice -notmatch '^[Qq]$') { Read-Host "`nPress Enter to continue" | Out-Null }

} while ($choice -notmatch '^[Qq]$')
