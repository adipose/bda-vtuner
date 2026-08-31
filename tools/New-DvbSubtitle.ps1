<#
.SYNOPSIS
    Builds a DVB subtitle (EN 300 743) elementary stream carrying readable text
    and a machine-checkable colour grid.

.DESCRIPTION
    DVB subtitles are bitmaps, not text: the broadcaster transmits an image and
    the player decodes and composites it. ffmpeg will not rasterise text into
    them ("only possible from text to text or bitmap to bitmap"), so a
    synthetic subtitle has to be drawn and encoded here.

    The output is a raw subtitle elementary stream. ffmpeg's `dvbsub` demuxer
    reads it directly, so muxing, PES packetisation, PID assignment and the
    subtitling_descriptor are left to ffmpeg:

        ffmpeg -f lavfi -i color=... \
               -f dvbsub -raw_packet_size 65536 -i out.dvbsub \
               -map 0:v -map 1:s -c:s copy -metadata:s:s:0 language=eng \
               -f mpegts out.ts

    -raw_packet_size is not optional. The raw demuxer chops its input into
    fixed-size packets, 1024 bytes by default, with no regard for segment
    boundaries. A display set larger than that is split across packets and the
    decoder discards it, reporting only "Junk in packet" and emitting no
    subtitle at all - the segments themselves are perfectly valid. Pass a size
    comfortably larger than the whole file.

    TSDuck then reports the result as "Subtitles (eng, DVB subtitles)" on a
    stream_type 0x06 PID with a 0x59 descriptor, which is what MPC-HC keys on
    to reach BDA_SUBTITLE.

    Each image carries two things. The text is for a human reading a failed
    test's screenshot. The colour grid is for the harness: a row of known
    colours at known offsets, so an assertion is a handful of pixel probes
    rather than an image comparison or OCR. Probing the grid exercises the
    whole path - RLE decode, CLUT mapping, region placement, compositing - and
    a wrong colour at a given cell localises the fault. The probe coordinates
    are returned so the caller does not have to duplicate the arithmetic.

.PARAMETER Text
    The line drawn into the bitmap, for human eyes.

.PARAMETER OutFile
    Path of the .dvbsub elementary stream to write.

.PARAMETER DisplayWidth
    Width of the display the subtitle is composed against. 720 is the DVB
    default and what the decoder assumes when no display definition segment is
    present.

.PARAMETER DisplayHeight
    Height of that display.

.PARAMETER GridColours
    Colours of the probe cells, left to right. Defaults to six well separated
    hues so a tolerant comparison can never confuse two of them.

.PARAMETER DisplaySeconds
    page_time_out. The decoder removes the page after this long, so it wants to
    exceed the clip length for a subtitle that should stay up throughout.

.OUTPUTS
    An object describing what was written, including ProbePoints - display
    coordinates and the colour expected at each.

.EXAMPLE
    $s = .\New-DvbSubtitle.ps1 -Text 'Channel 1 red/green' -OutFile ch1.dvbsub
    $s.ProbePoints | Format-Table
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]   $Text,

    [Parameter(Mandatory)]
    [string]   $OutFile,

    [int]      $DisplayWidth  = 720,
    [int]      $DisplayHeight = 576,
    # Deliberately DISJOINT from every channel video colour (red, green, blue,
    # yellow, cyan, magenta, white, black, orange, purple). The old defaults
    # began Red/Lime, and a probe on Channel 1 -- red/green video -- passed at
    # distance 1 by reading the video, not the subtitle. Each of these is more
    # than the probe tolerance (96) from every channel colour in RGB distance;
    # Goldenrod was rejected for sitting 49 from orange, which is why the set
    # looks arbitrary and is not.
    [string[]] $GridColours   = @('Teal', 'SaddleBrown', 'SlateBlue', 'DeepPink', 'SpringGreen', 'MidnightBlue'),
    [int]      $DisplaySeconds = 255,
    [string]   $FontName      = 'Consolas',
    [int]      $FontSize      = 22,

    # How many times the complete display set is written. One display set means
    # one PTS near the file start, and a decoder keying display on PTS against
    # a live clock -- which is what CDVBSub does against the looping driver --
    # never shows it to anyone who tuned after that instant. Real broadcasts
    # re-send the display set every few seconds for exactly this reason. The
    # first set is page_state "mode change", the repeats "acquisition point",
    # per EN 300 743 acquisition semantics.
    [ValidateRange(1, 60)]
    [int]      $RepeatCount   = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

# --- Bit-level writer ------------------------------------------------------
#
# Several segment fields are not byte aligned (version numbers are 4 bits,
# page_state 2, object positions 12), so segments are assembled bit by bit and
# checked for alignment at the end.

class BitWriter {
    [System.Collections.Generic.List[byte]] $Bytes
    [int] $Acc
    [int] $Bits

    BitWriter() {
        $this.Bytes = [System.Collections.Generic.List[byte]]::new()
        $this.Acc = 0
        $this.Bits = 0
    }

    [void] Write([int] $value, [int] $width) {
        for ($i = $width - 1; $i -ge 0; $i--) {
            $this.Acc = ($this.Acc -shl 1) -bor (($value -shr $i) -band 1)
            $this.Bits++
            if ($this.Bits -eq 8) {
                $this.Bytes.Add([byte]$this.Acc)
                $this.Acc = 0
                $this.Bits = 0
            }
        }
    }

    [void] Byte([int] $v) { $this.Write($v, 8) }

    [byte[]] ToArray() {
        if ($this.Bits -ne 0) {
            throw "Segment is not byte aligned: $($this.Bits) bits pending. A field width is wrong."
        }
        return $this.Bytes.ToArray()
    }
}

function New-Segment {
    param([int] $Type, [int] $PageId, [byte[]] $Data)
    $w = [BitWriter]::new()
    $w.Byte(0x0F)                    # sync_byte
    $w.Byte($Type)                   # segment_type
    $w.Write($PageId, 16)
    $w.Write($Data.Length, 16)       # segment_length
    $out = [System.Collections.Generic.List[byte]]::new()
    $out.AddRange($w.ToArray())
    if ($Data.Length -gt 0) { $out.AddRange($Data) }
    # Leading comma stops PowerShell unrolling the array, which would turn
    # byte[] into Object[] and break AddRange at the caller.
    return ,$out.ToArray()
}

# --- Palette ---------------------------------------------------------------
#
# Entry 0 must be the transparent background: the region is filled with it and
# runs of it are the cheapest thing to encode. Text and outline follow, then
# the probe colours.

$palette = [System.Collections.Generic.List[object]]::new()
$palette.Add(@{ Name = 'transparent'; R = 0;   G = 0;   B = 0;   Alpha = 0   })
$palette.Add(@{ Name = 'text';        R = 255; G = 255; B = 255; Alpha = 255 })
$palette.Add(@{ Name = 'backdrop';    R = 0;   G = 0;   B = 0;   Alpha = 255 })
foreach ($c in $GridColours) {
    $k = [System.Drawing.Color]::FromName($c)
    if (-not $k.IsKnownColor) { throw "Unknown colour '$c'." }
    $palette.Add(@{ Name = $c; R = $k.R; G = $k.G; B = $k.B; Alpha = 255 })
}
if ($palette.Count -gt 255) { throw 'Too many palette entries.' }

function ConvertTo-Ycrcb {
    # BT.601, which is what DVB subtitle CLUTs are defined against.
    param([int] $R, [int] $G, [int] $B)
    $y  = 16  + (0.257 * $R) + (0.504 * $G) + (0.098 * $B)
    $cr = 128 + (0.439 * $R) - (0.368 * $G) - (0.071 * $B)
    $cb = 128 - (0.148 * $R) - (0.291 * $G) + (0.439 * $B)
    return @{
        Y  = [int][Math]::Round([Math]::Max(0, [Math]::Min(255, $y)))
        Cr = [int][Math]::Round([Math]::Max(0, [Math]::Min(255, $cr)))
        Cb = [int][Math]::Round([Math]::Max(0, [Math]::Min(255, $cb)))
    }
}

# --- Draw ------------------------------------------------------------------
#
# The subtitle occupies a band across the lower part of the display. Drawing
# happens on an indexed canvas rather than a colour one: every pixel is written
# as a palette index directly, which avoids a quantisation step that could
# blur the probe cells into neighbouring colours.

$regionWidth  = [int]($DisplayWidth * 0.8)
$regionHeight = 96
$regionX      = [int](($DisplayWidth - $regionWidth) / 2)
$regionY      = $DisplayHeight - $regionHeight - 40

$indices = New-Object 'byte[]' ($regionWidth * $regionHeight)   # 0 = transparent

# Text is rasterised with System.Drawing, then thresholded to two indices. A
# threshold rather than a blend keeps every pixel exactly on a palette entry.
$bmp = New-Object System.Drawing.Bitmap $regionWidth, 48
$g   = [System.Drawing.Graphics]::FromImage($bmp)
try {
    $g.Clear([System.Drawing.Color]::Black)
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::SingleBitPerPixelGridFit
    $font  = New-Object System.Drawing.Font($FontName, $FontSize, [System.Drawing.FontStyle]::Bold)
    $brush = [System.Drawing.Brushes]::White
    $size  = $g.MeasureString($Text, $font)
    $g.DrawString($Text, $font, $brush, [float](($regionWidth - $size.Width) / 2), 6.0)
    $g.Flush()

    for ($y = 0; $y -lt 48; $y++) {
        for ($x = 0; $x -lt $regionWidth; $x++) {
            $p = $bmp.GetPixel($x, $y)
            # Anything appreciably bright is text; the rest is the opaque
            # backdrop that makes the text legible over any video.
            $indices[$y * $regionWidth + $x] = if ((($p.R + $p.G + $p.B) / 3) -gt 110) { 1 } else { 2 }
        }
    }
} finally {
    $g.Dispose()
    $bmp.Dispose()
    if ($font) { $font.Dispose() }
}

# Probe grid: one cell per colour, filling the band below the text.
$cellCount  = $GridColours.Count
$cellWidth  = [int]($regionWidth / $cellCount)
$gridTop    = 52
$gridHeight = $regionHeight - $gridTop

$probePoints = [System.Collections.Generic.List[object]]::new()
for ($c = 0; $c -lt $cellCount; $c++) {
    $idx  = 3 + $c                       # palette entries after transparent/text/backdrop
    $x0   = $c * $cellWidth
    $x1   = if ($c -eq $cellCount - 1) { $regionWidth } else { $x0 + $cellWidth }
    for ($y = $gridTop; $y -lt $regionHeight; $y++) {
        for ($x = $x0; $x -lt $x1; $x++) { $indices[$y * $regionWidth + $x] = [byte]$idx }
    }
    $entry = $palette[$idx]
    $probePoints.Add([pscustomobject]@{
        Cell     = $c
        Colour   = $GridColours[$c]
        # Centre of the cell in display coordinates, which is where a harness
        # should sample. Kept away from cell edges so that chroma subsampling
        # and any scaling cannot bleed a neighbour in.
        X        = $regionX + [int](($x0 + $x1) / 2)
        Y        = $regionY + $gridTop + [int]($gridHeight / 2)
        Expected = [pscustomobject]@{ R = $entry.R; G = $entry.G; B = $entry.B }
    })
}

# --- Encode pixels ---------------------------------------------------------
#
# 8-bit/pixel_code_string (EN 300 743 7.2.5.3) is used rather than 4-bit
# because in the forms needed here it is byte aligned, which removes a whole
# class of bit-packing bug:
#   nonzero byte              one pixel of that colour
#   0x00 then 0LLLLLLL        run of L pixels of entry 0
#   0x00 then 1LLLLLLL, code  run of L pixels of that colour, L = 3..127
#   0x00 then 0x00            end of string

function Add-PixelRun {
    param([System.Collections.Generic.List[byte]] $Out, [int] $Colour, [int] $Length)
    while ($Length -gt 0) {
        $n = [Math]::Min($Length, 127)
        if ($Colour -eq 0) {
            $Out.Add(0x00); $Out.Add([byte]$n)
        } elseif ($n -ge 3) {
            $Out.Add(0x00); $Out.Add([byte](0x80 -bor $n)); $Out.Add([byte]$Colour)
        } else {
            for ($i = 0; $i -lt $n; $i++) { $Out.Add([byte]$Colour) }
        }
        $Length -= $n
    }
}

# Objects are interlaced: the top field carries the even display lines of the
# region and the bottom field the odd ones. Emitting every line into the top
# field overruns the region by a factor of two and the decoder discards the
# object ("Junk in packet") without producing a subtitle at all.

function ConvertTo-FieldData {
    param([byte[]] $Indices, [int] $Width, [int] $Height, [int] $FirstRow)

    $out = [System.Collections.Generic.List[byte]]::new()
    for ($y = $FirstRow; $y -lt $Height; $y += 2) {
        $out.Add(0x12)                   # data_type: 8-bit/pixel code string
        $x = 0
        while ($x -lt $Width) {
            $colour = $Indices[$y * $Width + $x]
            $run = 1
            while (($x + $run) -lt $Width -and $Indices[$y * $Width + $x + $run] -eq $colour) { $run++ }
            Add-PixelRun -Out $out -Colour $colour -Length $run
            $x += $run
        }
        $out.Add(0x00); $out.Add(0x00)   # end of string
        $out.Add(0xF0)                   # end_of_object_line_code
    }
    return ,$out.ToArray()
}

$topField    = ConvertTo-FieldData -Indices $indices -Width $regionWidth -Height $regionHeight -FirstRow 0
$bottomField = ConvertTo-FieldData -Indices $indices -Width $regionWidth -Height $regionHeight -FirstRow 1

# --- Segments --------------------------------------------------------------

$pageId = 1

# Page composition
$w = [BitWriter]::new()
$w.Byte([Math]::Min($DisplaySeconds, 255))
$w.Write(0, 4)                # page_version_number
$w.Write(2, 2)                # page_state: mode change
$w.Write(0, 2)                # reserved
$w.Byte(0)                    # region_id
$w.Byte(0)                    # reserved
$w.Write($regionX, 16)
$w.Write($regionY, 16)
$pcs = New-Segment -Type 0x10 -PageId $pageId -Data $w.ToArray()

# Region composition
$w = [BitWriter]::new()
$w.Byte(0)                    # region_id
$w.Write(0, 4)                # region_version_number
$w.Write(1, 1)                # region_fill_flag
$w.Write(0, 3)                # reserved
$w.Write($regionWidth, 16)
$w.Write($regionHeight, 16)
$w.Write(3, 3)                # region_level_of_compatibility: 8-bit CLUT
$w.Write(3, 3)                # region_depth: 8 bit
$w.Write(0, 2)                # reserved
$w.Byte(0)                    # CLUT_id
$w.Byte(0)                    # region_8-bit_pixel_code -> fill with transparent
$w.Write(0, 4)                # region_4-bit_pixel_code
$w.Write(0, 2)                # region_2-bit_pixel_code
$w.Write(0, 2)                # reserved
$w.Write(0, 16)               # object_id
$w.Write(0, 2)                # object_type: basic bitmap
$w.Write(0, 2)                # object_provider_flag
$w.Write(0, 12)               # object_horizontal_position
$w.Write(0, 4)                # reserved
$w.Write(0, 12)               # object_vertical_position
$rcs = New-Segment -Type 0x11 -PageId $pageId -Data $w.ToArray()

# CLUT
$w = [BitWriter]::new()
$w.Byte(0)                    # CLUT_id
$w.Write(0, 4)                # CLUT_version_number
$w.Write(0, 4)                # reserved
for ($i = 0; $i -lt $palette.Count; $i++) {
    $e = $palette[$i]
    $c = ConvertTo-Ycrcb -R $e.R -G $e.G -B $e.B
    $w.Byte($i)               # CLUT_entry_id
    $w.Write(0, 1)            # 2-bit/entry_CLUT_flag
    $w.Write(0, 1)            # 4-bit/entry_CLUT_flag
    $w.Write(1, 1)            # 8-bit/entry_CLUT_flag
    $w.Write(0, 4)            # reserved
    $w.Write(1, 1)            # full_range_flag
    $w.Byte($c.Y); $w.Byte($c.Cr); $w.Byte($c.Cb)
    # T is transparency, not opacity: 0 is fully opaque, 255 fully transparent.
    $w.Byte(255 - $e.Alpha)
}
$cds = New-Segment -Type 0x12 -PageId $pageId -Data $w.ToArray()

# Object data
$w = [BitWriter]::new()
$w.Write(0, 16)               # object_id
$w.Write(0, 4)                # object_version_number
$w.Write(0, 2)                # object_coding_method: coding of pixels
$w.Write(0, 1)                # non_modifying_colour_flag
$w.Write(0, 1)                # reserved
$w.Write($topField.Length, 16)      # top_field_data_block_length
$w.Write($bottomField.Length, 16)   # bottom_field_data_block_length
$odsData = [System.Collections.Generic.List[byte]]::new()
$odsData.AddRange($w.ToArray())
$odsData.AddRange($topField)
$odsData.AddRange($bottomField)
if ($odsData.Count % 2 -ne 0) { $odsData.Add(0x00) }
$ods = New-Segment -Type 0x13 -PageId $pageId -Data $odsData.ToArray()

$eds = New-Segment -Type 0x80 -PageId $pageId -Data @()

# One complete display set, PCS built per repetition so page_state can differ:
# mode change announces the page, acquisition point re-sends it for late
# joiners. Everything else is byte-identical between repeats, which keeps
# SetBytes constant -- the demuxer splits the file into packets of exactly
# that size, so every repeat gets its own packet and its own PTS.
function New-DisplaySet {
    param([int] $PageState)
    $w = [BitWriter]::new()
    $w.Byte([Math]::Min($DisplaySeconds, 255))
    $w.Write(0, 4)                # page_version_number
    $w.Write($PageState, 2)       # page_state
    $w.Write(0, 2)                # reserved
    $w.Byte(0)                    # region_id
    $w.Byte(0)                    # reserved
    $w.Write($regionX, 16)
    $w.Write($regionY, 16)
    $p = New-Segment -Type 0x10 -PageId $pageId -Data $w.ToArray()
    $set = [System.Collections.Generic.List[byte]]::new()
    foreach ($seg in @($p, $rcs, $cds, $ods, $eds)) { $set.AddRange([byte[]]$seg) }
    ,$set.ToArray()
}

$firstSet = New-DisplaySet -PageState 2    # mode change
$repeat   = New-DisplaySet -PageState 1    # acquisition point
if ($firstSet.Length -ne $repeat.Length) { throw 'display set size varies with page_state; SetBytes would be wrong' }

$stream = [System.Collections.Generic.List[byte]]::new()
$stream.AddRange($firstSet)
for ($i = 1; $i -lt $RepeatCount; $i++) { $stream.AddRange($repeat) }

New-Item -ItemType Directory -Force (Split-Path $OutFile -Parent) -ErrorAction SilentlyContinue | Out-Null
[System.IO.File]::WriteAllBytes($OutFile, $stream.ToArray())

[pscustomobject]@{
    File         = $OutFile
    Bytes        = $stream.Count
    # The raw demuxer's packet size: one display set exactly, so each repeat
    # becomes its own packet with its own PTS. A caller passing anything else
    # (the old 65536) fuses all repeats into one packet at one PTS and undoes
    # the whole point.
    SetBytes     = $firstSet.Length
    RepeatCount  = $RepeatCount
    Text         = $Text
    Region       = [pscustomobject]@{ X = $regionX; Y = $regionY; Width = $regionWidth; Height = $regionHeight }
    ProbePoints  = $probePoints
}
