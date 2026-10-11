<#
.SYNOPSIS
    One seam between the test bed and wherever MPC-HC actually runs.

.DESCRIPTION
    Everything guest-side in this project is plain Win32 -- registry,
    scheduled tasks, window messages, loopback HTTP -- and neither knows nor
    cares what is underneath it. The only Hyper-V-specific thing the host side
    ever did was open the session: PowerShell Direct (-VMName) is a Hyper-V
    transport. This file makes that seam explicit and swappable, so the
    project is reproducible by someone with no Hyper-V VM ready to go.

    Transports:

      hyperv   PowerShell Direct to a named VM. What this project's original
               rig uses, and the only transport that works when guests share a
               computer name with their network adapters disconnected.
      winrm    PowerShell remoting to a computer name. Any reachable Windows
               machine -- a VM on another hypervisor, a second PC, bare metal.
               Needs Enable-PSRemoting on the target and network reachability.
      local    A loopback WinRM session to this machine. The
               smallest-possible reproduction: driver, MPC-HC and harness all
               on one test-signed box. Needs Enable-PSRemoting locally.

    Configuration comes from testbed.config.psd1, found by walking upward
    from this file (so a superproject's root config wins); copy
    testbed.sample.psd1 and edit. Values not set fall back to placeholders
    that will not match any real machine -- create the config.

    The rig POOL (broker claims, rig-id identity, clone conventions) is
    Hyper-V-flavoured machinery and is optional with it: with no broker
    configured the pool degrades to a single named guest and claims become
    no-ops. Multi-machine WinRM pools would work, but nobody has needed one.

.EXAMPLE
    . "$PSScriptRoot\GuestTransport.ps1"
    $session = Connect-TestGuest -Guest 'test-guest-3'
    Invoke-Command -Session $session { hostname }
#>

Set-StrictMode -Version Latest

function Get-TestBedConfig {
    <#
    .SYNOPSIS
        The test bed configuration, with defaults matching the original rig.
    .PARAMETER Guest
        The guest about to be driven. When the config has a Guests block with
        an entry for it, that entry's CredentialPath, GuestConsoleUser,
        Checkpoint and RequireRigId replace the top-level ones, so a pool can
        mix guests with different accounts and checkpoints and a caller needs
        only the guest's name:

          Checkpoint = 'virtual-av-drivers-20261008'      # default for every guest
          Guests = @{
              'mpc-testbed-w11' = @{
                  CredentialPath   = 'C:\...\guest.cred.xml'
                  GuestConsoleUser = 'mpctest'
                  Checkpoint       = 'testbed-ready-20261011'
              }
          }

        Without -Guest, or for a guest with no entry, the top-level values.
    #>
    [CmdletBinding()]
    param([string] $Guest)

    # Walk upward from this file for testbed.config.psd1, so a superproject
    # holding this repository as a submodule configures everything from its
    # own root. Nearest wins; $env:VTUNER_TESTBED_CONFIG overrides outright.
    $cfg = @{}
    if ($env:VTUNER_TESTBED_CONFIG -and (Test-Path $env:VTUNER_TESTBED_CONFIG)) {
        $cfg = Import-PowerShellDataFile $env:VTUNER_TESTBED_CONFIG
    } else {
        $dir = Split-Path -Parent $PSScriptRoot   # repo root (this file lives in tools/)
        for ($i = 0; $i -lt 4 -and $dir; $i++) {
            $cand = Join-Path $dir 'testbed.config.psd1'
            if (Test-Path $cand) { $cfg = Import-PowerShellDataFile $cand; break }
            $dir = Split-Path -Parent $dir
        }
    }

    # Per-guest overrides, applied over the top-level keys for the guest being driven.
    if ($Guest -and $cfg.ContainsKey('Guests') -and $cfg.Guests -is [hashtable] -and $cfg.Guests.ContainsKey($Guest)) {
        $entry = $cfg.Guests[$Guest]
        foreach ($key in 'CredentialPath', 'GuestConsoleUser', 'Checkpoint', 'RequireRigId') {
            if ($entry.ContainsKey($key)) { $cfg[$key] = $entry[$key] }
        }
    }

    # Defaults are the original environment, so an unconfigured checkout on the
    # original machine behaves exactly as before.
    [pscustomobject]@{
        Transport      = if ($cfg.ContainsKey('Transport'))      { $cfg.Transport }      else { 'hyperv' }
        Guest          = if ($cfg.ContainsKey('Guest'))          { $cfg.Guest }          else { 'test-guest' }
        CredentialPath = if ($cfg.ContainsKey('CredentialPath')) { $cfg.CredentialPath } else { '' }
        # Path to the rig broker's control script; $null disables pooling and
        # every claim becomes a no-op against the single configured guest.
        BrokerPath     = if ($cfg.ContainsKey('BrokerPath'))     { $cfg.BrokerPath }     else { '' }
        # Pool identity checks (rig-id.txt) only make sense where clones share
        # a name; single-guest setups skip them.
        RequireRigId   = if ($cfg.ContainsKey('RequireRigId'))   { [bool]$cfg.RequireRigId } else { $false }
        # The interactive account on the guest console, needed where a task or
        # SID must name it explicitly (frame capture). Auto-detection covers
        # most paths; this covers the rest.
        GuestConsoleUser = if ($cfg.ContainsKey('GuestConsoleUser')) { $cfg.GuestConsoleUser } else { '' }
        # The checkpoint a run restores the guest to (Restore-TestGuest); '' when none is configured.
        Checkpoint       = if ($cfg.ContainsKey('Checkpoint'))       { $cfg.Checkpoint }       else { '' }
    }
}

function Connect-TestGuest {
    <#
    .SYNOPSIS
        Open a PSSession to the guest, by whatever transport is configured.
    .PARAMETER Guest
        Overrides the configured guest/computer name. For hyperv this is the
        VM name; for winrm the computer name; ignored for local.
    .PARAMETER CredentialPath
        Overrides the configured credential. An empty value on winrm/local
        uses the current user, which is the common case for a loopback session.
    #>
    [CmdletBinding()]
    param(
        [string] $Guest,
        [string] $CredentialPath
    )

    if (-not $Guest) { $Guest = (Get-TestBedConfig).Guest }
    $cfg = Get-TestBedConfig -Guest $Guest
    # Empty means "use the config", whether the caller omitted the parameter
    # or forwarded its own empty default -- every harness script now defaults
    # to '' so the config is the single source of credential truth.
    if (-not $CredentialPath) { $CredentialPath = $cfg.CredentialPath }

    $cred = $null
    if ($CredentialPath -and (Test-Path $CredentialPath)) { $cred = Import-Clixml $CredentialPath }

    switch ($cfg.Transport) {
        'hyperv' {
            if (-not $cred) { throw "hyperv transport needs a credential; none found at '$CredentialPath'. See testbed.sample.psd1." }
            New-PSSession -VMName $Guest -Credential $cred -ErrorAction Stop
        }
        'winrm' {
            if ($cred) { New-PSSession -ComputerName $Guest -Credential $cred -ErrorAction Stop }
            else       { New-PSSession -ComputerName $Guest -ErrorAction Stop }
        }
        'local' {
            # Loopback remoting rather than running in-process, so the
            # guest-side scripts see the same Invoke-Command world on every
            # transport and nothing needs two code paths.
            if ($cred) { New-PSSession -ComputerName 'localhost' -EnableNetworkAccess -Credential $cred -ErrorAction Stop }
            else       { New-PSSession -ComputerName 'localhost' -EnableNetworkAccess -ErrorAction Stop }
        }
        default { throw "unknown transport '$($cfg.Transport)' in testbed.config.psd1 (hyperv | winrm | local)" }
    }
}

function Restore-TestGuest {
    <#
    .SYNOPSIS
        Restore a Hyper-V guest to its own configured checkpoint, start it, and
        return once its console account has a desktop and the guest has gone idle.
    .DESCRIPTION
        The checkpoint comes from the config (Checkpoint, or the guest's entry in
        Guests), so a caller that was handed a guest by the pool needs only its
        name. Idle means total CPU under -IdlePercent for -IdleSeconds in a row;
        a guest just booted stays busy for minutes, and timed cases started on a
        busy guest flaked. After -IdleTimeoutMinutes it goes on with a warning.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Guest,
        [string] $Checkpoint,
        [int] $IdlePercent = 10,
        [int] $IdleSeconds = 30,
        [int] $IdleTimeoutMinutes = 10
    )
    $cfg = Get-TestBedConfig -Guest $Guest
    if ($cfg.Transport -ne 'hyperv') { throw "Restore-TestGuest needs the hyperv transport; '$($cfg.Transport)' is configured." }
    if (-not $Checkpoint) { $Checkpoint = $cfg.Checkpoint }
    if (-not $Checkpoint) { throw "No checkpoint configured for $Guest (Checkpoint, or Guests['$Guest'].Checkpoint, in testbed.config.psd1)." }

    if ((Get-VM -Name $Guest).State -ne 'Off') { Stop-VM -Name $Guest -TurnOff -Force }
    Restore-VMSnapshot -VMName $Guest -Name $Checkpoint -Confirm:$false
    Start-VM -Name $Guest

    $ready = Wait-TestGuestReady -Guest $Guest -IdlePercent $IdlePercent -IdleSeconds $IdleSeconds -IdleTimeoutMinutes $IdleTimeoutMinutes
    [pscustomobject]@{ Guest = $Guest; Checkpoint = $Checkpoint; Idle = $ready.Idle; BootToDesktopSec = $ready.BootToDesktopSec; IdleWaitSec = $ready.IdleWaitSec }
}

function Wait-TestGuestReady {
    <#
    .SYNOPSIS
        Wait until a guest that is booting (or has just booted) is ready for a
        run: its console account has a desktop, then the guest is idle.
    .DESCRIPTION
        The one boot wait for every guest. A heartbeat or an answering session
        only means the integration services are up; the desktop means autologon
        has happened. Idle means total CPU under -IdlePercent for -IdleSeconds
        in a row, sampled every 3 s; after -IdleTimeoutMinutes it goes on with a
        warning. A guest just booted stays busy for minutes (106 to 284 s on a
        Windows 11 guest), and timed cases started on a busy guest flaked, where
        a fixed sleep was either too short or wasted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Guest,
        [int] $DesktopTimeoutMinutes = 10,
        [int] $IdlePercent = 10,
        [int] $IdleSeconds = 30,
        [int] $IdleTimeoutMinutes = 10
    )
    $t0 = Get-Date
    $deadline = $t0.AddMinutes($DesktopTimeoutMinutes)
    $session = $null
    while (-not $session -and (Get-Date) -lt $deadline) {
        try {
            $s = Connect-TestGuest -Guest $Guest
            if (Invoke-Command -Session $s { [bool] (Get-Process explorer -ErrorAction SilentlyContinue) }) { $session = $s } else { Remove-PSSession $s }
        } catch { }
        if (-not $session) { Start-Sleep -Seconds 10 }
    }
    if (-not $session) { throw "$Guest did not reach its console desktop within $DesktopTimeoutMinutes minutes." }
    $desktopSec = [int] ((Get-Date) - $t0).TotalSeconds

    try {
        $started = Get-Date; $calmSince = $null; $cpu = $null; $idle = $false
        while (((Get-Date) - $started).TotalMinutes -lt $IdleTimeoutMinutes) {
            $cpu = Invoke-Command -Session $session { [int] (Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime }
            if ($cpu -lt $IdlePercent) {
                if (-not $calmSince) { $calmSince = Get-Date }
                if (((Get-Date) - $calmSince).TotalSeconds -ge $IdleSeconds) { $idle = $true; break }
            } else { $calmSince = $null }
            Start-Sleep -Seconds 3
        }
        if (-not $idle) { Write-Warning "$Guest did not stay under $IdlePercent% CPU for $IdleSeconds s within $IdleTimeoutMinutes min (last $cpu%); going on." }
        [pscustomobject]@{ Guest = $Guest; Idle = $idle; BootToDesktopSec = $desktopSec; IdleWaitSec = [int] ((Get-Date) - $started).TotalSeconds; LastCpu = $cpu }
    } finally { Remove-PSSession $session -ErrorAction SilentlyContinue }
}

function Test-GuestTransportAvailable {
    <#
    .SYNOPSIS
        Says whether the configured transport can work here, and why not.
    #>
    [CmdletBinding()]
    param()
    $cfg = Get-TestBedConfig
    switch ($cfg.Transport) {
        'hyperv' {
            if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
                return [pscustomobject]@{ Ok = $false; Reason = 'Hyper-V PowerShell module not present; switch Transport in testbed.config.psd1' } }
            [pscustomobject]@{ Ok = $true; Reason = '' }
        }
        default {
            if (-not (Test-WSMan -ErrorAction SilentlyContinue)) {
                return [pscustomobject]@{ Ok = $false; Reason = 'WinRM not running; Enable-PSRemoting on the target' } }
            [pscustomobject]@{ Ok = $true; Reason = '' }
        }
    }
}
