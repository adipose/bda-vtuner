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
    #>
    [CmdletBinding()]
    param()

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

    $cfg = Get-TestBedConfig
    if (-not $Guest) { $Guest = $cfg.Guest }
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
