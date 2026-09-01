<#
.SYNOPSIS
    Runs the whole virtual-tuner pipeline against the Hyper-V test guest:
    toolchain, build, sign, install, verify.

.DESCRIPTION
    Every phase runs from the host and drives the guest over PowerShell Direct,
    so this script is identical whoever executes it, interactively or
    under automation: if a step is blocked from reading the
    guest credential, the user can run this exact command instead and lose
    nothing.

    Phases are idempotent and individually selectable, because the loop that
    matters during driver work is edit-build-deploy, not the whole chain:

      Toolchain  Install the WDK 7600 build environment in the guest from the
                 ISO attached as a DVD. Slow, once per guest.
      Source     Copy the driver source into the guest.
      Build      setenv + build. The WDK 7600 environment is the one this
                 sample was written for, so no project conversion is needed.
      Sign       Create a test certificate in the guest, build the catalogue
                 with inf2cat, sign the .sys and .cat, and trust the
                 certificate locally. Test signing widens which roots the
                 kernel accepts; it does not permit unsigned drivers, so this
                 phase is required, not optional.
      Install    devcon install, DeviceInstanceID wiring, stream map import.
      Verify     Report the device's PnP status and the driver's view of it.

    The guest is checkpointed before the Install phase. A faulty AVStream
    driver bugchecks on load, and rolling back a checkpoint is much faster
    than repairing a boot loop.

.PARAMETER VMName
    Hyper-V guest. Must be running, with Secure Boot off.

.PARAMETER Standard
    Which tuner variant to build and install.

.PARAMETER Phase
    Phases to run, in order. Defaults to all of them.

.PARAMETER CredentialPath
    Exported PSCredential for the guest. The password is never rendered.

.PARAMETER StreamMap
    .reg from Provision-VTuner.ps1. Generate it with -GuestPath pointing at
    where the streams live *in the guest*, not on the host.

.EXAMPLE
    .\Build-And-Deploy.ps1 -VMName MyTestVM -Standard DVBT

.EXAMPLE
    .\Build-And-Deploy.ps1 -VMName MyTestVM -Standard DVBT -Phase Build,Sign,Install,Verify
#>
[CmdletBinding()]
param(
    # No default. This is a per-run action against the guest the caller holds,
    # and a default that silently picks one guest out of a pool is the trap
    # this whole arrangement exists to avoid. Take it from rig-claim.
    [Parameter(Mandatory)][string] $VMName,

    [ValidateSet('DVBT', 'DVBC', 'DVBS', 'ATSC', 'QAM')]
    [string]   $Standard = 'DVBT',

    [ValidateSet('Toolchain', 'Source', 'Build', 'Sign', 'Install', 'Verify')]
    [string[]] $Phase = @('Toolchain', 'Source', 'Build', 'Sign', 'Install', 'Verify'),

    [string]   $CredentialPath = '',   # empty: transport/config default,
    [string]   $StreamMap,
    [string]   $DeviceInstanceId = 'ROOT_MEDIA_0000',
    [switch]   $NoCheckpoint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$variants = @{
    DVBT = @{ Target = 'SWTDVBT'; HardwareId = 'ms_swtdvbt'; Dir = 'BDADVBTTuner' }
    DVBC = @{ Target = 'SWTDVBC'; HardwareId = 'ms_swtdvbc'; Dir = 'BDADVBCTuner' }
    DVBS = @{ Target = 'SWTDVBS'; HardwareId = 'ms_swtdvbs'; Dir = 'BDADVBSTuner' }
    ATSC = @{ Target = 'SWTATSC'; HardwareId = 'ms_swtatsc'; Dir = 'BDAATSCTuner' }
    QAM  = @{ Target = 'SWTQAM';  HardwareId = 'ms_swtqam';  Dir = 'BDAQAMTuner'  }
}
$v = $variants[$Standard]

$GuestSrc   = 'C:\vtuner\src'

# Per-variant staging. inf2cat catalogues an entire directory, so two driver
# packages sharing one output directory produce a catalogue covering both and
# a signature that does not match either package cleanly.
$GuestOut   = "C:\vtuner\out\$Standard"

# Where the WDK packages are installed to, and where they actually end up.
# The WDK 7600 MSIs carry their own directory structure inside them, so a
# TARGETDIR of X yields X\WinDDK\7600.16385.win7_wdk.<build>\... rather than X.
# The effective root is resolved from the guest by locating bin\setenv.bat.
$WdkInstallRoot = 'C:\WinDDK\7600.16385.1'
$WdkRoot        = $WdkInstallRoot
$MediaClass = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4D36E96C-E325-11CE-BFC1-08002BE10318}'
$RepoRoot   = Split-Path $PSScriptRoot -Parent

function Write-Phase { param([string] $Name) Write-Host "`n=== $Name ===" -ForegroundColor Cyan }

# --- Preconditions ---------------------------------------------------------

. (Join-Path $PSScriptRoot 'GuestTransport.ps1')
if ((Get-TestBedConfig).Transport -eq 'hyperv') {
    # Hyper-V-only preflight. On winrm/local the operator owns the
    # equivalents: the machine must be up, and Secure Boot must permit
    # the test-signed driver to load.
    $vm = Get-VM -Name $VMName -ErrorAction Stop
    if ($vm.State -ne 'Running') { throw "VM '$VMName' is $($vm.State). Start-VM -Name $VMName" }
    if ($vm.Generation -eq 2 -and (Get-VMFirmware -VMName $VMName).SecureBoot -eq 'On') {
        throw "Secure Boot is on for '$VMName', which blocks test signing. Stop-VM $VMName; Set-VMFirmware $VMName -EnableSecureBoot Off; Start-VM $VMName"
    }
}
if ($CredentialPath -and -not (Test-Path $CredentialPath)) { throw "Credential not found: $CredentialPath" }

$who = if ($CredentialPath) { (Import-Clixml $CredentialPath).UserName } else { 'the configured credential' }
Write-Host "Connecting to $VMName as $who ..." -ForegroundColor Cyan
$session = Connect-TestGuest -Guest $VMName -CredentialPath $CredentialPath

try {
    # --- Toolchain ---------------------------------------------------------

    # Resolve the effective WDK root, installing it first if it is absent.
    # Done before any phase so that Build, Sign and Install can all rely on it
    # regardless of which phases were selected.
    $resolveWdk = {
        $hit = Get-ChildItem $using:WdkInstallRoot -Recurse -Filter 'setenv.bat' -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { Split-Path (Split-Path $hit.FullName -Parent) -Parent } else { $null }
    }

    if ($Phase -contains 'Toolchain') {
        Write-Phase 'Toolchain'
        $found = Invoke-Command -Session $session -ScriptBlock $resolveWdk
        if ($found) {
            Write-Host "WDK already present at $found - skipping install." -ForegroundColor Green
        } else {
            Invoke-Command -Session $session -ScriptBlock { New-Item -ItemType Directory -Force 'C:\vtuner' | Out-Null }
            Copy-Item "$PSScriptRoot\Setup-GuestToolchain.ps1" -Destination 'C:\vtuner\Setup-GuestToolchain.ps1' -ToSession $session -Force
            Invoke-Command -Session $session -ScriptBlock {
                & 'C:\vtuner\Setup-GuestToolchain.ps1' -InstallRoot $using:WdkInstallRoot
            }
        }
    }

    $WdkRoot = Invoke-Command -Session $session -ScriptBlock $resolveWdk
    if (-not $WdkRoot) {
        throw "No WDK found under $WdkInstallRoot in the guest. Run with -Phase Toolchain first."
    }
    Write-Host "WDK root: $WdkRoot" -ForegroundColor DarkGray

    # --- Source ------------------------------------------------------------

    if ($Phase -contains 'Source') {
        Write-Phase 'Source'
        Invoke-Command -Session $session -ScriptBlock {
            New-Item -ItemType Directory -Force $using:GuestSrc | Out-Null
        }
        # Copy the shared driver sources plus only the variant being built.
        $files = Get-ChildItem "$RepoRoot\src\MergedDevice" -File
        foreach ($f in $files) {
            Copy-Item $f.FullName -Destination "$GuestSrc\$($f.Name)" -ToSession $session -Force
        }
        Invoke-Command -Session $session -ScriptBlock {
            New-Item -ItemType Directory -Force "$using:GuestSrc\$($using:v.Dir)" | Out-Null
        }
        foreach ($f in Get-ChildItem "$RepoRoot\src\MergedDevice\$($v.Dir)" -File) {
            Copy-Item $f.FullName -Destination "$GuestSrc\$($v.Dir)\$($f.Name)" -ToSession $session -Force
        }
        Write-Host "Copied driver source for $Standard to $GuestSrc" -ForegroundColor Green
    }

    # --- Build -------------------------------------------------------------

    if ($Phase -contains 'Build') {
        Write-Phase 'Build'
        $build = Invoke-Command -Session $session -ScriptBlock {
            $dir = "$using:GuestSrc\$($using:v.Dir)"

            # Driven through a batch file rather than `cmd /c "<long string>"`:
            # cmd strips the outer quotes of a /c argument and then re-parses,
            # which mangles a command line containing several quoted paths.
            #
            # The kit root is passed to setenv UNQUOTED. setenv does a bare
            # `set BASEDIR=%1`, so quotes survive into BASEDIR and every path
            # it derives (%BASEDIR%\Bin and friends) comes out malformed --
            # which surfaces only as "The syntax of the command is incorrect."
            # This is why the kit must not be installed under a path
            # containing spaces.
            #
            # setenv must be `call`ed (it ends with an exit) and leaves the
            # working directory at the kit root, hence the explicit cd after.
            # no_oacr: without it the build routes every compile and link
            # through Bin\amd64\oacr\oacrcl, the static-analysis wrapper, which
            # is a separate WDK package (oacr_x86fre.msi) we do not install.
            # Its absence is not fatal to build.exe -- nmake runs with -i, so
            # each invocation fails with "The system cannot find the path
            # specified" and the build still reports "1 executable built"
            # while producing nothing. Turning OACR off uses cl.exe directly.
            $bat = @"
@echo off
call $using:WdkRoot\bin\setenv.bat $using:WdkRoot fre x64 win7 no_oacr
if errorlevel 1 exit /b 1
cd /d "$dir"
build -cZ
"@
            $batPath = 'C:\vtuner\build.bat'
            Set-Content -Path $batPath -Value $bat -Encoding ASCII

            $out = & cmd.exe /c $batPath 2>&1
            $code = $LASTEXITCODE

            # build.exe reports real errors in its logs, not on stdout.
            $logs = Get-ChildItem $dir -Filter 'build*.log' -ErrorAction SilentlyContinue |
                    ForEach-Object { "--- $($_.Name) ---`n" + (Get-Content $_.FullName -Tail 40 -ErrorAction SilentlyContinue | Out-String) }
            $errs = Get-ChildItem $dir -Filter 'build*.err' -ErrorAction SilentlyContinue |
                    ForEach-Object { "--- $($_.Name) ---`n" + (Get-Content $_.FullName -ErrorAction SilentlyContinue | Out-String) }

            [pscustomobject]@{
                ExitCode = $code
                Tail     = ($out | Select-Object -Last 40) -join "`n"
                Logs     = ($logs + $errs) -join "`n"
                Sys      = @(Get-ChildItem $dir -Recurse -Filter '*.sys' -ErrorAction SilentlyContinue |
                             Select-Object -ExpandProperty FullName)
            }
        }
        if ($build.Logs) { Write-Host $build.Logs -ForegroundColor DarkGray }
        Write-Host $build.Tail
        if ($build.Sys.Count -eq 0) {
            throw "Build produced no .sys. Exit code $($build.ExitCode). See the output above; build.exe writes detail to buildfre_win7_amd64.log in the source directory."
        }
        Write-Host "Built: $($build.Sys -join ', ')" -ForegroundColor Green

        # Stage the built driver package together for inf2cat, which requires
        # the INF and every file it copies to sit in one directory.
        Invoke-Command -Session $session -ScriptBlock {
            $dir = "$using:GuestSrc\$($using:v.Dir)"
            New-Item -ItemType Directory -Force $using:GuestOut | Out-Null
            Get-ChildItem $dir -Recurse -Include '*.sys', '*.inf' |
                ForEach-Object { Copy-Item $_.FullName -Destination $using:GuestOut -Force }
            Get-ChildItem $using:GuestOut | Select-Object Name, Length
        } | Format-Table -AutoSize | Out-String | Write-Host
    }

    # --- Sign --------------------------------------------------------------

    if ($Phase -contains 'Sign') {
        Write-Phase 'Sign'
        $sign = Invoke-Command -Session $session -ScriptBlock {
            $ErrorActionPreference = 'Stop'
            $out    = $using:GuestOut
            $target = $using:v.Target
            $log    = [System.Collections.Generic.List[string]]::new()

            $cert = Get-ChildItem Cert:\LocalMachine\My |
                    Where-Object { $_.Subject -eq 'CN=bda-vtuner test' -and $_.NotAfter -gt (Get-Date) } |
                    Select-Object -First 1
            if (-not $cert) {
                $cert = New-SelfSignedCertificate -Subject 'CN=bda-vtuner test' -Type CodeSigningCert `
                            -CertStoreLocation Cert:\LocalMachine\My -NotAfter (Get-Date).AddYears(5)
                $log.Add("created certificate $($cert.Thumbprint)")
            } else {
                $log.Add("using certificate $($cert.Thumbprint)")
            }

            # Trust it as a root (so the chain validates) and as a publisher
            # (so installation does not prompt).
            $tmp = "$env:TEMP\bda-vtuner-test.cer"
            Export-Certificate -Cert $cert -FilePath $tmp -Force | Out-Null
            Import-Certificate -FilePath $tmp -CertStoreLocation Cert:\LocalMachine\Root            | Out-Null
            Import-Certificate -FilePath $tmp -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
            $log.Add('certificate trusted as root and publisher')

            $inf2cat  = Get-ChildItem $using:WdkRoot -Recurse -Filter inf2cat.exe  -ErrorAction SilentlyContinue | Select-Object -First 1
            $signtool = Get-ChildItem $using:WdkRoot -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
                        Where-Object { $_.FullName -match '\\x64\\|\\amd64\\' } | Select-Object -First 1
            if (-not $inf2cat)  { throw 'inf2cat.exe not found in the WDK install' }
            if (-not $signtool) { throw 'signtool.exe not found in the WDK install' }

            $c = & $inf2cat.FullName /driver:"$out" /os:7_X64,Server2008R2_X64 2>&1
            $log.Add("inf2cat exit $LASTEXITCODE : $(($c | Select-Object -Last 3) -join ' | ')")

            # /sm selects the LocalMachine store. Without it signtool looks in
            # CurrentUser and reports "No certificates were found that met all
            # the given criteria" even though the thumbprint is correct.
            foreach ($f in @("$out\$target.cat", "$out\$target.sys")) {
                if (-not (Test-Path $f)) { throw "missing $f  [log: $($log -join ' / ')]" }
                $s = & $signtool.FullName sign /fd SHA256 /sm /sha1 $cert.Thumbprint /s My $f 2>&1
                if ($LASTEXITCODE -ne 0) {
                    throw "signtool failed on $(Split-Path $f -Leaf): $($s -join ' | ')  [log: $($log -join ' / ')]"
                }
                $log.Add("signed $(Split-Path $f -Leaf)")
            }

            # Name the boot entry explicitly and read the value back. A bare
            # `bcdedit /set testsigning on` has been observed to report success
            # while leaving nothing in {current}, which surfaces much later and
            # very confusingly as CM_PROB_UNSIGNED_DRIVER (Code 52) on a
            # correctly signed driver.
            $ts = ((bcdedit /enum '{current}' | Select-String 'testsigning\s+Yes') -ne $null)
            if (-not $ts) {
                $b = & bcdedit /set '{current}' testsigning on 2>&1
                $confirmed = ((bcdedit /enum '{current}' | Select-String 'testsigning\s+Yes') -ne $null)
                if (-not $confirmed) {
                    throw "Could not enable test signing: $b. Secure Boot must be off for this to take effect."
                }
                $log.Add('enabled test signing (verified) - REBOOT REQUIRED before the driver will load')
            } else {
                $log.Add('test signing already enabled')
            }
            [pscustomobject]@{ Log = $log; TestSigningWasOn = $ts }
        }
        $sign.Log | ForEach-Object { Write-Host "  $_" }
        if (-not $sign.TestSigningWasOn) {
            Write-Warning "Test signing was just enabled. Reboot the guest, then re-run with -Phase Install,Verify:"
            Write-Warning "  Restart-VM -Name $VMName -Force -Wait -For Heartbeat"
            return
        }
    }

    # --- Install -----------------------------------------------------------

    if ($Phase -contains 'Install') {
        Write-Phase 'Install'
        if (-not $NoCheckpoint) {
            $snap = "pre-vtuner-$Standard-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Checkpoint-VM -Name $VMName -SnapshotName $snap
            Write-Host "Checkpointed as '$snap'" -ForegroundColor Green

            # Checkpointing briefly suspends the guest, which drops the
            # PowerShell Direct session into a Broken state. Reconnect rather
            # than failing the phase that the checkpoint exists to protect.
            Remove-PSSession $session -ErrorAction SilentlyContinue
            $session = Connect-TestGuest -Guest $VMName -CredentialPath $CredentialPath
            Write-Host 'Reconnected after checkpoint.' -ForegroundColor DarkGray
        }

        $devcon = Invoke-Command -Session $session -ScriptBlock {
            (Get-ChildItem $using:WdkRoot -Recurse -Filter devcon.exe -ErrorAction SilentlyContinue |
             Where-Object { $_.FullName -match '\\amd64\\|\\x64\\' } | Select-Object -First 1).FullName
        }
        if (-not $devcon) { throw 'devcon.exe not found in the guest WDK install.' }

        if ($StreamMap) {
            if (-not (Test-Path $StreamMap)) { throw "Stream map not found: $StreamMap" }
            Copy-Item $StreamMap -Destination 'C:\vtuner\streammap.reg' -ToSession $session -Force
        }

        $install = Invoke-Command -Session $session -ScriptBlock {
            $log = [System.Collections.Generic.List[string]]::new()
            $o = & $using:devcon install "$using:GuestOut\$($using:v.Target).inf" $using:v.HardwareId 2>&1
            $log.Add("devcon exit $LASTEXITCODE : $($o -join ' | ')")

            # Match this variant specifically, not merely "Sample Tuner":
            # several tuners can be installed at once (DVBT alongside ATSC),
            # each with its own PSWTuner subtree, and writing DeviceInstanceID
            # across all of them would repoint a working device at the wrong
            # stream map.
            $keys = @(Get-ChildItem $using:MediaClass -ErrorAction SilentlyContinue |
                      Where-Object { $_.PSChildName -match '^\d{4}$' } |
                      Where-Object {
                          $d = (Get-ItemProperty $_.PSPath -Name DriverDesc -ErrorAction SilentlyContinue).DriverDesc
                          $d -and $d -match 'Sample Tuner' -and $d -match $using:Standard
                      })
            foreach ($k in $keys) {
                Set-ItemProperty -Path $k.PSPath -Name 'DeviceInstanceID' -Value $using:DeviceInstanceId -Type String
                $log.Add("DeviceInstanceID=$($using:DeviceInstanceId) on $($k.PSChildName)")
            }
            if ($keys.Count -eq 0) { $log.Add('WARNING: no Sample Tuner key found under the Media class') }

            if (Test-Path 'C:\vtuner\streammap.reg') {
                & reg.exe import 'C:\vtuner\streammap.reg' 2>&1 | Out-Null
                $log.Add("stream map import exit $LASTEXITCODE")
            }
            $log
        }
        $install | ForEach-Object { Write-Host "  $_" }
    }

    # --- Verify ------------------------------------------------------------

    if ($Phase -contains 'Verify') {
        Write-Phase 'Verify'
        $verify = Invoke-Command -Session $session -ScriptBlock {
            $dev = Get-PnpDevice -Class Media -ErrorAction SilentlyContinue |
                   Where-Object { $_.FriendlyName -match 'Sample Tuner' }
            $freqs = @()
            $base = "HKLM:\SYSTEM\PSWTuner\$using:DeviceInstanceId\Device Parameters"
            if (Test-Path $base) {
                $freqs = Get-ChildItem $base | ForEach-Object {
                    $p = Get-ItemProperty $_.PSPath
                    "{0} kHz -> {1} (lock={2})" -f $_.PSChildName, (Split-Path $p.StreamLocation -Leaf), $p.SignalLocked
                }
            }
            [pscustomobject]@{
                Devices  = $dev | Select-Object FriendlyName, Status, Problem
                Channels = $freqs
            }
        }
        if ($verify.Devices) {
            $verify.Devices | Format-Table -AutoSize | Out-String | Write-Host
            $bad = $verify.Devices | Where-Object { $_.Status -ne 'OK' }
            if ($bad) {
                Write-Warning 'Device present but not started. Problem 52 = signature rejected (check the Sign phase and that the guest rebooted after test signing was enabled).'
            } else {
                Write-Host 'Tuner started. In the guest, open MPC-HC:' -ForegroundColor Green
                Write-Host '  Options > Playback > Digital TV > BDA Tuner, then scan the band.' -ForegroundColor Green
            }
        } else {
            Write-Warning 'No Sample Tuner device found.'
        }
        if ($verify.Channels) {
            Write-Host "`nProvisioned channels:" -ForegroundColor Cyan
            $verify.Channels | ForEach-Object { Write-Host "  $_" }
        } else {
            Write-Warning 'No channels provisioned. Generate a map with Provision-VTuner.ps1 -GuestPath <path in guest> and pass -StreamMap.'
        }
    }
}
finally {
    if ($session -and $session.State -eq 'Opened') { Remove-PSSession $session }
}
