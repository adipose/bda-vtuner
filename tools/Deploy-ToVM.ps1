<#
.SYNOPSIS
    Deploys the signed virtual tuner into a Hyper-V test VM and installs it,
    using PowerShell Direct.

.DESCRIPTION
    Build and sign on the host, test in the VM. The host already has Visual
    Studio and the WDK; installing a 3 GB toolchain in the guest as well would
    only slow the edit/build/test loop.

    PowerShell Direct carries all of this over the VMBus, so the guest needs no
    network, no shared folder and no open firewall.

    Two phases:

      -Prepare   One-time per VM. Imports the test certificate into the guest's
                 Trusted Root and Trusted Publishers stores, enables test
                 signing, and reboots. Test signing lets the kernel accept a
                 certificate chaining to a root the machine trusts; it does not
                 permit genuinely unsigned drivers, which is why the certificate
                 import is not optional.

      (default)  Copies the driver package in, checkpoints the VM, installs the
                 device, wires DeviceInstanceID, and imports the stream map.

    The VM is checkpointed immediately before the driver is installed. A faulty
    AVStream driver bugchecks the guest on load, and recovering by rolling back
    a checkpoint is considerably faster than repairing a boot loop.

.PARAMETER VMName
    Target Hyper-V VM. Must be running, and must have Secure Boot off.

.PARAMETER Standard
    Which tuner variant to deploy.

.PARAMETER Credential
    Guest credentials. Prompted for if omitted.

.PARAMETER DriverPath
    Host directory holding the signed .sys, .inf and .cat.

.PARAMETER StreamMap
    Optional .reg from Provision-VTuner.ps1. Paths inside it must be valid
    *in the guest*, so generate it against the guest's view of the library.

.PARAMETER Prepare
    Run the one-time trust and test-signing setup, then reboot the guest.

.PARAMETER NoCheckpoint
    Skip the pre-install checkpoint.

.EXAMPLE
    .\Deploy-ToVM.ps1 -VMName MyTestVM -Standard DVBT -Prepare

.EXAMPLE
    .\Deploy-ToVM.ps1 -VMName MyTestVM -Standard DVBT -StreamMap .\vtuner-dvbt.reg
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    # No default, and required: per-run, against the guest the caller holds.
    [Parameter(Mandatory)][string] $VMName,

    [Parameter(Mandatory)]
    [ValidateSet('DVBT', 'DVBC', 'DVBS', 'ATSC', 'QAM')]
    [string] $Standard,

    [pscredential] $Credential,
    [string] $DriverPath,
    [string] $StreamMap,
    [string] $DeviceInstanceId = 'ROOT_MEDIA_0000',
    [switch] $Prepare,
    [switch] $NoCheckpoint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$variants = @{
    DVBT = @{ Target = 'SWTDVBT'; HardwareId = 'ms_swtdvbt' }
    DVBC = @{ Target = 'SWTDVBC'; HardwareId = 'ms_swtdvbc' }
    DVBS = @{ Target = 'SWTDVBS'; HardwareId = 'ms_swtdvbs' }
    ATSC = @{ Target = 'SWTATSC'; HardwareId = 'ms_swtatsc' }
    QAM  = @{ Target = 'SWTQAM';  HardwareId = 'ms_swtqam'  }
}
$v = $variants[$Standard]

$GuestStage = 'C:\vtuner'
$MediaClass = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E96C-E325-11CE-BFC1-08002BE10318}'

# --- Preconditions ---------------------------------------------------------

. (Join-Path $PSScriptRoot 'GuestTransport.ps1')
if ((Get-TestBedConfig).Transport -eq 'hyperv') {
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    if ($vm.State -ne 'Running') {
        throw "VM '$VMName' is $($vm.State). Start it first: Start-VM -Name $VMName"
    }
    if ($vm.Generation -eq 2) {
        $fw = Get-VMFirmware -VMName $VMName
        if ($fw.SecureBoot -eq 'On') {
            throw "VM '$VMName' has Secure Boot enabled, which blocks test signing. Turn it off with: Stop-VM $VMName; Set-VMFirmware $VMName -EnableSecureBoot Off; Start-VM $VMName"
        }
    }
    
    if (-not $Credential) {
        $Credential = Get-Credential -Message "Credentials for guest '$VMName'"
    }
    
    Write-Host "Connecting to $VMName over PowerShell Direct ..." -ForegroundColor Cyan
}

$session = Connect-TestGuest -Guest $VMName

try {
    # --- Prepare phase -----------------------------------------------------

    if ($Prepare) {
        $cer = Join-Path $PSScriptRoot '..\build\bda-vtuner-test.cer'
        if (-not (Test-Path $cer)) {
            throw "Test certificate not found at $cer. Run Sign-Driver.ps1 first."
        }

        Invoke-Command -Session $session -ScriptBlock {
            New-Item -ItemType Directory -Force $using:GuestStage | Out-Null
        }
        Copy-Item -Path $cer -Destination "$GuestStage\bda-vtuner-test.cer" -ToSession $session -Force

        $result = Invoke-Command -Session $session -ScriptBlock {
            $cerPath = "$using:GuestStage\bda-vtuner-test.cer"

            # The certificate must be trusted as a root (so the chain validates)
            # and as a publisher (so installation does not prompt).
            Import-Certificate -FilePath $cerPath -CertStoreLocation Cert:\LocalMachine\Root            | Out-Null
            Import-Certificate -FilePath $cerPath -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null

            $before = (bcdedit /enum '{current}' | Select-String 'testsigning\s+Yes') -ne $null
            bcdedit /set testsigning on | Out-Null

            [pscustomobject]@{
                AlreadyOn = $before
                Certs     = (Get-ChildItem Cert:\LocalMachine\Root |
                             Where-Object { $_.Subject -match 'bda-vtuner' }).Count
            }
        }

        Write-Host "Imported test certificate into guest trust stores ($($result.Certs) match)." -ForegroundColor Green
        if ($result.AlreadyOn) {
            Write-Host 'Test signing was already enabled.' -ForegroundColor Green
        } else {
            Write-Host 'Enabled test signing. Rebooting guest ...' -ForegroundColor Cyan
            Remove-PSSession $session
            Restart-VM -Name $VMName -Force -Wait -For Heartbeat
            Write-Host 'Guest rebooted. Re-run without -Prepare to deploy.' -ForegroundColor Green
        }
        return
    }

    # --- Deploy phase ------------------------------------------------------

    if (-not $DriverPath) { $DriverPath = Join-Path $PSScriptRoot '..\build\out\x64' }
    $DriverPath = (Resolve-Path $DriverPath).Path

    $files = @("$($v.Target).sys", "$($v.Target).inf", "$($v.Target).cat") |
             ForEach-Object { Join-Path $DriverPath $_ }
    foreach ($f in $files) {
        if (-not (Test-Path $f)) {
            throw "Missing $f. Build, then sign with Sign-Driver.ps1 -Standard $Standard."
        }
    }

    # devcon has to run inside the guest, so it travels with the package.
    $devcon = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\Tools' -Recurse -Filter devcon.exe -ErrorAction SilentlyContinue |
              Where-Object { $_.FullName -match '\\x64\\' } |
              Select-Object -First 1
    if (-not $devcon) { throw 'devcon.exe not found in the WDK on this host.' }

    # Confirm the guest will actually load the driver before spending a reboot
    # cycle finding out.
    $state = Invoke-Command -Session $session -ScriptBlock {
        [pscustomobject]@{
            TestSigning = ((bcdedit /enum '{current}' | Select-String 'testsigning\s+Yes') -ne $null)
            Trusted     = ((Get-ChildItem Cert:\LocalMachine\Root |
                            Where-Object { $_.Subject -match 'bda-vtuner' }).Count -gt 0)
        }
    }
    if (-not $state.TestSigning -or -not $state.Trusted) {
        throw "Guest is not ready (test signing: $($state.TestSigning), certificate trusted: $($state.Trusted)). Run with -Prepare first."
    }

    if (-not $NoCheckpoint) {
        $snap = "pre-vtuner-$Standard-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Write-Host "Checkpointing VM as '$snap' ..." -ForegroundColor Cyan
        Checkpoint-VM -Name $VMName -SnapshotName $snap
    }

    Invoke-Command -Session $session -ScriptBlock {
        New-Item -ItemType Directory -Force $using:GuestStage | Out-Null
    }
    foreach ($f in ($files + $devcon.FullName)) {
        Copy-Item -Path $f -Destination "$GuestStage\$(Split-Path $f -Leaf)" -ToSession $session -Force
    }
    if ($StreamMap) {
        Copy-Item -Path $StreamMap -Destination "$GuestStage\streammap.reg" -ToSession $session -Force
    }
    Write-Host "Staged driver package to $GuestStage in guest." -ForegroundColor Green

    $install = Invoke-Command -Session $session -ScriptBlock {
        $stage  = $using:GuestStage
        $target = $using:v.Target
        $hwid   = $using:v.HardwareId
        $devId  = $using:DeviceInstanceId
        $class  = $using:MediaClass
        $hasMap = [bool]$using:StreamMap

        $log = [System.Collections.Generic.List[string]]::new()

        $out = & "$stage\devcon.exe" install "$stage\$target.inf" $hwid 2>&1
        $log.Add("devcon exit $LASTEXITCODE : $($out -join ' | ')")

        $keys = @(Get-ChildItem $class -ErrorAction SilentlyContinue |
                  Where-Object { $_.PSChildName -match '^\d{4}$' } |
                  Where-Object {
                      $d = (Get-ItemProperty $_.PSPath -Name DriverDesc -ErrorAction SilentlyContinue).DriverDesc
                      $d -and $d -match 'Sample Tuner'
                  })
        foreach ($k in $keys) {
            Set-ItemProperty -Path $k.PSPath -Name 'DeviceInstanceID' -Value $devId -Type String
            $log.Add("DeviceInstanceID=$devId set on $($k.PSChildName)")
        }
        if ($keys.Count -eq 0) { $log.Add('WARNING: no Sample Tuner key found under the Media class') }

        if ($hasMap) {
            & reg.exe import "$stage\streammap.reg" 2>&1 | Out-Null
            $log.Add("stream map import exit $LASTEXITCODE")
        }

        # Problem 0 means the device started. 52 means the signature was
        # rejected, which points back at the trust setup rather than the driver.
        $dev = Get-PnpDevice -Class Media -ErrorAction SilentlyContinue |
               Where-Object { $_.FriendlyName -match 'Sample Tuner' }

        [pscustomobject]@{
            Log     = $log
            Devices = $dev | Select-Object FriendlyName, Status, Problem, InstanceId
        }
    }

    $install.Log | ForEach-Object { Write-Host "  $_" }
    Write-Host ''
    if ($install.Devices) {
        $install.Devices | Format-Table -AutoSize | Out-String | Write-Host
        $bad = $install.Devices | Where-Object { $_.Status -ne 'OK' }
        if ($bad) {
            Write-Warning "Device present but not started. Problem 52 = signature rejected; re-run with -Prepare. Check the guest's Device Manager for detail."
        } else {
            Write-Host 'Tuner installed and started. In the guest, open MPC-HC:' -ForegroundColor Green
            Write-Host '  Options > Playback > Digital TV > BDA Tuner, then scan the band.' -ForegroundColor Green
        }
    } else {
        Write-Warning 'No Sample Tuner device found after install. Check the devcon output above.'
    }
}
finally {
    if ($session -and $session.State -eq 'Opened') { Remove-PSSession $session }
}
