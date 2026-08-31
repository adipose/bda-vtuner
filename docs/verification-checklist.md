# Verification checklist

What a working end-to-end setup shows, item by item. Result artefacts do not
live in this repository -- the test bed's job is to regenerate them, and a
screenshot describes one run on one rig at one moment -- so this is the
checklist a fresh run reproduces, with per-run screenshots landing beside the
result JSON.

The checks run against the generated streams, which any clone can produce.
Where an item below cites specific off-air services (channel names, PSIP
tables), those come from the capture set used during original validation and
are illustrative -- the equivalent check against generated content is the
normative one.

## MPC-HC enumerates the tuner

Options > Playback > Capture, "Digital settings (BDA)":

- Network Provider: `Microsoft Network Provider`
- **Tuner: `BDA DVBT Sample Tuner`**

This is `FGManagerBDA.cpp:361` enumerating `KSCATEGORY_BDA_NETWORK_TUNER` and
finding a device with no hardware behind it. MPC-HC stored the full moniker:

    BDATuner=@device:pnp:\\?\root#media#0000#{71985f48-1ca1-11d3-9cc8-00c04f7971e0}\{0e7e99d5-8a1c-11db-bda1-00123f758252}

## The BDA filter graph builds

File > Open Device (Ctrl+V) puts MPC-HC in Digital TV mode: title bar reads
`Live | DVB`, status bar `Playing [MPEG2 720x576] [AAC 2.0] … Live`.

So `CFGManagerBDA::RenderFile` completed: network provider created, connected
to our tuner, `SearchIBDATopology` found `IBDA_FrequencyFilter` and the
statistics interfaces, and the Microsoft MPEG-2 Demultiplexer connected
downstream. That is the whole BDA plumbing working against a software device.

## The tuner scan dialog

Freq Start 474000, Freq End 858000, Bandwidth 8000, Symbol Rate 0 — MPC-HC's
own defaults, and the units line up with the kHz keys in the stream map.

## The channel scan finds the right services

The scan swept 474000-858000 kHz and populated the list from the real PSI/SI
in the captures, at exactly the frequencies they were provisioned to:

| LCN | Name | kHz | Encrypted |
|---|---|---|---|
| 4, 5, 6 | Rete4 HD, Canale5 HD, Italia1 HD | 474000 | No |
| 4 | CANAL+ | 482000 | No |
| 8, 15 | C8, BFM TV | 506000 | No |
| 11, 12, 13, 14 | 11 РЕН ТВ, 12 Спас, 13 СТС, 14 Домашний | 666000 | No |
| 9, 10, 11, 14 | Veronica / Disney XD, RTL 8, Comedy Central, één | 682000 | **Yes** |

The encryption column matches the independent `tsanalyze` profile exactly: every
service on the Dutch mux at 682000 is flagged encrypted, everything else clear.
Cyrillic service names decode correctly, exercising MPC-HC's DVB character-set
handling.

## Live playback with EPG

Title bar `Live | Rete4 HD - Uragano`, status bar `Playing [H264 1920x1080]
[MP2 2.0] … Live`, and the EPG overlay reads
`Rete4 HD | Uragano (08:40 - 10:58)` — present/following EIT parsed from the
capture.

That is the whole chain working against a software device: enumeration, graph
construction, tuning, lock, PSI/SI parsing, channel list, PID mapping, video and
audio decode, and EPG.

## Pitfall: a zero-channel scan with an unkillable player

A scan that finds zero channels and leaves an unkillable MPC-HC process (a
thread stuck in `Wait`/`Executive`) has two known configuration causes,
neither a driver defect:

- No `DefaultStreamLocation` was set, so the driver had nothing to serve while
  the graph was being built.
- A seeded `mpc-hc64.ini` put MPC-HC into a state where it started without ever
  creating a main window, so the keystrokes driving the scan went nowhere.

With `DefaultStreamLocation` set and MPC-HC on its normal settings store,
the scan completes and playback works. The driver opens the stream file
(verified by an exclusive-open test failing while the graph runs) and releases
it on teardown.

## The ATSC variant

The same driver source built as `SWTATSC` and installed alongside the DVB-T
tuner, each with its own `DeviceInstanceID` and stream map
(`ROOT_MEDIA_0000` for DVB-T, `ROOT_MEDIA_0001` for ATSC). Both report
`CM_PROB_NONE` simultaneously.

MPC-HC selects `BDA ATSC Sample Tuner`, and because that name contains "ATSC"
the friendly-name check at `FGManagerBDA.cpp:370` puts it into MGT/VCT parsing
rather than SDT/NIT. The scan then reads real PSIP out of the captures:

| Virtual channel | Name | kHz (RF channel) |
|---|---|---|
| 10.1–10.4 | KULX, TelXito, LightTV, Quest | 473000 (ch 14) |
| 50.1 | KEJT-HD | 515000 (ch 21) |
| 9.1–9.4, 9.91 | KUEN, MHzWrld, FNX, NHK, KUER-FM | 605000 (ch 36) |

Note the decoupling that makes ATSC awkward: the KUEN mux is broadcast on RF
channel 36 but presents itself as virtual channel 9. That is normal ATSC — the
virtual channel number is what a viewer knows the station by, and it is carried
in the VCT rather than implied by the frequency.

### Defects this exposed in MPC-HC

The `N` column reads `0` for every ATSC channel, where the DVB-T scan showed
real LCNs. `ParseVCT` formats the major and minor numbers into the channel
*name* and never calls `SetOriginNumber`, so the scan list is left unsorted and
the channel number is unavailable to anything downstream. `access_controlled`
and `hidden` are read from the VCT and discarded, so every ATSC service reports
as unencrypted and test services are listed as if viewable.

Separately, the scan sweeps by stepping the bandwidth, which assumes a uniform
raster. The US ATSC plan is not uniform: 10 MHz separates channels 4 and 5, the
FM band sits between 6 and 7, and 260 MHz between 13 and 14. A 6 MHz sweep is
off-channel from channel 5 upward and wastes some forty tuning attempts
crossing the gap below UHF.

Fixes for all of these were merged upstream in clsid2/mpc-hc#4136.
