<#
.SYNOPSIS
    Verifies that generated transport streams really contain what
    encoding-matrix.psd1 claims, by reading their tables with TSDuck.

.DESCRIPTION
    The point of this script is to distrust the generator. ffmpeg exits 0 on
    plenty of streams that MPC-HC cannot classify: it signals MPEG-1 video as
    stream_type 0x02, it signals AC-3 the ATSC way unless told otherwise, and
    it signals E-AC-3 as 0x87, a value MPC-HC has no case for at all. None of
    that shows up in an exit code, and none of it shows up in a file that plays
    correctly in VLC. It only shows up in the PMT.

    So every assertion here is made against the tables as parsed out of the
    finished file by TSDuck, never against the command line that produced it.

    Per entry the checks are:

      * the file exists and TSDuck can analyse it
      * the declared service_id is present, and is the only service
      * DVB:  the service is in the SDT with the declared name and service_type
        ATSC: the MGT announces a VCT on PID 0x1FFB and that VCT carries the
              service as an ATSC_DIGITAL_TV channel with the declared name
      * the PMT names a PCR PID, and PCR values are actually present on it
      * every expected elementary stream is matched to a PMT component with
        the same stream_type, carrying every descriptor the matrix requires,
        in the declared language where one is declared
      * no unexpected extra components are present

    The SDT/VCT check is not incidental. CMpeg2DataParser::ParsePAT only calls
    ParsePMT for a program it has already seen in the SDT (or VCT), so a sample
    whose service description is missing or carries an unsupported
    service_type is invisible to MPC-HC no matter how correct its PMT is.

    Stream matching is by stream_type and descriptors rather than by PID or
    ordinal, so the generator stays free to allocate PIDs however it likes.

.PARAMETER StreamDirectory
    Directory holding the generated .ts files named by the matrix.

.PARAMETER MatrixPath
    The matrix data file. Defaults to encoding-matrix.psd1 beside this script.

.PARAMETER TsduckBin
    Directory containing tsanalyze.exe and tstables.exe. Defaults to the
    vendored portable build under third_party/bin.

.PARAMETER EntryId
    Check only these matrix entries, by Id. Wildcards are accepted.

.PARAMETER Detailed
    Print the full PMT composition of every entry, passing or not. Without it
    only failures are explained.

.PARAMETER PassThru
    Emit a result object per entry as well as printing the table, for callers
    that want to do their own reporting.

.EXAMPLE
    .\Test-StreamMatrix.ps1 -StreamDirectory .\samples

.EXAMPLE
    .\Test-StreamMatrix.ps1 -StreamDirectory .\samples -EntryId 'h264-*' -Detailed

.OUTPUTS
    Exit code 0 when every checked entry passes, 1 otherwise. A missing file
    counts as a failure, since the matrix says it should be there.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({
        if (Test-Path -LiteralPath $_ -PathType Container) { $true }
        else { throw "Stream directory not found: $_" }
    })]
    [string]   $StreamDirectory,

    [ValidateScript({
        if (Test-Path -LiteralPath $_ -PathType Leaf) { $true }
        else { throw "Matrix file not found: $_" }
    })]
    [string]   $MatrixPath,

    [string]   $TsduckBin,

    [string[]] $EntryId,

    [switch]   $Detailed,
    [switch]   $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Locating things -------------------------------------------------------

$scriptDir = Split-Path -Parent $PSCommandPath
$repoRoot  = Split-Path -Parent $scriptDir

# Held in its own variable rather than assigned back into $MatrixPath, because
# PowerShell re-runs a parameter's validation attributes on every assignment to
# it: writing the default back would raise the parameter's own "file not found"
# in place of the clearer message below.
$matrixFile = $MatrixPath
if (-not $matrixFile) {
    $matrixFile = Join-Path $scriptDir 'encoding-matrix.psd1'
    if (-not (Test-Path -LiteralPath $matrixFile -PathType Leaf)) {
        throw "No -MatrixPath given and no encoding-matrix.psd1 beside $PSCommandPath"
    }
}

if (-not $TsduckBin) {
    $TsduckBin = Join-Path $repoRoot 'third_party\bin\tsduck\TSDuck\bin'
}

$tsanalyze = Join-Path $TsduckBin 'tsanalyze.exe'
$tstables  = Join-Path $TsduckBin 'tstables.exe'
foreach ($exe in @($tsanalyze, $tstables)) {
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw "TSDuck tool not found: $exe. Pass -TsduckBin, or fetch the portable build into third_party/bin."
    }
}

# Run the falsifiability lint before verifying anything. A matrix entry whose
# expectation equals what ParsePMT invents without the descriptor passes
# whether or not the descriptor is there, so checking a stream against it
# reports a pass that means nothing. This has shipped three times; catching it
# here costs a second and needs no rig.
#
# It gates rather than warns for the same reason the descriptor checks do: a
# test that cannot fail is not a weaker test, it is a misleading one.
#
# $matrixFile, not $MatrixPath: the parameter is empty when the caller relied
# on the default, and the resolved value deliberately lives in its own variable
# (see above). Passing the parameter made this fail for every default caller.
& (Join-Path $PSScriptRoot 'Test-MatrixFalsifiable.ps1') -MatrixPath $matrixFile

# --- Descriptor tags -------------------------------------------------------
#
# The matrix names descriptors by their numeric tag, because that is the
# language ParsePMT speaks (DT_SUBTITLING = 0x59 and so on). TSDuck's XML/JSON
# names them instead, so this is the bridge. Only tags that matter to MPC-HC
# or that routinely appear in these samples need a name here; anything TSDuck
# does not recognise arrives as <generic_descriptor tag="..."> and is read
# straight off the tag attribute.

$descriptorNames = @{
    0x02 = @('video_stream_descriptor')
    0x03 = @('audio_stream_descriptor')
    0x05 = @('registration_descriptor')
    0x06 = @('data_stream_alignment_descriptor')
    0x07 = @('target_background_grid_descriptor')
    0x08 = @('video_window_descriptor')
    0x09 = @('CA_descriptor')
    0x0A = @('ISO_639_language_descriptor')
    0x0E = @('maximum_bitrate_descriptor')
    0x11 = @('STD_descriptor')
    0x28 = @('AVC_video_descriptor')
    0x38 = @('HEVC_video_descriptor')
    0x50 = @('component_descriptor')
    0x52 = @('stream_identifier_descriptor')
    0x56 = @('teletext_descriptor')
    0x59 = @('subtitling_descriptor')
    0x5F = @('private_data_specifier_descriptor')
    0x6A = @('DVB_AC3_descriptor', 'AC3_descriptor')
    0x6B = @('ancillary_data_descriptor')
    0x7A = @('DVB_enhanced_AC3_descriptor', 'enhanced_AC3_descriptor')
    0x7B = @('DVB_DTS_descriptor')
    0x7C = @('AAC_descriptor')
    0x81 = @('ATSC_AC3_audio_stream_descriptor')
}

# Reverse lookup, built once: TSDuck element name -> tag.
$tagByName = @{}
foreach ($tag in $descriptorNames.Keys) {
    foreach ($name in $descriptorNames[$tag]) { $tagByName[$name] = $tag }
}

function Get-DescriptorLabel {
    param([int] $Tag)
    if ($descriptorNames.ContainsKey($Tag)) { return ('0x{0:X2} {1}' -f $Tag, $descriptorNames[$Tag][0]) }
    return ('0x{0:X2}' -f $Tag)
}

# --- JSON helpers ----------------------------------------------------------
#
# TSDuck's XML-to-JSON conversion puts the element name in "#name" and children
# in "#nodes", and omits "#nodes" entirely for a childless element. Under
# Set-StrictMode a bare property access on the missing case is an error, so
# every read goes through here.

function Get-Prop {
    param($Object, [string] $Name, $Default = $null)

    if ($null -eq $Object) { return $Default }

    # Two shapes arrive here and they need different lookups. TSDuck's JSON
    # comes back as PSCustomObject, where keys are PSObject properties; the
    # matrix comes back from Import-PowerShellDataFile as nested Hashtables,
    # whose keys are NOT PSObject properties - a PSObject.Properties lookup on
    # one returns nothing at all and every optional matrix field silently
    # reads as its default.
    if ($Object -is [System.Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) { return $Default }
        $value = $Object[$Name]
        if ($null -eq $value) { return $Default }
        return $value
    }

    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    if ($null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function Get-Nodes {
    param($Object, [string] $Name)

    $nodes = Get-Prop $Object '#nodes'
    if ($null -eq $nodes) { return @() }
    return @($nodes | Where-Object { (Get-Prop $_ '#name') -eq $Name })
}

# --- TSDuck invocation -----------------------------------------------------

function Invoke-TsAnalyze {
    <#
        tsanalyze writes its JSON report to stdout. --json is an exact option
        name here, unlike tstables, where --json is an abbreviation of
        --json-output and would silently overwrite the .ts file passed after
        it. Both tools are always called with fully spelled options below for
        that reason.
    #>
    param([string] $Path)

    $raw = & $tsanalyze --json --no-pager -- $Path 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "tsanalyze failed on $Path (exit $LASTEXITCODE): $($raw -join ' ')"
    }
    return ($raw -join "`n" | ConvertFrom-Json)
}

function Get-Tables {
    <#
        Returns the tables found on one PID as parsed objects. TSDuck can only
        emit table JSON to a named file, never to stdout, so a scratch file is
        unavoidable.
    #>
    # Named PidValue, not Pid: $Pid is a read-only automatic variable holding
    # this process's own id, and binding a parameter over it is a hard error.
    param([string] $Path, [int] $PidValue, [int] $MaxTables = 8)

    $temp = [System.IO.Path]::GetTempFileName()
    try {
        $null = & $tstables --pid $PidValue --max-tables $MaxTables --json-output $temp --no-pager -- $Path 2>&1
        $text = Get-Content -LiteralPath $temp -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($text)) { return @() }

        # TSDuck always writes a JSON array of tables. Assign before wrapping:
        # Windows PowerShell 5.1 emits a top-level JSON array as a single
        # Object[] rather than enumerating it, so @($text | ConvertFrom-Json)
        # yields one element that is itself the array, and every table lookup
        # downstream silently finds nothing. Assigning first, then wrapping,
        # normalises 5.1 and 7 to the same shape.
        $parsed = $text | ConvertFrom-Json
        if ($null -eq $parsed) { return @() }
        return @($parsed)
    } finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

# --- Reading a PMT into something comparable -------------------------------

function Read-PmtComponents {
    param($Pmt)

    $result = [System.Collections.Generic.List[object]]::new()
    foreach ($component in (Get-Nodes $Pmt 'component')) {

        $tags      = [System.Collections.Generic.List[int]]::new()
        $languages = [System.Collections.Generic.List[string]]::new()

        $descriptors = Get-Prop $component '#nodes'
        if ($null -ne $descriptors) {
            foreach ($descriptor in $descriptors) {
                $name = Get-Prop $descriptor '#name'
                if (-not $name) { continue }

                if ($name -eq 'generic_descriptor') {
                    # TSDuck could not identify it; the tag is on the node.
                    $tag = Get-Prop $descriptor 'tag'
                    if ($null -ne $tag) { $tags.Add([int]$tag) }
                    continue
                }
                if ($tagByName.ContainsKey($name)) { $tags.Add($tagByName[$name]) }

                # Language lives in a different place in each of the two
                # descriptors that carry one, so pull both here rather than
                # making the caller know the difference.
                if ($name -eq 'ISO_639_language_descriptor') {
                    foreach ($lang in (Get-Nodes $descriptor 'language')) {
                        $code = Get-Prop $lang 'code'
                        if ($code) { $languages.Add([string]$code) }
                    }
                } elseif ($name -eq 'subtitling_descriptor') {
                    foreach ($sub in (Get-Nodes $descriptor 'subtitling')) {
                        $code = Get-Prop $sub 'language_code'
                        if ($code) { $languages.Add([string]$code) }
                    }
                }
            }
        }

        $result.Add([pscustomobject]@{
            Pid        = [int](Get-Prop $component 'elementary_pid' -1)
            StreamType = [int](Get-Prop $component 'stream_type' -1)
            Tags       = @($tags)
            Languages  = @($languages)
            Matched    = $false
        })
    }
    return $result
}

function Format-Component {
    param($Component)

    $text = '  PID 0x{0:X4}  stream_type 0x{1:X2}' -f $Component.Pid, $Component.StreamType
    if ($Component.Tags.Count)      { $text += '  [' + (($Component.Tags | ForEach-Object { Get-DescriptorLabel $_ }) -join ', ') + ']' }
    if ($Component.Languages.Count) { $text += '  lang=' + ($Component.Languages -join '/') }
    return $text
}

# --- Per-entry checks ------------------------------------------------------

function Test-ServiceSignalling {
    <#
        DVB and ATSC put the service description in completely different
        places, and MPC-HC reads whichever one the tuner's friendly name put
        it into (FGManagerBDA.cpp:370). Returns the list of problems found.
    #>
    param($Entry, [string] $Path)

    $problems = [System.Collections.Generic.List[string]]::new()

    if ($Entry.Standard -eq 'ATSC') {
        $psip = Get-Tables -Path $Path -PidValue 0x1FFB -MaxTables 12

        $mgt = @($psip | Where-Object { (Get-Prop $_ '#name') -eq 'MGT' }) | Select-Object -First 1
        if (-not $mgt) {
            $problems.Add('no MGT on PID 0x1FFB; ParseMGT fails and the VCT is never read')
        } else {
            # ParseMGT only accepts a VCT announced with table_type_PID
            # 0x1FFB, so an MGT that points elsewhere is as good as absent.
            $vctEntries = @(Get-Nodes $mgt 'table' | Where-Object {
                ((Get-Prop $_ 'type' '') -like '*VCT*') -and ([int](Get-Prop $_ 'pid' -1) -eq 0x1FFB)
            })
            if ($vctEntries.Count -eq 0) {
                $problems.Add('MGT announces no TVCT/CVCT on PID 0x1FFB')
            }
        }

        $vct = @($psip | Where-Object { (Get-Prop $_ '#name') -in @('TVCT', 'CVCT') }) | Select-Object -First 1
        if (-not $vct) {
            $problems.Add('no TVCT or CVCT on PID 0x1FFB')
        } else {
            $channel = @(Get-Nodes $vct 'channel' |
                         Where-Object { [int](Get-Prop $_ 'program_number' -1) -eq [int]$Entry.ServiceId }) |
                       Select-Object -First 1
            if (-not $channel) {
                $problems.Add(('VCT has no channel for program_number 0x{0:X4}' -f $Entry.ServiceId))
            } else {
                # ParseVCT keeps only ATSC_DIGITAL_TV; TSDuck renders that as "dtv".
                $serviceType = [string](Get-Prop $channel 'service_type' '')
                if ($serviceType -ne 'dtv') {
                    $problems.Add("VCT service_type is '$serviceType', not 'dtv'; ParseVCT would skip this channel")
                }
                $shortName = [string](Get-Prop $channel 'short_name' '')
                if ($shortName -ne $Entry.ServiceName) {
                    $problems.Add("VCT short_name is '$shortName', expected '$($Entry.ServiceName)'")
                }
            }
        }
    } else {
        $sdt = @(Get-Tables -Path $Path -PidValue 0x0011 -MaxTables 4 |
                 Where-Object { (Get-Prop $_ '#name') -eq 'SDT' }) | Select-Object -First 1
        if (-not $sdt) {
            $problems.Add('no SDT on PID 0x0011; ParsePAT never reaches ParsePMT for this service')
        } else {
            $service = @(Get-Nodes $sdt 'service' |
                         Where-Object { [int](Get-Prop $_ 'service_id' -1) -eq [int]$Entry.ServiceId }) |
                       Select-Object -First 1
            if (-not $service) {
                $problems.Add(('SDT has no service 0x{0:X4}' -f $Entry.ServiceId))
            } else {
                $descriptor = @(Get-Nodes $service 'service_descriptor') | Select-Object -First 1
                if (-not $descriptor) {
                    $problems.Add('SDT service carries no service_descriptor, so it has no name or type')
                } else {
                    $name = [string](Get-Prop $descriptor 'service_name' '')
                    if ($name -ne $Entry.ServiceName) {
                        $problems.Add("SDT service_name is '$name', expected '$($Entry.ServiceName)'")
                    }
                    $type = [int](Get-Prop $descriptor 'service_type' -1)
                    if ($type -ne [int]$Entry.ServiceType) {
                        $problems.Add(('SDT service_type is 0x{0:X2}, expected 0x{1:X2}' -f $type, $Entry.ServiceType))
                    }
                    # ParseSDT drops anything outside this set before ParsePMT
                    # is ever called, so a sample with a plausible-looking but
                    # unlisted type would simply not appear in the scan.
                    $accepted = @(0x01, 0x02, 0x0A, 0x11, 0x16, 0x19, 0x1F)
                    if ($accepted -notcontains $type) {
                        $problems.Add(('SDT service_type 0x{0:X2} is not one MPC-HC accepts in ParseSDT' -f $type))
                    }
                }
            }
        }
    }

    return $problems
}

function Test-MatrixEntry {
    param($Entry, [string] $Directory)

    $problems = [System.Collections.Generic.List[string]]::new()
    $detail   = [System.Collections.Generic.List[string]]::new()
    $path     = Join-Path $Directory $Entry.File

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{
            Id = $Entry.Id; File = $Entry.File; Standard = $Entry.Standard
            Status = 'MISSING'; Problems = @("not found: $path"); Detail = @()
            SizeKB = 0
        }
    }

    $sizeKb = [math]::Round((Get-Item -LiteralPath $path).Length / 1KB)

    $analysis = Invoke-TsAnalyze -Path $path
    $services = @(Get-Prop $analysis 'services')
    $pids     = @(Get-Prop $analysis 'pids')

    $service = @($services | Where-Object { [int](Get-Prop $_ 'id' -1) -eq [int]$Entry.ServiceId }) | Select-Object -First 1
    if (-not $service) {
        $found = ($services | ForEach-Object { '0x{0:X4}' -f [int](Get-Prop $_ 'id' -1) }) -join ', '
        $problems.Add(('no service 0x{0:X4} in the stream (found: {1})' -f $Entry.ServiceId, $found))
        return [pscustomobject]@{
            Id = $Entry.Id; File = $Entry.File; Standard = $Entry.Standard
            Status = 'FAIL'; Problems = @($problems); Detail = @(); SizeKB = $sizeKb
        }
    }

    # One sample, one service. A stray second service means the generator
    # merged two entries, which would make everything below ambiguous.
    if ($services.Count -ne 1) {
        $problems.Add("expected exactly one service, found $($services.Count)")
    }

    foreach ($problem in (Test-ServiceSignalling -Entry $Entry -Path $path)) { $problems.Add($problem) }

    # --- PMT ---------------------------------------------------------------

    $pmtPid = [int](Get-Prop $service 'pmt-pid' -1)
    if ($pmtPid -lt 0) {
        $problems.Add('the service has no PMT PID in the PAT')
        return [pscustomobject]@{
            Id = $Entry.Id; File = $Entry.File; Standard = $Entry.Standard
            Status = 'FAIL'; Problems = @($problems); Detail = @(); SizeKB = $sizeKb
        }
    }

    $pmt = @(Get-Tables -Path $path -PidValue $pmtPid -MaxTables 4 |
             Where-Object {
                 ((Get-Prop $_ '#name') -eq 'PMT') -and
                 ([int](Get-Prop $_ 'service_id' -1) -eq [int]$Entry.ServiceId)
             }) | Select-Object -First 1
    if (-not $pmt) {
        $problems.Add(('no PMT for service 0x{0:X4} on PID 0x{1:X4}' -f $Entry.ServiceId, $pmtPid))
        return [pscustomobject]@{
            Id = $Entry.Id; File = $Entry.File; Standard = $Entry.Standard
            Status = 'FAIL'; Problems = @($problems); Detail = @(); SizeKB = $sizeKb
        }
    }

    # --- PCR ---------------------------------------------------------------
    #
    # A PMT can name a PCR PID that carries no PCR at all. The driver restamps
    # from PCR to pace playback, so an empty PCR PID stalls the graph rather
    # than producing a visible error, which makes this worth checking
    # separately from the PMT field.

    $pcrPid = [int](Get-Prop $pmt 'pcr_pid' 0x1FFF)
    if ((Get-Prop $Entry.Expect 'PcrRequired' $true)) {
        if ($pcrPid -eq 0x1FFF) {
            $problems.Add('PMT declares no PCR PID (0x1FFF)')
        } else {
            $pcrEntry = @($pids | Where-Object { [int](Get-Prop $_ 'id' -1) -eq $pcrPid }) | Select-Object -First 1
            $pcrCount = 0
            if ($pcrEntry) { $pcrCount = [int](Get-Prop (Get-Prop $pcrEntry 'packets') 'pcr' 0) }
            if ($pcrCount -lt 2) {
                $problems.Add(('PCR PID 0x{0:X4} carries {1} PCR value(s); playback pacing needs a running clock' -f $pcrPid, $pcrCount))
            } else {
                $detail.Add(('  PCR on PID 0x{0:X4}, {1} values' -f $pcrPid, $pcrCount))
            }
        }
    }

    # --- Elementary streams ------------------------------------------------

    $components = Read-PmtComponents -Pmt $pmt
    foreach ($component in $components) { $detail.Add((Format-Component $component)) }

    foreach ($expected in @($Entry.Expect.Streams)) {

        $wantTags = @(Get-Prop $expected 'Descriptors' @())
        $wantLang = [string](Get-Prop $expected 'Language' '')

        $match = $null
        foreach ($component in $components) {
            if ($component.Matched) { continue }
            if ($component.StreamType -ne [int]$expected.StreamType) { continue }

            $missingTags = @($wantTags | Where-Object { $component.Tags -notcontains [int]$_ })
            if ($missingTags.Count) { continue }

            if ($wantLang -and ($component.Languages -notcontains $wantLang)) { continue }

            $match = $component
            break
        }

        if ($match) {
            $match.Matched = $true
        } else {
            $description = 'stream_type 0x{0:X2}' -f [int]$expected.StreamType
            if ($wantTags.Count) { $description += ' with ' + (($wantTags | ForEach-Object { Get-DescriptorLabel ([int]$_) }) -join ' + ') }
            if ($wantLang)       { $description += " in '$wantLang'" }
            $problems.Add("no $($expected.Role) component matched: expected $description (MPC-HC would report $($expected.Bda))")
        }
    }

    foreach ($component in $components) {
        if (-not $component.Matched) {
            $problems.Add(('unexpected component: PID 0x{0:X4} stream_type 0x{1:X2}' -f $component.Pid, $component.StreamType))
        }
    }

    $status = 'PASS'
    if ($problems.Count) { $status = 'FAIL' }

    return [pscustomobject]@{
        Id       = $Entry.Id
        File     = $Entry.File
        Standard = $Entry.Standard
        Status   = $status
        Problems = @($problems)
        Detail   = @($detail)
        SizeKB   = $sizeKb
    }
}

# --- Run -------------------------------------------------------------------

function Import-MatrixData {
    <#
        Import-PowerShellDataFile arrived in PowerShell 6, and a good deal of
        this rig runs in a Windows 10 guest whose only shell is Windows
        PowerShell 5.1. Parsing the file and evaluating just its literal
        hashtable is what that cmdlet does internally, and it keeps the data
        file data: SafeGetValue refuses anything that is not a literal, so a
        matrix cannot smuggle in code the way Invoke-Expression would let it.
    #>
    param([string] $Path)

    if (Get-Command Import-PowerShellDataFile -ErrorAction SilentlyContinue) {
        return Import-PowerShellDataFile -LiteralPath $Path
    }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and @($errors).Count -gt 0) {
        throw "$Path does not parse: $(@($errors)[0].Message)"
    }

    $hashtable = $ast.Find({
        param($node) $node -is [System.Management.Automation.Language.HashtableAst]
    }, $false)
    if (-not $hashtable) {
        throw "$Path contains no hashtable; is it a PowerShell data file?"
    }
    return $hashtable.SafeGetValue()
}

$matrix = Import-MatrixData -Path $matrixFile
if (-not $matrix.ContainsKey('Entries')) {
    throw "$matrixFile has no Entries key; is it an encoding matrix?"
}

$entries = @($matrix.Entries)
if ($EntryId) {
    $entries = @($entries | Where-Object {
        $entry = $_
        @($EntryId | Where-Object { $entry.Id -like $_ }).Count -gt 0
    })
    if ($entries.Count -eq 0) {
        throw "No matrix entry matched -EntryId $($EntryId -join ', ')"
    }
}

Write-Host ''
Write-Host "Matrix   $matrixFile"
Write-Host "Streams  $StreamDirectory"
Write-Host "TSDuck   $TsduckBin"
Write-Host ''

$results = [System.Collections.Generic.List[object]]::new()
foreach ($entry in $entries) {
    Write-Verbose "Checking $($entry.Id)"
    $results.Add((Test-MatrixEntry -Entry $entry -Directory $StreamDirectory))
}

$results |
    Select-Object @{ N = 'Entry'; E = { $_.Id } },
                  @{ N = 'Std';   E = { $_.Standard } },
                  @{ N = 'KB';    E = { $_.SizeKB } },
                  @{ N = 'Result'; E = { $_.Status } },
                  @{ N = 'Notes'; E = { if ($_.Problems.Count) { "$($_.Problems.Count) problem(s)" } else { '' } } } |
    Format-Table -AutoSize |
    Out-String |
    Write-Host

foreach ($result in $results) {
    $wantDetail = $Detailed -or ($result.Status -ne 'PASS')
    if (-not $wantDetail) { continue }

    Write-Host "$($result.Id) [$($result.Status)]  $($result.File)"
    foreach ($line in $result.Detail)   { Write-Host $line }
    foreach ($problem in $result.Problems) { Write-Host "  ! $problem" }
    Write-Host ''
}

$failed = @($results | Where-Object { $_.Status -ne 'PASS' })

Write-Host ("{0} of {1} entries passed." -f ($results.Count - $failed.Count), $results.Count)

if ($PassThru) { $results }

if ($failed.Count) { exit 1 }
exit 0
