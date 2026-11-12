<#
.SYNOPSIS
    Ainotes installer for Windows.

.DESCRIPTION
    Downloads the current Ainotes release and installs it for the current
    user (no administrator rights required).

.EXAMPLE
    irm https://raw.githubusercontent.com/envsecure/ainotes/main/scripts/install.ps1 | iex

.EXAMPLE
    irm https://raw.githubusercontent.com/envsecure/ainotes/main/scripts/install.ps1 | iex
    # then, to remove it again:
    & "$env:LOCALAPPDATA\Programs\Ainotes\Uninstall.exe" /S

.PARAMETER Uninstall
    Remove a previous installation instead of installing.

.PARAMETER NoLaunch
    Do not start Ainotes after the installation.
#>

[CmdletBinding()]
param(
    [switch] $Uninstall,
    [switch] $NoLaunch
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo = 'envsecure/ainotes'
$BaseUrl = if ($env:AINOTES_BASE_URL) { $env:AINOTES_BASE_URL } else { "https://github.com/$Repo/releases/latest/download" }
$AssetSetup = 'Ainotes-Setup.exe'
$AssetSums = 'SHA256SUMS'

$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\Ainotes'
$ExePath = Join-Path $InstallDir 'Ainotes.exe'
$Uninstaller = Join-Path $InstallDir 'Uninstall.exe'

function Write-Step($message) { Write-Host "==> $message" -ForegroundColor Cyan }

function Get-Checksum($file) {
    (Get-FileHash -Path $file -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-Checksum($file, $name) {
    $sumsPath = Join-Path $env:TEMP "ainotes-$name.sums"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/$AssetSums" -OutFile $sumsPath
    } catch {
        Write-Warning 'checksum file not available, continuing without verification'
        return
    }
    $line = Get-Content $sumsPath | Where-Object { $_ -match "\s$([regex]::Escape($name))$" } | Select-Object -First 1
    if (-not $line) {
        Write-Warning "no checksum for $name in $AssetSums, continuing without verification"
        return
    }
    $expected = ($line -split '\s+')[0].ToLowerInvariant()
    $actual = Get-Checksum $file
    if ($expected -ne $actual) {
        throw "checksum mismatch for $name"
    }
    Write-Step 'checksum verified'
}

if ($Uninstall) {
    Write-Step 'removing Ainotes'
    if (Test-Path $Uninstaller) {
        $process = Start-Process -FilePath $Uninstaller -ArgumentList '/S' -Wait -PassThru
        Write-Step "uninstaller finished with exit code $($process.ExitCode)"
    } else {
        Write-Warning 'Ainotes is not installed'
    }
    if (Test-Path $InstallDir) {
        Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host 'Ainotes removed (your vaults and settings are kept)' -ForegroundColor Green
    return
}

if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'Ainotes needs a 64-bit Windows installation'
}

$temp = Join-Path $env:TEMP "ainotes-setup-$([guid]::NewGuid().ToString('N')).exe"
Write-Step 'downloading Ainotes'
try {
    Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/$AssetSetup" -OutFile $temp
    Assert-Checksum $temp $AssetSetup

    # Remove the mark-of-the-web so Windows does not ask for confirmation.
    try { Unblock-File -Path $temp } catch { }

    Write-Step 'installing Ainotes'
    $process = Start-Process -FilePath $temp -ArgumentList '/S' -Wait -PassThru
    if ($process.ExitCode -ne 0) {
        throw "the installer failed with exit code $($process.ExitCode)"
    }
} finally {
    Remove-Item -Path $temp -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path $ExePath)) {
    throw "installation finished but $ExePath is missing"
}

Write-Step 'Ainotes installed' -ForegroundColor Green
Write-Host "    start it with: $ExePath"

if (-not $NoLaunch) {
    Start-Process -FilePath $ExePath
}
