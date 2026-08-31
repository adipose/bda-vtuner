<#
.SYNOPSIS
    Creates a test signing certificate if needed, builds a catalogue for the
    driver package, and signs both the catalogue and the .sys.

.DESCRIPTION
    On x64 Windows, "test signing mode" does not mean unsigned drivers load. It
    means the kernel will accept a certificate that chains to any root in the
    machine's trust store rather than only Microsoft's. The driver still has to
    be signed; what changes is who is allowed to have signed it.

    So the sequence is:

      1. Create a self-signed code-signing certificate (once) and keep it in
         CurrentUser\My. Export the public half so the test machine can trust it.
      2. Run inf2cat to produce a .cat listing the hashes of every file the INF
         installs. Windows validates the package against this.
      3. signtool the .cat and the .sys with that certificate.

    The certificate is self-signed and only meaningful on machines that have
    been told to trust it. It cannot be used to distribute a driver, which is
    the point.

.PARAMETER Standard
    Which tuner variant to sign.

.PARAMETER DriverPath
    Directory holding the built .sys and .inf.

.PARAMETER CertName
    Subject CN for the test certificate.

.PARAMETER CertOut
    Where to export the public certificate (.cer) for import on the test machine.

.PARAMETER OsTarget
    inf2cat operating system target list.

.EXAMPLE
    .\Sign-Driver.ps1 -Standard DVBT
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('DVBT', 'DVBC', 'DVBS', 'ATSC', 'QAM')]
    [string] $Standard,

    [string] $DriverPath,
    [string] $CertName = 'bda-vtuner test signing',
    [string] $CertOut,
    [string] $OsTarget = '10_X64'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$targets = @{
    DVBT = 'SWTDVBT'; DVBC = 'SWTDVBC'; DVBS = 'SWTDVBS'
    ATSC = 'SWTATSC'; QAM  = 'SWTQAM'
}
$target = $targets[$Standard]

if (-not $DriverPath) { $DriverPath = Join-Path $PSScriptRoot '..\build\out\x64' }
$DriverPath = (Resolve-Path $DriverPath).Path
if (-not $CertOut) { $CertOut = Join-Path $PSScriptRoot '..\build\bda-vtuner-test.cer' }

$sys = Join-Path $DriverPath "$target.sys"
$inf = Join-Path $DriverPath "$target.inf"
foreach ($f in @($sys, $inf)) {
    if (-not (Test-Path $f)) { throw "Missing $f. Build the driver first." }
}

# --- WDK tools -------------------------------------------------------------
#
# inf2cat and signtool live in the WDK/SDK bin directories, versioned by SDK
# build. Take the newest x64 copy of each.

function Find-KitTool {
    param([string] $Name)
    $hit = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' -Recurse -Filter $Name -ErrorAction SilentlyContinue |
           Where-Object { $_.FullName -match '\\x64\\' } |
           Sort-Object FullName -Descending |
           Select-Object -First 1
    if (-not $hit) {
        throw "$Name not found under Windows Kits\10\bin. Install the WDK: winget install Microsoft.WindowsWDK.10.0.26100"
    }
    $hit.FullName
}

$inf2cat  = Find-KitTool 'inf2cat.exe'
$signtool = Find-KitTool 'signtool.exe'

# --- Certificate -----------------------------------------------------------

$cert = Get-ChildItem Cert:\CurrentUser\My |
        Where-Object { $_.Subject -eq "CN=$CertName" -and $_.NotAfter -gt (Get-Date) } |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1

if (-not $cert) {
    Write-Host "Creating test certificate CN=$CertName ..." -ForegroundColor Cyan
    $cert = New-SelfSignedCertificate `
        -Subject "CN=$CertName" `
        -Type CodeSigningCert `
        -KeyUsage DigitalSignature `
        -CertStoreLocation Cert:\CurrentUser\My `
        -NotAfter (Get-Date).AddYears(5) `
        -KeyExportPolicy Exportable
    Write-Host "Created $($cert.Thumbprint)" -ForegroundColor Green
} else {
    Write-Host "Using existing certificate $($cert.Thumbprint)" -ForegroundColor Green
}

New-Item -ItemType Directory -Force (Split-Path $CertOut) | Out-Null
Export-Certificate -Cert $cert -FilePath $CertOut -Force | Out-Null
Write-Host "Exported public certificate to $CertOut" -ForegroundColor Green

# --- Catalogue -------------------------------------------------------------
#
# inf2cat requires the INF and every file it copies to sit in the same
# directory, which is why it runs against DriverPath rather than the source tree.

Write-Host "Building catalogue for $target ($OsTarget) ..." -ForegroundColor Cyan
& $inf2cat /driver:"$DriverPath" /os:$OsTarget /verbose
if ($LASTEXITCODE -ne 0) {
    throw "inf2cat failed with exit code $LASTEXITCODE. A common cause is the INF listing a file that is not present in $DriverPath."
}

$cat = Join-Path $DriverPath "$target.cat"
if (-not (Test-Path $cat)) { throw "inf2cat reported success but $cat was not produced." }

# --- Sign ------------------------------------------------------------------
#
# Timestamping is deliberately omitted: it requires network access and a
# self-signed test certificate gains nothing from it.

foreach ($f in @($cat, $sys)) {
    Write-Host "Signing $(Split-Path $f -Leaf) ..." -ForegroundColor Cyan
    & $signtool sign /v /fd SHA256 /sha1 $cert.Thumbprint /s My $f
    if ($LASTEXITCODE -ne 0) { throw "signtool failed on $f with exit code $LASTEXITCODE" }
}

Write-Host ''
& $signtool verify /pa /v $sys 2>&1 | Select-Object -Last 6

Write-Host ''
Write-Host "Signed. Deploy with:" -ForegroundColor Cyan
Write-Host "  .\Deploy-ToVM.ps1 -VMName MyTestVM -Standard $Standard" -ForegroundColor Cyan
