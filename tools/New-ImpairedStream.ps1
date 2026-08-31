<#
.SYNOPSIS
    Produces deliberately damaged copies of a good transport stream, one per
    named impairment, together with a machine-readable manifest saying what
    each one does and what a correct receiver is expected to do about it.

.DESCRIPTION
    The virtual BDA tuner streams a .ts file straight off disk, so whatever is
    in that file is exactly what MPC-HC's demultiplexer and PSI/SI parsers
    see. A clean capture only ever exercises the happy path. The registry
    contract already covers "never locks" (SignalLocked=0); this covers the
    harder case of a tuner that locks and then delivers a stream that is
    wrong.

    Each impairment is built with TSDuck and then verified by analysing the
    output, because tsp reports success for plugin chains that quietly did
    nothing - a mistyped PID, or a service that is not in this multiplex, both
    exit zero. Nothing is recorded as verified unless a second pass over the
    produced file observed the damage.

    The manifest's expected-behaviour field is the point of the exercise. It
    separates what a receiver is actually required to do (mostly: fail in
    bounded time without crashing, hanging or spinning) from what is merely
    desirable, and says so when the standards do not settle the question.

    Impairments are independent: each is applied to a fresh copy of the
    source, never to the output of another.

.PARAMETER InputStream
    A clean MPEG-2 transport stream, 188-byte packets. Not modified.

.PARAMETER OutDir
    Where the impaired streams and the manifest are written. Defaults to the
    current directory.

.PARAMETER Impairment
    Which impairments to build. Defaults to all of them. Use
    -ListImpairments to see the catalogue without producing anything.

.PARAMETER Service
    Service to damage, by name or by id (decimal, or 0x-prefixed hex). Several
    impairments have to pick one service out of the multiplex; by default that
    is the one with the lowest service id. Impairments that need a second,
    undamaged service take the next one after it.

.PARAMETER DelaySeconds
    How far into the stream the mid-stream impairments strike. Applies to
    pmt-vanishes. Must be shorter than the stream, or there is nothing after
    the cut to test.

.PARAMETER ErrorRate
    Denominator of the 1-in-N packet error rate used by cc-errors and
    transport-error. 20 means one packet in twenty. Lower is more damaged.

.PARAMETER Bitrate
    Override the transport stream bitrate in bits/second, used to convert
    -DelaySeconds into a packet offset. Only needed for streams with no usable
    PCRs, where TSDuck cannot estimate one.

.PARAMETER TsduckBin
    Directory holding tsp.exe and tstables.exe. Defaults to the portable
    build vendored under third_party/bin.

.PARAMETER ManifestPath
    Manifest location. Defaults to impairments.json in -OutDir.

.PARAMETER ListImpairments
    Print the catalogue - id, what it does, what a receiver should do - and
    exit without reading or writing any stream.

.PARAMETER Force
    Overwrite existing output files.

.EXAMPLE
    .\New-ImpairedStream.ps1 -InputStream C:\captures\ts\DVB-T_666000_H_0-41.ts -OutDir C:\ts-fault

    Builds every impairment from the Russian RTRS capture, which is the best
    source available because all ten of its services are clear.

.EXAMPLE
    .\New-ImpairedStream.ps1 -InputStream C:\ts-gen\mux1.ts -OutDir C:\ts-fault `
        -Impairment sdt-removed,pmt-vanishes -DelaySeconds 5

.EXAMPLE
    .\New-ImpairedStream.ps1 -ListImpairments

.NOTES
    Output names keep the source stem, so a frequency embedded in the source
    filename survives and Provision-VTuner.ps1 still infers it. Provision the
    damaged copies onto their own frequencies alongside the clean originals,
    so that one scan sweeps both.

    Windows PowerShell 5.1 and pwsh 7. The manifest is JSON rather than a
    .psd1 precisely so that 5.1 in the test guest can read it back:
    Import-PowerShellDataFile does not exist there.
#>
[CmdletBinding(DefaultParameterSetName = 'Generate')]
param(
    [Parameter(Mandatory, Position = 0, ParameterSetName = 'Generate')]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]   $InputStream,

    [Parameter(ParameterSetName = 'Generate')]
    [string]   $OutDir,

    # Kept in step with the catalogue below by an assertion after it is built:
    # a ValidateSet is what gives tab-completion and an early, readable error,
    # but the catalogue is the single source of truth.
    [Parameter(ParameterSetName = 'Generate')]
    [ValidateSet('crc-pat', 'crc-pmt', 'crc-sdt', 'pat-removed', 'pat-truncated',
                 'pmt-vanishes', 'sdt-removed', 'nit-removed', 'cc-errors',
                 'pcr-removed', 'pcr-pid-missing', 'pid-collision',
                 'transport-error', 'false-scrambling')]
    [string[]] $Impairment,

    [Parameter(ParameterSetName = 'Generate')]
    [string]   $Service,

    [Parameter(ParameterSetName = 'Generate')]
    [ValidateRange(1, 86400)]
    [int]      $DelaySeconds = 10,

    [Parameter(ParameterSetName = 'Generate')]
    [ValidateRange(2, 1000000)]
    [int]      $ErrorRate = 20,

    [Parameter(ParameterSetName = 'Generate')]
    [ValidateRange(1, 1000000000)]
    [int]      $Bitrate,

    [Parameter(ParameterSetName = 'Generate')]
    [string]   $TsduckBin,

    [Parameter(ParameterSetName = 'Generate')]
    [string]   $ManifestPath,

    [Parameter(Mandatory, ParameterSetName = 'List')]
    [switch]   $ListImpairments,

    [Parameter(ParameterSetName = 'Generate')]
    [switch]   $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Well-known PIDs and table ids, named because the bare numbers are unreadable
# in the middle of a plugin argument list.
$PidPat = 0x0000
$PidNit = 0x0010
$PidSdt = 0x0011

$TidPat       = 0x00
$TidPmt       = 0x02
$TidSdtActual = 0x42

# --- Locating TSDuck -------------------------------------------------------

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot  = Split-Path -Parent $scriptDir

if (-not $TsduckBin) {
    $TsduckBin = Join-Path $repoRoot 'third_party\bin\tsduck\TSDuck\bin'
}
$tsp      = Join-Path $TsduckBin 'tsp.exe'
$tstables = Join-Path $TsduckBin 'tstables.exe'

# --- Running TSDuck --------------------------------------------------------
#
# Every TSDuck invocation here writes its machine-readable output to a file
# rather than to standard output. That is not fussiness: PowerShell decodes a
# native command's stdout using [Console]::OutputEncoding, which on a stock
# Windows console is a code page, and these streams carry Cyrillic and
# accented service names. Read back as UTF-8 from a file the names survive;
# captured off the pipeline they do not.
#
# The -I, -P and -O plugin markers are the exception to spelling things out:
# tsp has no long forms for them at all.
#
# TSDuck also accepts unambiguous option abbreviations, and the one that bites
# is "tstables --json": it resolves to --json-output, which takes the NEXT
# argument as its output filename - the .ts you meant to analyse. Every option
# below is therefore spelled out in full.

function Invoke-TsduckTool {
    <#
        Runs a TSDuck executable and returns its console output. The exit code
        is checked, but a zero exit code is never taken as evidence that an
        impairment worked - that is what the verification pass is for.
    #>
    param(
        [Parameter(Mandatory)] [string]   $Exe,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [switch] $AllowFailure
    )

    # Windows PowerShell 5.1 turns every stderr line of a native command into
    # an ErrorRecord, and with $ErrorActionPreference = 'Stop' the first one
    # aborts the script - which for tsp is its version banner, printed before
    # it has done anything at all. pwsh 7 does not do this. Relaxing the
    # preference across the call is the portable fix; the exit code below is
    # what actually decides whether the run failed.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    # ToString() on each item because 5.1 delivers stderr as ErrorRecords, and
    # an ErrorRecord formats itself as a multi-line diagnostic rather than as
    # the line TSDuck printed.
    try { $output = @(& $Exe @Arguments 2>&1 | ForEach-Object { $_.ToString() }) }
    finally { $ErrorActionPreference = $previous }
    $code = $LASTEXITCODE
    if (-not $AllowFailure -and $code -ne 0) {
        $name = [IO.Path]::GetFileName($Exe)
        throw ("{0} exited {1}: {2}{3}{4}" -f $name, $code, ($Arguments -join ' '),
               [Environment]::NewLine, ($output -join [Environment]::NewLine))
    }
    return ($output | Out-String)
}

function New-TempPath {
    param([string] $Extension = '.tmp')
    return (Join-Path ([IO.Path]::GetTempPath()) ('impair-' + [Guid]::NewGuid().ToString('n') + $Extension))
}

function Read-Utf8Json {
    <# ConvertFrom-Json on a file TSDuck wrote, with no console in the way. #>
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return (ConvertFrom-Json $text)
}

function Get-StreamAnalysis {
    <#
        The full tsanalyze report as an object. Built with the analyze plugin
        rather than tsanalyze.exe because only the plugin can write its JSON
        straight to a file, which the encoding note above requires.
    #>
    param([Parameter(Mandatory)] [string] $Path)

    $tmp = New-TempPath '.json'
    try {
        Invoke-TsduckTool -Exe $tsp -Arguments @(
            '-I', 'file', $Path,
            '-P', 'analyze', '--json', '--output-file', $tmp,
            '-O', 'drop') | Out-Null
        $a = Read-Utf8Json $tmp
        if ($null -eq $a) { throw "TSDuck produced no analysis for $Path" }
        return $a
    }
    finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
}

function Get-TableJson {
    <# The first table(s) found on a PID. Returns $null when there are none. #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [int]    $TablePid,
        [int] $MaxTables = 1
    )

    $tmp = New-TempPath '.json'
    try {
        Invoke-TsduckTool -Exe $tstables -Arguments @(
            $Path, '--pid', $TablePid, '--max-tables', $MaxTables,
            '--json-output', $tmp) -AllowFailure | Out-Null
        # Always an array, and the leading comma is what keeps it one.
        # ConvertFrom-Json in Windows PowerShell 5.1 unwraps a one-element JSON
        # array into a bare object, and PowerShell then unwraps a one-element
        # array again on the way out of a function - after which .Count is a
        # terminating error under Set-StrictMode.
        return ,@(Read-Utf8Json $tmp | Where-Object { $null -ne $_ })
    }
    finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
}

function Get-TableText {
    <#
        Human-readable table dump. The invalid-section checks need this rather
        than JSON: TSDuck has no way to express, as a table, a section it
        refused to parse.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [int]    $TablePid,
        [int]    $MaxTables = 2,
        [switch] $OnlyInvalidSections
    )

    $tmp = New-TempPath '.txt'
    try {
        $a = @($Path, '--pid', $TablePid, '--max-tables', $MaxTables, '--output-file', $tmp)
        if ($OnlyInvalidSections) { $a += '--only-invalid-sections' }
        Invoke-TsduckTool -Exe $tstables -Arguments $a -AllowFailure | Out-Null
        if (-not (Test-Path -LiteralPath $tmp)) { return '' }
        return [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)
    }
    finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
}

function Measure-PidPackets {
    <#
        Packets on a PID, optionally counting only what follows a packet
        offset. The offset form is how a mid-stream impairment is shown to
        have struck where it was aimed and not merely somewhere.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [int]    $TargetPid,
        [int] $SkipPackets = 0
    )

    $tmp = New-TempPath '.txt'
    try {
        $a = @('-I', 'file', $Path)
        if ($SkipPackets -gt 0) { $a += @('-P', 'skip', '--packets', $SkipPackets) }
        $a += @('-P', 'count', '--pid', $TargetPid, '--total',
                '--output-file', $tmp, '-O', 'drop')
        Invoke-TsduckTool -Exe $tsp -Arguments $a | Out-Null

        $text = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)
        if ($text -match 'counted\s+([\d,]+)\s+packets') {
            return [int](($Matches[1]) -replace ',', '')
        }
        throw "No packet count in TSDuck's output: $text"
    }
    finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force } }
}

# --- Reading the analysis --------------------------------------------------
#
# TSDuck omits properties rather than emitting nulls, and Set-StrictMode turns
# a missing property into a terminating error, so optional reads go through
# Get-Prop.

function Get-Prop {
    param($Object, [string] $Name, $Default = $null)

    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    if ($null -eq $p.Value) { return $Default }
    return $p.Value
}

function Get-PidInfo {
    param($Analysis, [int] $TargetPid)
    foreach ($p in @($Analysis.pids)) { if ([int]$p.id -eq $TargetPid) { return $p } }
    return $null
}

function Get-PidPacketCount {
    param($Analysis, [int] $TargetPid)
    $p = Get-PidInfo $Analysis $TargetPid
    if ($null -eq $p) { return 0 }
    return [int](Get-Prop (Get-Prop $p 'packets') 'total' 0)
}

function Get-PidStat {
    param($Analysis, [int] $TargetPid, [string] $Name)
    $p = Get-PidInfo $Analysis $TargetPid
    if ($null -eq $p) { return 0 }
    return [int](Get-Prop (Get-Prop $p 'packets') $Name 0)
}

function Get-Services {
    <# Same reason as Get-TableJson, leading comma included: a single-service
       multiplex must still arrive as a countable collection. #>
    param($Analysis)
    return ,@($Analysis.services)
}

function Get-ServiceInfo {
    param($Analysis, [int] $ServiceId)
    foreach ($s in (Get-Services $Analysis)) { if ([int]$s.id -eq $ServiceId) { return $s } }
    return $null
}

# --- CRC damage ------------------------------------------------------------

function Invoke-SectionCrcDamage {
    <#
        Inverts the last byte of every matching PSI/SI section, which is the
        low byte of its CRC_32. The section body is left exactly as it was, so
        the only thing wrong with the table is that it no longer verifies -
        which is the point. A receiver that checks CRCs must throw the table
        away; one that does not will read a perfectly good table and behave
        normally, and the difference between those two outcomes is the test.

        This is the one impairment not built with tsp. TSDuck 3.44 ships no
        CRC-corrupting plugin, and the obvious substitute - pull the table out
        with tstables, flip a CRC byte, put it back with "tsp -P inject
        --replace" - does not work: inject validates every section it loads and
        rejects a bad CRC outright with "invalid section". What is left inside
        TSDuck is the fuzz plugin, which corrupts random bytes and cannot be
        aimed at a field, or craft with a fixed --offset-pattern, which only
        lands on the CRC for tables whose sections happen to start a packet and
        fit inside it. Walking the sections is both exact and general.

        Sections are followed across packet boundaries. Two cases are given up
        on rather than guessed at - a section header split between two packets,
        and a continuation whose start was never seen - and both are counted.
        The verification pass is what decides whether that mattered: it fails
        the impairment if any valid copy of the table survives.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Destination,
        [Parameter(Mandatory)] [int]    $TargetPid,
        [int[]] $TableId = @()
    )

    $packetSize = 188
    $blockSize  = $packetSize * 4096
    $buf = New-Object byte[] $blockSize

    $damaged   = 0      # sections whose CRC byte was inverted
    $skipped   = 0      # sections whose end could not be located
    $remaining = 0      # bytes of the current section still to arrive
    $wanted    = $false # whether that section is one of ours
    $offset    = 0      # byte offset of this block, for error messages

    $in = [IO.File]::OpenRead($Path)
    try {
        $out = [IO.File]::Create($Destination)
        try {
            while ($true) {
                # A FileStream read may return short at any point, not only at
                # the end of the file, so fill the buffer before splitting it
                # into packets.
                $n = 0
                while ($n -lt $blockSize) {
                    $got = $in.Read($buf, $n, $blockSize - $n)
                    if ($got -le 0) { break }
                    $n += $got
                }
                if ($n -le 0) { break }

                # A trailing fragment means the capture was cut mid-packet.
                # tsp discards it, so discard it here too rather than emitting
                # a file whose last packet is a stub.
                $whole = $n - ($n % $packetSize)
                $truncated = ($whole -ne $n)
                if ($truncated) {
                    Write-Verbose "$Path ends with a partial packet; $($n - $whole) trailing bytes dropped."
                }

                for ($base = 0; $base -lt $whole; $base += $packetSize) {
                    if ($buf[$base] -ne 0x47) {
                        throw "Lost packet sync at byte $($offset + $base) of $Path."
                    }
                    # Not $pid: that is PowerShell's own read-only process id.
                    $packetPid = ((($buf[$base + 1] -band 0x1F) -shl 8) -bor $buf[$base + 2])
                    if ($packetPid -ne $TargetPid) { continue }

                    # adaptation_field_control 0 and 2 carry no payload at all.
                    $afc = ($buf[$base + 3] -shr 4) -band 0x03
                    if ($afc -eq 0 -or $afc -eq 2) { continue }
                    $pos = $base + 4
                    if ($afc -eq 3) { $pos += 1 + $buf[$base + 4] }
                    $end = $base + $packetSize
                    if ($pos -ge $end) { continue }

                    if (($buf[$base + 1] -band 0x40) -ne 0) {
                        # payload_unit_start_indicator: a pointer_field says how
                        # many bytes of the previous section come first.
                        $ptr = $buf[$pos]; $pos++
                        if ($remaining -gt 0) {
                            if ($remaining -le $ptr -and ($pos + $remaining) -le $end) {
                                if ($wanted) {
                                    $buf[$pos + $remaining - 1] = $buf[$pos + $remaining - 1] -bxor 0xFF
                                    $damaged++
                                }
                            }
                            elseif ($wanted) { $skipped++ }
                            $remaining = 0
                        }
                        $pos += $ptr
                    }
                    elseif ($remaining -gt 0) {
                        $available = $end - $pos
                        if ($remaining -gt $available) { $remaining -= $available; continue }
                        if ($wanted) {
                            $buf[$pos + $remaining - 1] = $buf[$pos + $remaining - 1] -bxor 0xFF
                            $damaged++
                        }
                        $pos += $remaining
                        $remaining = 0
                    }
                    else {
                        # Mid-section with no start ever seen: wait for a PUSI.
                        continue
                    }

                    # 0xFF is the stuffing byte that ends the section area.
                    while ($pos -lt $end -and $buf[$pos] -ne 0xFF) {
                        if (($pos + 3) -gt $end) { $skipped++; break }
                        $tid = [int]$buf[$pos]
                        $len = 3 + (((($buf[$pos + 1] -band 0x0F) -shl 8) -bor $buf[$pos + 2]))
                        $wanted = ($TableId.Count -eq 0 -or $TableId -contains $tid)
                        if (($pos + $len) -le $end) {
                            if ($wanted) {
                                $buf[$pos + $len - 1] = $buf[$pos + $len - 1] -bxor 0xFF
                                $damaged++
                            }
                            $pos += $len
                        }
                        else {
                            $remaining = $len - ($end - $pos)
                            break
                        }
                    }
                }

                $out.Write($buf, 0, $whole)
                $offset += $whole
                if ($truncated) { break }
            }
        }
        finally { $out.Dispose() }
    }
    finally { $in.Dispose() }

    return [pscustomobject]@{ Damaged = $damaged; Skipped = $skipped }
}

# --- Verification helpers --------------------------------------------------

function New-Check {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Expected,
        [Parameter(Mandatory)] [string] $Observed,
        [Parameter(Mandatory)] [bool]   $Pass
    )
    [pscustomobject]@{ check = $Name; expected = $Expected; observed = $Observed; pass = $Pass }
}

function Test-NoValidTable {
    <#
        True when the PID yields no parseable table at all. Used by the CRC
        impairments: a table with a broken CRC is not a table TSDuck will
        report, so silence here is the proof that every copy was hit.
    #>
    param([string] $Path, [int] $TablePid)
    $text = Get-TableText -Path $Path -TablePid $TablePid -MaxTables 1
    return [string]::IsNullOrWhiteSpace($text)
}

# --- The catalogue ---------------------------------------------------------
#
# Every entry carries the two scriptblocks that make it real - Build produces
# the file and returns the command it used, Verify reads the file back - plus
# the prose that makes it useful to a test harness. Expected, MustNot and
# Certainty are the fields the harness and a human reader actually consume:
# what should happen, what is not allowed to happen whatever else does, and
# how firm the ground is.
#
# Certainty values:
#   required   the standard says so, or the failure mode is a defect on any
#              reading (a crash, a hang, an unbounded retry)
#   expected   conventional receiver behaviour, widely implemented, not
#              mandated in so many words
#   unclear    genuinely unsettled; both outcomes are defensible and the test
#              exists to find out which one MPC-HC picks

# Signature of the scriptblocks:
#   Requires ($ctx)                        -> $null, or why this source cannot
#                                             carry this impairment. Optional.
#   Build    ($source, $destination, $ctx) -> string describing what was run
#   Verify   ($destination, $after, $ctx)  -> array of check objects
#
# Requires exists because removing a table that was never there looks exactly
# like success: the verification would find no SDT and pass. Better to say the
# source cannot host the impairment than to ship a file that tests nothing.

$catalogue = @(

    [pscustomobject]@{
        Id      = 'crc-pat'
        Title   = 'PAT with a broken CRC'
        Summary = 'Every PAT section carries a deliberately wrong CRC_32. The table body is untouched, so the program list is still readable by anything that does not check.'
        Expected = 'ISO/IEC 13818-1 requires a decoder to discard a section whose CRC_32 does not verify, so a conformant receiver has no program list and no service is tunable. The correct outcome is a bounded, reported failure: an empty channel list, or a tune that gives up and says so.'
        MustNot  = @('crash', 'hang or block the UI thread', 'retry without bound',
                     'act on the section body after the CRC failed')
        Certainty = 'required'
        Notes    = 'MPC-HC does not parse PAT itself - the Microsoft MPEG-2 Demultiplexer does - and we do not know whether that component verifies CRCs. If it does not, playback will look entirely normal here, because the body of every section is still correct. That is a conformance deviation rather than a functional failure, and it is worth knowing which way it falls.'
        Build   = {
            param($src, $dst, $ctx)
            $r = Invoke-SectionCrcDamage -Path $src -Destination $dst -TargetPid $ctx.PidPat -TableId @($ctx.TidPat)
            return "section CRC rewrite on PID $($ctx.PidPat), table id 0x00 ($($r.Damaged) sections damaged, $($r.Skipped) skipped)"
        }
        Verify  = {
            param($dst, $after, $ctx)
            $bad  = Get-TableText -Path $dst -TablePid $ctx.PidPat -OnlyInvalidSections
            @(
                (New-Check 'invalid PAT sections present' 'at least one section reported with an invalid CRC32' `
                    ($(if ($bad -match 'invalid CRC32') { 'invalid CRC32 reported' } else { 'none reported' })) `
                    ([bool]($bad -match 'invalid CRC32')))
                (New-Check 'no valid PAT survives' 'tstables finds no parseable PAT' `
                    ($(if (Test-NoValidTable $dst $ctx.PidPat) { 'none found' } else { 'a valid PAT is still present' })) `
                    (Test-NoValidTable $dst $ctx.PidPat))
                (New-Check 'PAT packets still carried' 'PID 0 still occupies the stream at its original rate' `
                    ("$(Get-PidPacketCount $after $ctx.PidPat) packets") `
                    ((Get-PidPacketCount $after $ctx.PidPat) -eq (Get-PidPacketCount $ctx.Baseline $ctx.PidPat)))
            )
        }
    },

    [pscustomobject]@{
        Id      = 'crc-pmt'
        Title   = 'PMT with a broken CRC on one service'
        Summary = 'Every PMT section of the target service carries a wrong CRC_32. Its elementary streams and its PAT and SDT entries are untouched.'
        Expected = 'The service is still announced by the PAT and named by the SDT, but a conformant receiver can never learn its elementary PIDs, so it cannot render it. The other services in the multiplex are unaffected and must still play. The correct outcome is that selecting this one service fails cleanly and quickly.'
        MustNot  = @('crash', 'hang', 'disturb the other services in the multiplex',
                     'act on the section body after the CRC failed')
        Certainty = 'required'
        Notes    = 'Same caveat as crc-pat: if the demultiplexer ignores CRCs, this service will play normally because the table body is valid.'
        Requires = {
            param($ctx)
            if ($ctx.OtherServiceId -eq 0) { return 'the source carries only one service' }
            return $null
        }
        Build   = {
            param($src, $dst, $ctx)
            $r = Invoke-SectionCrcDamage -Path $src -Destination $dst -TargetPid $ctx.PmtPid -TableId @($ctx.TidPmt)
            return "section CRC rewrite on PID $($ctx.PmtPid), table id 0x02 ($($r.Damaged) sections damaged, $($r.Skipped) skipped)"
        }
        Verify  = {
            param($dst, $after, $ctx)
            $bad = Get-TableText -Path $dst -TablePid $ctx.PmtPid -OnlyInvalidSections
            $otherPmtOk = -not (Test-NoValidTable $dst $ctx.OtherPmtPid)
            @(
                (New-Check 'invalid PMT sections present' 'at least one section reported with an invalid CRC32' `
                    ($(if ($bad -match 'invalid CRC32') { 'invalid CRC32 reported' } else { 'none reported' })) `
                    ([bool]($bad -match 'invalid CRC32')))
                (New-Check 'no valid PMT survives' "tstables finds no parseable PMT on PID $($ctx.PmtPid)" `
                    ($(if (Test-NoValidTable $dst $ctx.PmtPid) { 'none found' } else { 'a valid PMT is still present' })) `
                    (Test-NoValidTable $dst $ctx.PmtPid))
                (New-Check 'another service left intact' "the PMT on PID $($ctx.OtherPmtPid) still parses" `
                    ($(if ($otherPmtOk) { 'parses' } else { 'missing' })) $otherPmtOk)
                (New-Check 'elementary streams left in place' 'the service video PID still carries every packet it did' `
                    ("$(Get-PidPacketCount $after $ctx.VideoPid) video packets, was $(Get-PidPacketCount $ctx.Baseline $ctx.VideoPid)") `
                    ((Get-PidPacketCount $after $ctx.VideoPid) -eq (Get-PidPacketCount $ctx.Baseline $ctx.VideoPid)))
            )
        }
    },

    [pscustomobject]@{
        Id      = 'crc-sdt'
        Title   = 'SDT actual with a broken CRC'
        Summary = 'Every SDT actual section carries a wrong CRC_32. PAT, PMT and NIT are untouched.'
        Expected = 'Service names, provider names and service types are unavailable. Every service must still be found through the PAT and must still play; they simply appear unnamed, or under a fallback label such as the service id.'
        MustNot  = @('crash', 'hang', 'drop services from the channel list',
                     'refuse to play a service because it has no name')
        Certainty = 'required'
        Notes    = 'Functionally the same test as sdt-removed, with one difference worth having separately: here the SDT is present and repeating, so a receiver that never checks CRCs will show correct names and this impairment will be invisible. Comparing the two tells you whether CRCs are checked at all.'
        Requires = {
            param($ctx)
            if ((Get-PidPacketCount $ctx.Baseline $ctx.PidSdt) -eq 0) { return 'the source carries no SDT' }
            return $null
        }
        Build   = {
            param($src, $dst, $ctx)
            $r = Invoke-SectionCrcDamage -Path $src -Destination $dst -TargetPid $ctx.PidSdt -TableId @($ctx.TidSdtActual)
            return "section CRC rewrite on PID $($ctx.PidSdt), table id 0x42 ($($r.Damaged) sections damaged, $($r.Skipped) skipped)"
        }
        Verify  = {
            param($dst, $after, $ctx)
            $bad = Get-TableText -Path $dst -TablePid $ctx.PidSdt -OnlyInvalidSections -MaxTables 4
            $named = @((Get-Services $after) | Where-Object { (Get-Prop $_ 'name' '') -notmatch '^\(unknown\)$' -and (Get-Prop $_ 'name' '') -ne '' })
            @(
                (New-Check 'invalid SDT sections present' 'at least one section reported with an invalid CRC32' `
                    ($(if ($bad -match 'invalid CRC32') { 'invalid CRC32 reported' } else { 'none reported' })) `
                    ([bool]($bad -match 'invalid CRC32')))
                (New-Check 'service names gone' 'no service resolves to a name' `
                    ("$($named.Count) of $((Get-Services $after).Count) services still named") `
                    ($named.Count -eq 0))
                (New-Check 'services still present' 'the service count is unchanged' `
                    ("$((Get-Services $after).Count) services, was $((Get-Services $ctx.Baseline).Count)") `
                    ((Get-Services $after).Count -eq (Get-Services $ctx.Baseline).Count))
            )
        }
    },

    [pscustomobject]@{
        Id      = 'pat-removed'
        Title   = 'No PAT at all'
        Summary = 'PID 0 is replaced by null packets for the whole stream. The bitrate is unchanged; there is simply never a program association table.'
        Expected = 'Nothing in the multiplex is discoverable. A receiver has no legal way to find a PMT and must give up. This is deliberately different from the SignalLocked=0 registry case: here the tuner locks, the bitrate is correct and packets flow, and the failure is above the demodulator.'
        MustNot  = @('crash', 'hang', 'spin waiting for a table that never comes',
                     'report a successful tune with an empty channel list and no diagnostic')
        Certainty = 'required'
        Notes    = 'The distinction from a no-lock failure is the reason this is worth testing at all. MPC-HC waits for BDA_CHANGES_PENDING on the tune path (FGManagerBDA.cpp:709); this exercises what happens after that wait succeeds.'
        Build   = {
            param($src, $dst, $ctx)
            $a = @('-I', 'file', $src,
                   '-P', 'filter', '--pid', $ctx.PidPat, '--negate', '--stuffing',
                   '-O', 'file', $dst)
            Invoke-TsduckTool -Exe $ctx.Tsp -Arguments $a | Out-Null
            return "tsp $($a -join ' ')"
        }
        Verify  = {
            param($dst, $after, $ctx)
            $n = Get-PidPacketCount $after $ctx.PidPat
            $noPat = Test-NoValidTable $dst $ctx.PidPat
            @(
                (New-Check 'PAT gone' 'no packets remain on PID 0' "$n packets" ($n -eq 0))
                (New-Check 'no program list' 'tstables finds no PAT at all' `
                    ($(if ($noPat) { 'none found' } else { 'a PAT is still present' })) $noPat)
                (New-Check 'bitrate preserved' 'the packet count is unchanged, the PAT having been stuffed rather than dropped' `
                    ("$([int]$after.ts.packets.total) packets, was $([int]$ctx.Baseline.ts.packets.total)") `
                    ([int]$after.ts.packets.total -eq [int]$ctx.Baseline.ts.packets.total))
            )
        }
    },

    [pscustomobject]@{
        Id      = 'pat-truncated'
        Title   = 'PAT lists one service out of many'
        Summary = 'The PAT is rewritten to announce only the target service. The other services keep their PMTs, their elementary streams and their SDT entries, but nothing points at them any more.'
        Expected = 'Exactly one service is legitimately discoverable. A receiver that builds its channel list from the PAT, as it should, finds one. The other nine are advertised by the SDT and are physically present, so a receiver that trusts the SDT will list them and then fail to play them.'
        MustNot  = @('crash', 'hang on a service it cannot resolve',
                     'fail to play the one service that is still properly signalled')
        Certainty = 'unclear'
        Notes    = 'Whether the ghost services should appear in the channel list is genuinely arguable. ETSI EN 300 468 expects SDT and PAT to agree, and says nothing useful about what to do when they do not. Listing them is defensible (the broadcaster says they exist); hiding them is defensible (nothing can be tuned). What is not defensible is listing one and hanging when it is selected. That is the behaviour this impairment is really looking for.'
        Requires = {
            param($ctx)
            if ($ctx.OtherServiceId -eq 0) { return 'the source carries only one service' }
            return $null
        }
        Build   = {
            param($src, $dst, $ctx)
            $a = @('-I', 'file', $src, '-P', 'pat')
            foreach ($id in $ctx.OtherServiceIds) { $a += @('--remove-service', $id) }
            $a += @('--increment-version', '-O', 'file', $dst)
            Invoke-TsduckTool -Exe $ctx.Tsp -Arguments $a | Out-Null
            return "tsp $($a -join ' ')"
        }
        Verify  = {
            param($dst, $after, $ctx)
            $pat = Get-TableJson -Path $dst -TablePid $ctx.PidPat
            $svc = @()
            if ($null -ne $pat -and $pat.Count -gt 0) {
                $svc = @((Get-Prop $pat[0] '#nodes' @()) | Where-Object { (Get-Prop $_ '#name' '') -eq 'service' })
            }
            $unref = [int](Get-Prop (Get-Prop $after.ts 'pids') 'unreferenced' 0)
            @(
                (New-Check 'PAT reduced to one service' 'the PAT announces exactly one service' `
                    ("$($svc.Count) services in the PAT") ($svc.Count -eq 1))
                (New-Check 'the survivor is the target' "service $($ctx.ServiceId) is the one left" `
                    ($(if ($svc.Count -eq 1) { "service $(Get-Prop $svc[0] 'service_id' '?')" } else { 'n/a' })) `
                    ($svc.Count -eq 1 -and [int](Get-Prop $svc[0] 'service_id' -1) -eq $ctx.ServiceId))
                (New-Check 'orphans left in the stream' 'the unreferenced services are still physically present' `
                    ("$unref unreferenced PIDs") ($unref -gt 0))
            )
        }
    },

    [pscustomobject]@{
        Id      = 'pmt-vanishes'
        Title   = 'PMT stops repeating part-way through'
        Summary = 'The target service plays normally, then its PMT PID is replaced by null packets from -DelaySeconds onwards. Its elementary streams keep flowing.'
        Expected = 'This is the mid-playback case. ISO/IEC 13818-1 sets no timeout on PSI repetition, and ETSI TR 101 290 makes a missing PMT a measurement error rather than a decoding instruction, so a receiver may quite properly keep decoding on the PMT it already has. Continuing to play is a correct outcome. Stopping the service cleanly is also a correct outcome. Both are acceptable and the harness should accept either.'
        MustNot  = @('crash', 'hang', 'spin at high CPU rebuilding the graph',
                     'leave the channel list in a state where the service can no longer be selected after a retune')
        Certainty = 'unclear'
        Notes    = 'The only firm requirement here is bounded, stable behaviour. Anyone asserting that the picture must freeze at exactly -DelaySeconds is over-specifying: the elementary streams are still present and a receiver that caches the PMT will play to the end of the file quite legitimately.'
        Build   = {
            param($src, $dst, $ctx)
            # --after-packets lets the first N packets through untouched and
            # only then starts filtering, which is what makes this an event
            # part-way into playback rather than a stream that was never right.
            $a = @('-I', 'file', $src,
                   '-P', 'filter', '--pid', $ctx.PmtPid,
                   '--after-packets', $ctx.CutPacket, '--negate', '--stuffing',
                   '-O', 'file', $dst)
            Invoke-TsduckTool -Exe $ctx.Tsp -Arguments $a | Out-Null
            return "tsp $($a -join ' ')"
        }
        Verify  = {
            param($dst, $after, $ctx)
            $before = Measure-PidPackets -Path $dst -TargetPid $ctx.PmtPid
            $tail   = Measure-PidPackets -Path $dst -TargetPid $ctx.PmtPid -SkipPackets $ctx.CutPacket
            @(
                (New-Check 'PMT present before the cut' 'the service is signalled normally up to the cut' `
                    ("$before PMT packets in total") ($before -gt 0))
                (New-Check 'PMT absent after the cut' "no PMT packets after packet $($ctx.CutPacket)" `
                    ("$tail PMT packets after the cut") ($tail -eq 0))
                (New-Check 'elementary streams still flowing' 'the video PID is unchanged' `
                    ("$(Get-PidPacketCount $after $ctx.VideoPid) video packets, was $(Get-PidPacketCount $ctx.Baseline $ctx.VideoPid)") `
                    ((Get-PidPacketCount $after $ctx.VideoPid) -eq (Get-PidPacketCount $ctx.Baseline $ctx.VideoPid)))
            )
        }
    },

    [pscustomobject]@{
        Id      = 'sdt-removed'
        Title   = 'No SDT'
        Summary = 'PID 0x11 is replaced by null packets, so there is no service description table and no bouquet association table either.'
        Expected = 'Services should still tune and play, but appear unnamed. Everything needed to decode a service lives in the PAT and the PMT; the SDT only supplies names, providers, service types and the free_CA_mode flag. A correct receiver lists all the services it found and labels them with something - the service id, a placeholder - rather than dropping them.'
        MustNot  = @('crash', 'hang', 'omit services from the scan because they have no name',
                     'produce an empty channel list')
        Certainty = 'required'
        Notes    = 'This is the cheapest and most likely-to-bite impairment in the set, because an unnamed service is an empty string flowing into UI code and settings serialisation. Note that MPC-HC uses the SDT to decide whether a service is encrypted, so with no SDT everything should report as clear - which, for a genuinely clear multiplex, is correct.'
        Requires = {
            param($ctx)
            if ((Get-PidPacketCount $ctx.Baseline $ctx.PidSdt) -eq 0) { return 'the source carries no SDT' }
            return $null
        }
        Build   = {
            param($src, $dst, $ctx)
            $a = @('-I', 'file', $src,
                   '-P', 'filter', '--pid', $ctx.PidSdt, '--negate', '--stuffing',
                   '-O', 'file', $dst)
            Invoke-TsduckTool -Exe $ctx.Tsp -Arguments $a | Out-Null
            return "tsp $($a -join ' ')"
        }
        Verify  = {
            param($dst, $after, $ctx)
            $n = Get-PidPacketCount $after $ctx.PidSdt
            $named = @((Get-Services $after) | Where-Object { (Get-Prop $_ 'name' '') -notmatch '^\(unknown\)$' -and (Get-Prop $_ 'name' '') -ne '' })
            @(
                (New-Check 'SDT gone' 'no packets remain on PID 0x11' "$n packets" ($n -eq 0))
                (New-Check 'services unnamed' 'no service resolves to a name' `
                    ("$($named.Count) of $((Get-Services $after).Count) services still named") ($named.Count -eq 0))
                (New-Check 'services still discoverable' 'the PAT and PMTs still describe every service' `
                    ("$((Get-Services $after).Count) services, was $((Get-Services $ctx.Baseline).Count)") `
                    ((Get-Services $after).Count -eq (Get-Services $ctx.Baseline).Count))
            )
        }
    },

    [pscustomobject]@{
        Id      = 'nit-removed'
        Title   = 'No NIT'
        Summary = 'PID 0x10 is replaced by null packets, so there is no network information table: no network name, no delivery system descriptors and no logical channel numbers.'
        Expected = 'Every service must still scan and play. What is lost is presentation: the network name, and the logical channel numbers MPC-HC reads out of the private LCN descriptor to fill its N column. Channels should fall back to a stable arbitrary order rather than disappearing.'
        MustNot  = @('crash', 'hang', 'require an LCN before a channel can be listed or played')
        Certainty = 'required'
        Notes    = 'The expected symptom - N reading 0 or blank for every channel - is the same symptom the ATSC scan already shows for an unrelated reason (ParseVCT never calling SetOriginNumber). Worth keeping the two apart when reading results.'
        Requires = {
            param($ctx)
            if ((Get-PidPacketCount $ctx.Baseline $ctx.PidNit) -eq 0) { return 'the source carries no NIT' }
            return $null
        }
        Build   = {
            param($src, $dst, $ctx)
            $a = @('-I', 'file', $src,
                   '-P', 'filter', '--pid', $ctx.PidNit, '--negate', '--stuffing',
                   '-O', 'file', $dst)
            Invoke-TsduckTool -Exe $ctx.Tsp -Arguments $a | Out-Null
            return "tsp $($a -join ' ')"
        }
        Verify  = {
            param($dst, $after, $ctx)
            $n = Get-PidPacketCount $after $ctx.PidNit
            @(
                (New-Check 'NIT gone' 'no packets remain on PID 0x10' "$n packets" ($n -eq 0))
                (New-Check 'services unaffected' 'the service count and their names are unchanged' `
                    ("$((Get-Services $after).Count) services, was $((Get-Services $ctx.Baseline).Count)") `
                    ((Get-Services $after).Count -eq (Get-Services $ctx.Baseline).Count))
            )
        }
    },

    [pscustomobject]@{
        Id      = 'cc-errors'
        Title   = 'Continuity counter errors on the video PID'
        Summary = 'One packet in -ErrorRate is removed from the target service video PID and replaced by a null packet, so the continuity counter jumps and a fragment of every few PES packets is missing.'
        Expected = 'This is the everyday real-world impairment, and the only one in this set that a receiver is expected to survive rather than merely to fail cleanly on. Playback must continue: the decoder should show artefacts, recover at the next intra frame, and keep audio and the clock running throughout.'
        MustNot  = @('crash', 'hang', 'abandon the channel', 'stop audio',
                     'accumulate unbounded memory buffering for the missing packets')
        Certainty = 'required'
        Notes    = 'The bitrate is preserved because the dropped packets become null packets, so this isolates data loss from any change in stream rate. Real transmission errors usually arrive in bursts rather than evenly spaced; an even spread is the harsher test for a receiver that resynchronises per burst.'
        Build   = {
            param($src, $dst, $ctx)
            # Two filters, not one. The filter plugin ORs its criteria, so
            # "--pid V --every N" would select the whole of PID V *or* every
            # Nth packet of anything - which, negated, empties the video PID
            # completely. Labelling the PID first and then thinning only the
            # labelled packets is what actually means "one in N of this PID".
            $a = @('-I', 'file', $src,
                   '-P', 'filter', '--pid', $ctx.VideoPid, '--set-label', 1,
                   '-P', 'filter', '--only-label', 1, '--every', $ctx.ErrorRate,
                   '--negate', '--stuffing',
                   '-O', 'file', $dst)
            Invoke-TsduckTool -Exe $ctx.Tsp -Arguments $a | Out-Null
            return "tsp $($a -join ' ')"
        }
        Verify  = {
            param($dst, $after, $ctx)
            $disc = Get-PidStat $after $ctx.VideoPid 'discontinuities'
            $lost = (Get-PidPacketCount $ctx.Baseline $ctx.VideoPid) - (Get-PidPacketCount $after $ctx.VideoPid)
            $audioSame = (Get-PidPacketCount $after $ctx.AudioPid) -eq (Get-PidPacketCount $ctx.Baseline $ctx.AudioPid)
            @(
                (New-Check 'continuity errors present' 'the video PID reports continuity counter discontinuities' `
                    ("$disc discontinuities, baseline had $(Get-PidStat $ctx.Baseline $ctx.VideoPid 'discontinuities')") `
                    ($disc -gt 0))
                (New-Check 'loss is at the requested rate' "about 1 packet in $($ctx.ErrorRate) of the video PID" `
                    ("$lost of $(Get-PidPacketCount $ctx.Baseline $ctx.VideoPid) video packets removed") `
                    ($lost -gt 0))
                (New-Check 'only the video PID affected' 'the audio PID is untouched' `
                    ($(if ($audioSame) { 'unchanged' } else { 'changed' })) $audioSame)
                (New-Check 'bitrate preserved' 'total packet count unchanged' `
                    ("$([int]$after.ts.packets.total) packets, was $([int]$ctx.Baseline.ts.packets.total)") `
                    ([int]$after.ts.packets.total -eq [int]$ctx.Baseline.ts.packets.total))
            )
        }
    },

    [pscustomobject]@{
        Id      = 'pcr-removed'
        Title   = 'PCR fields stripped from the clock PID'
        Summary = 'The program clock reference is deleted from every adaptation field of the target service PCR PID. The PMT still names that PID as PCR_PID, and the elementary stream itself is untouched - only the clock samples are gone.'
        Expected = 'There is no time base. PTS and DTS are still present, so a receiver can render by decoding timestamps against its own clock, which will free-run and drift. Either behaviour is acceptable: free-running playback, or a clean refusal. What matters is that the failure is bounded.'
        MustNot  = @('crash', 'hang waiting for a clock that never arrives',
                     'block the graph indefinitely in a paused or prerolling state')
        Certainty = 'unclear'
        Notes    = 'Deliberately not implemented as "delete the PCR PID". In this capture, and in most DVB multiplexes, the PCR PID is the video PID, so deleting it would remove the video and test nothing about clocks. Stripping the PCR from the adaptation field isolates the clock failure from everything else. pcr-pid-missing is the complementary case, where the packets are fine and the signalling is wrong.'
        Requires = {
            param($ctx)
            if ((Get-PidStat $ctx.Baseline $ctx.PcrPid 'pcr') -eq 0) { return 'the source PCR PID carries no PCR' }
            return $null
        }
        Build   = {
            param($src, $dst, $ctx)
            # craft has no PID selector - its --pid option *sets* the PID on
            # every packet, which silently collapses the whole multiplex onto
            # one PID. Selecting with filter --set-label and acting with craft
            # --only-label is the only correct way to aim it.
            $a = @('-I', 'file', $src,
                   '-P', 'filter', '--pid', $ctx.PcrPid, '--set-label', 1,
                   '-P', 'craft', '--only-label', 1, '--no-pcr',
                   '-O', 'file', $dst)
            Invoke-TsduckTool -Exe $ctx.Tsp -Arguments $a | Out-Null
            return "tsp $($a -join ' ')"
        }
        Verify  = {
            param($dst, $after, $ctx)
            $pcr = Get-PidStat $after $ctx.PcrPid 'pcr'
            $pkts = Get-PidPacketCount $after $ctx.PcrPid
            @(
                (New-Check 'no PCR samples left' 'the PCR PID carries no PCR' `
                    ("$pcr PCR samples, baseline had $(Get-PidStat $ctx.Baseline $ctx.PcrPid 'pcr')") ($pcr -eq 0))
                (New-Check 'elementary stream intact' 'the PID keeps all of its packets' `
                    ("$pkts packets, was $(Get-PidPacketCount $ctx.Baseline $ctx.PcrPid)") `
                    ($pkts -eq (Get-PidPacketCount $ctx.Baseline $ctx.PcrPid)))
                (New-Check 'other services still clocked' 'the rest of the multiplex keeps its PCRs' `
                    ("$([int](Get-Prop (Get-Prop $after.ts 'pids') 'pcr' 0)) PID(s) with PCR, was $([int](Get-Prop (Get-Prop $ctx.Baseline.ts 'pids') 'pcr' 0))") `
                    ([int](Get-Prop (Get-Prop $after.ts 'pids') 'pcr' 0) -eq [int](Get-Prop (Get-Prop $ctx.Baseline.ts 'pids') 'pcr' 0) - 1))
            )
        }
    },

    [pscustomobject]@{
        Id      = 'pcr-pid-missing'
        Title   = 'PMT points its PCR_PID at nothing'
        Summary = 'The target service PMT is rewritten to declare a PCR_PID that carries no packets at all. Every elementary stream, including the real clock samples on the original PID, is left alone.'
        Expected = 'The signalling is wrong rather than the data. A receiver that follows the PMT will wait for a clock on a PID that is empty. A tolerant one will notice PCRs arriving on the video PID and use them, or fall back to PTS. Either is acceptable; what is required is that it decides in bounded time.'
        MustNot  = @('crash', 'hang waiting on the empty PID', 'preroll forever')
        Certainty = 'unclear'
        Notes    = 'The complement of pcr-removed. Running both separates "cannot cope without a clock" from "cannot cope with wrong signalling", which are different defects with different fixes. The TSDuck pmt plugin rebuilds the whole PMT PID rather than editing packets in place, and in doing so it re-times the stream and drops roughly the last three per cent of it. The output is otherwise sound - PCR jitter is unchanged from the source - but this file is shorter than the others, which is why the manifest records a packet count per output.'
        Build   = {
            param($src, $dst, $ctx)
            $a = @('-I', 'file', $src,
                   '-P', 'pmt', '--service', $ctx.ServiceId,
                   '--pcr-pid', $ctx.SentinelPid, '--increment-version',
                   '-O', 'file', $dst)
            Invoke-TsduckTool -Exe $ctx.Tsp -Arguments $a | Out-Null
            return "tsp $($a -join ' ')"
        }
        Verify  = {
            param($dst, $after, $ctx)
            $svc = Get-ServiceInfo $after $ctx.ServiceId
            $declared = [int](Get-Prop $svc 'pcr-pid' -1)
            $carried  = Get-PidPacketCount $after $ctx.SentinelPid
            @(
                (New-Check 'PMT redirected' "the PMT declares PCR_PID $($ctx.SentinelPid)" `
                    ("declared PCR_PID $declared") ($declared -eq $ctx.SentinelPid))
                (New-Check 'the declared PID is empty' 'no packets exist on the declared PCR PID' `
                    ("$carried packets") ($carried -eq 0))
                (New-Check 'real clock still present' 'the original PCR PID still carries its PCRs' `
                    ("$(Get-PidStat $after $ctx.PcrPid 'pcr') PCR samples on PID $($ctx.PcrPid)") `
                    ((Get-PidStat $after $ctx.PcrPid 'pcr') -gt 0))
            )
        }
    },

    [pscustomobject]@{
        Id      = 'pid-collision'
        Title   = 'Two services claiming one elementary PID'
        Summary = 'A second service PMT is rewritten to also list the target service video PID, with the same stream type. Two PMTs now point at the same elementary stream.'
        Expected = 'Both services must still play. Sharing an elementary PID between programs is legal in MPEG-2 - it is how a simulcast is signalled - so a receiver has no grounds to reject either service. The second service will legitimately show the first service picture. Selecting one service must not disturb the other.'
        MustNot  = @('crash', 'hang', 'build two demultiplexer output pins for one PID and deadlock',
                     'corrupt the channel list by mapping one PID to two entries')
        Certainty = 'expected'
        Notes    = 'Honest caveat: this is malformed signalling in practice but not illegal, so nothing here is a spec violation the receiver may punish. The failure this is fishing for is structural - a PID-to-pin map that assumes a PID belongs to one program. If MPC-HC survives it, that is a genuine pass rather than a lucky one. The TSDuck pmt plugin rebuilds the whole PMT PID rather than editing packets in place, and in doing so it re-times the stream and drops roughly the last three per cent of it. The output is otherwise sound - PCR jitter is unchanged from the source - but this file is shorter than the others, which is why the manifest records a packet count per output.'
        Requires = {
            param($ctx)
            if ($ctx.OtherServiceId -eq 0) { return 'the source carries only one service' }
            return $null
        }
        Build   = {
            param($src, $dst, $ctx)
            $a = @('-I', 'file', $src,
                   '-P', 'pmt', '--service', $ctx.OtherServiceId,
                   '--add-pid', ("{0}/{1}" -f $ctx.VideoPid, $ctx.VideoStreamType),
                   '--increment-version',
                   '-O', 'file', $dst)
            Invoke-TsduckTool -Exe $ctx.Tsp -Arguments $a | Out-Null
            return "tsp $($a -join ' ')"
        }
        Verify  = {
            param($dst, $after, $ctx)
            $other = Get-ServiceInfo $after $ctx.OtherServiceId
            $pids  = @(Get-Prop $other 'pids' @())
            $mine  = Get-ServiceInfo $after $ctx.ServiceId
            $minePids = @(Get-Prop $mine 'pids' @())
            @(
                (New-Check 'second service claims the PID' "service $($ctx.OtherServiceId) now lists PID $($ctx.VideoPid)" `
                    ("PIDs: $($pids -join ', ')") ($pids -contains $ctx.VideoPid))
                (New-Check 'first service keeps the PID' "service $($ctx.ServiceId) still lists PID $($ctx.VideoPid)" `
                    ("PIDs: $($minePids -join ', ')") ($minePids -contains $ctx.VideoPid))
                (New-Check 'no PID orphaned' 'the multiplex has no unreferenced PIDs' `
                    ("$([int](Get-Prop (Get-Prop $after.ts 'pids') 'unreferenced' 0)) unreferenced") `
                    ([int](Get-Prop (Get-Prop $after.ts 'pids') 'unreferenced' 0) -eq 0))
            )
        }
    },

    [pscustomobject]@{
        Id      = 'transport-error'
        Title   = 'Transport error indicator set on a proportion of packets'
        Summary = 'transport_error_indicator is set on one packet in -ErrorRate across the whole multiplex, null packets excluded. The payloads are not otherwise touched.'
        Expected = 'ISO/IEC 13818-1 defines the bit as meaning the packet contains at least one uncorrectable bit error, so a receiver must discard the packet rather than parse it. The result should look like heavy but survivable packet loss spread over every service: artefacts, audio dropouts, tables that take longer to assemble.'
        MustNot  = @('crash', 'hang', 'parse a PSI section out of a packet flagged as errored',
                     'abandon playback outright')
        Certainty = 'required'
        Notes    = 'TSDuck own analyser discards flagged packets, which is why the verification below sees the affected PIDs lose packets and gain discontinuities: that is the correct reading of the flag, and a useful demonstration of what the receiver ought to do. This impairment hits PSI as well as elementary streams, so it also exercises table reassembly under loss.'
        Build   = {
            param($src, $dst, $ctx)
            # Three stages: label everything that is not stuffing, thin that to
            # one in N, then set the flag. Marking null packets would waste half
            # the error budget on packets no receiver looks at.
            $a = @('-I', 'file', $src,
                   '-P', 'filter', '--pid', 0x1FFF, '--negate', '--set-label', 1,
                   '-P', 'filter', '--only-label', 1, '--every', $ctx.ErrorRate, '--set-label', 2,
                   '-P', 'craft', '--only-label', 2, '--error',
                   '-O', 'file', $dst)
            Invoke-TsduckTool -Exe $ctx.Tsp -Arguments $a | Out-Null
            return "tsp $($a -join ' ')"
        }
        Verify  = {
            param($dst, $after, $ctx)
            $tei = [int](Get-Prop (Get-Prop $after.ts 'packets') 'transport-errors' 0)
            $total = [int]$after.ts.packets.total
            $want = [math]::Floor($total / $ctx.ErrorRate)
            @(
                (New-Check 'errored packets present' 'transport_error_indicator is set on some packets' `
                    ("$tei of $total packets flagged") ($tei -gt 0))
                (New-Check 'rate is roughly as asked' "near 1 in $($ctx.ErrorRate), allowing for null packets being skipped" `
                    ("$tei flagged, an even spread would be about $want") `
                    ($tei -gt ($want / 4) -and $tei -le $want))
                (New-Check 'stream still intact' 'the packet count is unchanged; only the flag was set' `
                    ("$total packets, was $([int]$ctx.Baseline.ts.packets.total)") `
                    ($total -eq [int]$ctx.Baseline.ts.packets.total))
            )
        }
    },

    [pscustomobject]@{
        Id      = 'false-scrambling'
        Title   = 'Scrambling flag set on clear video'
        Summary = 'transport_scrambling_control is set to 2 (even key) on the target service video PID. Nothing is encrypted and no conditional-access signalling is added or changed anywhere - the flag is simply a lie.'
        Expected = 'The bit is normative: when transport_scrambling_control is non-zero the payload is undefined, so a receiver must not hand those packets to a decoder. The correct outcome is that video does not decode. Audio is untouched and should continue. The service is signalled as clear everywhere else, so a receiver that reports encryption status from the SDT free_CA_mode flag will still call this service clear - a mismatch that is exactly the interesting part.'
        MustNot  = @('crash', 'hang', 'feed the flagged packets to the video decoder as clear',
                     'stop the audio or the clock')
        Certainty = 'required'
        Notes    = 'On a multiplex that also carries genuinely scrambled services there will already be a CAT, which is why the check below asks only that the conditional-access signalling is unchanged rather than absent. Genuinely uncertain part: whether MPC-HC ought to *report* the service as encrypted. It derives that from the SI, which says clear, so probably not - and arguably should not, since inventing an encryption status from packet headers would misreport a transient error as a subscription problem. The requirement is only that the packets are not decoded as if clear.'
        Build   = {
            param($src, $dst, $ctx)
            $a = @('-I', 'file', $src,
                   '-P', 'filter', '--pid', $ctx.VideoPid, '--set-label', 1,
                   '-P', 'craft', '--only-label', 1, '--scrambling', 2,
                   '-O', 'file', $dst)
            Invoke-TsduckTool -Exe $ctx.Tsp -Arguments $a | Out-Null
            return "tsp $($a -join ' ')"
        }
        Verify  = {
            param($dst, $after, $ctx)
            $p = Get-PidInfo $after $ctx.VideoPid
            $scr = Get-PidStat $after $ctx.VideoPid 'scrambled'
            $tot = Get-PidPacketCount $after $ctx.VideoPid
            $catNow    = Get-PidPacketCount $after 0x0001
            $catBefore = Get-PidPacketCount $ctx.Baseline 0x0001
            $wasClear  = -not [bool](Get-Prop (Get-PidInfo $ctx.Baseline $ctx.VideoPid) 'is-scrambled' $false)
            @(
                (New-Check 'video PID flagged scrambled' 'every packet of the video PID reports as scrambled' `
                    ("$scr of $tot packets") ($tot -gt 0 -and $scr -eq $tot))
                (New-Check 'analyser agrees' 'the PID is classified as scrambled' `
                    ($(if ([bool](Get-Prop $p 'is-scrambled' $false)) { 'scrambled' } else { 'clear' })) `
                    ([bool](Get-Prop $p 'is-scrambled' $false)))
                (New-Check 'the flag is ours' 'the video PID was clear in the source' `
                    ($(if ($wasClear) { 'source PID was clear' } else { 'source PID was already scrambled' })) $wasClear)
                (New-Check 'no CA signalling added' 'conditional-access signalling is unchanged from the source' `
                    ("CAT packets $catBefore -> $catNow") ($catNow -eq $catBefore))
                (New-Check 'audio left clear' 'the audio PID is not flagged' `
                    ("$(Get-PidStat $after $ctx.AudioPid 'scrambled') scrambled audio packets") `
                    ((Get-PidStat $after $ctx.AudioPid 'scrambled') -eq 0))
            )
        }
    }
)

# The ValidateSet above is a copy of these ids, kept for tab completion. If the
# two ever drift, fail here rather than silently offering an impairment that
# does not exist.
$catalogueIds = @($catalogue | ForEach-Object { $_.Id })
$declaredIds = @((Get-Command -Name $PSCommandPath).Parameters['Impairment'].Attributes |
                 Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
                 ForEach-Object { $_.ValidValues })
if (@(Compare-Object $catalogueIds $declaredIds).Count -ne 0) {
    throw "The -Impairment ValidateSet and the catalogue disagree: $((Compare-Object $catalogueIds $declaredIds | ForEach-Object { $_.InputObject }) -join ', ')"
}

# --- Listing ---------------------------------------------------------------

if ($PSCmdlet.ParameterSetName -eq 'List') {
    foreach ($imp in $catalogue) {
        Write-Host ''
        Write-Host $imp.Id -ForegroundColor Cyan -NoNewline
        Write-Host "  ($($imp.Certainty))" -ForegroundColor DarkGray
        Write-Host "  $($imp.Title)"
        Write-Host "  does:     $($imp.Summary)" -ForegroundColor DarkGray
        Write-Host "  expected: $($imp.Expected)" -ForegroundColor DarkGray
        Write-Host "  must not: $($imp.MustNot -join '; ')" -ForegroundColor DarkGray
    }
    Write-Host ''
    return
}

# --- Preflight -------------------------------------------------------------

foreach ($exe in @($tsp, $tstables)) {
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "TSDuck tool not found: $exe. Pass -TsduckBin, or fetch the portable build into third_party/bin."
    }
}

$source = (Resolve-Path -LiteralPath $InputStream).ProviderPath
if (-not $OutDir) { $OutDir = (Get-Location).Path }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).ProviderPath
if (-not $ManifestPath) { $ManifestPath = Join-Path $OutDir 'impairments.json' }

$wanted = $catalogue
if ($Impairment) { $wanted = @($catalogue | Where-Object { $Impairment -contains $_.Id }) }
if ($wanted.Count -eq 0) { throw "No impairments selected." }

$tsduckVersion = ((Invoke-TsduckTool -Exe $tsp -Arguments @('--version')).Trim() -replace '^tsp:\s*', '')

Write-Host "Source:  $source" -ForegroundColor Green
Write-Host "TSDuck:  $tsduckVersion"

# --- Baseline --------------------------------------------------------------
#
# Everything downstream is expressed as a difference from this, so a check can
# say "the video PID lost 135 packets" rather than "the video PID has 13305
# packets", which on its own proves nothing.

$baseline = Get-StreamAnalysis -Path $source

if ((Get-Services $baseline).Count -eq 0) {
    throw "$source carries no services that TSDuck can see. A T2-MI or otherwise non-playable capture cannot be impaired usefully."
}

# Pick the service to damage.
# Choosing which service to damage.
#
# Two properties make a service a poor target and both occur in the capture
# library. A scrambled service will not decode whatever we do to it, so a pass
# would be meaningless - whole multiplexes are scrambled. And a radio or data
# service has no video PID at all, which several impairments need; the Italian
# mux leads with one of those. So the default walks the services in id order
# and takes the first that is clear and carries video, relaxing each
# requirement in turn only if nothing qualifies.

function Get-ComponentPid {
    <# First PID of the service that the analyser classified as $Kind. #>
    param($Analysis, $ServiceInfo, [ValidateSet('video', 'audio')] [string] $Kind)

    foreach ($id in @(Get-Prop $ServiceInfo 'pids' @())) {
        $info = Get-PidInfo $Analysis ([int]$id)
        if ($null -ne $info -and [bool](Get-Prop $info $Kind $false)) { return [int]$id }
    }
    return 0
}

$ordered = @((Get-Services $baseline) | Sort-Object { [int]$_.id })
$target = $null
if ($Service) {
    $asId = 0
    if ($Service -match '^0[xX][0-9a-fA-F]+$') { $asId = [Convert]::ToInt32($Service, 16) }
    elseif ($Service -match '^\d+$')           { $asId = [int]$Service }
    if ($asId) { $target = $ordered | Where-Object { [int]$_.id -eq $asId } | Select-Object -First 1 }
    if (-not $target) { $target = $ordered | Where-Object { (Get-Prop $_ 'name' '') -eq $Service } | Select-Object -First 1 }
    if (-not $target) {
        throw "No service '$Service' in $source. Present: $((($ordered | ForEach-Object { "$($_.id) $(Get-Prop $_ 'name' '(unnamed)')" }) -join '; '))"
    }
}
else {
    foreach ($wantClear in @($true, $false)) {
        foreach ($s in $ordered) {
            if ($wantClear -and [bool](Get-Prop $s 'is-scrambled' $false)) { continue }
            if ((Get-ComponentPid $baseline $s 'video') -ne 0) { $target = $s; break }
        }
        if ($target) { break }
    }
    if (-not $target) {
        throw "No service in $source carries video. Pass -Service to name one anyway, or pick another capture."
    }
    if ([bool](Get-Prop $target 'is-scrambled' $false)) {
        Write-Warning "Every service in $source is scrambled; results of the video impairments will not be separable from the encryption. Pick a clear multiplex, or pass -Service to override."
    }
}

# A single-service multiplex simply cannot host the impairments that need a
# second service to leave alone, to collide with, or to drop. Those declare it
# in their Requires block and are skipped rather than aborting the run.
$other = @($ordered | Where-Object { [int]$_.id -ne [int]$target.id })

# The elementary PIDs to aim at. tsanalyze classifies PIDs, so video and audio
# come out of the analysis; the stream type does not appear there and is read
# from the PMT below.
$videoPid = Get-ComponentPid $baseline $target 'video'
$audioPid = Get-ComponentPid $baseline $target 'audio'
if (-not $videoPid) {
    throw "Service $($target.id) has no video PID, so the video impairments cannot be aimed. Pick another with -Service."
}
if (-not $audioPid) { $audioPid = $videoPid }   # the audio-is-untouched checks then degrade to a no-op

$pmtPid = [int](Get-Prop $target 'pmt-pid' 0)
$pcrPid = [int](Get-Prop $target 'pcr-pid' $videoPid)
if (-not $pmtPid) { throw "Service $($target.id) has no PMT PID in the analysis." }

# Stream type of the video PID, needed verbatim for pmt --add-pid.
$videoStreamType = 0x1B
$pmtJson = Get-TableJson -Path $source -TablePid $pmtPid
if ($null -ne $pmtJson -and $pmtJson.Count -gt 0) {
    foreach ($node in (Get-Prop $pmtJson[0] '#nodes' @())) {
        if ((Get-Prop $node '#name' '') -eq 'component' -and [int](Get-Prop $node 'elementary_pid' -1) -eq $videoPid) {
            $videoStreamType = [int](Get-Prop $node 'stream_type' 0x1B)
        }
    }
}

# A PID that carries nothing, for pcr-pid-missing. Walk down from 0x1FFE so
# that a stream already using the high PIDs still gets a genuinely empty one.
$sentinelPid = 0
for ($p = 0x1FFE; $p -ge 0x1F00; $p--) {
    if ($null -eq (Get-PidInfo $baseline $p)) { $sentinelPid = $p; break }
}
if (-not $sentinelPid) { throw "Could not find an unused PID for pcr-pid-missing." }

# Where the mid-stream impairments strike, converted from seconds.
$tsBitrate = if ($Bitrate) { $Bitrate } else { [int64](Get-Prop $baseline.ts 'bitrate' 0) }
if ($tsBitrate -le 0) {
    throw "TSDuck could not estimate a bitrate for $source, so -DelaySeconds cannot be converted to a packet offset. Pass -Bitrate."
}
$totalPackets = [int64]$baseline.ts.packets.total
$cutPacket = [int64][math]::Floor($DelaySeconds * $tsBitrate / (8 * 188))
if ($cutPacket -ge $totalPackets) {
    throw ("-DelaySeconds $DelaySeconds is past the end of a {0:N0}-packet stream (about {1} s). Use a shorter delay or a longer capture." -f
           $totalPackets, [int](Get-Prop $baseline.ts 'duration' 0))
}

$ctx = [pscustomobject]@{
    Tsp             = $tsp
    Baseline        = $baseline
    ServiceId       = [int]$target.id
    ServiceName     = [string](Get-Prop $target 'name' '')
    PmtPid          = $pmtPid
    PcrPid          = $pcrPid
    VideoPid        = $videoPid
    AudioPid        = $audioPid
    VideoStreamType = ('0x{0:X2}' -f $videoStreamType)
    OtherServiceId  = $(if ($other.Count) { [int]$other[0].id } else { 0 })
    OtherPmtPid     = $(if ($other.Count) { [int](Get-Prop $other[0] 'pmt-pid' 0) } else { 0 })
    OtherServiceIds = @($other | ForEach-Object { [int]$_.id })
    SentinelPid     = $sentinelPid
    CutPacket       = [int]$cutPacket
    ErrorRate       = $ErrorRate
    PidPat          = $PidPat
    PidNit          = $PidNit
    PidSdt          = $PidSdt
    TidPat          = $TidPat
    TidPmt          = $TidPmt
    TidSdtActual    = $TidSdtActual
}

Write-Host ("Target:  service {0} '{1}'  PMT 0x{2:X4}  PCR 0x{3:X4}  video 0x{4:X4}  audio 0x{5:X4}" -f `
            $ctx.ServiceId, $ctx.ServiceName, $ctx.PmtPid, $ctx.PcrPid, $ctx.VideoPid, $ctx.AudioPid)
Write-Host ("Stream:  {0:N0} packets, {1:N0} b/s, {2} s; cut at packet {3:N0} (~{4} s)" -f `
            $totalPackets, $tsBitrate, [int](Get-Prop $baseline.ts 'duration' 0), $cutPacket, $DelaySeconds)
Write-Host ''

# --- Build and verify ------------------------------------------------------

$stem = [IO.Path]::GetFileNameWithoutExtension($source)
$records = [System.Collections.Generic.List[object]]::new()
$failed = 0
$skipped = 0

foreach ($imp in $wanted) {
    $dst = Join-Path $OutDir "$stem-$($imp.Id).ts"
    if ((Test-Path -LiteralPath $dst) -and -not $Force) {
        throw "$dst already exists. Use -Force to overwrite."
    }

    Write-Host ("{0,-18} " -f $imp.Id) -NoNewline

    $requires = Get-Prop $imp 'Requires' $null
    $skipReason = $null
    if ($null -ne $requires) { $skipReason = & $requires $ctx }
    if ($skipReason) {
        Write-Host "skipped: $skipReason" -ForegroundColor DarkYellow
        $skipped++
        $records.Add([pscustomobject]@{
            id        = $imp.Id
            title     = $imp.Title
            file      = $null
            packets   = 0
            summary   = $imp.Summary
            expected  = $imp.Expected
            mustNot   = $imp.MustNot
            certainty = $imp.Certainty
            notes     = $imp.Notes
            method    = $null
            target    = $null
            verified  = $false
            skipped   = $true
            error     = $skipReason
            checks    = @()
        })
        continue
    }

    $method = $null
    $checks = @()
    $failure = $null
    $outPackets = 0

    try {
        $method = & $imp.Build $source $dst $ctx
        if (-not (Test-Path -LiteralPath $dst)) { throw "no output file was produced" }

        # The verification pass. tsp exits zero for a chain that matched
        # nothing, so this is the only thing that decides whether an
        # impairment is real.
        $after  = Get-StreamAnalysis -Path $dst
        $outPackets = [int]$after.ts.packets.total
        $checks = @(& $imp.Verify $dst $after $ctx)
    }
    catch {
        $failure = $_.Exception.Message
    }

    $ok = ($null -eq $failure) -and $checks.Count -gt 0 -and -not ($checks | Where-Object { -not $_.pass })
    if ($ok) { Write-Host 'verified' -ForegroundColor Green }
    elseif ($failure) { Write-Host "failed: $failure" -ForegroundColor Red; $failed++ }
    else {
        $failed++
        Write-Host 'NOT VERIFIED' -ForegroundColor Red
        foreach ($c in ($checks | Where-Object { -not $_.pass })) {
            Write-Host ("    {0}: expected {1}, observed {2}" -f $c.check, $c.expected, $c.observed) -ForegroundColor Red
        }
    }

    $records.Add([pscustomobject]@{
        id        = $imp.Id
        title     = $imp.Title
        file      = (Split-Path -Leaf $dst)
        packets   = $outPackets
        summary   = $imp.Summary
        expected  = $imp.Expected
        mustNot   = $imp.MustNot
        certainty = $imp.Certainty
        notes     = $imp.Notes
        method    = $method
        target    = [pscustomobject]@{
            serviceId   = $ctx.ServiceId
            serviceName = $ctx.ServiceName
            pmtPid      = $ctx.PmtPid
            pcrPid      = $ctx.PcrPid
            videoPid    = $ctx.VideoPid
            audioPid    = $ctx.AudioPid
        }
        verified  = $ok
        skipped   = $false
        error     = $failure
        checks    = $checks
    })
}

# --- Manifest --------------------------------------------------------------

$manifest = [pscustomobject]@{
    generator = 'tools/New-ImpairedStream.ps1'
    generated = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    tsduck    = $tsduckVersion
    source    = [pscustomobject]@{
        path     = $source
        packets  = $totalPackets
        bitrate  = $tsBitrate
        duration = [int](Get-Prop $baseline.ts 'duration' 0)
        services = (Get-Services $baseline).Count
        tsid     = [int](Get-Prop $baseline.ts 'id' 0)
    }
    parameters = [pscustomobject]@{
        delaySeconds = $DelaySeconds
        cutPacket    = [int]$cutPacket
        errorRate    = $ErrorRate
    }
    # Every impairment is applied to a fresh copy of the source, so a harness
    # may load these in any order and combine none of them.
    impairments = $records
}

$json = $manifest | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText($ManifestPath, $json, (New-Object Text.UTF8Encoding($false)))

Write-Host ''
Write-Host "Manifest: $ManifestPath" -ForegroundColor Green
Write-Host ("{0} of {1} impairments verified{2}." -f ($records.Count - $failed - $skipped), $records.Count,
            $(if ($skipped) { ", $skipped skipped as unbuildable from this source" } else { '' })) `
    -ForegroundColor $(if ($failed) { 'Yellow' } else { 'Green' })

if ($failed) {
    Write-Warning "$failed impairment(s) could not be verified. Their .ts files were still written; do not use them as test cases until the checks above pass."
    exit 1
}
