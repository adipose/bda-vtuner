<#
.SYNOPSIS
    Installs (or removes) a virtual BDA tuner and wires it to its PSWTuner
    stream map.

.DESCRIPTION
    Installing the swtuner sample takes three steps, of which the WDK
    documentation automates none:

      1. devcon install <inf> <hardware-id>
      2. Locate the device's key under the Media setup class and add a
         DeviceInstanceID string. Without this the driver cannot find its
         PSWTuner subtree and every frequency reports no signal, which looks
         exactly like a broken driver.
      3. Import the stream map produced by Provision-VTuner.ps1.

    Step 2 is the fiddly one: the class subkey is an arbitrary four-digit
    ordinal assigned at install time, so it has to be found by matching
    DeviceDesc rather than assumed. This script does that matching.

    Requires an elevated session, and a machine in test-signing mode unless the
    driver has been production-signed.

.PARAMETER Standard
    Which tuner variant to install.

.PARAMETER DriverPath
    Directory holding the built .sys and .inf. Defaults to the repo's build output.

.PARAMETER StreamMap
    Optional .reg file from Provision-VTuner.ps1 to import after installation.

.PARAMETER DeviceInstanceId
    Must match the value used when the stream map was generated.

.PARAMETER Uninstall
    Remove the device and delete its PSWTuner subtree.

.EXAMPLE
    .\Install-VTuner.ps1 -Standard DVBT -StreamMap .\vtuner-dvbt.reg

.EXAMPLE
    .\Install-VTuner.ps1 -Standard DVBT -Uninstall
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('DVBT', 'DVBC', 'DVBS', 'ATSC', 'QAM')]
    [string] $Standard,

    [string] $DriverPath,
    [string] $StreamMap,
    [string] $DeviceInstanceId = 'ROOT_MEDIA_0000',
    [switch] $Uninstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Driver name, INF name and hardware ID per variant, taken from the INF
# templates in src\MergedDevice\BDA*Tuner\*.inx.
$variants = @{
    DVBT = @{ Target = 'SWTDVBT'; HardwareId = 'ms_swtdvbt' }
    DVBC = @{ Target = 'SWTDVBC'; HardwareId = 'ms_swtdvbc' }
    DVBS = @{ Target = 'SWTDVBS'; HardwareId = 'ms_swtdvbs' }
    ATSC = @{ Target = 'SWTATSC'; HardwareId = 'ms_swtatsc' }
    QAM  = @{ Target = 'SWTQAM';  HardwareId = 'ms_swtqam'  }
}
$v = $variants[$Standard]

# Media setup class. The installed device appears as a numbered subkey here.
$MediaClass = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E96C-E325-11CE-BFC1-08002BE10318}'

function Assert-Elevated {
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
                [Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw 'This script must run in an elevated session.'
    }
}

function Get-Devcon {
    $candidates = @(
        Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\Tools' -Recurse -Filter devcon.exe -ErrorAction SilentlyContinue
    ) | Where-Object { $_.FullName -match '\\x64\\' }

    if (-not $candidates) {
        throw 'devcon.exe not found. It ships in the WDK under Windows Kits\10\Tools\<arch>\. Install the WDK (winget install Microsoft.WindowsWDK.10.0.26100).'
    }
    ($candidates | Select-Object -First 1).FullName
}

function Find-DeviceKey {
    <#
        The sample's DeviceDesc strings all end in "Sample Tuner Device"
        (see the [Strings] section of each .inx). Match on that plus the
        standard name so multiple variants can coexist.
    #>
    param([string] $Standard)

    Get-ChildItem $MediaClass -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^\d{4}$' } |
        Where-Object {
            $desc = (Get-ItemProperty $_.PSPath -Name DriverDesc -ErrorAction SilentlyContinue).DriverDesc
            $desc -and $desc -match 'Sample Tuner' -and $desc -match $Standard
        }
}

Assert-Elevated

# --- Uninstall -------------------------------------------------------------

if ($Uninstall) {
    $devcon = Get-Devcon
    Write-Host "Removing $($v.HardwareId)..." -ForegroundColor Cyan
    & $devcon remove $v.HardwareId

    $pswKey = "HKLM:\SYSTEM\PSWTuner\$DeviceInstanceId"
    if (Test-Path $pswKey) {
        Remove-Item $pswKey -Recurse -Force
        Write-Host "Deleted $pswKey" -ForegroundColor Green
    }
    Write-Host 'Uninstalled.' -ForegroundColor Green
    return
}

# --- Install ---------------------------------------------------------------

if (-not $DriverPath) {
    $DriverPath = Join-Path $PSScriptRoot '..\build\out\x64'
}
$inf = Join-Path $DriverPath "$($v.Target).inf"
$sys = Join-Path $DriverPath "$($v.Target).sys"

foreach ($f in @($inf, $sys)) {
    if (-not (Test-Path $f)) {
        throw "Missing $f. Build the driver first, or pass -DriverPath."
    }
}

# Test signing is required for an unsigned kernel driver. Warn rather than
# fail, since a production-signed build would not need it.
$testsigning = (bcdedit /enum '{current}' | Select-String 'testsigning\s+Yes')
if (-not $testsigning) {
    Write-Warning 'Test signing does not appear to be enabled. An unsigned driver will fail to load with STATUS_INVALID_IMAGE_HASH (Code 52 in Device Manager).'
    Write-Warning 'To enable:  bcdedit /set testsigning on   (then reboot; Secure Boot must be off)'
}

$devcon = Get-Devcon
Write-Host "Installing $($v.Target) from $inf ..." -ForegroundColor Cyan
& $devcon install $inf $v.HardwareId
if ($LASTEXITCODE -ne 0) {
    throw "devcon install failed with exit code $LASTEXITCODE"
}

# Wire the device to its PSWTuner subtree.
$keys = @(Find-DeviceKey -Standard $Standard)
if ($keys.Count -eq 0) {
    throw "Installed the driver but could not find its key under the Media class. Look for a DriverDesc containing 'Sample Tuner' under $MediaClass and set DeviceInstanceID manually."
}
if ($keys.Count -gt 1) {
    Write-Warning "Found $($keys.Count) matching device keys; setting DeviceInstanceID on all of them."
}
foreach ($k in $keys) {
    Set-ItemProperty -Path $k.PSPath -Name 'DeviceInstanceID' -Value $DeviceInstanceId -Type String
    Write-Host "Set DeviceInstanceID=$DeviceInstanceId on $($k.PSChildName)" -ForegroundColor Green
}

# Import the stream map.
if ($StreamMap) {
    if (-not (Test-Path $StreamMap)) { throw "Stream map not found: $StreamMap" }
    & reg.exe import $StreamMap
    if ($LASTEXITCODE -ne 0) { throw "reg import failed with exit code $LASTEXITCODE" }
    Write-Host "Imported stream map $StreamMap" -ForegroundColor Green
}

Write-Host ''
Write-Host 'Installed. In MPC-HC: Options > Playback > Digital TV, pick the tuner' -ForegroundColor Cyan
Write-Host 'from the BDA Tuner dropdown, then run a channel scan across the band.' -ForegroundColor Cyan
