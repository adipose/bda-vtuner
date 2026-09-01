<#
.SYNOPSIS
    One-shot host-side setup: downloads and verifies everything the test bed
    needs -- the WDK 7600 ISO, the TSDuck portable build, ffmpeg -- extracts
    the WDK installation media, and creates the test bed configuration.

.DESCRIPTION
    Every phase is idempotent: an artefact that is already present and
    verifies is skipped, so re-running after a partial failure is the normal
    recovery path.

      Wdk     Download GRMWDK_EN_7600_1.ISO (SHA256-verified) into
              third_party\iso\ and extract its WDK\ installer directory to
              third_party\iso\wdk-media\WDK -- the directory
              Setup-GuestToolchain.ps1 consumes. The ISO is still publicly
              downloadable from Microsoft; archive.org mirrors the identical
              file (same published hash) as a fallback.
      Tsduck  Download the pinned TSDuck portable build and lay it out at
              third_party\bin\tsduck\TSDuck\bin\tsp.exe, where every script
              that needs it looks.
      FFmpeg  Install ffmpeg via winget if it is not already resolvable.
      Config  Create testbed.config.psd1 from testbed.sample.psd1 if no
              config exists anywhere in the transport's upward search path.
              In a submodule checkout (e.g. the MPC-HC test framework) the
              config is created at the superproject root, which the
              transport finds first.
      Verify  Re-check every artefact and summarise; exits non-zero if
              anything is missing.

    Getting the WDK media to the target afterwards is transport-specific;
    pass -Target to have this script do it, or do it by hand:

      hyperv       Add-VMDvdDrive -VMName <vm> -Path <the ISO> -- the
                   Toolchain phase of Build-And-Deploy.ps1 finds the DVD.
      winrm/local  copy third_party\iso\wdk-media to C:\vtuner\wdk-media on
                   the target; Setup-GuestToolchain.ps1 -IsoDrive
                   C:\vtuner\wdk-media consumes a plain directory as readily
                   as a DVD drive.

.PARAMETER Phase
    Which phases to run. Default: all of them.

.PARAMETER Target
    Optional: a target to stage the WDK media onto, using the configured
    transport (hyperv: attach the ISO as a DVD; winrm/local: copy the
    extracted media to C:\vtuner\wdk-media). Requires the Config phase to
    have produced a usable config first. If you run a claim broker, claim
    the target before passing it here.

.PARAMETER IsoDir
    Where the ISO and extracted media live. Default: third_party\iso under
    this repository (gitignored).

.PARAMETER Force
    Re-download and re-extract even when present artefacts verify.

.EXAMPLE
    .\tools\Install-TestBed.ps1
    .\tools\Install-TestBed.ps1 -Target MyTestVM
#>
[CmdletBinding()]
param(
    [ValidateSet('Wdk', 'Tsduck', 'FFmpeg', 'Config', 'Verify')]
    [string[]] $Phase = @('Wdk', 'Tsduck', 'FFmpeg', 'Config', 'Verify'),
    [string]   $Target,
    [string]   $IsoDir,
    [switch]   $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path $PSScriptRoot -Parent
if (-not $IsoDir) { $IsoDir = Join-Path $RepoRoot 'third_party\iso' }

# --- Pinned artefacts -------------------------------------------------------
#
# The ISO hash is cross-verified: the same file (size 649,877,504) is served
# by Microsoft's still-live direct link and mirrored on archive.org, whose
# published SHA1 (de6abdb8eb4e08942add4aa270c763ed4e3d8242) matches.
$WdkIsoName   = 'GRMWDK_EN_7600_1.ISO'
$WdkIsoSha256 = '5EDC723B50EA28A070CAD361DD0927DF402B7A861A036BBCF11D27EBBA77657D'
$WdkIsoUrls   = @(
    'https://download.microsoft.com/download/4/A/2/4A25C7D5-EFBE-4182-B6A9-AE6850409A78/GRMWDK_EN_7600_1.ISO'
    'https://archive.org/download/grmwdk-en-7600-1/GRMWDK_EN_7600_1.ISO'
)

# The version the streams and matrix were developed against; the zip's root
# directory is TSDuck\, so extracting into third_party\bin\tsduck yields the
# canonical third_party\bin\tsduck\TSDuck\bin\tsp.exe layout directly.
$TsduckTag    = 'v3.44-4676'
$TsduckZip    = 'TSDuck-Win64-3.44-4676-Portable.zip'
$TsduckSha256 = 'B0CA0F963FCD77488B8C32D6F9D85030DAA891ED753C36E57BBB458807A44EB1'
$TsduckUrl    = "https://github.com/tsduck/tsduck/releases/download/$TsduckTag/$TsduckZip"

$IsoPath   = Join-Path $IsoDir $WdkIsoName
$WdkMedia  = Join-Path $IsoDir 'wdk-media'
$TsduckDir = Join-Path $RepoRoot 'third_party\bin\tsduck'
$TspExe    = Join-Path $TsduckDir 'TSDuck\bin\tsp.exe'

function Write-Phase { param([string] $Name) Write-Host "`n=== $Name ===" -ForegroundColor Cyan }

function Test-FileHash {
    param([string] $Path, [string] $Sha256)
    (Test-Path $Path) -and ((Get-FileHash $Path -Algorithm SHA256).Hash -eq $Sha256)
}

function Get-Download {
    <#
        Download to <dest>.partial, verify the hash, then move into place --
        an interrupted transfer never leaves a plausible-looking file behind.
        Tries each URL in order; a hash mismatch is treated like a failed
        download and the next mirror is tried.
    #>
    param([string[]] $Urls, [string] $Dest, [string] $Sha256)

    New-Item -ItemType Directory -Force (Split-Path $Dest -Parent) | Out-Null
    $partial = "$Dest.partial"
    foreach ($url in $Urls) {
        Write-Host "Downloading $url" -ForegroundColor Cyan
        Remove-Item $partial -Force -ErrorAction SilentlyContinue
        try {
            Invoke-WebRequest -Uri $url -OutFile $partial -MaximumRetryCount 2 -RetryIntervalSec 5
        } catch {
            Write-Warning "Download failed: $($_.Exception.Message)"
            continue
        }
        if (Test-FileHash $partial $Sha256) {
            Move-Item $partial $Dest -Force
            return
        }
        Write-Warning "Hash mismatch from $url -- discarding."
        Remove-Item $partial -Force -ErrorAction SilentlyContinue
    }
    throw "Could not obtain $(Split-Path $Dest -Leaf) with SHA256 $Sha256 from any source."
}

# --- Wdk --------------------------------------------------------------------

if ($Phase -contains 'Wdk') {
    Write-Phase 'Wdk'

    if (-not $Force -and (Test-FileHash $IsoPath $WdkIsoSha256)) {
        Write-Host "ISO already present and verified: $IsoPath" -ForegroundColor Green
    } else {
        Get-Download -Urls $WdkIsoUrls -Dest $IsoPath -Sha256 $WdkIsoSha256
        Write-Host "ISO verified: $IsoPath" -ForegroundColor Green
    }

    # Extract the WDK\ installer directory (MSIs plus their external cabs).
    # Mount-DiskImage needs no third-party tools and no elevation; the mount
    # is released in finally so a copy failure does not strand a phantom
    # DVD drive.
    $mediaMarker = Join-Path $WdkMedia 'WDK\headers.msi'
    if (-not $Force -and (Test-Path $mediaMarker)) {
        Write-Host "WDK media already extracted: $WdkMedia" -ForegroundColor Green
    } else {
        Write-Host 'Mounting ISO and extracting WDK installer media ...' -ForegroundColor Cyan
        $img = Mount-DiskImage -ImagePath $IsoPath -PassThru
        try {
            $letter = ($img | Get-Volume).DriveLetter
            if (-not $letter) { throw "Mounted $IsoPath but no volume appeared." }
            $src = "${letter}:\WDK"
            if (-not (Test-Path (Join-Path $src 'headers.msi'))) {
                throw "No WDK\headers.msi on the mounted ISO -- wrong image?"
            }
            if (Test-Path $WdkMedia) { Remove-Item $WdkMedia -Recurse -Force }
            New-Item -ItemType Directory -Force $WdkMedia | Out-Null
            Copy-Item $src -Destination $WdkMedia -Recurse
        } finally {
            Dismount-DiskImage -ImagePath $IsoPath | Out-Null
        }
        Write-Host "WDK media extracted: $WdkMedia" -ForegroundColor Green
    }
}

# --- Tsduck -----------------------------------------------------------------

if ($Phase -contains 'Tsduck') {
    Write-Phase 'Tsduck'

    if (-not $Force -and (Test-Path $TspExe)) {
        Write-Host "TSDuck already present: $TspExe" -ForegroundColor Green
    } else {
        $zip = Join-Path $env:TEMP $TsduckZip
        if (-not (Test-FileHash $zip $TsduckSha256)) {
            Get-Download -Urls @($TsduckUrl) -Dest $zip -Sha256 $TsduckSha256
        }
        if (Test-Path $TsduckDir) { Remove-Item $TsduckDir -Recurse -Force }
        New-Item -ItemType Directory -Force $TsduckDir | Out-Null
        Expand-Archive -Path $zip -DestinationPath $TsduckDir
        if (-not (Test-Path $TspExe)) { throw "Extracted $TsduckZip but $TspExe did not appear." }
        Remove-Item $zip -Force
    }
    $tspVersion = (& $TspExe --version 2>&1 | Select-Object -First 1)
    Write-Host "tsp runs: $tspVersion" -ForegroundColor Green
}

# --- FFmpeg -----------------------------------------------------------------

function Resolve-FFmpegPath {
    # Mirrors New-TestStreams.ps1: PATH first, then the winget package tree,
    # which winget populates without always updating PATH for the session.
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $hit = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
}

if ($Phase -contains 'FFmpeg') {
    Write-Phase 'FFmpeg'
    $ff = Resolve-FFmpegPath
    if ($ff) {
        Write-Host "ffmpeg already present: $ff" -ForegroundColor Green
    } elseif (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id Gyan.FFmpeg --accept-source-agreements --accept-package-agreements
        $ff = Resolve-FFmpegPath
        if ($ff) { Write-Host "ffmpeg installed: $ff" -ForegroundColor Green }
        else     { Write-Warning 'winget reported success but ffmpeg did not resolve; open a new shell or install manually.' }
    } else {
        Write-Warning 'winget not available. Install ffmpeg manually (https://ffmpeg.org) and put it on PATH.'
    }
}

# --- Config -----------------------------------------------------------------

if ($Phase -contains 'Config') {
    Write-Phase 'Config'

    # Same upward walk the transport performs: nearest config wins, so only
    # create one if the walk finds nothing.
    $existing = $null
    $probe = $RepoRoot
    for ($i = 0; $i -lt 5 -and $probe; $i++) {
        $cand = Join-Path $probe 'testbed.config.psd1'
        if (Test-Path $cand) { $existing = $cand; break }
        $probe = Split-Path $probe -Parent
    }

    if ($existing) {
        Write-Host "Config already exists: $existing" -ForegroundColor Green
    } else {
        # A .git *file* (not directory) means this checkout is a submodule;
        # the superproject root is then the right home for the config, since
        # one file there configures every suite.
        $dest = $RepoRoot
        if (Test-Path (Join-Path $RepoRoot '.git') -PathType Leaf) {
            $dest = Split-Path $RepoRoot -Parent
        }
        $destFile = Join-Path $dest 'testbed.config.psd1'
        Copy-Item (Join-Path $RepoRoot 'testbed.sample.psd1') $destFile
        Write-Host "Created $destFile -- edit it to point at your target (see README, 'Where it runs')." -ForegroundColor Yellow
    }
}

# --- Stage to a target ------------------------------------------------------

if ($Target) {
    Write-Phase "Stage to $Target"
    . (Join-Path $PSScriptRoot 'GuestTransport.ps1')
    $transport = (Get-TestBedConfig).Transport

    if ($transport -eq 'hyperv') {
        if (-not (Test-Path $IsoPath)) { throw "No ISO at $IsoPath -- run the Wdk phase first." }
        # Match by file name, not full path: the operator may already have the
        # same ISO attached from somewhere else, and a second DVD drive with
        # the identical image helps nobody.
        $attached = Get-VMDvdDrive -VMName $Target -ErrorAction Stop |
                    Where-Object { $_.Path -and (Split-Path $_.Path -Leaf) -eq $WdkIsoName }
        if ($attached) {
            Write-Host "ISO already attached to $Target." -ForegroundColor Green
        } else {
            Add-VMDvdDrive -VMName $Target -Path $IsoPath
            Write-Host "Attached $WdkIsoName to $Target as a DVD drive." -ForegroundColor Green
        }
    } else {
        if (-not (Test-Path (Join-Path $WdkMedia 'WDK\headers.msi'))) { throw "No extracted media at $WdkMedia -- run the Wdk phase first." }
        $session = Connect-TestGuest -Guest $Target
        try {
            Write-Host "Copying WDK media to C:\vtuner\wdk-media on $Target ..." -ForegroundColor Cyan
            Invoke-Command -Session $session { New-Item -ItemType Directory -Force 'C:\vtuner\wdk-media' | Out-Null }
            Copy-Item (Join-Path $WdkMedia 'WDK') -Destination 'C:\vtuner\wdk-media\WDK' -ToSession $session -Recurse -Force
            Write-Host "Done. Setup-GuestToolchain.ps1 -IsoDrive C:\vtuner\wdk-media will find it." -ForegroundColor Green
        } finally {
            Remove-PSSession $session
        }
    }
}

# --- Verify -----------------------------------------------------------------

if ($Phase -contains 'Verify') {
    Write-Phase 'Verify'
    $checks = @(
        @{ Name = 'WDK ISO (hash)';   Ok = (Test-FileHash $IsoPath $WdkIsoSha256);                  Detail = $IsoPath }
        @{ Name = 'WDK media';        Ok = [bool](Test-Path (Join-Path $WdkMedia 'WDK\headers.msi')); Detail = $WdkMedia }
        @{ Name = 'TSDuck tsp.exe';   Ok = [bool](Test-Path $TspExe);                               Detail = $TspExe }
        @{ Name = 'ffmpeg';           Ok = [bool](Resolve-FFmpegPath);                              Detail = (Resolve-FFmpegPath) }
        @{ Name = 'testbed config';   Ok = $false;                                                  Detail = '' }
    )
    $probe = $RepoRoot
    for ($i = 0; $i -lt 5 -and $probe; $i++) {
        $cand = Join-Path $probe 'testbed.config.psd1'
        if (Test-Path $cand) { $checks[-1].Ok = $true; $checks[-1].Detail = $cand; break }
        $probe = Split-Path $probe -Parent
    }

    $missing = 0
    foreach ($c in $checks) {
        if ($c.Ok) { Write-Host ("  OK      {0}  ({1})" -f $c.Name, $c.Detail) -ForegroundColor Green }
        else       { Write-Host ("  MISSING {0}" -f $c.Name) -ForegroundColor Red; $missing++ }
    }
    if ($missing) { exit 1 }

    Write-Host "`nTest bed ready. Next:" -ForegroundColor Cyan
    Write-Host '  1. Edit testbed.config.psd1 for your target (README: Where it runs).'
    Write-Host "  2. Stage the WDK media:  .\tools\Install-TestBed.ps1 -Target <name>"
    Write-Host '  3. Build and install the driver:  .\tools\Build-And-Deploy.ps1 -VMName <name> -Standard DVBT'
}
