<#
.SYNOPSIS
    Fail matrix entries whose expectations cannot fail.

.DESCRIPTION
    Three times now this matrix has carried an entry that reads as a careful
    test and could not have failed. Each was the same defect: an expectation
    that happened to equal a value ParsePMT invents when the descriptor is
    absent, so a stream carrying the descriptor and a stream missing it
    produced an identical result.

        Defaults raster                720x576   Mpeg2SectionData.cpp:605-608
        mpv-background-grid            720x576   same
        mpv-video-stream-descriptor    frc 3     :603 and :611, BDA_FPS_25_0

    They were plausible because the fallback was chosen to be plausible. That
    is why review keeps missing them, and why this is mechanical rather than a
    matter of looking harder.

    Four rules.

    UNASSERTED - a patch injects a descriptor and the entry claims nothing
    about what it should produce. The purest unfalsifiable entry there is: it
    does work and makes no claim. Checked per descriptor rather than by
    demanding Expect.Video everywhere, because entries that patch stream types
    assert through Expect.Streams and would otherwise false-positive.

    UNFALSIFIABLE - an Expect field equal to the fallback for that field.
    Allowed when some other field in the same entry differs from its own
    fallback, because that field then proves the descriptor arrived. This is
    what lets the MPEG_1_only control expect BDA_Chroma_NONE legitimately: its
    paired BDA_FPS_50_0 does the proving.

    UNSATISFIABLE - an expectation no stream could ever meet, the only one of
    these that fails closed rather than open. MPEG_1_only="true" makes the
    descriptor one byte and ParsePMT never reaches the chroma read, so any
    chroma other than BDA_Chroma_NONE can never be produced. It matters beyond
    its own report: such a value would otherwise be counted as a proving field
    and license a second field to sit at its fallback, so the hole could mask
    a defect rather than merely miss one.

    DISAGREEMENT - a descriptor claiming something the elementary stream does
    not have. A video_stream_descriptor declaring frame_rate_code 6 over a
    25 fps stream is a lie that would pass every assertion here, because
    nothing downstream compares the descriptor against the media.

    Host-side and rig-free by construction: it reads the matrix, never a
    stream and never a guest.

.EXAMPLE
    .\Test-MatrixFalsifiable.ps1
    .\Test-MatrixFalsifiable.ps1 -SelfTest
#>
[CmdletBinding()]
param(
    [string] $MatrixPath = (Join-Path $PSScriptRoot 'encoding-matrix.psd1'),
    [switch] $SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# What ParsePMT invents when the descriptor is absent. Every value here is one
# MPC-HC supplies itself, so an expectation equal to it proves nothing.
#
# The self-test deliberately does NOT reference this table. Its fixtures carry
# the true values as literals, so a mistyped entry here fails the self-test
# instead of silently disabling the lint.
$script:Fallback = @{
    Fps    = 'BDA_FPS_25_0'      # :603 and :611, for MPV, H264 and HEVC
    Chroma = 'BDA_Chroma_NONE'   # reset at :519, set only when MPEG_1_only = 0
    Width  = 720                 # :605-608, MPV only, and only with Height
    Height = 576
}

# frame_rate_code -> enum name and actual rate, so a descriptor can be checked
# against the stream it claims to describe.
$script:FrameRateCode = @{
    1 = @{ Enum = 'BDA_FPS_23_976'; Rate = 23.976 }
    2 = @{ Enum = 'BDA_FPS_24_0';   Rate = 24 }
    3 = @{ Enum = 'BDA_FPS_25_0';   Rate = 25 }
    4 = @{ Enum = 'BDA_FPS_29_97';  Rate = 29.97 }
    5 = @{ Enum = 'BDA_FPS_30_0';   Rate = 30 }
    6 = @{ Enum = 'BDA_FPS_50_0';   Rate = 50 }
    7 = @{ Enum = 'BDA_FPS_59_94';  Rate = 59.94 }
    8 = @{ Enum = 'BDA_FPS_60_0';   Rate = 60 }
}

function Get-EntryValue {
    # An entry inherits anything it does not override, and the FrameRate defect
    # was exactly that: the entry read as 50 because its patch said so, while
    # the stream inherited 25 from Defaults.
    param($Entry, $Defaults, [string] $Key)
    if ($Entry.ContainsKey($Key)) { return $Entry[$Key] }
    if ($Defaults -and $Defaults.ContainsKey($Key)) { return $Defaults[$Key] }
    return $null
}

function New-Finding {
    param([string] $Entry, [string] $Rule, [string] $Detail)
    [pscustomobject]@{ Entry = $Entry; Rule = $Rule; Detail = $Detail }
}

function Test-MatrixEntry {
    param($Entry, $Defaults)

    $findings = @()
    $id = if ($Entry.ContainsKey('Id')) { $Entry.Id } else { '(unnamed)' }

    $patch = $null
    if ($Entry.ContainsKey('Tsduck') -and $Entry.Tsduck -and $Entry.Tsduck.ContainsKey('PatchXml')) {
        $patch = $Entry.Tsduck.PatchXml
    }
    # Nothing declared means nothing here claims to test a descriptor, so there
    # is no fallback collision to have.
    if (-not $patch) { return $findings }

    $hasVideoDesc = $patch -match 'video_stream_descriptor'
    $hasGridDesc  = $patch -match 'target_background_grid_descriptor'

    $video = @{}
    if ($Entry.ContainsKey('Expect') -and $Entry.Expect -and $Entry.Expect.ContainsKey('Video')) {
        $video = $Entry.Expect.Video
    }
    $has = { param($k) $video -and $video.ContainsKey($k) -and $null -ne $video[$k] }

    # MPEG_1_only closes the gate before the chroma read, so a chroma
    # expectation is only meaningful when the gate is open.
    $mpeg1Only = ($patch -match 'MPEG_1_only="true"')

    # ---- rule: injected but unasserted ------------------------------------
    #
    # Checked per descriptor. Requiring Expect.Video on every patched entry
    # would false-positive on the entries that patch stream types and assert
    # through Expect.Streams instead.
    if ($hasVideoDesc -and -not ((& $has 'Fps') -or (& $has 'Chroma'))) {
        $findings += New-Finding $id 'UNASSERTED' (
            "injects a video_stream_descriptor and asserts nothing about it. Expect.Video needs Fps or " +
            "Chroma, or the entry does work and makes no claim, which cannot fail by construction.")
    }
    if ($hasGridDesc -and -not ((& $has 'Width') -or (& $has 'Height'))) {
        $findings += New-Finding $id 'UNASSERTED' (
            "injects a target_background_grid_descriptor and asserts nothing about it. Expect.Video needs " +
            "Width or Height.")
    }

    # ---- rule: unsatisfiable ----------------------------------------------
    if ($mpeg1Only -and (& $has 'Chroma') -and $video['Chroma'] -ne 'BDA_Chroma_NONE') {
        $findings += New-Finding $id 'UNSATISFIABLE' (
            ("declares MPEG_1_only=true but expects Chroma '{0}'. The descriptor is one byte in that form and " +
             "ParsePMT never reaches SetVideoChroma, so no stream can produce this. Expect " +
             "BDA_Chroma_NONE.") -f $video['Chroma'])
    }

    # ---- rule: expectations that cannot fail ------------------------------
    $atFallback = @()
    $proving    = @()
    foreach ($field in 'Fps', 'Chroma', 'Width', 'Height') {
        if (-not (& $has $field)) { continue }
        if ($video[$field] -eq $script:Fallback[$field]) { $atFallback += $field; continue }
        # An unsatisfiable chroma is not evidence of anything, so it must not
        # be allowed to license another field sitting at its fallback.
        if ($field -eq 'Chroma' -and $mpeg1Only) { continue }
        $proving += $field
    }

    if ($atFallback.Count -and -not $proving.Count) {
        $findings += New-Finding $id 'UNFALSIFIABLE' (
            ("every asserted field equals what ParsePMT invents without the descriptor ({0}). A stream " +
             "carrying the descriptor and one missing it both pass, so this entry cannot fail. Give at " +
             "least one field a value no fallback produces.") -f ($atFallback -join ', '))
    } elseif ($atFallback.Count) {
        Write-Verbose ("{0}: {1} at fallback, disambiguated by {2}" -f $id, ($atFallback -join ','), ($proving -join ','))
    }

    # ---- rule: descriptor disagreeing with the stream ---------------------
    if ($patch -match 'frame_rate_code="(\d+)"') {
        $code = [int]$Matches[1]
        $declared = Get-EntryValue -Entry $Entry -Defaults $Defaults -Key 'FrameRate'
        if ($script:FrameRateCode.ContainsKey($code) -and $null -ne $declared) {
            $expected = $script:FrameRateCode[$code].Rate
            if ([math]::Abs([double]$declared - [double]$expected) -gt 0.01) {
                $findings += New-Finding $id 'DISAGREEMENT' (
                    ("descriptor declares frame_rate_code {0} ({1} fps) but the stream is generated at {2} fps. " +
                     "The descriptor would describe a stream that does not exist, and nothing downstream " +
                     "compares the two.") -f $code, $expected, $declared)
            }
        }
    }

    $hs = $null; $vs = $null
    if ($patch -match 'horizontal_size="(\d+)"') { $hs = [int]$Matches[1] }
    if ($patch -match 'vertical_size="(\d+)"')   { $vs = [int]$Matches[1] }

    foreach ($axis in @(
        @{ Name = 'horizontal_size'; Declared = $hs; Key = 'Width' },
        @{ Name = 'vertical_size';   Declared = $vs; Key = 'Height' })) {
        if ($null -eq $axis.Declared) { continue }
        $stream = Get-EntryValue -Entry $Entry -Defaults $Defaults -Key $axis.Key
        if ($null -ne $stream -and [int]$stream -ne $axis.Declared) {
            $findings += New-Finding $id 'DISAGREEMENT' (
                ("target_background_grid_descriptor declares {0} {1} but the stream is generated {2} on that " +
                 "axis.") -f $axis.Name, $axis.Declared, $stream)
        }
    }

    # The back-fill sets 720 and 576 together, so only the pair is ambiguous.
    # 720x480 is genuinely provable and must not be flagged.
    if ($null -ne $hs -and $null -ne $vs -and
        $hs -eq $script:Fallback.Width -and $vs -eq $script:Fallback.Height) {
        $findings += New-Finding $id 'UNFALSIFIABLE' (
            ("declares {0}x{1}, exactly what ParsePMT invents for MPEG-2 when the descriptor is absent. " +
             "Present and absent look identical.") -f $hs, $vs)
    }

    $findings
}

# --------------------------------------------------------------------------

if ($SelfTest) {
    # A lint that passes everything is worth nothing, so prove it catches the
    # defects this repo shipped, plus each gap found in the lint itself.
    #
    # Fixtures carry literal fallback values on purpose. Written as
    # $script:Fallback.Fps they would agree with a corrupted table and go green
    # while the lint quietly stopped catching anything.
    $defaults = @{ Width = 704; Height = 576; FrameRate = 25 }

    $cases = @(
        @{ Name = 'shipped: frame_rate_code 3, the fps fallback'
           Entry = @{ Id = 'x'; FrameRate = 25
                      Tsduck = @{ PatchXml = '<video_stream_descriptor frame_rate_code="3" chroma_format="1"/>' }
                      Expect = @{ Video = @{ Fps = 'BDA_FPS_25_0'; Chroma = 'BDA_Chroma_NONE' } } }
           Expect = @('UNFALSIFIABLE') }

        @{ Name = 'shipped: grid claiming the 720x576 fallback'
           Entry = @{ Id = 'y'; Width = 720; Height = 576
                      Tsduck = @{ PatchXml = '<target_background_grid_descriptor horizontal_size="720" vertical_size="576"/>' }
                      Expect = @{ Video = @{ Width = 720; Height = 576 } } }
           Expect = @('UNFALSIFIABLE') }

        @{ Name = 'near-miss: descriptor 50 fps over a 25 fps stream'
           Entry = @{ Id = 'z'
                      Tsduck = @{ PatchXml = '<video_stream_descriptor frame_rate_code="6" chroma_format="2"/>' }
                      Expect = @{ Video = @{ Fps = 'BDA_FPS_50_0'; Chroma = 'BDA_Chroma_4_2_2' } } }
           Expect = @('DISAGREEMENT') }

        @{ Name = 'gap 1: video descriptor injected, nothing asserted'
           Entry = @{ Id = 'unasserted'; FrameRate = 50
                      Tsduck = @{ PatchXml = '<video_stream_descriptor frame_rate_code="6" chroma_format="2"/>' }
                      Expect = @{ } }
           Expect = @('UNASSERTED') }

        @{ Name = 'gap 1: grid injected, nothing asserted'
           Entry = @{ Id = 'unasserted-grid'; Width = 704; Height = 576
                      Tsduck = @{ PatchXml = '<target_background_grid_descriptor horizontal_size="704" vertical_size="576"/>' }
                      Expect = @{ Video = @{ Fps = 'BDA_FPS_50_0' } } }
           Expect = @('UNASSERTED') }

        @{ Name = 'gap 2: vertical_size 480 over a 576 stream'
           Entry = @{ Id = 'vaxis'; Width = 704; Height = 576
                      Tsduck = @{ PatchXml = '<target_background_grid_descriptor horizontal_size="704" vertical_size="480"/>' }
                      Expect = @{ Video = @{ Width = 704; Height = 480 } } }
           Expect = @('DISAGREEMENT') }

        @{ Name = 'gap 3: MPEG_1_only with a chroma no stream can produce'
           Entry = @{ Id = 'unsat'; FrameRate = 50
                      Tsduck = @{ PatchXml = '<video_stream_descriptor frame_rate_code="6" MPEG_1_only="true"/>' }
                      Expect = @{ Video = @{ Fps = 'BDA_FPS_25_0'; Chroma = 'BDA_Chroma_4_2_2' } } }
           # Both: the chroma is impossible, AND with it discounted as proving,
           # the fps sitting at its fallback is no longer licensed by anything.
           Expect = @('UNFALSIFIABLE', 'UNSATISFIABLE') }

        @{ Name = 'cosmetic: 720x480 grid is provable, must not be flagged'
           Entry = @{ Id = 'grid720x480'; Width = 720; Height = 480
                      Tsduck = @{ PatchXml = '<target_background_grid_descriptor horizontal_size="720" vertical_size="480"/>' }
                      Expect = @{ Video = @{ Width = 720; Height = 480 } } }
           Expect = @() }

        @{ Name = 'legitimate: chroma at fallback, disambiguated by fps'
           Entry = @{ Id = 'ok'; FrameRate = 50
                      Tsduck = @{ PatchXml = '<video_stream_descriptor frame_rate_code="6" MPEG_1_only="true"/>' }
                      Expect = @{ Video = @{ Fps = 'BDA_FPS_50_0'; Chroma = 'BDA_Chroma_NONE' } } }
           Expect = @() }
    )

    $failed = 0
    foreach ($c in $cases) {
        $got = @(Test-MatrixEntry -Entry $c.Entry -Defaults $defaults)
        # Exact set comparison, not a substring match: a case producing both the
        # expected rule and a spurious extra one must fail, or the self-test
        # flatters future changes.
        $gotRules = @($got | ForEach-Object { $_.Rule } | Sort-Object -Unique)
        $wantRules = @($c.Expect | Sort-Object -Unique)
        $ok = ($gotRules.Count -eq $wantRules.Count) -and
              (-not (Compare-Object $gotRules $wantRules -SyncWindow 0))
        if ($ok) { Write-Host ("  PASS  " + $c.Name) -ForegroundColor Green }
        else {
            Write-Host ("  FAIL  {0}" -f $c.Name) -ForegroundColor Red
            Write-Host ("        expected [{0}] got [{1}]" -f ($wantRules -join ','), ($gotRules -join ','))
            $failed++
        }
    }
    if ($failed) { throw "$failed self-test case(s) failed; the lint does not do what it claims" }
    Write-Host 'self-test passed' -ForegroundColor Green
    return
}

$matrix   = Import-PowerShellDataFile $MatrixPath
$defaults = if ($matrix.ContainsKey('Defaults')) { $matrix.Defaults } else { @{} }

$all = @()
foreach ($entry in $matrix.Entries) { $all += Test-MatrixEntry -Entry $entry -Defaults $defaults }

$declaring = @($matrix.Entries | Where-Object { $_.ContainsKey('Tsduck') -and $_.Tsduck -and $_.Tsduck.ContainsKey('PatchXml') })
Write-Host ("Checked {0} entries, {1} declaring a descriptor." -f $matrix.Entries.Count, $declaring.Count)

if (-not $all.Count) {
    Write-Host 'No unfalsifiable expectations.' -ForegroundColor Green
    return
}

foreach ($f in $all) {
    Write-Host ("{0}  {1}" -f $f.Rule, $f.Entry) -ForegroundColor Red
    Write-Host ("    " + $f.Detail)
}
throw ("{0} entr{1} cannot fail as written." -f $all.Count, $(if ($all.Count -eq 1) { 'y' } else { 'ies' }))
