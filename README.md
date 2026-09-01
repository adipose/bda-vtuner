# bda-vtuner — an emulated DVB/ATSC tuner for Windows

A virtual BDA (Broadcast Driver Architecture -- Windows' digital TV driver
model) tuner that presents itself to the OS as a real digital
TV receiver and serves transport streams from disk. Any BDA application
enumerates, tunes, scans, locks and reads signal statistics exactly as it
would against hardware — no application changes, no RF, no capture card.

The repository has two layers:

- **A general-purpose emulated tuner** — the driver (all four broadcast
  standards side by side), provisioning, deployment, and tooling that
  generates and verifies transport streams with known values, down to
  hand-built EN 300 743 subtitles.
- **One specific application of it: a test harness for MPC-HC's Digital TV
  support**, which drives scans, asserts MPC-HC's decoded channel records and
  JSON against the generated streams' declarations, and probes rendered
  pixels, with no broadcast or modulator hardware involved.

The harness is deliberately a consumer of the generic layer, not entangled
with it: another BDA application could be tested by adding a sibling harness
against the same driver, streams and transport seam.

## Getting started

The path from clone to a scanning tuner, in order. Prerequisites: a Windows
host with PowerShell 7+, a disposable Windows 10 x64 guest/target machine
(a VM with a checkpoint is ideal) and an MPC-HC build
(https://github.com/clsid2/mpc-hc).

1. **Fetch and configure everything host-side:**
   `.\tools\Install-TestBed.ps1`. Downloads the WDK 7600 ISO
   (`GRMWDK_EN_7600_1.ISO`, SHA256-verified, from Microsoft's still-live
   [direct link](https://download.microsoft.com/download/4/A/2/4A25C7D5-EFBE-4182-B6A9-AE6850409A78/GRMWDK_EN_7600_1.ISO),
   falling back to an archive.org mirror publishing the same hash), extracts
   the WDK installer media, fetches the pinned TSDuck build, installs ffmpeg
   via winget, and creates `testbed.config.psd1` from the sample. Then edit
   the config to point at your target (see *Where it runs*) and stage the
   WDK media: `.\tools\Install-TestBed.ps1 -Target <name>` (hyperv:
   attaches the ISO as a DVD; winrm/local: copies the media to
   `C:\vtuner\wdk-media`).
2. **Build, sign, install the driver** -- one command, phases end to end:
   `.\tools\Build-And-Deploy.ps1 -VMName <target> -Standard DVBT`. This
   installs the build toolchain on the target from the staged WDK media,
   builds there, test-signs, installs the device, and verifies it
   enumerates. Repeat with `-Standard ATSC/DVBC/DVBS`
   for more tuners (each needs its own `-DeviceInstanceId`).
3. **Generate streams:** `.\tools\New-TestStreams.ps1 -OutDir C:\ts-gen
   -Standard DVBT` (self-describing colour channels), and/or
   `.\tools\New-MatrixStreams.ps1` for the per-codec matrix. Verify them
   with `.\tools\Test-StreamMatrix.ps1` before trusting anything downstream.
4. **Provision:** map the streams onto frequencies with
   `.\tools\Provision-VTuner.ps1` (see *Provisioning example*), copy the
   `.ts` files to `C:\ts` on the target, apply the emitted `.reg`.
5. **Prepare the player** (see *Preparing the guest* below): MPC-HC at
   `C:\mpc-hc\mpc-hc64.exe` with its `LAVFilters64` directory beside it.
6. **Scan.** Manually: open MPC-HC, Options > Playback > Capture, pick the
   tuner, Ctrl+V, Scan. Scripted: use the **mpc-hc-tests** superproject,
   which holds this repository and MPC-HC as submodules and carries the scan
   harness, decode assertions and frame probes.

## Preparing the guest

The harness expects this layout on the target; nothing creates it for you
except where noted:

| Path | What | Created by |
|---|---|---|
| `C:\mpc-hc\mpc-hc64.exe` | the MPC-HC build under test, **with `LAVFilters64\` beside it** -- a bare exe fails the BDA graph instantly | you |
| `C:\ts\*.ts` | provisioned transport streams (each file >= ~1.2 MB, see *Minimum stream size*) | you (step 4) |
| `C:\vtuner\` | harness scripts, results, scheduled task | `Install-MpcHarness.ps1` |

A user must be logged on at the target's console: MPC-HC needs an interactive
desktop, and the harness drives it through a scheduled task with an
interactive token. The harness stamps the registry settings a run depends on
(digital capture mode, web interface, updater prompt suppression) into that
user's hive on every run.

## Where it runs

The player and driver run on any Windows machine the host can open a
PowerShell session to. Copy `testbed.sample.psd1` to `testbed.config.psd1`
and set the transport:

| Transport | Target | Prerequisite |
|---|---|---|
| `local` | this machine — driver, player and harness on one box (test signing enabled; see *Signing*) | `Enable-PSRemoting` |
| `winrm` | any reachable Windows machine: a VM on any hypervisor, a second PC, bare metal | `Enable-PSRemoting` on the target |
| `hyperv` | a Hyper-V VM by name, over PowerShell Direct — works with no network in the guest | an exported credential (`Get-Credential \| Export-Clixml`) |

Without a config file the transport defaults to `hyperv` with placeholder
values that will not match any machine -- creating the config is step one.

The target needs Secure Boot off (or a signing setup the machine trusts) for
the test-signed driver to load; `Build-And-Deploy.ps1` checks this
automatically on `hyperv` and it is the operator's to ensure elsewhere.

For a pool of interchangeable guests -- optional, and most setups have one
target -- point `BrokerPath` at a claim broker: an external tool (not
included) whose command-line verbs `rig-claim`, `rig-release`, `rig-status`
and `whoami` return JSON naming guests and holders. Stamp each guest's
identity
in `C:\vtuner\rig-id.txt`; leave `BrokerPath` empty to run against the
single configured target.

Everything host-side — stream generation, the falsifiability lint, TSDuck
verification, `Test-MpcDecode -JsonPath`/`-SelfTest` — needs no target
machine at all: any Windows box with ffmpeg and the vendored TSDuck.

## Provenance

`src/` is the `swtuner` sample from **WDK 7600** (`7600.16385.win7_wdk.100208-1538`),
extracted from `GRMWDK_EN_7600_1.ISO` (`WDK\swtuner.msi` + `swtuner_cab001.cab`)
via an msiexec administrative install.

This sample was dropped from WDK 8 onward and is **not** in
[microsoft/Windows-driver-samples](https://github.com/microsoft/Windows-driver-samples).
The first commit is the pristine extraction, so every port change is a diff
against Microsoft's original.

The sample source covers ATSC, DVB-T, DVB-C, DVB-S, QAM, ISDB-T/S, DMB-TH
and PBDA variants, plus a separate analog tuner (`src/analogtuner`). The four
named throughout this README (DVB-T, ATSC, DVB-C, DVB-S) are the ported,
built and end-to-end-tested subset; the remaining variants exist in the
source and some scripts accept them (`Install-VTuner.ps1` knows `QAM`), but
they carry no INF port, provisioning plan, or test content here.

## Why this works for MPC-HC specifically

Two findings from reading MPC-HC's `FGManagerBDA.cpp` shaped the whole
approach:

**MPC-HC never uses `ITuneRequest`.** There is no `ITuner`, `ITuningSpace`, or
network-type GUID anywhere in the codebase. It creates the Microsoft Network
Provider only to satisfy graph topology, then drives the tuner directly:

```
IBDA_DeviceControl::StartChanges
IBDA_DigitalDemodulator::put_SymbolRate      (only when non-zero)
IBDA_FrequencyFilter::put_FrequencyMultiplier(1000)   -> frequency is in kHz
IBDA_FrequencyFilter::put_Bandwidth(bw / 1000)        -> MHz
IBDA_FrequencyFilter::put_Frequency(freq)
IBDA_DeviceControl::CheckChanges / CommitChanges
```

So the only tune inputs the driver ever receives are **frequency, bandwidth and
symbol rate**. No modulation, polarisation, LNB, DiSEqC or T2 PLP handling is
needed. DVB-T/T2, DVB-C, DVB-S/S2 and ATSC therefore reduce to the same driver
plus different INFs and different stream content.

**ATSC mode is selected by tuner friendly name.** `FGManagerBDA.cpp:370`
string-matches `"ATSC"` in the device name to decide between SDT/NIT and
MGT/VCT parsing. The sample's `SWTATSC.FriendlyName="BDA ATSC Sample Tuner"`
trips this correctly, and `"BDA DVBT Sample Tuner"` correctly does not.

`KSCATEGORY_SWTATSC` in the INFs is `{71985F48-1CA1-11d3-9CC8-00C04F7971E0}`,
which is `KSCATEGORY_BDA_NETWORK_TUNER` — the category MPC-HC enumerates at
`FGManagerBDA.cpp:361` to populate its tuner dropdown.

## How the driver picks a stream

The driver looks up the tuned frequency as a decimal subkey:

```
HKLM\SYSTEM\PSWTuner\<DeviceInstanceID>\Device Parameters\<frequency-in-kHz>
    StreamLocation   REG_SZ     \??\C:\ts\mux1.ts
    FriendlyName     REG_SZ     BBC A
    SignalLocked     REG_DWORD  1
    SignalPresent    REG_DWORD  1
    SignalQuality    REG_DWORD  100
    SignalStrength   REG_DWORD  0x3f
```

Relevant behaviour in `src/MergedDevice/device.cpp`:

- `:557` — subkey is the decimal frequency string.
- `:667,:695,:724,:762` — falls back to `frequency × 1000`, but only when `dwFreq < 1000000`, so it never fires for DVB-S. A DVB-S map must be exact kHz.
- `:581,:600` — probes ±100000 around the request, but **only when `fUseSatellite` is set**. As MPC-HC drives the tuner, lookups are exact-match for every standard, so a scan must land precisely on a provisioned frequency.

**Minimum stream size.** `VIDEO_READ_BUFFER_SIZE` is `188 × 312 × 10` =
586,560 bytes, double-buffered in `fileread.cpp`. A stream smaller than about
1,173,120 bytes is smaller than the read machinery's working set, and the
driver goes on serving whatever file it had open — while the device reports
`OK`, the frequency reports locked, and a scan completes and returns channels.
Silently wrong content, with no error anywhere. Real captures are far above
the threshold; short generated samples are not -- keep every provisioned file
above it.

**The device-cycle wedge.** The second silent wrong answer, and the same shape.
After MPC-HC tears down a filter graph the tuner stops locking, and every later
scan finds zero channels — while the device still reports `Status: OK` and the
frequency still reports locked. Cycling the device clears it, which is why
the mpc-hc-tests dvb suite does so before every run.

The tell, without needing a reboot to confirm, is in the scan's progress trace:
locking onto real muxes shows as multi-second gaps, one per mux, while a wedged
tuner shows an unbroken run of quarter-second steps with no gaps at all. Three
provisioned muxes should produce three pauses.

**Detecting both from inside a scan.** Neither failure announces itself, so the
cheapest general defence is a control frequency: provision a second frequency
whose content is known to differ, and scan both in one pass. If the driver is
serving a stale file, or is wedged, the two frequencies return the same thing —
whereas two frequencies disagreeing in exactly the authored way can only happen
if each was served its own file. That holds without knowing which failure mode
you are looking for, or that either exists. It is worth doing as a habit rather
than as a step in one particular test.

Because the signal statistics are plain registry data, **failure conditions are
configuration, not code**. A frequency with `SignalLocked=0` exercises MPC-HC's
lock-wait timeout (the `BDA_CHANGES_PENDING` spin at `FGManagerBDA.cpp:709`) —
a path a clean file replay would never reach, and one a hardware rig could
only reach by physically degrading the signal.

## What this replaces, and what it does not

Replaced: a hardware playout rig -- modulator card, its host machine, and
playout software. The driver reads the `.ts` file directly, so the whole
file → modulate → RF → demodulate → file round trip disappears. That round trip
is designed to be bit-transparent, so a stream library is already the golden
reference.

Not reproduced: genuine RF and demodulator behaviour — real signal-quality
curves, vendor BDA extensions, hardware PID-filtering quirks. MPC-HC touches
none of these, so for this purpose the gap is empty. It would matter if the
target under test were a different application.

## Layout

Generic tuner — usable by any BDA application:

```
src/MergedDevice/     the digital BDA tuner driver (pristine WDK 7600)
  filter.cpp          BDA topology, ~320 KB
  device.cpp          registry lookup, signal stats, tuning
  fileread.cpp        transport stream file reader
  ctstimestampmodifier.cpp   PCR restamping and stream pacing
  hwsim.cpp           hardware simulation layer
  BDA*Tuner/          per-standard sources + INF templates + frequency maps
src/analogtuner/      analog variant (unused)
tools/
  Install-TestBed.ps1    downloads and verifies all prerequisites (WDK ISO, TSDuck, ffmpeg), creates the config
  Build-And-Deploy.ps1   build, sign, install, verify — end to end
  Provision-VTuner.ps1   maps a .ts library onto a frequency plan, emits/applies the registry tree
  Install-VTuner.ps1     devcon install, DeviceInstanceID wiring, stream map import
  New-TestStreams.ps1    generates self-describing channel muxes (flat colour + overlay + subtitles)
  New-DvbSubtitle.ps1    EN 300 743 subtitle encoder (bitmaps, probe grid, periodic display sets)
  New-MatrixStreams.ps1  builds one stream per encoding-matrix entry, gated on what landed in the file
  New-ImpairedStream.ps1 fault injection (see docs/fault-injection.md)
  Sign-Driver.ps1        test certificate, inf2cat catalogue, signtool
  Deploy-ToVM.ps1        older host-built deploy variant
  Setup-GuestToolchain.ps1  installs the WDK toolchain on the target from the ISO
  Test-StreamMatrix.ps1  verifies generated streams against the matrix with TSDuck
  Test-MatrixFalsifiable.ps1  fails matrix entries whose expectations cannot fail
  GuestTransport.ps1     the host-to-guest seam (hyperv / winrm / local)
  RigClaim.ps1, RigLock.ps1  optional multi-guest pooling and locking
```

MPC-HC-specific — nothing, by design. The MPC-HC test harness lives in the
**mpc-hc-tests** superproject, which pins this repository and MPC-HC as
submodules and asserts the player against this repository's streams and
`encoding-matrix.psd1` (whose expected-classification columns document the
consumer under test).

## Signing

Turning Secure Boot off does not let unsigned kernel drivers load. On x64,
test-signing mode means the kernel will accept a certificate chaining to any
root the machine trusts, rather than only Microsoft's — the driver still has to
be signed, but you can be the one who signed it. `Sign-Driver.ps1` creates a
self-signed certificate, builds the catalogue with `inf2cat`, and signs the
`.sys` and `.cat`; `Deploy-ToVM.ps1 -Prepare` imports that certificate into the
guest's Trusted Root and Trusted Publishers stores and enables test signing.

The alternative, which genuinely removes the check, is to attach a kernel
debugger to the guest. For AVStream work that is worth doing regardless, since
a driver fault bugchecks the machine and the dump is where the answer is.

## Test environment

Drive everything from a host; build, sign and run on a separate, disposable
target. Two requirements, not preferences:

- **The WDK 7600 installer media must be available to the target** --
  `Install-TestBed.ps1` downloads the ISO and stages it (`-Target`). The
  canonical pipeline (`Build-And-Deploy.ps1`) installs the toolchain on the
  target from that media and builds there; the host needs only PowerShell.
  (`Deploy-ToVM.ps1` is the older host-built variant, kept for reference.)
- **Never load the driver on a machine you are not prepared to lose.** A
  kernel driver fault takes down whatever loaded it, so the target must be
  something you can revert or reinstall -- a VM with a checkpoint is ideal.

`Deploy-ToVM.ps1` drives the guest over PowerShell Direct, so it needs no
network, share, or open firewall — and it checkpoints the VM immediately before
installing, because rolling back a snapshot beats repairing a boot loop.

The guest must have Secure Boot off (Gen 2 VMs default to on;
`Set-VMFirmware <vm> -EnableSecureBoot Off` while stopped).

One limitation worth knowing up front: a Hyper-V guest has no GPU unless you
configure GPU-P or DDA. That is fine for what this rig is for — tuning,
scanning, PSI/SI parsing, PID mapping, channel lists, EPG — but it is not a
place to evaluate DXVA hardware decode or renderer behaviour.

## What a healthy install looks like

For each standard, the device enumerates and the service runs:

```
BDA DVBT Sample Tuner Device    Status: OK   Problem: CM_PROB_NONE
SWTDVBT service                 Running
Registered under                {71985f48-1ca1-11d3-9cc8-00c04f7971e0}
                                = KSCATEGORY_BDA_NETWORK_TUNER
```

All four standards (DVB-T, ATSC, DVB-C, DVB-S) build from the same source
with per-standard INFs and run side by side. MPC-HC lists each tuner, scans,
locks, plays with EPG, and the harness verifies the results end to end --
from generated streams with known values through MPC-HC's channel records,
its `/dvb/channels.json`, and pixel probes on the rendered frame.

## Build gotchas (WDK 7600)

Four traps, none obvious from the failure they produce.

**WDK root.** The WDK 7600 MSIs carry their own directory structure, so
`TARGETDIR=X` yields `X\WinDDK\7600.16385.win7_wdk.<build>`, not `X`. The
effective root is resolved in the guest by locating `bin\setenv.bat`.

**setenv arguments.** The kit root must be passed **unquoted**. `setenv` does a
bare `set BASEDIR=%1`, so quotes survive into every derived path and the only
symptom is `The syntax of the command is incorrect`.

**OACR.** Without `no_oacr`, the build routes every compile and link through
`Bin\amd64\oacr\oacrcl`, the static-analysis wrapper, which belongs to a
package we do not install. `build.exe` runs nmake with `-i`, so each invocation
failed while the build still reported *"1 executable built"* and produced
nothing at all.

**signtool store.** `/sm` is required to reach `LocalMachine`. Without it
signtool reports *"No certificates were found that met all the given criteria"*
despite a correct thumbprint.

And two at deploy time: `bcdedit` must name `{current}` explicitly and be read
back, and the guest must be rebooted **gracefully** — BCD is a lazily-flushed
registry hive, so `Restart-VM -Force` discards a just-written `testsigning`
setting and the driver then fails with `CM_PROB_UNSIGNED_DRIVER` despite being
correctly signed.

## Provisioning example

```powershell
# Map a stream library onto the UK/EU DVB-T UHF plan, with one dead
# multiplex and one weak one for failure-path testing.
.\tools\Provision-VTuner.ps1 -TsLibrary C:\ts -Standard DVBT `
    -DeadFrequency 490000 -WeakFrequency 498000

# Install and wire it up (elevated).
.\tools\Install-VTuner.ps1 -Standard DVBT -StreamMap .\vtuner-dvbt.reg
```

Supported plans: `DVBT` (UHF from 474000, 8 MHz), `ATSC` (from 473000,
6 MHz), `DVBC` (from 306000, 8 MHz, 6875 ksym/s), `DVBS` (Ku from 10714000,
30 MHz raster, 27500 ksym/s).

## Stream authoring

The emulator generates its own transport streams; the tools are vendored in
`third_party/`.

### TSDuck (`third_party/tsduck`, BSD 2-Clause)

The scripts run TSDuck's portable Windows build, which is not committed:
`Install-TestBed.ps1` downloads the pinned release (3.44) from
https://github.com/tsduck/tsduck/releases and lays it out so that
`third_party/bin/tsduck/TSDuck/bin/tsp.exe` exists. Every
script that needs it checks that path (override with `-TsduckBin`) and names
it in its error if absent. The `third_party/tsduck` submodule is the source,
kept for provenance.

The important one. MPC-HC's `Mpeg2SectionData.cpp` parses far more than PAT and
PMT, and TSDuck is what lets us produce the rest:

- **DVB**: SDT (service names), NIT, EIT present/following and schedule (EPG), TDT/TOT
- **ATSC**: MGT and VCT, which `FGManagerBDA.cpp:798` reaches for once the
  friendly-name check at `:370` puts it in ATSC mode
- PCR restamping, CBR stuffing with null packets, continuity-counter repair

It also earns its place for fault injection. `tsp` can corrupt a CRC, drop a
PMT mid-stream, collide PIDs or truncate a table — conditions no RF playout
chain can physically produce, and which combine with the `SignalLocked=0`
registry trick to cover MPC-HC's error paths properly.

Permissively licensed and buildable with Visual Studio.

### FFmpeg (`third_party/ffmpeg`, LGPL-2.1+ / GPL-2+ with `--enable-gpl`)

Needed only to author *new* video and audio. It emits valid PAT and PMT but no
DVB SI or ATSC PSIP, so a stream built with FFmpeg alone tunes and plays with
unnamed channels and no EPG — TSDuck supplies the table layer on top.

Note on building: FFmpeg on Windows wants MSYS2 and a long, fragile build. The
submodule is here for provenance and for the option; in practice a prebuilt binary is invoked instead
(`winget install Gyan.FFmpeg`; the scripts find it on PATH or in the WinGet
package directory automatically; any recent full build works). That is a licence-safe choice because these
tools are run as **separate processes**, never linked — invoking a GPL program
over a command line does not place our own code under the GPL. Linking FFmpeg's
libraries into this project would be a different question, and we do not.

## Notes on real off-air captures (optional)

Generated samples cover the structure MPC-HC exercises, so real captures are
optional. If a capture set is used, profile it with `tsanalyze` first --
several kinds of mux cannot play for reasons that are nothing to do with the
emulator. The set used during development illustrates the range:

| kHz | capture | services | notes |
|---|---|---|---|
| 474000 | mux3mediaset | 19 | Italian, generic `Servizio NN` names, 1 scrambled |
| 482000 | tnt-uhf22 | 12 | French CANAL+ bouquet, **5 scrambled** (Nagravision) |
| 490000 | screenDVBx1 | 1 | single unnamed service, clear |
| 498000 | T2MI_CAPITAL | — | **T2-MI**, not a playable TS (see below) |
| 506000 | tnt-uhf25 | 12 | French TNT — C8, BFM TV, CNEWS, Gulli, with LCNs |
| 666000 | DVB-T_666000 | 10 | Russian RTRS, **0 scrambled** — the best test target |
| 682000 | digitenne-682 | 8 | Dutch, **all 8 scrambled** — none will play |

Prefer a fully clear mux as the first test target -- in this set 666000, ten
clear services whose Cyrillic names also exercise MPC-HC's DVB character-set
decoding.

Two expected failures that are not bugs:

- **Scrambled services** carry Nagravision CA (EMM on PIDs 0x1449, 0x144F,
  0x1450, 0x1511, 0x1513, 0x1519 in the TNT mux). MPC-HC will list these
  channels and fail to decode them. There is no CAM and no keys, exactly as with
  real broadcast hardware and no subscription.
- **T2MI_CAPITAL.ts** is a T2-MI stream — the encapsulated format fed *into* a
  DVB-T2 modulator, not a transport stream a demux can play. The virtual
  tuner has no modulator, so such a file is useful as a scan target only.

The clear muxes are rich enough to exercise the parts that matter: SDT service
names and providers, LCNs, EIT, multiple audio tracks (`fra`/`eng` E-AC-3),
DVB subtitles including hard-of-hearing variants, AIT for HbbTV, and both
MPEG-2 and AVC video.

## Generating samples instead of carrying them

`tools/New-TestStreams.ps1` generates transport streams, so the project need
not depend on the ~1.7 GB capture library. Three muxes carrying five services
come to under 4 MB — roughly a 450-fold reduction — because flat colour encodes
to almost nothing while the *structure* the tuner and MPC-HC actually exercise
is unchanged.

Each channel is deliberately self-describing:

- the picture alternates between two colours once per second, so the second
  count is visible without reading anything;
- an overlay carries the channel name, its colour pair and a running second
  count (`Test Channel 1 [red/green] t=3s`);
- audio is a tone at a per-channel frequency, so services are distinguishable
  without looking at the picture.

That combination makes wrong-PID, wrong-service and stalled-stream faults
obvious at a glance rather than subtle. The default plan gives Channel 1
red/green, Channel 2 blue/yellow, Channel 3 cyan/magenta, Channel 4
white/black and Channel 5 orange/purple, spread across three frequencies so a
scan has several muxes to find.

```powershell
# Default: three DVB-T muxes, five services
.\tools\New-TestStreams.ps1 -OutDir C:\ts-gen

# ATSC, 15-second samples
.\tools\New-TestStreams.ps1 -OutDir C:\ts-gen -Standard ATSC -Duration 15

# Build channels from your own clips instead of generated colour; the
# identifying overlay is still applied so samples stay self-describing
.\tools\New-TestStreams.ps1 -OutDir C:\ts-gen -SourceDir D:\my-clips
```

Then provision them exactly as with real captures:

```powershell
.\tools\Provision-VTuner.ps1 -TsLibrary C:\ts-gen -Standard DVBT -GuestPath C:\ts
```

### Generated DVB subtitles

`-WithSubtitles` adds a real DVB subtitle stream to every service. TSDuck reads
them back as `Subtitles (eng, DVB subtitles)` on a stream_type 0x06 PID with a
0x59 descriptor, which is what MPC-HC keys on to reach `BDA_SUBTITLE`.

They are generated rather than borrowed. DVB subtitles
(EN 300 743) are **bitmaps**: the broadcaster transmits an image and the player
decodes and composites it. ffmpeg will not rasterise text into them, refusing
with *"Subtitle encoding currently only possible from text to text or bitmap to
bitmap"*, so `tools/New-DvbSubtitle.ps1` draws the bitmap and encodes the
segments itself. ffmpeg's raw `dvbsub` demuxer then takes the elementary
stream, so PES packetisation, PID assignment and the descriptor are not
reimplemented.

Each subtitle carries two things. The **text** is for a human reading a failed
test's screenshot. The **six-cell colour grid** is for the harness: probing it
exercises the whole path — RLE decode, CLUT mapping, region placement,
compositing — with a handful of pixel reads rather than an image comparison or
OCR, and a wrong colour localises the fault to a cell. Measured round-trip
deltas are 0 to 4 against a tolerance of 96, so the assertion has enormous
margin and will not produce flaky failures across codecs or renderers.

`-WithSubtitles` also writes `subtitle-probes.json` next to the streams, giving
the probe coordinates and expected colour per channel, so the harness never has
to re-derive the layout and a change to the subtitle design cannot silently
desynchronise the two.

Two traps are recorded in `New-DvbSubtitle.ps1`, both of which cost real
debugging time:

- Objects are **interlaced**. The top field carries only the even display lines
  of the region; filling it with every line overruns the region and the decoder
  discards the object.
- The raw demuxer splits its input at `raw_packet_size`, **1024 bytes by
  default**, with no regard for segment boundaries. A larger display set is
  silently corrupted, reported only as *"Junk in packet"* — while the segments
  themselves are perfectly valid. `-raw_packet_size 65536` is not optional.

What is still missing is **per-cue timing**: a raw subtitle elementary stream
carries no timestamps, so every display set lands at one PTS and the subtitle
is shown for the whole clip. That is sufficient for the probe assertion. Testing
subtitle *timing* would need PES with a PTS per cue, and a TSDuck merge to
multiplex it.
