# Stream fault injection

`tools/New-ImpairedStream.ps1` takes a good transport stream and produces a set
of deliberately damaged copies, one per named impairment, plus a JSON manifest
saying what each one does and what a correct receiver should do about it.

## Why

The registry contract already gives us one failure mode: a frequency with
`SignalLocked=0` never locks, which drives MPC-HC's lock-wait timeout. That is
the *only* error path the rig covers, and it is a pre-tune failure.

Everything after the lock — PSI/SI parsing, PID mapping, the channel list,
graph construction, decode — is exercised only by clean captures, which are
clean because they were recorded off working transmitters. Real broadcasts are
not. A receiver spends most of its defensive code on tables that do not
verify, services that disappear, clocks that stop and packets that arrive
corrupt, and none of that code is currently reached at all.

These streams put the failure *after* the lock. The tuner locks, the bitrate
is right, packets flow, and the content is wrong.

## Running it

```powershell
# Everything, against a generated mux (any real capture works the same way)
# because all ten of its services are clear.
.\tools\New-ImpairedStream.ps1 -InputStream C:\ts-gen\dvbt-mux1-474000.ts -OutDir C:\ts-fault

# Just the two that matter for a UI change, with the mid-stream event at 5 s.
.\tools\New-ImpairedStream.ps1 -InputStream C:\ts-gen\mux1.ts -OutDir C:\ts-fault `
    -Impairment sdt-removed,pmt-vanishes -DelaySeconds 5

# The catalogue, without touching a stream.
.\tools\New-ImpairedStream.ps1 -ListImpairments
```

Output filenames keep the source stem — `DVB-T_666000_H_0-41-sdt-removed.ts` —
so a frequency embedded in the source name survives and `Provision-VTuner.ps1`
still infers it. Give the damaged copies their own frequencies alongside the
clean originals and one scan sweeps both:

```powershell
.\tools\Provision-VTuner.ps1 -TsLibrary C:\ts-fault -Standard DVBT -GuestPath C:\ts
```

## The catalogue

| id | what it does | certainty |
|---|---|---|
| `crc-pat` | every PAT section gets a wrong CRC_32, body untouched | required |
| `crc-pmt` | same for one service's PMT | required |
| `crc-sdt` | same for SDT actual | required |
| `pat-removed` | PID 0 replaced by null packets throughout | required |
| `pat-truncated` | PAT announces one service; the rest are orphaned but still present | unclear |
| `pmt-vanishes` | one service's PMT stops repeating after N seconds, mid-playback | unclear |
| `sdt-removed` | PID 0x11 replaced by null packets — services have no names | required |
| `nit-removed` | PID 0x10 replaced by null packets — no LCNs, no network name | required |
| `cc-errors` | 1 packet in N dropped from the video PID, giving CC discontinuities | required |
| `pcr-removed` | PCR fields stripped from the service's clock PID | unclear |
| `pcr-pid-missing` | PMT declares a PCR_PID that carries nothing | unclear |
| `pid-collision` | a second service's PMT also claims the first's video PID | expected |
| `transport-error` | transport_error_indicator set on 1 packet in N | required |
| `false-scrambling` | scrambling flag set on clear video, no CA signalling | required |

## The expected-behaviour field

Each manifest entry carries `expected` (what should happen), `mustNot` (what is
not allowed to happen whatever else does), and `certainty`, which is the field
to read first:

- **required** — the standard says so, or the failure would be a defect on any
  reading. A crash, a hang, an unbounded retry, or acting on a section that
  failed its CRC.
- **expected** — conventional receiver behaviour, widely implemented, not
  mandated in so many words.
- **unclear** — genuinely unsettled. Both outcomes are defensible and the test
  exists to find out which one MPC-HC picks.

The distinction matters because most of these impairments have no single
correct response. `pmt-vanishes` is the clearest case: ISO/IEC 13818-1 sets no
timeout on PSI repetition, so a receiver that keeps decoding on the PMT it
already has is behaving correctly, and so is one that stops the service. The
only firm requirement is that it does one of them, promptly, and stays stable.
Asserting that the picture must freeze at exactly *N* seconds would be
over-specifying — the elementary streams are still flowing.

The two CRC entries are worth reading together. Their table *bodies* are
correct; only the checksum is wrong. A receiver that verifies CRCs sees no
table at all; one that does not sees a perfectly good table and behaves
normally. Both outcomes are informative, and comparing `crc-sdt` against
`sdt-removed` tells you directly whether CRCs are checked anywhere in the
chain. MPC-HC does not parse PAT and PMT itself — the Microsoft MPEG-2
Demultiplexer does — and we do not know what that component does with a bad
CRC.

## Verification

Nothing is recorded as verified because `tsp` exited zero. It exits zero for a
chain that matched nothing: a mistyped PID, a service that is not in this
multiplex, a table that was never there. Every impairment is built and then
read back, and the manifest records each check with the numbers it observed:

```json
{ "check": "continuity errors present",
  "expected": "the video PID reports continuity counter discontinuities",
  "observed": "641 discontinuities, baseline had 0",
  "pass": true }
```

The checks are deliberately expressed as differences from the source
(`13440 -> 13305 packets`) rather than as absolutes, and they avoid asserting
anything that is a property of the source rather than of the damage. An early
version checked that removing the PAT left unreferenced PIDs behind; on a
capture with no SDT there are no services to leave unreferenced, and the check
failed on a stream that had been impaired perfectly well.

For the same reason each impairment can declare a precondition. Removing a
table that was never present looks exactly like success — the verification
finds no SDT and passes — so `sdt-removed`, `crc-sdt`, `nit-removed` and
`pcr-removed` refuse to run on a source that lacks what they remove, and are
reported as skipped rather than shipped as a file that tests nothing. The same
applies to the three impairments that need a second service to leave alone.

## What is not implemented, and why

**Truncated PSI sections.** A section whose `section_length` runs off the end
of the data it is followed by, so the reassembler is asked for bytes that never
arrive. This is a different test from a bad CRC — it exercises the section
assembler rather than the checksum — and it is not implemented. `tsp -P inject`
validates every section it loads, so a malformed one cannot be injected; it
would need a second pass of the byte-level rewriter described below. Worth
adding; the CRC cases cover "the table must be rejected" in the meantime.

**Real burst errors.** `cc-errors` and `transport-error` spread their damage
evenly. Genuine transmission errors arrive in bursts. An even spread is
arguably the harsher test for a receiver that resynchronises once per burst,
but it is not what a real aerial produces.

**Actual encryption.** `false-scrambling` sets the scrambling flag on clear
data. It does not encrypt anything: TSDuck can (`-P scrambler`), but that would
be a conditional-access test, and the capture library already has five
genuinely Nagravision-scrambled muxes for that. The interesting case here is
the mismatch — packets that say scrambled inside SI that says clear.

**Anything requiring a modulator.** T2-MI, wrong FEC, real signal-quality
curves. The virtual tuner has no modulator; see the README.

## TSDuck notes

Quirks of the vendored TSDuck (3.44-4676):

- **There is no `corrupt` plugin.** CRC damage is therefore not done with
  `tsp` at all. The obvious substitute — pull the table out with `tstables`,
  flip a CRC byte, put it back with `tsp -P inject --replace` — does not work:
  `inject` validates every section it loads and rejects a bad CRC outright
  with *"invalid section"*. What is left inside TSDuck is `fuzz`, which
  corrupts random bytes and cannot be aimed at a field, or `craft` with a fixed
  `--offset-pattern`, which only lands on the CRC for tables whose sections
  happen to start a packet and fit inside it. The script walks the sections
  directly instead and inverts the last byte of each, which is exact and
  handles sections that span packets.

- **`craft --pid` sets the PID, it does not select one.** It is a
  transformation, not a filter, so `-P craft --pid 2011 --no-pcr` collapses the
  entire multiplex onto PID 2011. Aiming `craft` at a PID means labelling the
  packets first: `-P filter --pid X --set-label 1 -P craft --only-label 1 ...`.
  `filter --set-label` passes everything and marks the selection, so nothing is
  dropped.

- **`filter` ORs its criteria.** `-P filter --pid 2011 --every 100 --negate
  --stuffing` does not thin the video PID; it selects PID 2011 *or* every
  hundredth packet, and negated that empties the video PID completely. One in
  N of one PID needs two filters in series.

- **The `pmt` plugin shortens the stream.** It rebuilds the whole PMT PID
  rather than editing packets in place, which re-times the stream and drops
  roughly the last three per cent of it. The output is otherwise sound — PCR
  jitter measured with `pcrverify` is unchanged from the source — but
  `pcr-pid-missing` and `pid-collision` produce shorter files than the rest,
  which is why the manifest records a packet count per output.

- **`tstables --json` is an abbreviation of `--json-output`** and takes the
  next argument as its output filename — which is the `.ts` you meant to
  analyse. Every option in the script is spelled out in full.

- **Machine-readable output goes to a file, never to stdout.** PowerShell
  decodes a native command's stdout using `[Console]::OutputEncoding`, which on
  a stock Windows console is a code page, and these captures carry Cyrillic and
  accented service names. `tsanalyze` has no output-file option, so the script
  uses `tsp -P analyze --json --output-file` instead.

## PowerShell notes

The script runs on Windows PowerShell 5.1 as well as pwsh 7, which took three
pitfalls:

- 5.1 turns every stderr line of a native command into an `ErrorRecord`, and
  with `$ErrorActionPreference = 'Stop'` the first one aborts the script — for
  `tsp` that is its version banner, printed before it has done anything.
- `ConvertFrom-Json` unwraps a one-element JSON array into a bare object, and
  PowerShell unwraps a one-element array again on the way out of a function.
  Under `Set-StrictMode`, `.Count` on what comes back is then a terminating
  error. `return ,@(...)` is the fix.
- `$pid` is a read-only automatic variable.

The manifest is JSON rather than a `.psd1` because
`Import-PowerShellDataFile` does not exist in 5.1 and the harness has to read
it back inside the guest.

## Status

The streams are produced and verified; **no MPC-HC behaviour has been observed
against them yet.** The `expected` fields are what the standards and ordinary
practice say should happen, written before the fact and deliberately not
tuned to whatever MPC-HC turns out to do. When results arrive, disagreements
belong in this document's tables, and any `expected` field that turns out to have
been wrong should be corrected there with the reasoning, not quietly relaxed.
