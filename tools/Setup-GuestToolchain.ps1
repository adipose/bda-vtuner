<#
.SYNOPSIS
    Installs the WDK 7600 build environment inside a Hyper-V guest from the
    WDK ISO attached as a DVD drive, then verifies the pieces the swtuner
    build actually needs.

.DESCRIPTION
    The swtuner sample was written for the WDK 7600 build environment, so
    building it there needs no project conversion at all: run `build` in
    src\MergedDevice and it emits the .sys files.

    KitSetup.exe is an interactive installer, so this installs the individual
    MSI packages directly with msiexec instead. The package set below is a
    superset of what a kernel driver build needs; installing more than
    necessary costs disk, whereas missing one produces a confusing build
    failure much later.

    Everything is verified afterwards by looking for the specific tools and
    libraries the build consumes, rather than trusting exit codes -- an MSI can
    report success while installing a feature set that does not include the
    file you needed.

.PARAMETER IsoDrive
    Drive letter of the mounted WDK ISO in the guest, or a directory
    holding the extracted media (a WDK\ subdirectory of MSIs). Omitted:
    C:\vtuner\wdk-media is probed first, then mounted DVD drives.

.PARAMETER InstallRoot
    Where the WDK lands. The default matches the kit's own convention.

.NOTES
    Intended to be run inside the guest, normally via PowerShell Direct from
    Deploy-ToVM.ps1. Requires elevation.
#>
[CmdletBinding()]
param(
    [string] $IsoDrive,
    [string] $InstallRoot = 'C:\WinDDK\7600.16385.1'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Locate the ISO --------------------------------------------------------

if (-not $IsoDrive) {
    # Staged media first (Install-TestBed.ps1 -Target copies it here on
    # transports without a DVD drive), then any mounted WDK ISO.
    if (Test-Path 'C:\vtuner\wdk-media\WDK\headers.msi') {
        $IsoDrive = 'C:\vtuner\wdk-media'
    } else {
        $dvd = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=5' |
               Where-Object { $_.DeviceID -and (Test-Path "$($_.DeviceID)\WDK\headers.msi") } |
               Select-Object -First 1
        if (-not $dvd) {
            throw 'No WDK media found. Stage it with Install-TestBed.ps1 -Target <name>, or attach the ISO: Add-VMDvdDrive -VMName <vm> -Path <iso>'
        }
        $IsoDrive = $dvd.DeviceID
    }
}
$wdk = Join-Path $IsoDrive 'WDK'
if (-not (Test-Path $wdk)) { throw "No WDK directory on $IsoDrive" }

Write-Host "Using WDK media at $wdk" -ForegroundColor Cyan

$isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw 'Must run elevated to install MSI packages.' }

# --- Packages --------------------------------------------------------------
#
# headers  : DDK and SDK headers, including bdamedia.h / bdatypes.h / ks.h
# libs     : DDK link libraries -- BdaSup.lib, ks.lib, ksguid.lib, ntstrsafe.lib
# buildtools: build.exe, nmake and the compilers. Both host architectures are
#             installed because the build environment picks its compiler by
#             host arch, and getting that wrong fails obscurely.
# drvtools  : devcon
# setuptools: stampinf, inf2cat
# generaltools / tools: supporting utilities the build environment expects

$packages = @(
    'headers.msi'
    'libs_x64fre.msi'
    'libs_x86fre.msi'
    'buildtools_x64fre.msi'
    'buildtools_x86fre.msi'
    'drvtools_x64fre.msi'
    'setuptools_x64fre.msi'
    'generaltools_x64fre.msi'
    'tools_x64fre.msi'
    'wdftools_x64fre.msi'
)

New-Item -ItemType Directory -Force $InstallRoot | Out-Null
$logDir = Join-Path $env:TEMP 'wdk-install-logs'
New-Item -ItemType Directory -Force $logDir | Out-Null

$results = [System.Collections.Generic.List[object]]::new()

foreach ($p in $packages) {
    $msi = Join-Path $wdk $p
    if (-not (Test-Path $msi)) {
        $results.Add([pscustomobject]@{ Package = $p; Exit = 'missing'; Note = 'not on media' })
        continue
    }

    $log = Join-Path $logDir ($p -replace '\.msi$', '.log')
    Write-Host "Installing $p ..." -ForegroundColor Cyan

    # TARGETDIR steers the kit into one tree. /qn keeps it silent; the WDK MSIs
    # are plain installers with no custom UI requirements.
    $proc = Start-Process msiexec -Wait -PassThru -ArgumentList @(
        '/i', "`"$msi`"", '/qn', '/norestart',
        "TARGETDIR=`"$InstallRoot`"",
        '/l*v', "`"$log`""
    )

    $results.Add([pscustomobject]@{
        Package = $p
        Exit    = $proc.ExitCode
        Note    = switch ($proc.ExitCode) {
                      0     { 'ok' }
                      3010  { 'ok, reboot queued' }
                      1603  { 'fatal -- see log' }
                      default { "see $log" }
                  }
    })
}

$results | Format-Table -AutoSize | Out-String | Write-Host

# --- Verify ----------------------------------------------------------------
#
# Check for the actual artefacts the swtuner build consumes. This is the part
# that matters: a clean msiexec run does not guarantee BdaSup.lib is present.

$checks = @{
    'build.exe'    = 'bin\x86\build.exe'
    'setenv.bat'   = 'bin\setenv.bat'
    'BdaSup.lib'   = 'lib\win7\amd64\BdaSup.lib'
    'ks.lib'       = 'lib\win7\amd64\ks.lib'
    'ksguid.lib'   = 'lib\win7\amd64\ksguid.lib'
    'ntstrsafe.lib'= 'lib\win7\amd64\ntstrsafe.lib'
    'bdamedia.h'   = 'inc\api\bdamedia.h'
    'devcon.exe'   = 'tools\devcon\amd64\devcon.exe'
    'stampinf.exe' = 'bin\x86\stampinf.exe'
    'inf2cat.exe'  = 'bin\selfsign\inf2cat.exe'
}

Write-Host 'Verifying build prerequisites:' -ForegroundColor Cyan
$missing = [System.Collections.Generic.List[string]]::new()
foreach ($name in ($checks.Keys | Sort-Object)) {
    $path = Join-Path $InstallRoot $checks[$name]
    if (Test-Path $path) {
        Write-Host ("  OK      {0}" -f $name) -ForegroundColor Green
    } else {
        # Fall back to a search: the kit moves some tools between layouts.
        $found = Get-ChildItem $InstallRoot -Recurse -Filter (Split-Path $checks[$name] -Leaf) -ErrorAction SilentlyContinue |
                 Select-Object -First 1
        if ($found) {
            Write-Host ("  OK      {0}  (at {1})" -f $name, $found.FullName.Replace($InstallRoot, '.')) -ForegroundColor Green
        } else {
            Write-Host ("  MISSING {0}  (expected {1})" -f $name, $checks[$name]) -ForegroundColor Red
            $missing.Add($name)
        }
    }
}

Write-Host ''
if ($missing.Count -gt 0) {
    Write-Warning "$($missing.Count) prerequisite(s) missing: $($missing -join ', '). Additional packages from $wdk may be required; logs are in $logDir."
    exit 1
}

Write-Host "WDK build environment ready at $InstallRoot" -ForegroundColor Green
Write-Host 'Build with:' -ForegroundColor Cyan
Write-Host "  cmd /c `"$InstallRoot\bin\setenv.bat $InstallRoot fre x64 win7 && cd /d C:\vtuner\src\MergedDevice && build -cZ`"" -ForegroundColor Cyan
