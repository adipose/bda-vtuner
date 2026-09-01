# DVB-C and DVB-S variants

All four broadcast standards run side by side as instances of the one
driver; a healthy install shows all four devices at `CM_PROB_NONE` and MPC-HC
scans each standard and finds every provisioned service.

| Standard | Target | Hardware ID | DeviceInstanceID | Device |
|---|---|---|---|---|
| DVB-T | `SWTDVBT` | `ms_swtdvbt` | `ROOT_MEDIA_0000` | `ROOT\MEDIA\0000` |
| ATSC | `SWTATSC` | `ms_swtatsc` | `ROOT_MEDIA_0001` | `ROOT\MEDIA\0001` |
| DVB-C | `SWTDVBC` | `ms_swtdvbc` | `ROOT_MEDIA_0002` | `ROOT\MEDIA\0002` |
| DVB-S | `SWTDVBS` | `ms_swtdvbs` | `ROOT_MEDIA_0003` | `ROOT\MEDIA\0003` |

```
BDA DVBT Sample Tuner Device    OK    CM_PROB_NONE
BDA ATSC Sample Tuner Device    OK    CM_PROB_NONE
BDA DVBC Sample Tuner Device    OK    CM_PROB_NONE
BDA DVBS Sample Tuner Device    OK    CM_PROB_NONE
```

## Content

`New-TestStreams.ps1 -Standard DVBC` and `-Standard DVBS` with `-Duration 20`,
copied to `C:\ts` in the guest. Three muxes carrying five services per
standard, about 6 MB each.

| Standard | Muxes (kHz) | Services |
|---|---|---|
| DVB-C | 306000, 314000, 322000 | Test Channel 1–5 |
| DVB-S | 10714000, 10744000, 10774000 | Test Channel 1–5 |

`-Duration 20` rather than the default 10 is not cosmetic. See
**Minimum stream size** below.

## Expected scan results

The MPC-HC test framework's dvb suite reads MPC-HC's channel list rather than the screen;
records are `CBDAChannel::ToString()`. The fields shown are name, frequency,
bandwidth and symbol rate; a correct setup reproduces these exactly.

DVB-C, sweep 306000–322000 kHz, bandwidth 8000, symbol rate 6875, 46 s:

```
Test Channel 1|306000|8000|6875   Test Channel 2|306000|8000|6875
Test Channel 3|314000|8000|6875   Test Channel 4|314000|8000|6875
Test Channel 5|322000|8000|6875
```

DVB-S, sweep 10714000–10774000 kHz, bandwidth 30000, symbol rate 27500:

```
Test Channel 1|10714000|30000|27500   Test Channel 2|10714000|30000|27500
Test Channel 3|10744000|30000|27500   Test Channel 4|10744000|30000|27500
Test Channel 5|10774000|30000|27500
```

Every service lands at the frequency it was provisioned to, with full PID sets,
and MPC-HC's title bar reads `Live | DVB` after Open Device.
Screenshots regenerate with any scan run (the harness writes `<label>-scan.png` per run).

The `N` column reads 0 throughout. That is the content, not a defect: the
generated muxes carry no LCN descriptor, so there is no origin number to show.
The DVB-T captures do carry LCNs and MPC-HC displays them.

## What DVB-C and DVB-S need that DVB-T does not

### Symbol rate: nothing, and that is the point

MPC-HC sends a symbol rate only when it is non-zero
(`FGManagerBDA.cpp:712`), so DVB-T scans never exercise
`IBDA_DigitalDemodulator::put_SymbolRate` and DVB-C/DVB-S ones do.

The driver takes it and throws it away. `objdesc.cpp` puts
`DEFINE_KSPROPERTY_ITEM_BDA_SYMBOL_RATE` in `SampleDigitalDemodProperties`
unconditionally — not inside any `#if <STANDARD>_RECEIVER` — and the handler at
`ccapturepin.cpp:1246` is a `DbgPrint` and a `break`. A non-zero symbol rate is
therefore accepted, logged and ignored, `CheckChanges`/`CommitChanges` succeed,
and the tune proceeds on frequency alone. The
6875/27500 values survive into MPC-HC's saved channel records, so the
round trip is observable.

The units are BDA's: kilosymbols per second. MPC-HC passes the scan dialog's
field straight through with no scaling (`TunerScanDlg.cpp:178` →
`MainFrm.cpp:17006`), so 6875 and 27500 are what to type, matching the
`SymbolRate` column of the band plans in `Provision-VTuner.ps1`.

### The scan step is the bandwidth field

`MainFrm.cpp:17003` is `for (ulFrequency = start; ulFrequency <= stop;
ulFrequency += pTSD->Bandwidth)`. There is no channel plan behind it, so the
bandwidth box doubles as the raster. DVB-C is a genuine 8 MHz raster and
behaves like DVB-T; DVB-S has no raster at all, and the transponders here sit
30 MHz apart, so a DVB-S scan needs `Bandwidth = 30000`. That is a scan
parameter, not a signal property — the driver never looks at it.

### DVB-S frequencies switch off two driver fallbacks

Both are in `device.cpp` and both are invisible until a satellite frequency is
used.

**The Hz-compatibility retry is disabled.** `GetSignalQualityFromFrequency`
and friends retry the lookup with `dwFreq * 1000` only `if (dwFreq < 1000000)`
(`device.cpp:667`, `:695`, `:724`, `:762`). Every DVB-S frequency in kHz is
above that, so a DVB-S stream map has to be in exact kHz — there is no second
chance. DVB-T, ATSC and DVB-C all sit below the threshold and keep the retry.

**The satellite tolerance probe never fires.** `fUseSatellite` is set only when
`dwFreq > 2000000000` (`device.cpp:524`), which is what a caller encoding
polarisation and DiSEqC as two extra trailing digits would produce. MPC-HC
sends a plain kHz frequency, so the ±probe at `:581`/`:600` is dead code for
this rig — and in any case it probes ±100000, not ±1000. The README's
"probes ±1 MHz around the request" is true only of the two-extra-digit
satellite key format; as MPC-HC drives it the lookup is exact-match for every
standard. A scan must land exactly on a provisioned frequency.

## Minimum stream size: about 1.2 MB per file

Not DVB-C/DVB-S specific; any sufficiently small stream trips it.

A single-service mux at the default 10-second duration comes out at about
749 KB, roughly half the size of a two-service mux. Tuned to,
**the driver does not switch to it**: it goes on serving whatever file it had
open, and MPC-HC labels that stale content with the frequency it asked for.

The symptom is nasty because it looks like success. The device reports OK, the
frequency reports locked, the scan completes without error and returns
channels — just the wrong ones.

Evidence, reproducible in both directions:

| Test | Result |
|---|---|
| Sweep 306000–322000 | 322000 returned `mux2`'s services (the file open at the previous step) |
| Sweep 10714000–10774000 | 10774000 returned `mux2`'s services, identically |
| Single scan at 322000 | returned `mux1`'s services — the `DefaultStreamLocation`, i.e. what was open before the tune |
| Single scan at 314000 | correct, so the switching machinery works |
| `mux3`'s file mapped onto 314000, single scan | **failed there too** — it is the file, not the frequency |
| `mux3` regenerated at 20 s (1,254,524 bytes), single scan at 322000 | correct: `Test Channel 5` with full PIDs |

The number that explains it is in `bdatuner.h`:

```
PS_PACKET_SIZE 188 * PS_PACKETS_PER_SAMPLE 312 * 10 = VIDEO_READ_BUFFER_SIZE
                                                    = 586,560 bytes
```

`fileread.cpp` double-buffers that, so a file under about 1,173,120 bytes is
smaller than the read machinery's working set: the short-read/rewind path at
`fileread.cpp:943` runs on essentially every cycle and the global
`g_FileChangeIndex` it drives never behaves. The exact defect is not pinned
down — that wants a kernel debugger and the driver's `DbgPrint` trace — but
the threshold reproduces cleanly in both directions.

**Practical rule: keep every provisioned `.ts` above ~1.2 MB.** For generated
content that means `-Duration 20` or more for any mux with a single service.
Real captures are far above it, which is why DVB-T and ATSC never showed this.

## Provisioning quirk worth knowing

`Provision-VTuner.ps1` reports every generated mux as `ASSIGNED` rather than
reading the frequency out of its filename. `Get-FrequencyFromName` cannot match
`dvbc-mux1-306000`: its six-digit rule needs a delimiter *after* the digits and
its three-digit rule needs an exactly-three-digit group, and the name ends in
`306000`. So the frequency falls through to sequential assignment from the band
plan.

The result is correct — the generator's frequencies are `plan.First`,
`First + 1`, `First + 2` for every standard, which is exactly what sequential
assignment produces, and the files sort `mux1`, `mux2`, `mux3`. But it is a
coincidence of two tables agreeing, not a lookup, and it would drift silently
if either changed. Check the emitted `.reg` rather than trusting the column.

## Known quirks

**`Build-And-Deploy.ps1` may abort after a fully successful Install
phase**, printing only
`The operation completed successfully.` — the text of Win32 `ERROR_SUCCESS` —
on the error stream, with exit code 1, even though `devcon` created the
node, the `DeviceInstanceID` was written and the stream map was imported. If
it happens, re-run `-Phase Verify` and check the device before assuming the
install failed; do not re-run `-Phase Install`, which would create a second
device node.

**`Invoke-MpcScan.ps1` can sit in its wait loop after the guest has
already written the result.** A scan itself takes about 75 seconds.
When in doubt, read `C:\vtuner\out\<label>.json` out of the guest directly
rather than assuming the scan is still going.

## Reproducing

```powershell
.\tools\New-TestStreams.ps1 -OutDir C:\ts-gen -Standard DVBC -Duration 20
.\tools\New-TestStreams.ps1 -OutDir C:\ts-gen -Standard DVBS -Duration 20
# copy C:\ts-gen\*.ts into the guest at C:\ts

.\tools\Build-And-Deploy.ps1 -VMName <your-guest> -Standard DVBC `
    -Phase Source,Build,Sign,Install,Verify -DeviceInstanceId ROOT_MEDIA_0002 `
    -StreamMap .\build\vtuner-dvbc.reg

.\tools\Provision-VTuner.ps1 -TsLibrary C:\ts-gen -Standard DVBC -GuestPath C:\ts `
    -DeviceInstanceId ROOT_MEDIA_0002 -DefaultStream C:\ts\dvbc-mux1-306000.ts `
    -OutDir .\build
```

and the same with `DVBS` / `ROOT_MEDIA_0003` /
`C:\ts\dvbs-mux1-10714000.ts`. If test signing is not yet enabled in
the guest, the deploy enables it and a reboot is required: reboot with
`Invoke-Command ... { Restart-Computer -Force }` rather than `Restart-VM
-Force`, which discards the just-written BCD setting.
