<#
.SYNOPSIS
    Maps a library of MPEG-2 transport stream files onto a virtual BDA tuner's
    frequency plan, and emits (or applies) the HKLM\SYSTEM\PSWTuner registry
    tree that the swtuner driver reads.

.DESCRIPTION
    The swtuner BDA minidriver selects which .ts file to stream by looking up
    the tuned frequency as a decimal subkey under

        HKLM\SYSTEM\PSWTuner\<DeviceInstanceID>\Device Parameters\<frequency>

    Each frequency subkey carries the stream path plus the signal statistics the
    driver reports through IBDA_SignalStatistics. Those statistics are plain
    registry data, which makes bad-signal and no-lock conditions ordinary
    configuration rather than something you have to provoke with real RF.

    Frequencies are emitted in kHz. MPC-HC calls
    IBDA_FrequencyFilter::put_FrequencyMultiplier(1000) before put_Frequency(),
    so the values it sends are kHz and line up with these keys directly
    (see FGManagerBDA.cpp, SetFrequency).

    Capture filenames usually record the frequency the capture was made at, so
    by default each stream is placed at its original frequency rather than
    being assigned one arbitrarily. That matters: a channel scan then finds each
    multiplex where a real receiver in that country would find it, and the
    frequencies in MPC-HC's channel list match the ones written on the files.
    Streams whose name carries no frequency fall back to sequential assignment
    from the relevant band plan.

.PARAMETER TsLibrary
    Directory containing the transport streams. Searched recursively.

.PARAMETER Standard
    Restrict output to one standard. By default every standard detected in the
    library is emitted, one .reg file per standard, since a given tuner device
    only handles one of them.

.PARAMETER DeviceInstanceId
    Value written to the driver's DeviceInstanceID and used as the PSWTuner
    subtree name. Must match the DeviceInstanceID string set on the installed
    device under HKLM\SYSTEM\CurrentControlSet\Control\Class\{4D36E96C-...}.

.PARAMETER GuestPath
    Rewrite stream paths to this directory. Use when the .reg will be imported
    on a different machine from the one holding the library, since the driver
    resolves these paths in its own filesystem.

.PARAMETER DefaultStream
    Stream served for any frequency with no explicit mapping.

.PARAMETER DeadFrequency
    Frequencies (kHz) to provision as tuned-but-never-locked. The key exists and
    SignalPresent is set, but SignalLocked is 0, which drives MPC-HC's lock-wait
    timeout rather than its happy path.

.PARAMETER WeakFrequency
    Frequencies (kHz) to provision as locked but poor quality.

.PARAMETER OutDir
    Directory for the generated .reg files. Defaults to the current directory.

.PARAMETER Apply
    Additionally write the keys into the local registry. Requires elevation.

.EXAMPLE
    .\Provision-VTuner.ps1 -TsLibrary C:\captures\ts

.EXAMPLE
    .\Provision-VTuner.ps1 -TsLibrary C:\captures\ts -Standard DVBT -GuestPath C:\ts -DeadFrequency 490000
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Container })]
    [string]   $TsLibrary,

    [ValidateSet('DVBT', 'ATSC', 'DVBC', 'DVBS')]
    [string]   $Standard,

    [string]   $DeviceInstanceId = 'ROOT_MEDIA_0000',
    [string]   $GuestPath,
    [string]   $DefaultStream,
    [int[]]    $DeadFrequency = @(),
    [int[]]    $WeakFrequency = @(),
    [string]   $OutDir,
    [switch]   $Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Band plans ------------------------------------------------------------
#
# Centre frequencies in kHz, used both to convert a channel number found in a
# filename and to assign a frequency to streams whose name carries none.

$plans = @{
    DVBT = [pscustomobject]@{
        First = 21; Last = 69; BandwidthHz = 8000000; SymbolRate = 0
        Freq  = { param($ch) 474000 + ($ch - 21) * 8000 }
        Chan  = { param($khz) 21 + [math]::Round(($khz - 474000) / 8000) }
    }
    ATSC = [pscustomobject]@{
        First = 14; Last = 69; BandwidthHz = 6000000; SymbolRate = 0
        Freq  = { param($ch) 473000 + ($ch - 14) * 6000 }
        Chan  = { param($khz) 14 + [math]::Round(($khz - 473000) / 6000) }
    }
    DVBC = [pscustomobject]@{
        First = 5; Last = 60; BandwidthHz = 8000000; SymbolRate = 6875
        Freq  = { param($ch) 306000 + ($ch - 5) * 8000 }
        Chan  = { param($khz) 5 + [math]::Round(($khz - 306000) / 8000) }
    }
    DVBS = [pscustomobject]@{
        First = 1; Last = 40; BandwidthHz = 27500000; SymbolRate = 27500
        Freq  = { param($ch) 10714000 + ($ch - 1) * 30000 }
        Chan  = { param($khz) 1 + [math]::Round(($khz - 10714000) / 30000) }
    }
}

# --- Inference -------------------------------------------------------------

function Get-StandardFromName {
    <#
        Ordered most specific first. Satellite and ATSC markers are
        unambiguous; terrestrial is the fallback because it is both the most
        common case and the one whose names vary most by country.
    #>
    param([string] $Name)

    switch -Regex ($Name) {
        'astra|hotbird|eutelsat|dvb-?s|\bsat\b|19\.?2e'  { return 'DVBS' }
        'atsc|\bvsb\b'                                    { return 'ATSC' }
        'dvb-?c|\bqam\b|cable'                            { return 'DVBC' }
        'dvb-?t|tnt|digitenne|freeview|mux|t2mi|\bt2\b'   { return 'DVBT' }
    }

    # A bare three-digit name is a frequency in MHz. Whether that is ATSC or
    # DVB-T depends on the raster: ATSC channels sit on a 6 MHz grid offset
    # from 473, DVB-T on an 8 MHz grid offset from 474.
    if ($Name -match '^(\d{3})$') {
        $mhz = [int]$Matches[1]
        if ((($mhz - 473) % 6) -eq 0) { return 'ATSC' }
        if ((($mhz - 474) % 8) -eq 0) { return 'DVBT' }
    }
    return $null
}

function Get-FrequencyFromName {
    <#
        Returns kHz, or $null. Patterns are ordered so that an explicit
        frequency always beats a channel number, and an explicit unit always
        beats a bare number.
    #>
    param([string] $Name, [string] $Standard)

    # Explicit MHz: "tnt-uhf22-482MHz-2019-01-22"
    if ($Name -match '(\d{3,4})\s*MHz') { return [int]$Matches[1] * 1000 }

    # Explicit kHz as a six-digit group: "DVB-T_666000_H_0-41"
    if ($Name -match '[_\-](\d{6})[_\-]')  { return [int]$Matches[1] }

    # Channel number: "tnt-uhf22-..."
    if ($Name -match '(?:uhf|vhf|ch|channel)[_\-]?(\d{1,2})\b') {
        $ch = [int]$Matches[1]
        if ($Standard -and $plans.ContainsKey($Standard)) {
            return & $plans[$Standard].Freq $ch
        }
    }

    # Frequency in MHz with no unit: "atsc-605", "digitenne-682-2020-06-21",
    # "473". Bounded to plausible broadcast frequencies so that a date or a
    # resolution ("ts1080") is not mistaken for one.
    if ($Name -match '(?:^|[_\-])(\d{3})(?:$|[_\-])') {
        $mhz = [int]$Matches[1]
        if ($mhz -ge 100 -and $mhz -le 900) { return $mhz * 1000 }
    }

    return $null
}

# --- Collect ---------------------------------------------------------------

$files = @(Get-ChildItem -Path $TsLibrary -Recurse -File -Include *.ts, *.trp, *.mpg |
           Sort-Object Name)
if ($files.Count -eq 0) {
    throw "No transport stream files (*.ts, *.trp, *.mpg) found under $TsLibrary"
}

$entries = [System.Collections.Generic.List[object]]::new()
foreach ($f in $files) {
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
    $std  = Get-StandardFromName -Name $stem
    if (-not $std) { $std = 'DVBT' }          # most likely, and flagged below
    $khz  = Get-FrequencyFromName -Name $stem -Standard $std

    $entries.Add([pscustomobject]@{
        File      = $f
        Name      = $stem
        Standard  = $std
        Frequency = $khz
        Inferred  = [bool]$khz
        SizeMB    = [math]::Round($f.Length / 1MB, 1)
    })
}

# Assign frequencies to anything the filename did not carry one for, taking the
# next free slot in that standard's plan.
foreach ($group in $entries | Group-Object Standard) {
    $plan  = $plans[$group.Name]
    $taken = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($e in ($group.Group | Where-Object Frequency)) { [void]$taken.Add([int]$e.Frequency) }
    $ch = $plan.First
    foreach ($e in $group.Group | Where-Object { -not $_.Frequency }) {
        while ($true) {
            $cand = & $plan.Freq $ch
            $ch++
            if (-not $taken.Contains($cand)) { $taken.Add($cand) | Out-Null; break }
            if ($ch -gt $plan.Last) { throw "Ran out of channels in the $($group.Name) plan." }
        }
        $e.Frequency = $cand
    }
}

if ($Standard) {
    $entries = @($entries | Where-Object Standard -eq $Standard)
    if ($entries.Count -eq 0) { throw "No streams in the library were identified as $Standard." }
}

# --- Emit ------------------------------------------------------------------

if (-not $OutDir) { $OutDir = (Get-Location).Path }
New-Item -ItemType Directory -Force $OutDir | Out-Null

function ConvertTo-NativePath {
    <# The driver opens streams through the native object namespace. #>
    param([string] $Path)
    '\??\' + $Path
}

$written = [System.Collections.Generic.List[string]]::new()

foreach ($group in $entries | Group-Object Standard) {
    $std  = $group.Name
    $plan = $plans[$std]
    $base = "HKEY_LOCAL_MACHINE\SYSTEM\PSWTuner\$DeviceInstanceId\Device Parameters"

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('Windows Registry Editor Version 5.00')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("; Virtual BDA tuner stream map - $std")
    [void]$sb.AppendLine("; Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') from $TsLibrary")
    [void]$sb.AppendLine('; Frequencies in kHz, matching IBDA_FrequencyFilter with multiplier 1000.')
    [void]$sb.AppendLine("; Bandwidth $([int]($plan.BandwidthHz/1000000)) MHz$(if ($plan.SymbolRate) { ", symbol rate $($plan.SymbolRate) ksym/s" })")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("[$base]")
    if ($DefaultStream) {
        [void]$sb.AppendLine("`"DefaultStreamLocation`"=`"$((ConvertTo-NativePath $DefaultStream) -replace '\\','\\')`"")
    }
    [void]$sb.AppendLine()

    foreach ($e in $group.Group | Sort-Object Frequency) {
        $path = if ($GuestPath) { Join-Path $GuestPath $e.File.Name } else { $e.File.FullName }

        $locked = 1; $present = 1; $quality = 100; $strength = 63
        if ($DeadFrequency -contains $e.Frequency) {
            $locked = 0; $quality = 0; $strength = 20
        } elseif ($WeakFrequency -contains $e.Frequency) {
            $quality = 24; $strength = 31
        }

        $ch = [int](& $plan.Chan $e.Frequency)
        [void]$sb.AppendLine("; ch $ch  $($e.Frequency) kHz  $($e.SizeMB) MB  $($e.Name)$(if (-not $e.Inferred) { '  [frequency assigned, not from filename]' })")
        [void]$sb.AppendLine("[$base\$($e.Frequency)]")
        [void]$sb.AppendLine("`"StreamLocation`"=`"$((ConvertTo-NativePath $path) -replace '\\','\\')`"")
        [void]$sb.AppendLine("`"FriendlyName`"=`"$($e.Name)`"")
        [void]$sb.AppendLine("`"SignalLocked`"=dword:$('{0:x8}' -f $locked)")
        [void]$sb.AppendLine("`"SignalPresent`"=dword:$('{0:x8}' -f $present)")
        [void]$sb.AppendLine("`"SignalQuality`"=dword:$('{0:x8}' -f $quality)")
        [void]$sb.AppendLine("`"SignalStrength`"=dword:$('{0:x8}' -f $strength)")
        [void]$sb.AppendLine()

        $e | Add-Member -NotePropertyName Channel  -NotePropertyValue $ch     -Force
        $e | Add-Member -NotePropertyName Locked   -NotePropertyValue $locked -Force
        $e | Add-Member -NotePropertyName Quality  -NotePropertyValue $quality -Force
    }

    $out = Join-Path $OutDir "vtuner-$($std.ToLower()).reg"
    Set-Content -Path $out -Value $sb.ToString() -Encoding Unicode
    $written.Add($out)
    Write-Host "Wrote $out  ($($group.Count) streams)" -ForegroundColor Green
}

# --- Apply -----------------------------------------------------------------

if ($Apply) {
    $isAdmin = ([Security.Principal.WindowsPrincipal] `
                [Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "-Apply writes to HKLM and requires elevation. The .reg files were still written; import one with: reg import <file>"
    }
    if (($entries | Group-Object Standard).Count -gt 1) {
        throw "Refusing to apply: the library spans several standards and one device serves only one. Re-run with -Standard, or import the .reg you want."
    }
    $psBase = "HKLM:\SYSTEM\PSWTuner\$DeviceInstanceId\Device Parameters"
    New-Item -Path $psBase -Force | Out-Null
    foreach ($e in $entries) {
        $path = if ($GuestPath) { Join-Path $GuestPath $e.File.Name } else { $e.File.FullName }
        $k = Join-Path $psBase $e.Frequency
        New-Item -Path $k -Force | Out-Null
        Set-ItemProperty -Path $k -Name 'StreamLocation' -Value (ConvertTo-NativePath $path) -Type String
        Set-ItemProperty -Path $k -Name 'FriendlyName'   -Value $e.Name    -Type String
        Set-ItemProperty -Path $k -Name 'SignalLocked'   -Value $e.Locked  -Type DWord
        Set-ItemProperty -Path $k -Name 'SignalPresent'  -Value 1          -Type DWord
        Set-ItemProperty -Path $k -Name 'SignalQuality'  -Value $e.Quality -Type DWord
        Set-ItemProperty -Path $k -Name 'SignalStrength' -Value 63         -Type DWord
    }
    Write-Host "Applied $($entries.Count) channels to $psBase" -ForegroundColor Green
}

# --- Report ----------------------------------------------------------------

Write-Host ''
# Out-String with an explicit width, because Format-Table sizes to the host
# window and will otherwise crush the stream name down to a single character.
$entries | Sort-Object Standard, Frequency |
    Format-Table @{L='Std';E={$_.Standard};Width=5},
                 @{L='Ch';E={$_.Channel};Width=3},
                 @{L='kHz';E={$_.Frequency};Width=9},
                 @{L='From name';E={if ($_.Inferred) {'yes'} else {'ASSIGNED'}};Width=9},
                 @{L='MB';E={$_.SizeMB};Width=7},
                 @{L='Lock';E={if ($_.Locked) {'yes'} else {'NO'}};Width=4},
                 @{L='Stream';E={$_.Name}} |
    Out-String -Width 200 | Write-Host

if ($GuestPath) {
    Write-Host "Stream paths were rewritten to $GuestPath - the files must exist there on the machine that imports this." -ForegroundColor Yellow
}
