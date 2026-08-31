<#
.SYNOPSIS
    Generates transport stream samples for the virtual tuner, so the project
    does not have to carry a library of real off-air captures.

.DESCRIPTION
    The captures this project started with are around 1.7 GB. Nearly all of
    that is real broadcast video, which is exactly the part the tuner does not
    care about: the driver streams bytes and MPC-HC parses tables. Flat colour
    encodes to almost nothing, so a generated sample of the same structural
    complexity costs a fraction of the size and can live in the repository.

    Each generated channel is deliberately self-describing. The picture
    alternates between two colours once per second and carries the channel
    name, its colour pair and a running second count, so a glance at a frame
    tells you which service you are watching and how far into the loop it is.
    Audio is a tone at a per-channel frequency, so channels are distinguishable
    without looking. That makes a wrong-PID or wrong-service bug obvious rather
    than subtle.

    Output is one multi-service mux per frequency, matching how real muxes are
    laid out, so a channel scan has several frequencies to find and several
    services to enumerate at each.

.PARAMETER OutDir
    Where the .ts files are written.

.PARAMETER Standard
    Selects the band plan used to assign a frequency to each mux, and the
    video/audio codecs conventional for that standard.

.PARAMETER Duration
    Seconds per sample. Ten is enough to exercise tuning, table parsing and a
    few seconds of playback; the driver loops the file.

.PARAMETER SourceDir
    Use real video files from this directory instead of generated colour, one
    per channel. The identifying overlay is still applied, so samples stay
    self-describing. Use this to build tests from your own content.

.PARAMETER VideoCodec
    Overrides the codec that -Standard would choose. Useful for building
    per-codec samples.

.PARAMETER AudioCodec
    Overrides the audio codec.

.PARAMETER SubtitlesFrom
    Path to a transport stream containing DVB subtitles. A short extract of its
    subtitle stream is copied into each generated channel. DVB subtitles are
    bitmaps and ffmpeg will not rasterise text into them, so a real subtitle
    stream has to be borrowed from somewhere; see the note in the README.

.EXAMPLE
    .\New-TestStreams.ps1 -OutDir C:\ts-gen

.EXAMPLE
    .\New-TestStreams.ps1 -OutDir C:\ts-gen -Standard ATSC -Duration 15

.EXAMPLE
    .\New-TestStreams.ps1 -OutDir C:\ts-gen -SourceDir D:\my-clips
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]   $OutDir,

    [ValidateSet('DVBT', 'ATSC', 'DVBC', 'DVBS')]
    [string]   $Standard = 'DVBT',

    # Twenty seconds rather than ten, to clear the driver's minimum stream size.
    # VIDEO_READ_BUFFER_SIZE is 188 x 312 x 10 = 586,560 bytes, double-buffered
    # in fileread.cpp; below about 1,173,120 bytes the driver keeps serving
    # whatever file it had open while still reporting a lock, so a scan returns
    # channels from the wrong content with no error anywhere.
    [ValidateRange(2, 600)]
    [int]      $Duration = 20,

    [string]   $SourceDir,

    [ValidateSet('mpeg2video', 'libx264', 'libx265')]
    [string]   $VideoCodec,

    [ValidateSet('mp2', 'ac3', 'eac3', 'aac')]
    [string]   $AudioCodec,

    [switch]   $WithSubtitles,

    [string]   $FFmpeg,
    [string]   $FontFile = 'C:\Windows\Fonts\consola.ttf'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Tools -----------------------------------------------------------------

function Resolve-FFmpeg {
    param([string] $Explicit)
    if ($Explicit) {
        if (-not (Test-Path $Explicit)) { throw "ffmpeg not found at $Explicit" }
        return $Explicit
    }
    $cmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # winget installs to a versioned package directory that is not always on
    # PATH in a non-interactive shell.
    $hit = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if ($hit) { return $hit.FullName }
    throw 'ffmpeg not found. Install with: winget install Gyan.FFmpeg'
}

$ffmpeg = Resolve-FFmpeg -Explicit $FFmpeg
Write-Verbose "ffmpeg: $ffmpeg"

if (-not (Test-Path $FontFile)) {
    throw "Font not found: $FontFile. The overlay needs a TrueType font; pass -FontFile."
}

# --- Defaults per standard -------------------------------------------------
#
# Codecs are the ones conventional for each standard, so a sample looks like
# something the real world would produce. Frequencies come from the same band
# plans Provision-VTuner.ps1 uses, so generated muxes land where a scan expects.

$profiles = @{
    DVBT = @{ Video = 'mpeg2video'; Audio = 'mp2';  Size = '704x576'; Rate = 25;    Freqs = @(474000, 482000, 490000) }
    DVBC = @{ Video = 'mpeg2video'; Audio = 'mp2';  Size = '704x576'; Rate = 25;    Freqs = @(306000, 314000, 322000) }
    DVBS = @{ Video = 'mpeg2video'; Audio = 'mp2';  Size = '704x576'; Rate = 25;    Freqs = @(10714000, 10744000, 10774000) }
    ATSC = @{ Video = 'mpeg2video'; Audio = 'ac3';  Size = '704x480'; Rate = 29.97; Freqs = @(473000, 479000, 485000) }
}
$prof = $profiles[$Standard]

# fileread.cpp reads through two VIDEO_READ_BUFFER_SIZE buffers, that constant
# being PS_PACKET_SIZE x PS_PACKETS_PER_SAMPLE x 10 = 188 x 312 x 10.
$MinimumStreamBytes = 188 * 312 * 10 * 2

$vcodec = if ($VideoCodec) { $VideoCodec } else { $prof.Video }
$acodec = if ($AudioCodec) { $AudioCodec } else { $prof.Audio }

# --- Channel plan ----------------------------------------------------------
#
# Colour pairs are chosen to be unmistakable from each other at a glance, and
# the audio frequencies are spread far enough apart to tell apart by ear.

# Each mux gets its own transport stream id, and every service its own id
# within it. Previously neither was set, so ffmpeg defaulted all three muxes to
# the same tsid and numbered services from 1 in each -- which put an identical
# (onid, tsid, sid) triplet on three different frequencies -- found
# in a real capture: ten decoded channels collapsed to seven distinct
# triplets, with (65281, 256, 1) appearing at 474, 482 and 490 MHz.
#
# That matters beyond tidiness. Anything joining decoded channels to their
# specification by service identity would match the wrong service rather than
# fail, and a test passing against a channel it was not looking at is the exact
# failure this project keeps finding. No real network does this either: two
# frequencies never carry the same transport stream id.
$muxes = @(
    @{ Name = 'mux1'; Tsid = 0x0101; Channels = @(
        @{ Name = 'Test Channel 1'; Sid = 0x0011; ColourA = 'red';    ColourB = 'green';   Tone = 440 }
        @{ Name = 'Test Channel 2'; Sid = 0x0012; ColourA = 'blue';   ColourB = 'yellow';  Tone = 880 }
    )}
    @{ Name = 'mux2'; Tsid = 0x0102; Channels = @(
        @{ Name = 'Test Channel 3'; Sid = 0x0021; ColourA = 'cyan';   ColourB = 'magenta'; Tone = 1320 }
        @{ Name = 'Test Channel 4'; Sid = 0x0022; ColourA = 'white';  ColourB = 'black';   Tone = 1760 }
    )}
    @{ Name = 'mux3'; Tsid = 0x0103; Channels = @(
        @{ Name = 'Test Channel 5'; Sid = 0x0031; ColourA = 'orange'; ColourB = 'purple';  Tone = 2200 }
    )}
)

# Replace generated colour with the user's own clips when asked.
$sourceFiles = @()
if ($SourceDir) {
    if (-not (Test-Path $SourceDir -PathType Container)) { throw "SourceDir not found: $SourceDir" }
    $sourceFiles = @(Get-ChildItem $SourceDir -File -Include *.mp4, *.mkv, *.avi, *.mov, *.ts -Recurse | Sort-Object Name)
    if ($sourceFiles.Count -eq 0) { throw "No video files found under $SourceDir" }
    Write-Host "Using $($sourceFiles.Count) source clip(s) from $SourceDir" -ForegroundColor Cyan
}

# --- Filter construction ---------------------------------------------------
#
# ffmpeg's filter parser treats , : ' and \ as syntax, so anything appearing
# inside a filter argument has to be escaped for it -- separately from any
# escaping PowerShell does when building the string.

function ConvertTo-FilterLiteral {
    param([string] $Text)
    $Text -replace '\\', '\\\\' -replace ':', '\:' -replace "'", "\'" -replace ',', '\,'
}

# Forward slashes sidestep backslash escaping entirely inside a filter
# argument; only the drive-letter colon then needs escaping.
$fontEscaped = ($FontFile -replace '\\', '/') -replace ':', '\:'

function New-OverlayFilter {
    <#
        Alternates the two colours once per second and stamps the channel
        identity plus a running second count over the top. The second count is
        what makes a stalled or looping stream obvious at a glance.
    #>
    param([string] $InLabel, [string] $OutLabel, [hashtable] $Channel, [bool] $HasSource)

    $label = ConvertTo-FilterLiteral "$($Channel.Name) [$($Channel.ColourA)/$($Channel.ColourB)]"
    $text  = "$label t=%{eif\:trunc(t)\:d}s"

    $parts = @()
    if (-not $HasSource) {
        # Second colour is painted over the first on odd seconds.
        $parts += "drawbox=w=iw:h=ih:color=$($Channel.ColourB):t=fill:enable='gte(mod(t\,2)\,1)'"
    }
    # Size the text to the frame rather than fixing it, so a longer channel
    # name or a smaller raster does not run off the edge.
    $parts += ("drawtext=fontfile='{0}':text='{1}':fontcolor=white:fontsize=h/18:" +
               "box=1:boxcolor=black@0.6:boxborderw=10:x=(w-tw)/2:y=(h-th)/2") -f $fontEscaped, $text

    "[$InLabel]" + ($parts -join ',') + "[$OutLabel]"
}

# --- Generate --------------------------------------------------------------

New-Item -ItemType Directory -Force $OutDir | Out-Null
$results = [System.Collections.Generic.List[object]]::new()
$allSubtitles = [System.Collections.Generic.List[object]]::new()
$sourceIndex = 0
$freqIndex = 0

# Subtitles are composed against the display size, which the harness needs in
# order to translate probe coordinates onto a captured frame.
$dispW, $dispH = $prof.Size -split 'x' | ForEach-Object { [int]$_ }
$subDir = Join-Path $OutDir 'subtitles'
if ($WithSubtitles) { New-Item -ItemType Directory -Force $subDir | Out-Null }

foreach ($mux in $muxes) {
    $inputs   = [System.Collections.Generic.List[string]]::new()
    $filters  = [System.Collections.Generic.List[string]]::new()
    $maps     = [System.Collections.Generic.List[string]]::new()
    $programs = [System.Collections.Generic.List[string]]::new()
    $subtitleMeta = [System.Collections.Generic.List[object]]::new()

    $streamIndex = 0
    $inputIndex  = 0

    foreach ($ch in $mux.Channels) {
        $useSource = ($sourceFiles.Count -gt 0)

        if ($useSource) {
            $src = $sourceFiles[$sourceIndex % $sourceFiles.Count].FullName
            $sourceIndex++
            $inputs.AddRange([string[]]@('-t', "$Duration", '-i', $src))
            $vIn = "${inputIndex}:v:0"
            $aIn = "${inputIndex}:a:0"
            $inputIndex++
        } else {
            $inputs.AddRange([string[]]@('-f', 'lavfi', '-i', "color=c=$($ch.ColourA):s=$($prof.Size):r=$($prof.Rate):d=$Duration"))
            $vIn = "${inputIndex}:v"
            $inputIndex++
            $inputs.AddRange([string[]]@('-f', 'lavfi', '-i', "sine=frequency=$($ch.Tone):duration=$Duration`:sample_rate=48000"))
            $aIn = "${inputIndex}:a"
            $inputIndex++
        }

        $vOut = "v$streamIndex"
        $filters.Add((New-OverlayFilter -InLabel $vIn -OutLabel $vOut -Channel $ch -HasSource $useSource))

        $maps.AddRange([string[]]@('-map', "[$vOut]"))
        $vStream = $streamIndex; $streamIndex++
        $maps.AddRange([string[]]@('-map', $aIn))
        $aStream = $streamIndex; $streamIndex++

        $streamList = "st=$vStream`:st=$aStream"

        if ($WithSubtitles) {
            # A generated DVB subtitle carrying the channel identity for a human
            # and a colour grid for the harness. See New-DvbSubtitle.ps1 for why
            # the bitmap has to be built here rather than encoded from text.
            $subFile = Join-Path $subDir ("{0}-{1}.dvbsub" -f $mux.Name, ($ch.Name -replace '[^\w]', ''))
            $sub = & (Join-Path $PSScriptRoot 'New-DvbSubtitle.ps1') `
                        -Text "$($ch.Name) [$($ch.ColourA)/$($ch.ColourB)]" `
                        -OutFile $subFile -DisplayWidth $dispW -DisplayHeight $dispH
            # raw_packet_size = exactly one display set. Too small splits a set
            # and the decoder discards it silently; too large (the old 65536)
            # fuses every repeat into one packet at one PTS, and a viewer who
            # tunes after that instant never sees a subtitle -- which is what
            # made every tuned-channel probe read video colour.
            $inputs.AddRange([string[]]@('-f', 'dvbsub', '-raw_packet_size', "$($sub.SetBytes)", '-i', $subFile))
            $sIn = "${inputIndex}:s"
            $inputIndex++
            $maps.AddRange([string[]]@('-map', $sIn))
            $streamList += "`:st=$streamIndex"
            $streamIndex++

            $subtitleMeta.Add([pscustomobject]@{
                Channel     = $ch.Name
                Language    = 'eng'
                Region      = $sub.Region
                ProbePoints = $sub.ProbePoints
            })
        }

        $title = $ch.Name -replace ':', '-'
        # program_num is the service id in the PMT/SDT. Without it ffmpeg
        # numbers services from 1 in every mux, which is half of the collision
        # described above.
        $programs.AddRange([string[]]@('-program', "title=$title`:program_num=$($ch.Sid)`:$streamList"))
    }

    $outFile = Join-Path $OutDir ("{0}-{1}-{2}.ts" -f $Standard.ToLower(), $mux.Name, $prof.Freqs[$freqIndex])

    $args = [System.Collections.Generic.List[string]]::new()
    $args.AddRange([string[]]@('-y', '-hide_banner', '-loglevel', 'error'))
    $args.AddRange($inputs)
    $args.AddRange([string[]]@('-filter_complex', ($filters -join ';')))
    $args.AddRange($maps)
    # Flat colour needs very little bitrate; the point is structure, not fidelity.
    $args.AddRange([string[]]@('-c:v', $vcodec, '-b:v', '200k', '-c:a', $acodec, '-b:a', '64k'))
    if ($WithSubtitles) {
        # Copy, not re-encode: the segments were built to be exactly right and
        # a round trip through the decoder could only lose that.
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
        for ($s = 0; $s -lt $subtitleMeta.Count; $s++) {
            $args.AddRange([string[]]@("-metadata:s:s:$s", 'language=eng'))
        }
    }
    $args.AddRange($programs)
    $args.AddRange([string[]]@('-mpegts_transport_stream_id', "$($mux.Tsid)"))
    $args.AddRange([string[]]@('-metadata', 'service_provider=bda-vtuner', '-f', 'mpegts', $outFile))

    Write-Host "Generating $(Split-Path $outFile -Leaf) ($($mux.Channels.Count) services) ..." -ForegroundColor Cyan
    # Filter graphs are fiddly to escape correctly; log the exact command line
    # so a failure can be reproduced by hand rather than guessed at.
    Write-Verbose ("ffmpeg " + (($args | ForEach-Object { if ($_ -match '[\s;,]') { "`"$_`"" } else { $_ } }) -join ' '))
    $ffOutput = & $ffmpeg @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        $detail = ($ffOutput | Select-Object -Last 8) -join "`n  "
        throw "ffmpeg failed for $outFile (exit $LASTEXITCODE)`n  $detail"
    }

    # The driver reads through a double-buffered VIDEO_READ_BUFFER_SIZE window.
    # A file below that is served incorrectly but *silently* - lock is reported,
    # a scan completes, and the channels come from whichever file was open
    # before. Catch it here, where the cause is obvious, rather than in a test
    # result that looks merely puzzling.
    $sizeBytes = (Get-Item $outFile).Length
    if ($sizeBytes -lt $MinimumStreamBytes) {
        # Build the template first: -f binds tighter than +, so applying it to a
        # concatenation formats only the final literal and the rest prints raw.
        $template = "{0} is {1:N0} bytes, below the driver's {2:N0} byte minimum. " +
                    "It will appear to tune and lock while serving the previous file's content. " +
                    "Increase -Duration or add services to this mux."
        Write-Warning ($template -f (Split-Path $outFile -Leaf), $sizeBytes, $MinimumStreamBytes)
    }

    $results.Add([pscustomobject]@{
        File      = Split-Path $outFile -Leaf
        Frequency = $prof.Freqs[$freqIndex]
        Services  = $mux.Channels.Count
        SizeKB    = [math]::Round($sizeBytes / 1KB)
        Undersize = ($sizeBytes -lt $MinimumStreamBytes)
    })

    foreach ($m in $subtitleMeta) {
        $allSubtitles.Add([pscustomobject]@{
            File        = Split-Path $outFile -Leaf
            Frequency   = $prof.Freqs[$freqIndex]
            Channel     = $m.Channel
            Language    = $m.Language
            Region      = $m.Region
            ProbePoints = $m.ProbePoints
        })
    }
    $freqIndex++
}

# --- Report ----------------------------------------------------------------

Write-Host ''
$results | Format-Table -AutoSize @{L='File';E={$_.File}},
                                  @{L='kHz';E={$_.Frequency}},
                                  @{L='Services';E={$_.Services}},
                                  @{L='KB';E={$_.SizeKB}} |
    Out-String -Width 200 | Write-Host

if ($allSubtitles.Count -gt 0) {
    # The harness needs to know where to sample a captured frame. Emitting the
    # coordinates here means it never has to re-derive the layout, and a change
    # to the subtitle design cannot silently desynchronise the two.
    $manifest = Join-Path $OutDir 'subtitle-probes.json'
    $allSubtitles | ConvertTo-Json -Depth 6 | Set-Content $manifest -Encoding UTF8
    Write-Host "Probe manifest: $manifest ($($allSubtitles.Count) subtitle streams)" -ForegroundColor Green
}

$total = ($results | Measure-Object SizeKB -Sum).Sum
Write-Host ("Total {0:N0} KB for {1} muxes / {2} services" -f $total, $results.Count,
            ($results | Measure-Object Services -Sum).Sum) -ForegroundColor Green
Write-Host ''
Write-Host 'Provision these with:' -ForegroundColor Cyan
Write-Host "  .\Provision-VTuner.ps1 -TsLibrary $OutDir -Standard $Standard -GuestPath C:\ts" -ForegroundColor Cyan
