<#
.SYNOPSIS
    A mutual-exclusion lock over the test guest, for sessions driving it
    concurrently.

.DESCRIPTION
    More than one session drives the rig, and the task names do not collide:
    one uses MpcHarness, another VTunerFrame and VTunerMPC. Three things
    underneath are single-instance, though, and none of them announces
    contention:

      C:\mpc-hc\mpc-hc64.exe   both harnesses copy a binary over it. A swap
                               landing mid-run means the other session's scan
                               silently measures the wrong binary
      C:\vtuner\job.json       one file, read by both
      the tuner devices        Invoke-MpcScan disables and re-enables a device
                               before each run; landing that while another
                               session is tuned drops its lock and produces the
                               zero-channel signature that looks like a real
                               scan result

    The failure mode they share is the dangerous one: not an error, but
    plausible-looking output measured against the wrong thing. A binary being
    held open at least fails loudly. A binary replaced halfway through does
    not.

    So this exists to turn "did someone else touch the rig" from a silent
    contaminant into a refusal to start. It is deliberately a file rather than
    anything cleverer: any session, in any language, can honour it, and a
    human can read and delete it.

    Dot-source into a host-side script that already holds a PowerShell Direct
    session to the guest.

.EXAMPLE
    . "$PSScriptRoot\RigLock.ps1"
    $lock = Enter-RigLock -Session $s -Owner 'dvbEmulator' -Purpose 'frame capture'
    try   { ... }
    finally { Exit-RigLock -Session $s -Lock $lock }
#>

Set-StrictMode -Version Latest

$script:RigLockPath = 'C:\vtuner\rig.lock'

function Enter-RigLock {
    <#
    .SYNOPSIS
        Take the rig lock, or fail with who holds it.
    .PARAMETER Owner
        Session name recorded in the lock, so a holder can be identified and
        asked rather than guessed at.
    .PARAMETER WaitSeconds
        How long to keep trying before giving up. Zero fails immediately.
    .PARAMETER StaleMinutes
        A lock older than this is assumed abandoned and broken. A session that
        crashes mid-batch would otherwise block the rig indefinitely, and the
        rig is not valuable enough to warrant a manual unwedge every time.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] [string] $Owner,
        [string] $Purpose = '',
        [ValidateRange(0, 7200)] [int] $WaitSeconds = 0,
        # Minutes of heartbeat silence, not minutes held. A holder refreshes
        # every few seconds while it works, so this can be short: 45 minutes was
        # needed only because the old lock could not tell a long run from an
        # abandoned one.
        [ValidateRange(1, 1440)] [int] $StaleMinutes = 5
    )

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        $result = Invoke-Command -Session $Session -ArgumentList $script:RigLockPath, $Owner, $Purpose, $StaleMinutes -ScriptBlock {
            param($Path, $Owner, $Purpose, $StaleMinutes)

            New-Item -ItemType Directory -Force (Split-Path $Path -Parent) | Out-Null

            # heartbeatUtc is what makes staleness answerable instead of a
            # judgement call. A holder refreshes it while its run is alive, so a
            # lock seconds old is provably live and one minutes old is provably
            # not, and nobody has to decide whether to bypass it.
            #
            # That decision is what went wrong: this lock was released as stale
            # while the run holding it was still going, and two runs interleaved
            # on one guest. The lock did not fail. It could not prove it was
            # alive, and a flag that cannot prove it is live will eventually be
            # treated as dead, correctly or otherwise.
            #
            # holderPid is the second answer: a session can check whether that
            # process still exists rather than inferring from a clock.
            $now = (Get-Date).ToUniversalTime().ToString('o')
            $payload = [pscustomobject]@{
                owner        = $Owner
                purpose      = $Purpose
                acquiredUtc  = $now
                heartbeatUtc = $now
                holderPid    = $PID
                holderHost   = $env:COMPUTERNAME
            } | ConvertTo-Json -Compress

            # CreateNew is atomic: two sessions racing cannot both succeed,
            # which a Test-Path followed by a write would allow.
            try {
                $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew,
                                             [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                try {
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
                    $fs.Write($bytes, 0, $bytes.Length)
                } finally { $fs.Dispose() }
                return [pscustomobject]@{ Acquired = $true; Holder = $Owner; Broke = $false }
            } catch [System.IO.IOException] {
                # Held. Report by whom, and break it only if it is old enough
                # that the holder has almost certainly gone.
                $holder = 'unknown'; $age = $null
                try {
                    $existing = Get-Content $Path -Raw -ErrorAction Stop | ConvertFrom-Json
                    $holder = $existing.owner
                    # DateTimeOffset, not DateTime: [datetime]::Parse converts an
                    # offset-bearing ISO string to local time, and subtracting that
                    # from UtcNow adds the machine's UTC offset to every age. On a
                    # UTC-7 guest that made a fresh lock read as 420 minutes old,
                    # so the stale-break fired instantly and the lock never held.
                    # Age from the heartbeat, not from acquisition. A long run
                    # still working is not stale; a short one whose process died
                    # is. Falls back to acquiredUtc for a lock written before
                    # heartbeats existed.
                    $stamp = if ($existing.PSObject.Properties.Name -contains 'heartbeatUtc' -and $existing.heartbeatUtc) {
                        $existing.heartbeatUtc
                    } else { $existing.acquiredUtc }
                    $age = ([datetime]::UtcNow - [datetimeoffset]::Parse($stamp).UtcDateTime).TotalMinutes
                } catch {
                    # Unreadable lock: fall back to the file's own age.
                    try { $age = ((Get-Date) - (Get-Item $Path).LastWriteTime).TotalMinutes } catch { }
                }

                if ($null -ne $age -and $age -gt $StaleMinutes) {
                    Remove-Item $Path -Force -ErrorAction SilentlyContinue
                    return [pscustomobject]@{ Acquired = $false; Holder = $holder; Broke = $true; AgeMinutes = $age }
                }
                return [pscustomobject]@{ Acquired = $false; Holder = $holder; Broke = $false; AgeMinutes = $age }
            }
        }

        if ($result.Acquired) {
            Write-Verbose "Rig lock taken by $Owner"
            return [pscustomobject]@{ Owner = $Owner; Path = $script:RigLockPath }
        }

        if ($result.Broke) {
            # Loop round and try again immediately; the stale lock is gone.
            Write-Warning ("Broke a rig lock held by '{0}', {1:N0} minutes old — assuming that session ended." -f
                           $result.Holder, $result.AgeMinutes)
            continue
        }

        if ((Get-Date) -lt $deadline) { Start-Sleep -Seconds 5 }

    } while ((Get-Date) -lt $deadline)

    $msg = "The rig is held by '{0}'{1}. Nothing was started, because a run overlapping theirs would " +
           "measure the wrong binary or lose tuner lock and report it as an empty scan. " +
           "Wait, ask them, or delete {2} in the guest if you know that session has ended."
    throw ($msg -f $result.Holder,
                  $(if ($null -ne $result.AgeMinutes) { " (held {0:N0} minutes)" -f $result.AgeMinutes } else { '' }),
                  $script:RigLockPath)
}

function Exit-RigLock {
    <#
    .SYNOPSIS
        Release the rig lock, but only if it is still ours.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Session,
        [Parameter(Mandatory)] $Lock
    )

    Invoke-Command -Session $Session -ArgumentList $Lock.Path, $Lock.Owner -ScriptBlock {
        param($Path, $Owner)
        if (-not (Test-Path $Path)) { return }
        # If our lock went stale and someone else broke it, the file on disk is
        # now theirs. Deleting it would hand the rig to a third session while
        # they are still using it.
        try {
            $current = Get-Content $Path -Raw | ConvertFrom-Json
            if ($current.owner -ne $Owner) { return }
        } catch { }
        Remove-Item $Path -Force -ErrorAction SilentlyContinue
    } | Out-Null
}

function Get-RigLock {
    <#
    .SYNOPSIS
        Report who holds the rig, without taking or breaking anything.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Session)

    Invoke-Command -Session $Session -ArgumentList $script:RigLockPath -ScriptBlock {
        param($Path)
        if (-not (Test-Path $Path)) { return $null }
        try {
            $l = Get-Content $Path -Raw | ConvertFrom-Json
            [pscustomobject]@{
                Owner      = $l.owner
                Purpose    = $l.purpose
                # See Enter-RigLock: DateTimeOffset, or the age is off by the
                # guest's UTC offset.
                AgeMinutes = ([datetime]::UtcNow - [datetimeoffset]::Parse($l.acquiredUtc).UtcDateTime).TotalMinutes
            }
        } catch {
            [pscustomobject]@{ Owner = 'unreadable'; Purpose = ''; AgeMinutes = $null }
        }
    }
}

function Update-RigLock {
    <#
    .SYNOPSIS
        Refresh the heartbeat, proving the holder is still working.
    .DESCRIPTION
        Call periodically from a long run. Without it a lock cannot be told from
        an abandoned one except by guessing, and guessing is what caused two
        runs to interleave on one guest.

        Only refreshes a lock we still own: if ours was broken and someone else
        took it, refreshing would make their lock look like ours.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Session, [Parameter(Mandatory)] $Lock)

    Invoke-Command -Session $Session -ArgumentList $Lock.Path, $Lock.Owner -ScriptBlock {
        param($Path, $Owner)
        if (-not (Test-Path $Path)) { return }
        try {
            $l = Get-Content $Path -Raw | ConvertFrom-Json
            if ($l.owner -ne $Owner) { return }
            $l | Add-Member -NotePropertyName heartbeatUtc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
            $l | ConvertTo-Json -Compress | Set-Content $Path -Encoding UTF8
        } catch { }
    } | Out-Null
}
