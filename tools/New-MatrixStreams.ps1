<#
.SYNOPSIS
    Build one transport stream per encoding-matrix.psd1 entry.

.DESCRIPTION
    The matrix has had a verifier since it was written and never had a
    producer. Test-StreamMatrix.ps1 takes a directory of finished streams and
    asserts them against the matrix; nothing built that directory. So all 21
    entries were a specification with nothing to check, and the five carrying a
    Tsduck.PatchXml were declaring descriptors that no code applied.

    This is the missing half. Per entry it runs ffmpeg for the elementary
    streams and the service identity, then TSDuck for anything ffmpeg cannot
    express -- which is every PMT descriptor the matrix cares about, since
    ffmpeg emits none of them.

    THE GATE

    After patching, the descriptor is read back out of the finished file. If it
    is not there the entry fails as a GENERATOR fault and is marked so, rather
    than being handed on as a stream to test a parser with.

    That distinction is the point. A parser assertion against a stream missing
    the descriptor is not a weaker test, it is a meaningless one: it cannot
    distinguish "MPC-HC failed to read the descriptor" from "the descriptor was
    never there". This project has been in that ambiguous state twice -- the
    five unapplied patches, and a chroma question where a zero would have been
    this generator's fault and was read as possibly the parser's.

    Two exit states, kept apart on purpose:

        GENERATOR  the built file does not contain what the matrix declared.
                   Nothing downstream should run. Fix the generator.
        OK         the file demonstrably carries it. Only now does a
                   disagreement from MPC-HC mean something about MPC-HC.

    Test-StreamMatrix.ps1 remains the independent check and is deliberately not
    called from here: its stated purpose is to distrust this script, and a
    generator that verifies itself with its own logic proves nothing.

.PARAMETER EntryId
    Build only these entries. Without it, the whole matrix.

.EXAMPLE
    .\New-MatrixStreams.ps1 -OutDir C:\ts\matrix
    .\New-MatrixStreams.ps1 -EntryId mpv-video-stream-descriptor-422 -Verbose
#>
[CmdletBinding()]
param(
    [string]   $MatrixPath = (Join-Path $PSScriptRoot 'encoding-matrix.psd1'),
    [string]   $OutDir     = (Join-Path $PSScriptRoot '..\build\matrix-streams'),
    [string[]] $EntryId,
    [string]   $FFmpeg,
    [string]   $TsduckBin,
    [switch]   $KeepIntermediate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- tools -----------------------------------------------------------------

function Resolve-FFmpeg {
    param([string] $Explicit)
    if ($Explicit) {
        if (-not (Test-Path $Explicit)) { throw "ffmpeg not found at $Explicit" }
        return $Explicit
    }
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $hit = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($hit) { return $hit.FullName }
    throw 'ffmpeg not found. Install with: winget install Gyan.FFmpeg'
}

$ffmpegExe = Resolve-FFmpeg -Explicit $FFmpeg
if (-not $TsduckBin) {
    $TsduckBin = Join-Path $PSScriptRoot '..\third_party\bin\tsduck\TSDuck\bin'
}
$tspExe      = Join-Path $TsduckBin 'tsp.exe'
$tstablesExe = Join-Path $TsduckBin 'tstables.exe'
foreach ($exe in @($tspExe, $tstablesExe)) {
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "TSDuck tool not found: $exe. Pass -TsduckBin, or fetch the portable build into third_party/bin."
    }
}

# --- matrix ----------------------------------------------------------------

$repoRoot = Split-Path -Parent $PSScriptRoot
$matrix   = Import-PowerShellDataFile $MatrixPath
$defaults = $matrix.Defaults

# The falsifiability lint first. Building streams for an entry that cannot fail
# wastes the run and then reports a pass, which is worse than not running.
& (Join-Path $PSScriptRoot 'Test-MatrixFalsifiable.ps1') -MatrixPath $MatrixPath | Out-Null

function Get-Value {
    param($Entry, [string] $Key)
    if ($Entry.ContainsKey($Key)) { return $Entry[$Key] }
    if ($defaults.ContainsKey($Key)) { return $defaults[$Key] }
    return $null
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path

$entries = $matrix.Entries
if ($EntryId) { $entries = $entries | Where-Object { $EntryId -contains $_.Id } }
if (-not $entries) { throw "No matrix entries matched." }

# --- per entry -------------------------------------------------------------

function Resolve-SubtitleSource {
    <#
    .SYNOPSIS
        The .dvbsub file an entry names, generated if it is not there yet.
    .DESCRIPTION
        The matrix declares assets/flatcolour.dvbsub and that file has never
        existed, for the same reason the streams never did: nothing built it.
        New-DvbSubtitle.ps1 writes EN 300 743 segments directly, because DVB
        subtitles are bitmaps and there is no encoder that will rasterise text
        into them.

        Generated rather than committed: it is derived, it is regenerable from
        one command, and a binary blob in the tree is one more thing that can
        drift from the code that made it.
    #>
    param([string] $Source, [string] $RepoRoot)

    $path = if ([System.IO.Path]::IsPathRooted($Source)) { $Source } else { Join-Path $RepoRoot $Source }
    $meta = "$path.meta.json"
    if ((Test-Path -LiteralPath $path) -and (Test-Path -LiteralPath $meta)) {
        $m = Get-Content $meta -Raw | ConvertFrom-Json
        return [pscustomobject]@{ Path = $path; SetBytes = [int]$m.SetBytes }
    }

    New-Item -ItemType Directory -Force -Path (Split-Path $path -Parent) | Out-Null
    Write-Verbose "generating subtitle asset $path"
    $sub = & (Join-Path $PSScriptRoot 'New-DvbSubtitle.ps1') -Text 'bda-vtuner matrix' -OutFile $path
    if (-not (Test-Path -LiteralPath $path)) { throw "New-DvbSubtitle.ps1 did not produce $path" }
    # The sidecar exists because raw_packet_size must equal one display set
    # exactly; an asset without its size is unusable, so they regenerate as a
    # pair.
    @{ SetBytes = $sub.SetBytes; RepeatCount = $sub.RepeatCount; Bytes = $sub.Bytes
       Text = $sub.Text; Region = $sub.Region; ProbePoints = $sub.ProbePoints } |
        ConvertTo-Json -Depth 5 | Set-Content $meta
    [pscustomobject]@{ Path = $path; SetBytes = [int]$sub.SetBytes }
}

function New-AtscPsip {
    <#
    .SYNOPSIS
        Build the MGT and TVCT an ATSC service needs, as a TSDuck XML file.
    .DESCRIPTION
        ffmpeg emits no PSIP at all, and without it CMpeg2DataParser::ParseMGT
        fails, the VCT is never read, and the service is invisible to an ATSC
        scan no matter how correct its PMT is. So these entries were building
        streams that could not be found.

        The MGT announces a TVCT on PID 0x1FFB and the TVCT carries the channel
        as dtv, which is the ATSC_DIGITAL_TV the parser accepts.
    #>
    param($Entry, [int] $Tsid, [string] $Path)

    $a = $Entry.Atsc
    $xml = @"
<?xml version="1.0" encoding="UTF-8"?>
<tsduck>
  <MGT version="0" protocol_version="0">
    <table type="TVCT-current" PID="0x1FFB" version_number="0" number_bytes="0"/>
  </MGT>
  <TVCT version="0" current="true" protocol_version="0" transport_stream_id="$Tsid">
    <channel short_name="$($Entry.ServiceName)"
             major_channel_number="$($a.MajorChannelNumber)"
             minor_channel_number="$($a.MinorChannelNumber)"
             modulation_mode="$($a.ModulationMode)"
             channel_TSID="$Tsid"
             program_number="$($Entry.ServiceId)"
             service_type="dtv"
             source_id="$($a.SourceId)"/>
  </TVCT>
</tsduck>
"@
    Set-Content -LiteralPath $Path -Value $xml -Encoding UTF8
    $Path
}

function Get-PatchedDescriptors {
    # What the patch declares, element and attributes both, so the gate can
    # check the values landed rather than only that something of that name did.
    #
    # Name-only was the first version of this, and it was the same defect the
    # project keeps finding: all four chroma entries declare a
    # video_stream_descriptor, so a patch writing chroma_format 1 to every one
    # of them would have passed. A gate that cannot tell the entries apart is
    # not a gate.
    param([string] $Xml)
    $out = @()
    foreach ($m in [regex]::Matches($Xml, '<(\w+_descriptor)\b([^>]*)>')) {
        $attrs = @{}
        # [\w-]+ not \w+: \w stops at the hyphen, so x-node was captured as
        # "node" and the skip below never matched, making every entry fail with
        # a declared attribute the built descriptor could not have.
        foreach ($a in [regex]::Matches($m.Groups[2].Value, '([\w-]+)="([^"]*)"')) {
            # x-node is patch machinery, not a descriptor field.
            if ($a.Groups[1].Value -eq 'x-node') { continue }
            $attrs[$a.Groups[1].Value] = $a.Groups[2].Value
        }
        $out += [pscustomobject]@{ Name = $m.Groups[1].Value; Attributes = $attrs }
    }
    # No unary comma: it would wrap this in a second array, and @() at the call
    # site would then see one element that is itself the list. Callers wrap.
    $out
}

function Test-DescriptorLanded {
    # Compare declared attributes against the descriptor as TSDuck reads it back
    # out of the finished file. Returns mismatches; empty means it all landed.
    param($Declared, [string] $PmtXml)

    $problems = @()
    foreach ($d in $Declared) {
        $found = [regex]::Match($PmtXml, ('<' + [regex]::Escape($d.Name) + '\b([^>]*)>'))
        if (-not $found.Success) {
            $problems += "$($d.Name) is absent from the built PMT"
            continue
        }
        $actual = @{}
        foreach ($a in [regex]::Matches($found.Groups[1].Value, '([\w-]+)="([^"]*)"')) {
            $actual[$a.Groups[1].Value] = $a.Groups[2].Value
        }
        foreach ($k in $d.Attributes.Keys) {
            if (-not $actual.ContainsKey($k)) {
                $problems += "$($d.Name): declared $k but the built descriptor has no such attribute"
            }
            elseif ($actual[$k] -ne $d.Attributes[$k]) {
                $problems += "$($d.Name): declared $k=$($d.Attributes[$k]) but the built descriptor says $($actual[$k])"
            }
        }
    }
    $problems
}

function Test-StreamSize {
    # Returns a description of the problem, or nothing when the file is usable.
    param([string] $File)
    $bytes = (Get-Item -LiteralPath $File).Length
    if ($bytes -ge $script:MinStreamBytes) { return }
    ("{0:N0} bytes, under the {1:N0} the driver needs. Below that floor it serves the buffer still " +
     "holding the previous stream while reporting OK and locked, so the channel plays the wrong " +
     "content with no error anywhere. Raise VideoBitrate or DurationSeconds for this entry.") -f
        $bytes, $script:MinStreamBytes
}

function Test-AtscPsip {
    # Returns a description of what is missing, or nothing when both tables are
    # present. Reads them back out of the finished file for the same reason the
    # descriptor gate does: an inject that stole no stuffing leaves a file that
    # looks fine and is invisible to an ATSC scan.
    param([string] $File)
    $tmp = [System.IO.Path]::GetTempFileName() + '.xml'
    try {
        & $tstablesExe $File --pid 0x1FFB --xml-output $tmp --no-duplicate 2>&1 | Out-Null
        $xml = if (Test-Path $tmp) { Get-Content $tmp -Raw } else { '' }
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
    $missing = @()
    if ($xml -notmatch '<MGT\b')  { $missing += 'MGT' }
    if ($xml -notmatch '<TVCT\b') { $missing += 'TVCT' }
    if (-not $missing.Count) { return }
    ("PID 0x1FFB carries no {0}. ParseMGT then fails, the VCT is never read, and the service cannot be " +
     "found by an ATSC scan however correct its PMT is. tsp -P inject steals stuffing to build the PID, " +
     "so check the mux rate leaves any.") -f ($missing -join ' or ')
}

function Get-PmtXml {
    param([string] $File)
    $tmp = [System.IO.Path]::GetTempFileName() + '.xml'
    try {
        # tid 2 is the PMT. --xml-output rewrites the file per table, so the
        # last write wins and that is the table we want.
        & $tstablesExe $File --tid 2 --xml-output $tmp --no-duplicate 2>&1 | Out-Null
        if (-not (Test-Path $tmp)) { return $null }
        Get-Content $tmp -Raw
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

# src/MergedDevice: VIDEO_READ_BUFFER_SIZE is 188 * 312 * 10 and the driver
# double-buffers it. A file below that is served from the buffer still holding
# the PREVIOUS stream, while the driver reports OK and signal-locked -- so the
# scan succeeds, the channel plays, and the content belongs to whatever ran
# before. It is the worst failure shape this rig has: no error anywhere.
#
# A stream that cannot be played correctly is not a test stream, so this is a
# generator fault like any other. Checked here rather than left to the README,
# because the matrix's own defaults produce files well under the floor.
$script:MinStreamBytes = 188 * 312 * 10 * 2   # 1,173,120

$results = @()
$script:probeIndex = [System.Collections.Generic.List[object]]::new()

foreach ($entry in $entries) {
    $id       = $entry.Id
    $file     = Join-Path $OutDir $entry.File
    $duration = Get-Value $entry 'DurationSeconds'
    $width    = Get-Value $entry 'Width'
    $height   = Get-Value $entry 'Height'
    $rate     = Get-Value $entry 'FrameRate'

    $videoSource = (Get-Value $entry 'VideoSource') -replace '\{width\}', $width -replace '\{height\}', $height -replace '\{framerate\}', $rate
    $audioSource = Get-Value $entry 'AudioSource'

    $ff = $entry.FFmpeg
    $args = [System.Collections.Generic.List[string]]::new()
    $args.AddRange([string[]]@('-y', '-hide_banner', '-loglevel', 'error'))

    # Video is optional: radio-mpa is a DIGITAL_RADIO service with no video PID
    # at all, which is a real DVB service shape and one MPC-HC has to classify.
    $hasVideo = $ff.ContainsKey('Video') -and $null -ne $ff.Video
    if ($hasVideo) {
        $args.AddRange([string[]]@('-f', 'lavfi', '-t', "$duration", '-i', $videoSource))
    }
    # one audio input per declared audio stream
    $audioCount = 0
    if ($ff.ContainsKey('Audio') -and $ff.Audio) {
        foreach ($a in $ff.Audio) {
            $args.AddRange([string[]]@('-f', 'lavfi', '-t', "$duration", '-i', $audioSource))
            $audioCount++
        }
    }

    # Subtitle inputs, after the audio ones so the map indices stay predictable.
    $subCount = 0
    $subLangs = @()
    if ($ff.ContainsKey('Subtitles') -and $ff.Subtitles) {
        foreach ($sub in $ff.Subtitles) {
            $src = Resolve-SubtitleSource -Source $sub.Source -RepoRoot $repoRoot
            # Probe points travel with the run: Test-MpcFrame asserts pixel
            # colours at these display coordinates, and a probes file that
            # drifted from the streams would assert against the wrong grid.
            $assetPath = if ([System.IO.Path]::IsPathRooted($sub.Source)) { $sub.Source } else { Join-Path $repoRoot $sub.Source }
            $sideMeta = Get-Content ($assetPath + '.meta.json') -Raw | ConvertFrom-Json
            $script:probeIndex.Add([pscustomobject]@{
                Id = $id; ServiceName = $entry.ServiceName; Language = $sub.Language
                ProbePoints = $sideMeta.ProbePoints })
            # raw_packet_size = one display set exactly. Smaller splits a set
            # (silently discarded); larger fuses all repeats into one packet at
            # one PTS, so a viewer tuning mid-loop never sees a subtitle.
            $args.AddRange([string[]]@('-f', 'dvbsub', '-raw_packet_size', "$($src.SetBytes)", '-i', $src.Path))
            $subLangs += $sub.Language
            $subCount++
        }
    }

    $inputOffset = 0
    if ($hasVideo) {
        $args.AddRange([string[]]@('-map', '0:v'))
        $inputOffset = 1
    }
    for ($i = 0; $i -lt $audioCount; $i++) { $args.AddRange([string[]]@('-map', "$($i + $inputOffset):a")) }
    for ($i = 0; $i -lt $subCount; $i++) { $args.AddRange([string[]]@('-map', "$($i + $inputOffset + $audioCount):s")) }

    if ($hasVideo) {
        $args.AddRange([string[]]@('-c:v', $ff.Video.Encoder))
        if ($ff.Video.ContainsKey('Options') -and $ff.Video.Options) { $args.AddRange([string[]]$ff.Video.Options) }
        $args.AddRange([string[]]@('-b:v', (Get-Value $entry 'VideoBitrate')))
        $args.AddRange([string[]]@('-r', "$rate"))
    }

    if ($audioCount) {
        $ai = 0
        foreach ($a in $ff.Audio) {
            $args.AddRange([string[]]@("-c:a:$ai", $a.Encoder))
            if ($a.ContainsKey('Options') -and $a.Options) { $args.AddRange([string[]]$a.Options) }
            if ($a.ContainsKey('Language') -and $a.Language) {
                $args.AddRange([string[]]@("-metadata:s:a:$ai", "language=$($a.Language)"))
            }
            $ai++
        }
        $args.AddRange([string[]]@('-b:a', (Get-Value $entry 'AudioBitrate')))
    }

    if ($subCount) {
        # Copy, never re-encode: the segments were built to be exactly right and
        # a round trip through a decoder could only lose that.
        $args.AddRange([string[]]@('-c:s', 'copy'))
        # Spread the repeated display sets to broadcast cadence. The raw dvbsub
        # demuxer stamps every packet ~11 microseconds apart whatever the input
        # options say (-r, -framerate and -itsscale are all ignored for raw
        # subtitles -- tested, not assumed), so the timestamps are rewritten at
        # the bitstream layer: N is the per-stream packet index, the mpegts
        # subtitle timebase is 1/90000, so N*180000 is one display set every
        # two seconds. This is what makes a subtitle visible to a viewer who
        # tunes mid-loop; a single PTS near file start is stale for everyone
        # else, and CDVBSub keys display on PTS against the live clock.
        $args.AddRange([string[]]@('-bsf:s', 'setts=ts=N*180000'))
        for ($i = 0; $i -lt $subCount; $i++) {
            $args.AddRange([string[]]@("-metadata:s:s:$i", "language=$($subLangs[$i])"))
        }
    }

    # Service identity. ParsePMT is only reached for a program that appeared in
    # the SDT with an accepted service_type, so this is not cosmetic.
    # The TVCT has to name the same transport_stream_id the mux actually
    # carries, or the channel it describes belongs to a different stream.
    $tsid = [int](Get-Value $entry 'TransportStreamId')
    $args.AddRange([string[]]@('-mpegts_transport_stream_id', "$tsid"))
    # onid too: left unset, ffmpeg defaults to 0xFF01 while the matrix declares
    # 0x2000 -- found by Test-MpcDecode's first real run, when the triplet join
    # refused to match anything.
    $onid = [int](Get-Value $entry 'OriginalNetworkId')
    $args.AddRange([string[]]@('-mpegts_original_network_id', "$onid"))
    $args.AddRange([string[]]@(
        '-mpegts_service_id',   "$($entry.ServiceId)",
        '-mpegts_service_type', "$($entry.ServiceType)",
        '-metadata',            "service_name=$($entry.ServiceName)",
        '-metadata',            'service_provider=bda-vtuner'))

    # CBR stuffing, when the matrix asks for it. -b:v is a target, not a floor,
    # and flat colour never spends it -- so raising the video bitrate does not
    # reliably raise the file size, while a mux rate does. That is what makes
    # the driver's minimum reachable deterministically instead of depending on
    # how well a given entry's content happens to compress.
    $muxRate = Get-Value $entry 'MuxRate'
    if ($muxRate) { $args.AddRange([string[]]@('-muxrate', "$muxRate")) }

    if ($ff.ContainsKey('MuxerOptions') -and $ff.MuxerOptions) { $args.AddRange([string[]]$ff.MuxerOptions) }

    $patch = $null
    if ($entry.ContainsKey('Tsduck') -and $entry.Tsduck -and $entry.Tsduck.ContainsKey('PatchXml')) {
        $patch = $entry.Tsduck.PatchXml
    }
    # Post-ffmpeg stages. Either can be absent; both can apply.
    $hasAtsc   = $entry.ContainsKey('Atsc') -and $entry.Atsc
    $needsPost = $patch -or $hasAtsc
    $ffTarget  = if ($needsPost) { "$file.pre" } else { $file }
    $args.AddRange([string[]]@('-f', 'mpegts', $ffTarget))

    Write-Host ("{0,-42} " -f $id) -NoNewline
    Write-Verbose ("ffmpeg " + (($args | ForEach-Object { if ($_ -match '[\s;,=]') { '"' + $_ + '"' } else { $_ } }) -join ' '))

    $ffOut = & $ffmpegExe @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'GENERATOR (ffmpeg)' -ForegroundColor Red
        $results += [pscustomobject]@{ Id = $id; State = 'GENERATOR'; Detail = "ffmpeg exit $LASTEXITCODE`n$($ffOut | Out-String)" }
        continue
    }

    $current  = $ffTarget
    $scratch  = @()
    $failed   = $null

    if ($patch) {
        # --patch-xml takes inline XML when the argument starts with "<?xml",
        # which is why the matrix stores it that way. The standalone patch
        # plugin is absent from our portable TSDuck; this is the pmt plugin's
        # own option and needs nothing extra.
        $next = "$file.pmt"
        $tspArgs = @('-I', 'file', $current,
                     '-P', 'pmt', '--service', "$($entry.ServiceId)", '--patch-xml', $patch,
                     '-O', 'file', $next)
        Write-Verbose ("tsp " + ($tspArgs -join ' '))
        $tspOut = & $tspExe @tspArgs 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $next)) {
            $failed = "tsp pmt exit $LASTEXITCODE`n$($tspOut | Out-String)"
        } else {
            $scratch += $current; $current = $next
        }
    }

    if (-not $failed -and $hasAtsc) {
        # inject steals stuffing to make a new PID, which is why these entries
        # carry a mux rate: a VBR file offers nothing to steal and the PSIP
        # silently fails to appear.
        $psipXml = "$file.psip.xml"
        New-AtscPsip -Entry $entry -Tsid $tsid -Path $psipXml | Out-Null
        $next = "$file.psip"
        $tspArgs = @('-I', 'file', $current,
                     # No --repeat: it means "this many times then stop", not
                     # "forever", and 0 is rejected. Omitting it repeats for the
                     # length of the stream, which is what a PSIP table needs --
                     # a receiver tuning mid-file must still find the MGT.
                     '-P', 'inject', $psipXml, '--pid', '0x1FFB', '--bitrate', '5000',
                     '-O', 'file', $next)
        Write-Verbose ("tsp " + ($tspArgs -join ' '))
        $tspOut = & $tspExe @tspArgs 2>&1
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $next)) {
            $failed = "tsp inject exit $LASTEXITCODE`n$($tspOut | Out-String)"
        } else {
            $scratch += $current, $psipXml; $current = $next
        }
    }

    if ($failed) {
        Write-Host 'GENERATOR (tsp)' -ForegroundColor Red
        $results += [pscustomobject]@{ Id = $id; State = 'GENERATOR'; Detail = $failed }
        continue
    }

    if ($needsPost) {
        Move-Item -LiteralPath $current -Destination $file -Force
        if (-not $KeepIntermediate) {
            foreach ($f in $scratch) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
        }
    }

    # --- gates -------------------------------------------------------------

    $summary = @()

    if ($patch) {
        $want = @(Get-PatchedDescriptors -Xml $patch)
        $pmt  = Get-PmtXml -File $file
        if (-not $pmt) {
            Write-Host 'GENERATOR (no PMT)' -ForegroundColor Red
            $results += [pscustomobject]@{ Id = $id; State = 'GENERATOR'; Detail = 'no PMT could be read back from the built file' }
            continue
        }
        $problems = @(Test-DescriptorLanded -Declared $want -PmtXml $pmt)
        if ($problems.Count) {
            Write-Host 'GENERATOR (descriptor wrong)' -ForegroundColor Red
            $results += [pscustomobject]@{
                Id = $id; State = 'GENERATOR'
                Detail = ("the built PMT does not match what the patch declared:`n{0}" -f ($problems -join "`n"))
            }
            continue
        }
        $summary += ($want | ForEach-Object {
            $kv = ($_.Attributes.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '
            "$($_.Name) [$kv]" })
    }

    if ($hasAtsc) {
        # Same principle as the descriptor gate: read the tables back out of the
        # finished file. An injection that stole no stuffing produces a file
        # that looks fine and is invisible to an ATSC scan.
        $psipMissing = Test-AtscPsip -File $file
        if ($psipMissing) {
            Write-Host 'GENERATOR (PSIP absent)' -ForegroundColor Red
            $results += [pscustomobject]@{ Id = $id; State = 'GENERATOR'; Detail = $psipMissing }
            continue
        }
        $summary += "MGT + TVCT on 0x1FFB"
    }

    $tooSmall = Test-StreamSize -File $file
    if ($tooSmall) {
        Write-Host 'GENERATOR (too small for the driver)' -ForegroundColor Red
        $results += [pscustomobject]@{ Id = $id; State = 'GENERATOR'; Detail = $tooSmall }
        continue
    }

    Write-Host 'OK' -ForegroundColor Green
    if ($summary.Count) { Write-Verbose ("    verified in file: " + ($summary -join '; ')) }
    $results += [pscustomobject]@{ Id = $id; State = 'OK'; Detail = ($summary -join '; ') }
}

if ($script:probeIndex.Count) {
    $probesPath = Join-Path $OutDir 'subtitle-probes.json'
    ,$script:probeIndex | ConvertTo-Json -Depth 6 | Set-Content $probesPath
    Write-Host ("subtitle probes: {0}" -f $probesPath)
}

# --- report ----------------------------------------------------------------

$bad = @($results | Where-Object { $_.State -ne 'OK' })
Write-Host ''
Write-Host ("{0} built, {1} generator fault(s)." -f @($results | Where-Object { $_.State -eq 'OK' }).Count, $bad.Count)
Write-Host ("Output: {0}" -f $OutDir)

if ($bad.Count) {
    foreach ($b in $bad) {
        Write-Host ''
        Write-Host ("GENERATOR  {0}" -f $b.Id) -ForegroundColor Red
        Write-Host ("    " + ($b.Detail -replace "`r?`n", "`n    "))
    }
    Write-Host ''
    Write-Host 'Nothing downstream should run against these. Verify the rest with Test-StreamMatrix.ps1,' -ForegroundColor Yellow
    Write-Host 'which checks the built files independently of this script.' -ForegroundColor Yellow
    exit 1
}

Write-Host ''
Write-Host 'Now verify independently:' -ForegroundColor Cyan
Write-Host ("  .\Test-StreamMatrix.ps1 -StreamDirectory {0}" -f $OutDir)
