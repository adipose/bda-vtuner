<#
    encoding-matrix.psd1 - the elementary-stream encoding test matrix.

    WHAT THIS IS FOR

    MPC-HC classifies every elementary stream in a PMT with
    CMpeg2DataParser::ConvertToDVBType (mpc-hc\src\mpc-hc\Mpeg2SectionData.cpp).
    That function, plus the descriptor switch in ParsePMT immediately above it,
    is the entire specification for what MPC-HC can play off a virtual tuner.
    This file enumerates one generated sample per reachable branch of it, so a
    generated library covers the same ground as the retired ~1.7 GB library of
    off-air captures.

    The mapping, extracted from ParsePMT + ConvertToDVBType:

        PMT stream_type / descriptor      PES_STREAM_TYPE        BDA_STREAM_TYPE
        --------------------------------  ---------------------  ---------------
        0x01                              VIDEO_STREAM_MPEG1     BDA_MPV
        0x02                              VIDEO_STREAM_MPEG2     BDA_MPV
        0x1B                              VIDEO_STREAM_H264      BDA_H264
        0x24                              VIDEO_STREAM_HEVC      BDA_HEVC
        0x03                              AUDIO_STREAM_MPEG1     BDA_MPA
        0x04                              AUDIO_STREAM_MPEG2     BDA_MPA
        0x81                              AUDIO_STREAM_AC3       BDA_AC3
        0x0F                              AUDIO_STREAM_AAC       BDA_ADTS
        0x11                              AUDIO_STREAM_AAC_LATM  BDA_LATM
        any + AC-3 descriptor 0x6A        AUDIO_STREAM_AC3       BDA_AC3
        any + enhanced AC-3 desc 0x7A     AUDIO_STREAM_AC3_PLUS  BDA_EAC3
        any + AAC descriptor 0x7C         AUDIO_STREAM_AAC_LATM  BDA_LATM
        any + subtitling descriptor 0x59  SUBTITLE_STREAM        BDA_SUBTITLE

    The descriptor cases win: they overwrite pes_stream_type before the lookup,
    so under DVB signalling the carrier stream_type is 0x06 (PES private data)
    and the descriptor alone decides the result.

    Two further descriptors are read in the same loop without changing the
    stream type. They set what the channel list displays, so they get their own
    entries rather than being folded into another sample:

        0x02 video_stream_descriptor           -> frame rate, chroma format
        0x07 target_background_grid_descriptor -> width, height, aspect ratio
        0x0A ISO_639_language_descriptor       -> per-stream language

    ParsePMT is only ever reached for a program that already appeared in the
    SDT with an accepted service_type (DVB) or in the VCT as ATSC_DIGITAL_TV
    (ATSC) - see ParseSDT and ParseVCT. Every entry therefore declares its
    service identity, and Test-StreamMatrix.ps1 verifies it survived muxing.

    HOW TO READ AN ENTRY

    FFmpeg  - what the generator asks ffmpeg for. Options are literal argv
              fragments, so no quoting rules have to be reinvented downstream.
    Tsduck  - a post-pass, for what ffmpeg cannot express. PatchXml is passed
              straight to `tsp -P pmt --patch-xml`, which takes inline XML when
              the argument starts with "<?xml".
    Expect  - what Test-StreamMatrix.ps1 asserts against the finished file.
              Streams are matched to PMT components by stream_type plus
              required descriptors, not by order or PID, so the generator is
              free to assign PIDs however it likes.

    Bda and Pes on each expected stream document the branch under test rather
    than anything the validator can observe - nothing outside MPC-HC computes
    them. They are what a human compares the player's channel properties
    against.
#>

@{
    SchemaVersion = 1

    # Shared defaults. An entry may override any of these; the generator should
    # read a missing key on an entry as "use the default".
    Defaults = @{
        # Ten seconds of flat colour. Flat colour is the whole point: one
        # I-frame of solid blue plus nine seconds of near-empty P-frames costs
        # a few hundred KB, so the entire matrix fits in a git repo where the
        # capture library never could.
        DurationSeconds = 10

        # Deliberately NOT 720x576. ParsePMT back-fills exactly that raster for
        # MPEG-2 video carrying no target_background_grid_descriptor
        # (Mpeg2SectionData.cpp:605-608), so an expectation of 720x576 is
        # indistinguishable from the fallback and cannot fail. 704x576 is an
        # equally legitimate DVB SD raster and no fallback produces it, so a
        # correct parse and a missing descriptor now differ. Keep the SD
        # entries' target_background_grid_descriptor in step with this.
        Width     = 704
        Height    = 576
        FrameRate = 25

        VideoSource = 'color=c=0x10305a:s={width}x{height}:r={framerate}'
        AudioSource = 'sine=f=440'

        VideoBitrate = '250k'
        AudioBitrate = '64k'

        # CBR stuffing, which earlier notes here dismissed as padding for no
        # benefit. There is a benefit, and it is not about pacing: the driver
        # reads VIDEO_READ_BUFFER_SIZE (188 * 312 * 10) double-buffered, and a
        # file under 1,173,120 bytes is served from the buffer still holding the
        # PREVIOUS stream while it reports OK and signal-locked. The scan
        # succeeds and the channel plays the wrong content, with no error
        # anywhere.
        #
        # Raising VideoBitrate does not fix it: -b:v is a target, not a floor,
        # and ten seconds of flat colour never spends it -- these entries came
        # out at 598,592 bytes against a nominal 250k. A mux rate is the only
        # setting that makes the size deterministic rather than a function of
        # how well the content happens to compress.
        #
        # 1,200,000 bit/s over the default ten seconds is roughly 1.5 MB, which
        # clears the floor with margin. New-MatrixStreams.ps1 refuses to emit a
        # stream under it regardless, so an entry that overrides DurationSeconds
        # downward fails rather than producing a quietly unusable file.
        MuxRate = 1200000

        PmtStartPid       = 0x1000
        StartPid          = 0x0100
        TransportStreamId = 0x1000
        OriginalNetworkId = 0x2000
        Provider          = 'bda-vtuner'

        # Frequencies are assigned by Provision-VTuner.ps1, not here. The
        # matrix is about stream content; where a stream is tuned is a
        # separate concern.
    }

    Entries = @(

        # ---- Video codecs -------------------------------------------------

        @{
            Id          = 'mpv-mpa'
            File        = 'mpv-mpa.ts'
            Summary     = 'MPEG-2 video plus MPEG-1 layer II audio. The baseline DVB SD service.'
            Standard    = 'DVB'
            ServiceId   = 0x0101
            ServiceName = 'VT MPEG2'
            ServiceType = 0x01          # DIGITAL_TV
            FFmpeg = @{
                Video     = @{ Encoder = 'mpeg2video'; Options = @() }
                Audio     = @( @{ Encoder = 'mp2'; Language = 'eng'; Options = @() } )
                Subtitles = @()
                MuxerOptions = @('-mpegts_flags', '+system_b')
            }
            Expect = @{
                PcrRequired = $true
                Streams = @(
                    @{ Role = 'video'; StreamType = 0x02; Descriptors = @();     Bda = 'BDA_MPV'; Pes = 'VIDEO_STREAM_MPEG2' }
                    @{ Role = 'audio'; StreamType = 0x03; Descriptors = @(0x0A); Bda = 'BDA_MPA'; Pes = 'AUDIO_STREAM_MPEG1'; Language = 'eng' }
                )
            }
        }

        @{
            Id          = 'mpeg1v-mpa'
            File        = 'mpeg1v-mpa.ts'
            Summary     = 'stream_type 0x01, covering the VIDEO_STREAM_MPEG1 arm of ConvertToDVBType.'
            Standard    = 'DVB'
            ServiceId   = 0x0102
            ServiceName = 'VT MPEG1V'
            ServiceType = 0x01
            FFmpeg = @{
                Video     = @{ Encoder = 'mpeg1video'; Options = @() }
                Audio     = @( @{ Encoder = 'mp2'; Language = 'eng'; Options = @() } )
                Subtitles = @()
                MuxerOptions = @('-mpegts_flags', '+system_b')
            }
            Tsduck = @{
                # ffmpeg's mpegts muxer signals mpeg1video and mpeg2video alike
                # as 0x02, so the 0x01 branch is unreachable without a patch.
                # The elementary stream really is MPEG-1, so this corrects the
                # signalling rather than lying about the payload.
                Why      = 'ffmpeg writes stream_type 0x02 for MPEG-1 video; MPC-HC has a separate 0x01 branch.'
                PatchXml = '<?xml version="1.0" encoding="UTF-8"?><tsduck><PMT><component stream_type="2" x-add-stream_type="1"/></PMT></tsduck>'
            }
            Expect = @{
                PcrRequired = $true
                Streams = @(
                    @{ Role = 'video'; StreamType = 0x01; Descriptors = @();     Bda = 'BDA_MPV'; Pes = 'VIDEO_STREAM_MPEG1' }
                    @{ Role = 'audio'; StreamType = 0x03; Descriptors = @(0x0A); Bda = 'BDA_MPA'; Pes = 'AUDIO_STREAM_MPEG1'; Language = 'eng' }
                )
            }
        }

        @{
            Id          = 'h264-mpa'
            File        = 'h264-mpa.ts'
            Summary     = 'H.264 video, stream_type 0x1B.'
            Standard    = 'DVB'
            ServiceId   = 0x0103
            ServiceName = 'VT H264'
            ServiceType = 0x19          # AVC_HD_TV
            Width       = 1280
            Height      = 720
            FFmpeg = @{
                Video     = @{ Encoder = 'libx264'; Options = @('-preset', 'veryfast', '-b:v', '150k', '-pix_fmt', 'yuv420p') }
                Audio     = @( @{ Encoder = 'mp2'; Language = 'eng'; Options = @() } )
                Subtitles = @()
                MuxerOptions = @('-mpegts_flags', '+system_b')
            }
            Expect = @{
                PcrRequired = $true
                Streams = @(
                    @{ Role = 'video'; StreamType = 0x1B; Descriptors = @();     Bda = 'BDA_H264'; Pes = 'VIDEO_STREAM_H264' }
                    @{ Role = 'audio'; StreamType = 0x03; Descriptors = @(0x0A); Bda = 'BDA_MPA';  Pes = 'AUDIO_STREAM_MPEG1'; Language = 'eng' }
                )
            }
        }

        @{
            Id          = 'hevc-mpa'
            File        = 'hevc-mpa.ts'
            Summary     = 'HEVC video, stream_type 0x24, advertised as HEVC_TV in the SDT.'
            Standard    = 'DVB'
            ServiceId   = 0x0104
            ServiceName = 'VT HEVC'
            ServiceType = 0x1F          # HEVC_TV - the newest arm of the ParseSDT service filter
            Width       = 1280
            Height      = 720
            FFmpeg = @{
                Video     = @{ Encoder = 'libx265'; Options = @('-preset', 'veryfast', '-x265-params', 'log-level=none', '-b:v', '150k', '-pix_fmt', 'yuv420p') }
                Audio     = @( @{ Encoder = 'mp2'; Language = 'eng'; Options = @() } )
                Subtitles = @()
                MuxerOptions = @('-mpegts_flags', '+system_b')
            }
            Expect = @{
                PcrRequired = $true
                Streams = @(
                    @{ Role = 'video'; StreamType = 0x24; Descriptors = @();     Bda = 'BDA_HEVC'; Pes = 'VIDEO_STREAM_HEVC' }
                    @{ Role = 'audio'; StreamType = 0x03; Descriptors = @(0x0A); Bda = 'BDA_MPA';  Pes = 'AUDIO_STREAM_MPEG1'; Language = 'eng' }
                )
            }
        }

        # ---- Audio codecs -------------------------------------------------

        @{
            Id          = 'mpv-mpeg2audio'
            File        = 'mpv-mpeg2audio.ts'
            Summary     = 'stream_type 0x04, covering the AUDIO_STREAM_MPEG2 arm, which ffmpeg never emits.'
            Standard    = 'DVB'
            ServiceId   = 0x0105
            ServiceName = 'VT MP2A'
            ServiceType = 0x01
            FFmpeg = @{
                Video     = @{ Encoder = 'mpeg2video'; Options = @() }
                Audio     = @( @{ Encoder = 'mp2'; Language = 'eng'; Options = @() } )
                Subtitles = @()
                MuxerOptions = @('-mpegts_flags', '+system_b')
            }
            Tsduck = @{
                Why      = 'ffmpeg signals every MPEG audio layer as 0x03; 0x03 and 0x04 are separate cases in ConvertToDVBType.'
                PatchXml = '<?xml version="1.0" encoding="UTF-8"?><tsduck><PMT><component stream_type="3" x-add-stream_type="4"/></PMT></tsduck>'
            }
            Expect = @{
                PcrRequired = $true
                Streams = @(
                    @{ Role = 'video'; StreamType = 0x02; Descriptors = @();     Bda = 'BDA_MPV'; Pes = 'VIDEO_STREAM_MPEG2' }
                    @{ Role = 'audio'; StreamType = 0x04; Descriptors = @(0x0A); Bda = 'BDA_MPA'; Pes = 'AUDIO_STREAM_MPEG2'; Language = 'eng' }
                )
            }
        }

        @{
            Id          = 'h264-ac3-dvb'
            File        = 'h264-ac3-dvb.ts'
            Summary     = 'AC-3 in DVB signalling: stream_type 0x06 plus AC-3 descriptor 0x6A.'
            Standard    = 'DVB'
            ServiceId   = 0x0106
            ServiceName = 'VT AC3 DVB'
            ServiceType = 0x19
            Width       = 1280
            Height      = 720
            FFmpeg = @{
                Video     = @{ Encoder = 'libx264'; Options = @('-preset', 'veryfast', '-b:v', '150k', '-pix_fmt', 'yuv420p') }
                Audio     = @( @{ Encoder = 'ac3'; Language = 'eng'; Options = @('-b:a', '96k') } )
                Subtitles = @()
                # +system_b is what switches ffmpeg from ATSC AC-3 signalling
                # (bare stream_type 0x81) to DVB (0x06 plus descriptor 0x6A).
                MuxerOptions = @('-mpegts_flags', '+system_b')
            }
            Expect = @{
                PcrRequired = $true
                Streams = @(
                    @{ Role = 'video'; StreamType = 0x1B; Descriptors = @();           Bda = 'BDA_H264'; Pes = 'VIDEO_STREAM_H264' }
                    @{ Role = 'audio'; StreamType = 0x06; Descriptors = @(0x6A, 0x0A); Bda = 'BDA_AC3';  Pes = 'AUDIO_STREAM_AC3'; Language = 'eng' }
                )
            }
        }

        @{
            Id          = 'h264-ac3-atsc-style'
            File        = 'h264-ac3-atsc-style.ts'
            Summary     = 'AC-3 as bare stream_type 0x81 inside a DVB mux - what ffmpeg does by default, and still BDA_AC3.'
            Standard    = 'DVB'
            ServiceId   = 0x0107
            ServiceName = 'VT AC3 A'
            ServiceType = 0x19
            Width       = 1280
            Height      = 720
            FFmpeg = @{
                Video     = @{ Encoder = 'libx264'; Options = @('-preset', 'veryfast', '-b:v', '150k', '-pix_fmt', 'yuv420p') }
                Audio     = @( @{ Encoder = 'ac3'; Language = 'eng'; Options = @('-b:a', '96k') } )
                Subtitles = @()
                # Deliberately no +system_b. This is what a generator produces
                # when nobody thinks about signalling, so it is worth pinning
                # down that MPC-HC still resolves it - by stream_type 0x81
                # rather than by descriptor.
                MuxerOptions = @()
            }
            Expect = @{
                PcrRequired = $true
                Streams = @(
                    @{ Role = 'video'; StreamType = 0x1B; Descriptors = @();     Bda = 'BDA_H264'; Pes = 'VIDEO_STREAM_H264' }
                    @{ Role = 'audio'; StreamType = 0x81; Descriptors = @(0x0A); Bda = 'BDA_AC3';  Pes = 'AUDIO_STREAM_AC3'; Language = 'eng' }
                )
            }
        }

        @{
            Id          = 'h264-eac3-dvb'
            File        = 'h264-eac3-dvb.ts'
            Summary     = 'E-AC-3 in DVB signalling: stream_type 0x06 plus enhanced AC-3 descriptor 0x7A.'
            Standard    = 'DVB'
            ServiceId   = 0x0108
            ServiceName = 'VT EAC3'
            ServiceType = 0x19
            Width       = 1280
            Height      = 720
            FFmpeg = @{
                Video     = @{ Encoder = 'libx264'; Options = @('-preset', 'veryfast', '-b:v', '150k', '-pix_fmt', 'yuv420p') }
                Audio     = @( @{ Encoder = 'eac3'; Language = 'eng'; Options = @('-b:a', '96k') } )
                Subtitles = @()
                # +system_b is mandatory here, not cosmetic. See the
                # atsc-h264-eac3-gap entry for what happens without it.
                MuxerOptions = @('-mpegts_flags', '+system_b')
            }
            Expect = @{
                PcrRequired = $true
                Streams = @(
                    @{ Role = 'video'; StreamType = 0x1B; Descriptors = @();           Bda = 'BDA_H264'; Pes = 'VIDEO_STREAM_H264' }
                    @{ Role = 'audio'; StreamType = 0x06; Descriptors = @(0x7A, 0x0A); Bda = 'BDA_EAC3'; Pes = 'AUDIO_STREAM_AC3_PLUS'; Language = 'eng' }
                )
            }
        }

        @{
            Id          = 'h264-aac-adts'
            File        = 'h264-aac-adts.ts'
            Summary     = 'AAC with ADTS framing, stream_type 0x0F.'
            Standard    = 'DVB'
            ServiceId   = 0x0109
            ServiceName = 'VT AAC'
            ServiceType = 0x19
            Width       = 1280
            Height      = 720
            FFmpeg = @{
                Video     = @{ Encoder = 'libx264'; Options = @('-preset', 'veryfast', '-b:v', '150k', '-pix_fmt', 'yuv420p') }
                Audio     = @( @{ Encoder = 'aac'; Language = 'eng'; Options = @() } )
                Subtitles = @()
                MuxerOptions = @('-mpegts_flags', '+system_b')
            }
            Expect = @{
                PcrRequired = $true
                Streams = @(
                    @{ Role = 'video'; StreamType = 0x1B; Descriptors = @();     Bda = 'BDA_H264'; Pes = 'VIDEO_STREAM_H264' }
                    @{ Role = 'audio'; StreamType = 0x0F; Descriptors = @(0x0A); Bda = 'BDA_ADTS'; Pes = 'AUDIO_STREAM_AAC'; Language = 'eng' }
                )
            }
        }

        @{
            Id          = 'h264-aac-latm'
            File        = 'h264-aac-latm.ts'
            Summary     = 'AAC with LATM framing, stream_type 0x11.'
            Standard    = 'DVB'
            ServiceId   = 0x010A
            ServiceName = 'VT LATM'
            ServiceType = 0x19
            Width       = 1280
            Height      = 720
            FFmpeg = @{
                Video     = @{ Encoder = 'libx264'; Options = @('-preset', 'veryfast', '-b:v', '150k', '-pix_fmt', 'yuv420p') }
                Audio     = @( @{ Encoder = 'aac'; Language = 'eng'; Options = @() } )
                Subtitles = @()
                # +latm changes the framing as well as the signalling, so this
                # is a real LATM elementary stream rather than a relabelled
                # ADTS one.
                MuxerOptions = @('-mpegts_flags', '+system_b+latm')
            }
            Expect = @{
                PcrRequired = $true
                Streams = @(
                    @{ Role = 'video'; StreamType = 0x1B; Descriptors = @();     Bda = 'BDA_H264'; Pes = 'VIDEO_STREAM_H264' }
                    @{ Role = 'audio'; StreamType = 0x11; Descriptors = @(0x0A); Bda = 'BDA_LATM'; Pes = 'AUDIO_STREAM_AAC_LATM'; Language = 'eng' }
                )
            }
        }

        @{
            Id          = 'h264-aac-descriptor'
            File        = 'h264-aac-descriptor.ts'
            Summary     = 'ADTS AAC carrying a DVB AAC descriptor 0x7C, which MPC-HC reclassifies as LATM.'
            Standard    = 'DVB'
            ServiceId   = 0x010B
            ServiceName = 'VT AACD'
            ServiceType = 0x19
            Width       = 1280
            Height      = 720
            FFmpeg = @{
                Video     = @{ Encoder = 'libx264'; Options = @('-preset', 'veryfast', '-b:v', '150k', '-pix_fmt', 'yuv420p') }
                Audio     = @( @{ Encoder = 'aac'; Language = 'eng'; Options = @() } )
                Subtitles = @()
                MuxerOptions = @('-mpegts_flags', '+system_b')
            }
            Tsduck = @{
                # ParsePMT's DT_AAC_AUDIO case sets AUDIO_STREAM_AAC_LATM
                # unconditionally, so an ADTS stream (0x0F) that also carries
                # the descriptor is reported as BDA_LATM. EN 300 468 allows the
                # descriptor on both framings, so real broadcasts reach this.
                # The entry pins the behaviour down; it does not bless it.
                Why      = 'ffmpeg never writes the DVB AAC descriptor; this exercises the DT_AAC_AUDIO override.'
                PatchXml = '<?xml version="1.0" encoding="UTF-8"?><tsduck><PMT><component stream_type="15"><AAC_descriptor x-node="add" profile_and_level="0x50"/></component></PMT></tsduck>'
            }
            Expect = @{
                PcrRequired = $true
                Streams = @(
                    @{ Role = 'video'; StreamType = 0x1B; Descriptors = @();           Bda = 'BDA_H264'; Pes = 'VIDEO_STREAM_H264' }
                    @{ Role = 'audio'; StreamType = 0x0F; Descriptors = @(0x7C, 0x0A); Bda = 'BDA_LATM'; Pes = 'AUDIO_STREAM_AAC_LATM'; Language = 'eng' }
                )
            }
        }

        # ---- Subtitles ----------------------------------------------------

        @{
            Id          = 'mpv-mpa-dvbsub'
            File        = 'mpv-mpa-dvbsub.ts'
            Summary     = 'DVB subtitles: stream_type 0x06 plus subtitling descriptor 0x59.'
            Standard    = 'DVB'
            ServiceId   = 0x010C
            ServiceName = 'VT SUBS'
            ServiceType = 0x01
            FFmpeg = @{
                Video = @{ Encoder = 'mpeg2video'; Options = @() }
                Audio = @( @{ Encoder = 'mp2'; Language = 'eng'; Options = @() } )
                # ffmpeg cannot encode text subtitles to dvbsub - it refuses
                # with "Subtitle encoding currently only possible from text to
                # text or bitmap to bitmap" - so the generator supplies a raw
                # DVB subtitle elementary stream and copies it in through the
                # `dvbsub` demuxer (-f dvbsub -i <file> ... -c:s copy). Source
                # names that file.
                Subtitles = @(
                    @{ Encoder = 'copy'; Format = 'dvbsub'; Source = 'assets/flatcolour.dvbsub'; Language = 'eng'; SubtitlingType = 0x10 }
                )
                MuxerOptions = @('-mpegts_flags', '+system_b')
            }
            Expect = @{
                PcrRequired = $true
                Streams = @(
                    @{ Role = 'video';    StreamType = 0x02; Descriptors = @();     Bda = 'BDA_MPV';      Pes = 'VIDEO_STREAM_MPEG2' }
                    @{ Role = 'audio';    StreamType = 0x03; Descriptors = @(0x0A); Bda = 'BDA_MPA';      Pes = 'AUDIO_STREAM_MPEG1'; Language = 'eng' }
                    @{ Role = 'subtitle'; StreamType = 0x06; Descriptors = @(0x59); Bda = 'BDA_SUBTITLE'; Pes = 'SUBTITLE_STREAM';    Language = 'eng' }
                )
            }
        }

        # ---- Descriptors that decorate rather than classify ----------------

        @{
            Id          = 'mpv-video-stream-descriptor'
            FrameRate   = 50   # must equal frame_rate_code 6 in the patch below
            File        = 'mpv-video-stream-descriptor.ts'
            Summary     = 'video_stream_descriptor 0x02, where MPC-HC gets frame rate and chroma format.'
            Standard    = 'DVB'
            ServiceId   = 0x010D
            ServiceName = 'VT VSD'
            ServiceType = 0x01
            FFmpeg = @{
                Video     = @{ Encoder = 'mpeg2video'; Options = @() }
                Audio     = @( @{ Encoder = 'mp2'; Language = 'eng'; Options = @() } )
                Subtitles = @()
                MuxerOptions = @('-mpegts_flags', '+system_b')
            }
            Tsduck = @{
                # frame_rate_code 6 is 50 fps (BDA_FPS_50_0), deliberately not 3.
                # 3 is 25 fps, which is exactly what ParsePMT invents at
                # Mpeg2SectionData.cpp:603 when no video_stream_descriptor is
                # present -- so an entry claiming 3 cannot prove the descriptor
                # was read, the same defect as the 720x576 raster one field
                # over. With 6, fps "50" is itself proof the descriptor arrived,
                # which is what lets the MPEG_1_only control below mean
                # anything. chroma_format 1 is 4:2:0 (BDA_Chroma_4_2_0).
                # FrameRate is overridden to 50 to match: the descriptor and the
                # elementary stream have to agree or the channel properties lie.
                Why      = 'ffmpeg emits no video_stream_descriptor; without one ParsePMT falls back to BDA_FPS_25_0 and never sets chroma.'
                PatchXml = '<?xml version="1.0" encoding="UTF-8"?><tsduck><PMT><component stream_type="2"><video_stream_descriptor x-node="add" multiple_frame_rate="false" frame_rate_code="6" MPEG_1_only="false" constrained_parameter="false" still_picture="false" profile_and_level_indication="0x48" chroma_format="1" frame_rate_extension="false"/></component></PMT></tsduck>'
            }
            Expect = @{
                PcrRequired = $true
                # Assert the pair, never chroma alone: an empty chroma cannot
                # distinguish a closed MPEG_1_only gate from a descriptor that
                # was never injected, and the latter is a real failure mode
                # here. BDA_FPS_50_0 is what proves the descriptor arrived.
                Video = @{ FrameRateCode = 6; Fps = 'BDA_FPS_50_0'; ChromaFormat = 1; Chroma = 'BDA_Chroma_4_2_0' }
                Streams = @(
                    @{ Role = 'video'; StreamType = 0x02; Descriptors = @(0x02); Bda = 'BDA_MPV'; Pes = 'VIDEO_STREAM_MPEG2' }
                    @{ Role = 'audio'; StreamType = 0x03; Descriptors = @(0x0A); Bda = 'BDA_MPA'; Pes = 'AUDIO_STREAM_MPEG1'; Language = 'eng' }
                )
            }
        }


        @{
            Id          = 'mpv-video-stream-descriptor-422'
            File        = 'mpv-video-stream-descriptor-422.ts'
            # Endianness discriminator, not decoration. MPC-HC decodes the SDT
            # transport_stream_id byte-swapped (0x1000 arrived as 0x0010), and
            # 0x1234 separates the three candidate faults in one scan: a swap
            # reads 13330, a straight read 4660, a truncation 18 -- and no
            # fallback or default produces any of them.
            TransportStreamId = 0x1234
            Summary     = 'video_stream_descriptor 0x02 carrying chroma_format 2, so a wrong chroma cannot hide behind 4:2:0.'
            Standard    = 'DVB'
            ServiceId   = 0x0113
            ServiceName = 'VT VSD422'
            ServiceType = 0x01
            FrameRate   = 50   # must equal frame_rate_code 6 in the patch below
            FFmpeg = @{
                Video     = @{ Encoder = 'mpeg2video'; Options = @() }
                Audio     = @( @{ Encoder = 'mp2'; Language = 'eng'; Options = @() } )
                Subtitles = @()
                MuxerOptions = @('-mpegts_flags', '+system_b')
            }
            Tsduck = @{
                # chroma_format 2 is 4:2:2 (BDA_Chroma_4_2_2).
                Why      = 'ffmpeg emits no video_stream_descriptor; without one ParsePMT falls back to BDA_FPS_25_0 and never sets chroma.'
                PatchXml = '<?xml version="1.0" encoding="UTF-8"?><tsduck><PMT><component stream_type="2"><video_stream_descriptor x-node="add" multiple_frame_rate="false" frame_rate_code="6" MPEG_1_only="false" constrained_parameter="false" still_picture="false" profile_and_level_indication="0x48" chroma_format="2" frame_rate_extension="false"/></component></PMT></tsduck>'
            }
            Expect = @{
                PcrRequired = $true
                # Assert the pair, never chroma alone. An empty chroma cannot by
                # itself distinguish "descriptor present, MPEG_1_only gate closed
                # it" from "nothing injected the descriptor at all" -- and the
                # second is a real failure mode in this repo, not a hypothetical.
                # BDA_FPS_50_0 is what proves the descriptor arrived, because no
                # fallback produces it.
                Video = @{ FrameRateCode = 6; Fps = 'BDA_FPS_50_0'; ChromaFormat = 2; Chroma = 'BDA_Chroma_4_2_2' }
                Streams = @(
                    @{ Role = 'video'; StreamType = 0x02; Descriptors = @(0x02); Bda = 'BDA_MPV'; Pes = 'VIDEO_STREAM_MPEG2' }
                    @{ Role = 'audio'; StreamType = 0x03; Descriptors = @(0x0A); Bda = 'BDA_MPA'; Pes = 'AUDIO_STREAM_MPEG1'; Language = 'eng' }
                )
            }
        }

        @{
            Id          = 'mpv-video-stream-descriptor-444'
            File        = 'mpv-video-stream-descriptor-444.ts'
            Summary     = 'video_stream_descriptor 0x02 carrying chroma_format 3, the top of the 2-bit field.'
            Standard    = 'DVB'
            ServiceId   = 0x0114
            ServiceName = 'VT VSD444'
            ServiceType = 0x01
            FrameRate   = 50   # must equal frame_rate_code 6 in the patch below
            FFmpeg = @{
                Video     = @{ Encoder = 'mpeg2video'; Options = @() }
                Audio     = @( @{ Encoder = 'mp2'; Language = 'eng'; Options = @() } )
                Subtitles = @()
                MuxerOptions = @('-mpegts_flags', '+system_b')
            }
            Tsduck = @{
                # chroma_format 3 is 4:4:4 (BDA_Chroma_4_4_4).
                Why      = 'ffmpeg emits no video_stream_descriptor; without one ParsePMT falls back to BDA_FPS_25_0 and never sets chroma.'
                PatchXml = '<?xml version="1.0" encoding="UTF-8"?><tsduck><PMT><component stream_type="2"><video_stream_descriptor x-node="add" multiple_frame_rate="false" frame_rate_code="6" MPEG_1_only="false" constrained_parameter="false" still_picture="false" profile_and_level_indication="0x48" chroma_format="3" frame_rate_extension="false"/></component></PMT></tsduck>'
            }
            Expect = @{
                PcrRequired = $true
                # Assert the pair, never chroma alone. An empty chroma cannot by
                # itself distinguish "descriptor present, MPEG_1_only gate closed
                # it" from "nothing injected the descriptor at all" -- and the
                # second is a real failure mode in this repo, not a hypothetical.
                # BDA_FPS_50_0 is what proves the descriptor arrived, because no
                # fallback produces it.
                Video = @{ FrameRateCode = 6; Fps = 'BDA_FPS_50_0'; ChromaFormat = 3; Chroma = 'BDA_Chroma_4_4_4' }
                Streams = @(
                    @{ Role = 'video'; StreamType = 0x02; Descriptors = @(0x02); Bda = 'BDA_MPV'; Pes = 'VIDEO_STREAM_MPEG2' }
                    @{ Role = 'audio'; StreamType = 0x03; Descriptors = @(0x0A); Bda = 'BDA_MPA'; Pes = 'AUDIO_STREAM_MPEG1'; Language = 'eng' }
                )
            }
        }

        @{
            Id          = 'mpv-video-stream-descriptor-mpeg1only'
            File        = 'mpv-video-stream-descriptor-mpeg1only.ts'
            Summary     = 'video_stream_descriptor 0x02 with MPEG_1_only set, the gate that stops chroma being read at all.'
            Standard    = 'DVB'
            ServiceId   = 0x0115
            ServiceName = 'VT VSD1ONLY'
            ServiceType = 0x01
            FrameRate   = 50   # must equal frame_rate_code 6 in the patch below
            FFmpeg = @{
                Video     = @{ Encoder = 'mpeg2video'; Options = @() }
                Audio     = @( @{ Encoder = 'mp2'; Language = 'eng'; Options = @() } )
                Subtitles = @()
                MuxerOptions = @('-mpegts_flags', '+system_b')
            }
            Tsduck = @{
                # The control. MPEG_1_only="true" makes the descriptor one byte, and
                # ParsePMT then never reaches SetVideoChroma (the !MPEG_1_only
                # branch at Mpeg2SectionData.cpp:577). Expect chroma exactly ""
                # rather than "not one of the three": if someone later renders an
                # absent chroma as "none" or drops the key, that is a visible
                # change to a public web interface and should break a test.
                Why      = 'ffmpeg emits no video_stream_descriptor; without one ParsePMT falls back to BDA_FPS_25_0 and never sets chroma.'
                PatchXml = '<?xml version="1.0" encoding="UTF-8"?><tsduck><PMT><component stream_type="2"><video_stream_descriptor x-node="add" multiple_frame_rate="false" frame_rate_code="6" MPEG_1_only="true" constrained_parameter="false" still_picture="false"/></component></PMT></tsduck>'
            }
            Expect = @{
                PcrRequired = $true
                # Assert the pair, never chroma alone. An empty chroma cannot by
                # itself distinguish "descriptor present, MPEG_1_only gate closed
                # it" from "nothing injected the descriptor at all" -- and the
                # second is a real failure mode in this repo, not a hypothetical.
                # BDA_FPS_50_0 is what proves the descriptor arrived, because no
                # fallback produces it.
                # ChromaFormat $null: the descriptor carries no chroma field at
                # all when MPEG_1_only is set. BDA_Chroma_NONE says why the value
                # is absent, which '' could not. The harness maps it to the empty
                # string and asserts that on the wire, so a key that vanishes or
                # renders as 'none' still fails.
                Video = @{ FrameRateCode = 6; Fps = 'BDA_FPS_50_0'; ChromaFormat = $null; Chroma = 'BDA_Chroma_NONE' }
                Streams = @(
                    @{ Role = 'video'; StreamType = 0x02; Descriptors = @(0x02); Bda = 'BDA_MPV'; Pes = 'VIDEO_STREAM_MPEG2' }
                    @{ Role = 'audio'; StreamType = 0x03; Descriptors = @(0x0A); Bda = 'BDA_MPA'; Pes = 'AUDIO_STREAM_MPEG1'; Language = 'eng' }
                )
            }
        }

        @{
            Id          = 'mpv-background-grid'
            File        = 'mpv-background-grid.ts'
            Summary     = 'target_background_grid_descriptor 0x07, the only source MPC-HC has for width, height and aspect ratio.'
            Standard    = 'DVB'
            ServiceId   = 0x010E
            ServiceName = 'VT GRID'
            ServiceType = 0x01
            FFmpeg = @{
                Video     = @{ Encoder = 'mpeg2video'; Options = @() }
                Audio     = @( @{ Encoder = 'mp2'; Language = 'eng'; Options = @() } )
                Subtitles = @()
                MuxerOptions = @('-mpegts_flags', '+system_b')
            }
            Tsduck = @{
                # aspect_ratio_information 3 is 16:9 (BDA_AR_9_16). Without the
                # descriptor ParsePMT hardcodes 720x576 for MPEG-2 video and
                # leaves H.264/HEVC at 0x0, so a wrong value here is invisible
                # unless something asserts on it.
                # 704, not 720: ParsePMT guesses 720x576 when the descriptor is
                # absent, so claiming 720 here would make the entry pass whether
                # or not anything parsed it. This is the whole point of the entry.
                Why      = 'ffmpeg emits no target_background_grid_descriptor; ParsePMT otherwise guesses 720x576, so this entry claims 704x576 to stay distinguishable from that fallback.'
                PatchXml = '<?xml version="1.0" encoding="UTF-8"?><tsduck><PMT><component stream_type="2"><target_background_grid_descriptor x-node="add" horizontal_size="704" vertical_size="576" aspect_ratio_information="3"/></component></PMT></tsduck>'
            }
            Expect = @{
                PcrRequired = $true
                # The claim this entry existed to make and never did: the lint's
                # UNASSERTED rule caught it injecting 0x07 while asserting
                # nothing about the result. Width 704 is what proves the
                # descriptor was read -- Height 576 equals the back-fill and
                # could not carry that on its own. AspectRatio comes from
                # aspect_ratio_information 3 in the same descriptor.
                Video = @{ Width = 704; Height = 576; AspectRatio = 'BDA_AR_9_16' }
                Streams = @(
                    @{ Role = 'video'; StreamType = 0x02; Descriptors = @(0x07); Bda = 'BDA_MPV'; Pes = 'VIDEO_STREAM_MPEG2' }
                    @{ Role = 'audio'; StreamType = 0x03; Descriptors = @(0x0A); Bda = 'BDA_MPA'; Pes = 'AUDIO_STREAM_MPEG1'; Language = 'eng' }
                )
            }
        }

        # ---- Service shapes ------------------------------------------------

        @{
            Id          = 'multi-audio-multi-sub'
            File        = 'multi-audio-multi-sub.ts'
            Summary     = 'Three audio tracks in three codecs and two subtitle tracks, all language tagged.'
            Standard    = 'DVB'
            ServiceId   = 0x010F
            ServiceName = 'VT MULTI'
            ServiceType = 0x19
            Width       = 1280
            Height      = 720
            FFmpeg = @{
                Video = @{ Encoder = 'libx264'; Options = @('-preset', 'veryfast', '-b:v', '150k', '-pix_fmt', 'yuv420p') }
                # Mixed codecs on one service is the realistic case - it is
                # what the French and Dutch captures did - and it is the only
                # way to exercise CBDAChannel::AddStreamInfo filling m_Audios
                # with more than one nType.
                Audio = @(
                    @{ Encoder = 'mp2'; Language = 'eng'; Options = @() }
                    @{ Encoder = 'ac3'; Language = 'fra'; Options = @('-b:a', '96k') }
                    @{ Encoder = 'aac'; Language = 'deu'; Options = @() }
                )
                Subtitles = @(
                    @{ Encoder = 'copy'; Format = 'dvbsub'; Source = 'assets/flatcolour.dvbsub'; Language = 'eng'; SubtitlingType = 0x10 }
                    @{ Encoder = 'copy'; Format = 'dvbsub'; Source = 'assets/flatcolour.dvbsub'; Language = 'nld'; SubtitlingType = 0x20 }
                )
                MuxerOptions = @('-mpegts_flags', '+system_b')
            }
            Expect = @{
                PcrRequired = $true
                Streams = @(
                    @{ Role = 'video';    StreamType = 0x1B; Descriptors = @();           Bda = 'BDA_H264';     Pes = 'VIDEO_STREAM_H264' }
                    @{ Role = 'audio';    StreamType = 0x03; Descriptors = @(0x0A);       Bda = 'BDA_MPA';      Pes = 'AUDIO_STREAM_MPEG1'; Language = 'eng' }
                    @{ Role = 'audio';    StreamType = 0x06; Descriptors = @(0x6A, 0x0A); Bda = 'BDA_AC3';      Pes = 'AUDIO_STREAM_AC3';   Language = 'fra' }
                    @{ Role = 'audio';    StreamType = 0x0F; Descriptors = @(0x0A);       Bda = 'BDA_ADTS';     Pes = 'AUDIO_STREAM_AAC';   Language = 'deu' }
                    @{ Role = 'subtitle'; StreamType = 0x06; Descriptors = @(0x59);       Bda = 'BDA_SUBTITLE'; Pes = 'SUBTITLE_STREAM';    Language = 'eng' }
                    @{ Role = 'subtitle'; StreamType = 0x06; Descriptors = @(0x59);       Bda = 'BDA_SUBTITLE'; Pes = 'SUBTITLE_STREAM';    Language = 'nld' }
                )
            }
        }

        @{
            Id          = 'radio-mpa'
            File        = 'radio-mpa.ts'
            Summary     = 'Audio-only DIGITAL_RADIO service with no video PID at all.'
            Standard    = 'DVB'
            ServiceId   = 0x0110
            ServiceName = 'VT RADIO'
            ServiceType = 0x02          # DIGITAL_RADIO
            FFmpeg = @{
                # A radio service has no video stream, so PCR has to ride on
                # the audio PID. That is the interesting part: it is the only
                # entry where GetPCR() and GetVideoPID() cannot be the same
                # value, and the only one where GetVideoPID() stays 0.
                Video     = $null
                Audio     = @( @{ Encoder = 'mp2'; Language = 'eng'; Options = @() } )
                Subtitles = @()
                MuxerOptions = @('-mpegts_flags', '+system_b')
            }
            Expect = @{
                PcrRequired = $true
                Streams = @(
                    @{ Role = 'audio'; StreamType = 0x03; Descriptors = @(0x0A); Bda = 'BDA_MPA'; Pes = 'AUDIO_STREAM_MPEG1'; Language = 'eng' }
                )
            }
        }

        # ---- ATSC ------------------------------------------------------------
        #
        # ffmpeg emits no PSIP at all, so both ATSC entries need TSDuck to
        # inject an MGT and a TVCT on PID 0x1FFB. MPC-HC will not look at a VCT
        # it did not first find announced in the MGT: ParseMGT only sets
        # vctType when a table_type of 0x0000/0x0001 (TVCT current/next) is
        # listed with table_type_PID 0x1FFB.

        @{
            Id          = 'atsc-mpv-ac3'
            File        = 'atsc-mpv-ac3.ts'
            Summary     = 'ATSC SD service: MPEG-2 video and AC-3 as bare stream_type 0x81, announced in an MGT and TVCT.'
            Standard    = 'ATSC'
            ServiceId   = 0x0111
            ServiceName = 'VTATSC'      # TVCT short_name is 7 UTF-16 characters, so keep it short
            ServiceType = 0x02          # ATSC_DIGITAL_TV - the only type ParseVCT accepts
            Atsc = @{
                MajorChannelNumber = 40
                MinorChannelNumber = 1
                SourceId           = 1
                ModulationMode     = '8-VSB'
            }
            # Two constraints, both hard. `tsp -P inject` builds a new PID by
            # stealing null packets, and TSDuck has no plugin that inserts
            # stuffing, so a VBR file offers it nothing to steal and the PSIP
            # silently fails to appear -- the mux rate has to exceed the
            # ~350 kb/s of content to leave any. And the driver refuses to serve
            # a file under 1,173,120 bytes correctly, so ten seconds needs at
            # least ~940 kb/s. 600k satisfied the first and failed the second at
            # 750,872 bytes, which would have played the previous stream's
            # content while reporting locked. 1200k satisfies both, with more
            # stuffing headroom than before rather than less.
            MuxRate = '1200k'
            FFmpeg = @{
                Video     = @{ Encoder = 'mpeg2video'; Options = @() }
                Audio     = @( @{ Encoder = 'ac3'; Language = 'eng'; Options = @('-b:a', '96k') } )
                Subtitles = @()
                MuxerOptions = @()      # no +system_b: ATSC signalling is the point
            }
            Tsduck = @{
                Why        = 'ffmpeg writes no PSIP; MPC-HC reads the MGT and then the TVCT from PID 0x1FFB.'
                InjectPsip = $true
            }
            Expect = @{
                PcrRequired = $true
                Streams = @(
                    @{ Role = 'video'; StreamType = 0x02; Descriptors = @();     Bda = 'BDA_MPV'; Pes = 'VIDEO_STREAM_MPEG2' }
                    @{ Role = 'audio'; StreamType = 0x81; Descriptors = @(0x0A); Bda = 'BDA_AC3'; Pes = 'AUDIO_STREAM_AC3'; Language = 'eng' }
                )
            }
        }

        @{
            Id          = 'atsc-h264-eac3-gap'
            File        = 'atsc-h264-eac3-gap.ts'
            Summary     = 'KNOWN GAP. ATSC E-AC-3 is stream_type 0x87, which MPC-HC does not know, so the audio track vanishes.'
            Standard    = 'ATSC'
            ServiceId   = 0x0112
            ServiceName = 'VTGAP'
            ServiceType = 0x02
            Atsc = @{
                MajorChannelNumber = 40
                MinorChannelNumber = 2
                SourceId           = 2
                ModulationMode     = '8-VSB'
            }
            Width       = 1280
            Height      = 720
            # See atsc-mpv-ac3: stuffing for PSIP injection, and the driver's
            # minimum file size. 600k met the first and not the second.
            MuxRate     = '1200k'
            FFmpeg = @{
                Video     = @{ Encoder = 'libx264'; Options = @('-preset', 'veryfast', '-b:v', '150k', '-pix_fmt', 'yuv420p') }
                Audio     = @( @{ Encoder = 'eac3'; Language = 'eng'; Options = @('-b:a', '96k') } )
                Subtitles = @()
                MuxerOptions = @()
            }
            Tsduck = @{
                Why        = 'ffmpeg writes no PSIP; MPC-HC reads the MGT and then the TVCT from PID 0x1FFB.'
                InjectPsip = $true
            }
            # This entry is expected to fail in MPC-HC and to pass here. The
            # validator checks the transport stream, not the player, and the
            # file genuinely carries 0x87, which is correct ATSC A/53 Part 3
            # signalling for E-AC-3. What is missing is a case for it in
            # MPC-HC's PES_STREAM_TYPE, which stops at AUDIO_STREAM_AC3_PLUS =
            # 0x84 (the Blu-ray value). ConvertToDVBType therefore returns
            # BDA_UNKNOWN, AddStreamInfo is never called, and the service plays
            # with no audio track offered at all.
            KnownGap = 'MPC-HC has no PES_STREAM_TYPE for ATSC E-AC-3 (0x87); expect BDA_UNKNOWN and no audio track.'
            Expect = @{
                PcrRequired = $true

                # Which behaviour the binary has is readable from this entry's
                # own scan, because the entry generates the 0x87 stream itself.
                # An absence is only informative against a mux that actually
                # carried one, which is the condition this entry uniquely meets.
                #
                #   audio[] contains pes 135  -> binary classifies 0x87, gap fixed
                #   audio[] contains no 135   -> ConvertToDVBType returned
                #                                BDA_UNKNOWN, AddStreamInfo never
                #                                called, gap present
                #
                # Deliberately not keyed on deployedHash. A hash says which build
                # ran, not what it does; it changes on every rebuild for reasons
                # unrelated to 0x87, so the table would need updating whenever
                # anyone compiles and a stale row would silently mislabel a run.
                # Provenance from the artefact, not from a table maintained
                # beside it.
                #
                # Verified 2026-08-30: absent at fork branch dvb-json-api (5dd8e312f8) and
                # upstream/develop 9e8db1dc95 (both AUDIO_STREAM_AC3_PLUS = 0x84,
                # DSUtil/Mpeg2Def.h:67); present only on branch atsc-scan, which
                # adds AUDIO_STREAM_EAC3_ATSC = 0x87. A routine rebase does not
                # acquire it.
                GapDiscriminator = @{
                    Role    = 'audio'
                    Field   = 'pes'      # numeric on the wire, the PMT stream_type
                    Value   = 0x87
                    Present = 'gap fixed: this build classifies ATSC E-AC-3'
                    Absent  = 'gap present: the audio track is silently dropped'
                }
                Streams = @(
                    @{ Role = 'video'; StreamType = 0x1B; Descriptors = @();     Bda = 'BDA_H264';    Pes = 'VIDEO_STREAM_H264' }
                    @{ Role = 'audio'; StreamType = 0x87; Descriptors = @(0x0A); Bda = 'BDA_UNKNOWN'; Pes = 'INVALID'; Language = 'eng' }
                )
            }
        }
    )
}
