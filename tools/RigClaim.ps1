<#
.SYNOPSIS
    Claim a test guest from the session manager's rig pool.

.DESCRIPTION
    There is no longer one shared guest. The manager brokers a pool of clones
    (e.g. guest, guest-2, guest-3) and hands one session exclusive use of one
    guest. Claiming is what makes that exclusive: a session that scans without
    claiming is invisible to the broker and can be handed a guest another
    session is already driving.

    The clones are full copies of the original as it stood, so they share its
    computer name, its ROOT\MEDIA device instance IDs, its PSWTuner stream map
    and its C:\ts library. Their network adapters are disconnected precisely
    because they would fight over that shared name, so everything here goes
    over PowerShell Direct, which is what the harness already used.

    Two consequences the caller does not get to ignore:

      The guest you are given is not necessarily the one you had last time.
      Anything you assume is already deployed may be a clone-time copy of it
      instead. Deploy what you intend to measure, every run.

      The clone was imaged from a running guest, so whatever was in
      C:\vtuner\rig.lock at that moment is now in all three copies. On a guest
      the broker has just granted us, such a lock is by definition not live --
      nobody else can be holding a rig that is exclusively ours. Enter-RigClaim
      clears it, or the first scan on a fresh guest waits out the stale timeout
      for a session that was never there.

.EXAMPLE
    . "$PSScriptRoot\RigClaim.ps1"
    $claim = Enter-RigClaim
    try     { ... use $claim.Guest ... }
    finally { Exit-RigClaim -Claim $claim }
#>

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'GuestTransport.ps1')

# Broker path comes from testbed.config.psd1; empty disables pooling entirely
# and the functions below degrade to a single configured guest with no-op
# claims -- which is what a reproduction without the session manager gets.
$script:BrokerCtl = (Get-TestBedConfig).BrokerPath

function Invoke-RigBroker {
    param([Parameter(Mandatory)][ValidateSet('rig-claim', 'rig-release', 'rig-status', 'whoami')][string] $Verb,
          [string] $CtlPath = $script:BrokerCtl)

    if (-not $CtlPath -or -not (Test-Path $CtlPath)) {
        throw "no rig broker configured (BrokerPath in testbed.config.psd1); pooling is unavailable."
    }
    # Child scope with StrictMode off. This file sets it to Latest, and it is
    # dynamically scoped, so it would otherwise apply inside the broker script --
    # which reads $parsed.text on responses that do not carry it and throws
    # under strict mode. The control script is not ours to change, and a
    # caller's strictness is not its contract to satisfy.
    $raw = & {
        Set-StrictMode -Off
        & $CtlPath $Verb 2>&1 | Select-Object -Last 1
    }
    try { return $raw | ConvertFrom-Json }
    catch { throw "$Verb returned something that is not JSON: $raw" }
}

function Get-RigClaims {
    <#
    .SYNOPSIS
        Who holds which guest. Readable by any session, claims nothing.
    #>
    [CmdletBinding()] param([string] $CtlPath = $script:BrokerCtl)
    (Invoke-RigBroker -Verb 'rig-status' -CtlPath $CtlPath).rigs
}

function Enter-RigClaim {
    <#
    .SYNOPSIS
        Take a guest from the pool, or explain who has them all.
    .PARAMETER VMName
        Skip brokering and use this guest. The escape hatch for driving a
        specific rig by hand; nothing is claimed, so nothing is released, and
        no pre-existing lock is cleared -- another session may hold it validly.
    #>
    [CmdletBinding()]
    param([string] $VMName, [string] $CtlPath = $script:BrokerCtl)

    if (-not $CtlPath -or -not (Test-Path $CtlPath)) {
        # No broker: single-guest mode. The claim is a no-op and the guest is
        # whatever the config names. Exclusivity is the operator's problem on
        # a one-guest bench, exactly as it would be with real hardware.
        $g = if ($VMName) { $VMName } else { (Get-TestBedConfig).Guest }
        Write-Verbose "no broker; single-guest mode on $g"
        return [pscustomobject]@{ Guest = $g; Claimed = $false; Since = $null }
    }

    if ($VMName) {
        # The escape hatch is for driving a named rig by hand -- but it made the
        # run invisible to the broker -- which once put an unclaimed scan on a
        # guest another session had claimed legitimately. The named-guest
        # path now at least refuses when the broker says the guest is someone
        # else's; a caller who truly must override can rig-release first.
        try {
            $holder = (Get-RigClaims -CtlPath $CtlPath | Where-Object { $_.guest -eq $VMName }).session
            $me = Get-BrokerSession -CtlPath $CtlPath
            if ($holder -and $holder -ne $me) {
                throw ("cannot use $VMName directly: the broker says '$holder' holds it. An unclaimed run on " +
                       "a claimed guest is invisible contamination -- exactly what claiming exists to prevent. " +
                       "Wait, or ask them.")
            }
        } catch [System.Management.Automation.RuntimeException] { throw }
          catch { Write-Verbose "broker unreachable; proceeding on $VMName as a hand-driven rig" }
        Write-Verbose "using $VMName directly; not claiming"
        return [pscustomobject]@{ Guest = $VMName; Claimed = $false; Since = $null }
    }

    $r = Invoke-RigBroker -Verb 'rig-claim' -CtlPath $CtlPath
    if (-not $r.ok -or -not $r.guest) {
        $held = try {
            (Get-RigClaims -CtlPath $CtlPath |
                ForEach-Object { "  {0} -> {1}" -f $_.guest, $(if ($_.session) { $_.session } else { 'free' }) }) -join "`n"
        } catch { '  (rig-status unavailable)' }
        throw ("no rig available: {0}`nCurrently:`n{1}" -f
               $(if ($r.PSObject.Properties.Name -contains 'outcome' -and $r.outcome) { $r.outcome } else { 'claim refused' }),
               $held)
    }

    Write-Verbose "claimed $($r.guest)"
    [pscustomobject]@{ Guest = $r.guest; Claimed = $true; Since = (Get-Date).ToUniversalTime() }
}

function Clear-InheritedRigLock {
    <#
    .SYNOPSIS
        Drop a rig.lock that came in with the clone image.
    .DESCRIPTION
        Only safe on a guest we hold by claim, which is why the caller has to
        say so. The broker granting us the guest is what makes any lock on it
        dead by definition; on a guest reached with -VMName that reasoning does
        not hold and the lock may be someone's live one.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Session, [Parameter(Mandatory)] $Claim)

    if (-not $Claim.Claimed) { return }

    Invoke-Command -Session $Session -ScriptBlock {
        $p = 'C:\vtuner\rig.lock'
        if (-not (Test-Path $p)) { return }
        $owner = try { (Get-Content $p -Raw | ConvertFrom-Json).owner } catch { 'unreadable' }
        Remove-Item $p -Force -ErrorAction SilentlyContinue
        "cleared an inherited rig.lock (owner '$owner') -- it came in with the clone image"
    } | ForEach-Object { if ($_) { Write-Warning $_ } }
}

function Exit-RigClaim {
    <#
    .SYNOPSIS
        Give the guest back. A claim held past the work is a guest nobody else
        can have.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Claim, [string] $CtlPath = $script:BrokerCtl)

    if (-not $Claim.Claimed) { return }
    try   { $r = Invoke-RigBroker -Verb 'rig-release' -CtlPath $CtlPath; Write-Verbose $r.outcome }
    catch { Write-Warning "could not release $($Claim.Guest): $($_.Exception.Message)" }
}

function Get-BrokerSession {
    <#
    .SYNOPSIS
        This session's name, as the broker knows it.
    #>
    [CmdletBinding()] param([string] $CtlPath = $script:BrokerCtl)
    (Invoke-RigBroker -Verb 'whoami' -CtlPath $CtlPath).session
}

function Get-FanOutTargets {
    <#
    .SYNOPSIS
        Every guest in the pool, but only when the whole pool is ours to change.

    .DESCRIPTION
        A test run uses the guest you hold. A change to what a guest IS -- the
        harness, the stream map, the driver -- has to reach all three, because
        the pool is only worth having while they are interchangeable.

        Which makes a partial fan-out worse than none at all. Skipping a guest
        another session is using leaves the three different while everyone
        still believes they are the same, and that difference then shows up as
        a result that depends on which rig you happened to draw. So this
        refuses the whole operation when any guest is held by someone else,
        and names who holds what, rather than doing part of the job quietly.
    #>
    [CmdletBinding()] param([string] $CtlPath = $script:BrokerCtl)

    $me   = Get-BrokerSession -CtlPath $CtlPath
    $rigs = @(Get-RigClaims -CtlPath $CtlPath)
    if (-not $rigs) { throw 'rig-status returned no guests; cannot fan out to a pool of none.' }

    $others = @($rigs | Where-Object { $_.session -and $_.session -ne $me })
    if ($others) {
        $who = ($rigs | ForEach-Object {
            "  {0,-18} {1}" -f $_.guest, $(if ($_.session) { $_.session } else { 'free' }) }) -join "`n"
        throw ("cannot fan out while part of the pool is in use. Changing what a guest is has to reach " +
               "all of them, and doing some now would leave them different while everyone still treats " +
               "them as identical.`nCurrently:`n$who`n" +
               "Wait for those sessions, or name guests explicitly with -VMName to override.")
    }
    ,@($rigs | ForEach-Object { $_.guest })
}

function Assert-RigIdentity {
    <#
    .SYNOPSIS
        Confirm the guest we reached is the guest we think we reached.

    .DESCRIPTION
        The clones share a computer name, so nothing the guest reports about
        itself distinguishes them. The manager therefore stamps each with
        C:\vtuner\rig-id.txt holding its own VM name, which is stronger than
        anything the caller can assert: our rigGuest records what we believed,
        this records what the guest is.

        A disagreement is not a warning. If the connection did not land where
        we think it did, we do not know which environment produced the result,
        and a result you cannot attribute is worse than no result -- it gets
        compared against others as though it were sound.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Session, [Parameter(Mandatory)][string] $Expected)

    if (-not (Get-TestBedConfig).RequireRigId) {
        # Identity files only distinguish clones that share a computer name; a
        # single-guest bench has nothing to confuse and nothing to stamp.
        Write-Verbose 'rig-id check skipped: RequireRigId is false'
        return $Expected
    }

    $actual = Invoke-Command -Session $Session -ScriptBlock {
        $p = 'C:\vtuner\rig-id.txt'
        if (Test-Path $p) { (Get-Content $p -Raw).Trim() } else { '' }
    }

    if (-not $actual) {
        throw ("guest has no C:\vtuner\rig-id.txt, so which of the clones this is cannot be " +
               "confirmed. Every guest in the pool is supposed to carry one; a guest without it " +
               "is either not from the pool or was provisioned before the file existed.")
    }
    if ($actual -ne $Expected) {
        throw ("rig identity mismatch: connected expecting '$Expected', but the guest says it is " +
               "'$actual'. Stopping rather than returning a result, because at this point the " +
               "environment that produced it is unknown.")
    }
    $actual
}
