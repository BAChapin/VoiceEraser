import Foundation
import Testing
@testable import VoiceEraserKit

struct MediaProbeTests {
    static let json = """
    {
      "streams": [
        {"index": 0, "codec_name": "h264", "codec_type": "video", "disposition": {"default": 1, "attached_pic": 0}},
        {"index": 1, "codec_name": "aac", "profile": "LC", "codec_type": "audio", "sample_fmt": "fltp",
         "sample_rate": "48000", "channels": 2, "channel_layout": "stereo", "bit_rate": "192000",
         "start_time": "0.021333", "duration": "60.010667", "disposition": {"default": 1, "attached_pic": 0}},
        {"index": 2, "codec_name": "ac3", "codec_type": "audio", "sample_rate": "48000", "channels": 6,
         "channel_layout": "5.1(side)", "disposition": {"default": 0}},
        {"index": 3, "codec_name": "mov_text", "codec_type": "subtitle"},
        {"index": 4, "codec_name": "mjpeg", "codec_type": "video", "disposition": {"attached_pic": 1}}
      ],
      "format": {"format_name": "mov,mp4,m4a,3gp,3g2,mj2", "start_time": "0.000000", "duration": "60.032000"}
    }
    """

    @Test func parsesStreamsAndFormat() throws {
        let url = URL(filePath: "/tmp/movie.mp4")
        let info = try MediaProbe.parse(Data(Self.json.utf8), url: url)
        #expect(info.formatName == "mov,mp4,m4a,3gp,3g2,mj2")
        #expect(info.duration == 60.032)
        #expect(info.streams.count == 5)
        #expect(info.audioStreams.map(\.index) == [1, 2])
        #expect(info.hasVideo)

        let aac = info.audioStreams[0]
        #expect(aac.codecName == "aac")
        #expect(aac.sampleRate == 48_000)
        #expect(aac.channels == 2)
        #expect(aac.bitRate == 192_000)
        #expect(aac.startTime == 0.021333)
        #expect(aac.isDefault)
        #expect(info.audioStreams[1].isDefault == false)
        #expect(info.streams[4].isAttachedPicture)
        #expect(info.streams[3].kind == .subtitle)
    }

    @Test func coverArtAloneIsNotVideo() throws {
        let json = """
        {"streams": [{"index": 0, "codec_type": "audio", "codec_name": "mp3"},
                     {"index": 1, "codec_type": "video", "codec_name": "png", "disposition": {"attached_pic": 1}}],
         "format": {"format_name": "mp3"}}
        """
        let info = try MediaProbe.parse(Data(json.utf8), url: URL(filePath: "/tmp/song.mp3"))
        #expect(info.hasVideo == false)
    }

    @Test func rejectsGarbage() {
        #expect(throws: FFmpegError.self) {
            try MediaProbe.parse(Data("not json".utf8), url: URL(filePath: "/tmp/x"))
        }
    }

    @Test func parsesEncoderList() {
        let output = """
        Encoders:
         V..... = Video
         A..... = Audio
         ------
         V....D libx264              libx264 H.264
         A....D aac                  AAC (Advanced Audio Coding)
         A....D aac_at               aac (AudioToolbox) (codec aac)
         A....D libmp3lame           libmp3lame MP3 (MPEG audio layer 3) (codec mp3)
         S..... srt                  SubRip subtitle
        """
        #expect(FFmpegTools.parseAudioEncoders(output) == ["aac", "aac_at", "libmp3lame"])
    }
}

struct AudioEncodingPlanTests {
    static let allEncoders: Set<String> = [
        "aac", "aac_at", "libmp3lame", "opus", "vorbis", "flac", "alac", "pcm_s16le", "pcm_s24le", "pcm_s16be", "ac3", "eac3", "mp2", "wmav2",
    ]

    @Test func keepsAACWithAudioToolboxAndSourceBitrate() {
        let stream = MediaStream(index: 1, kind: .audio, codecName: "aac", sampleRate: 48_000, channels: 2, channelLayout: "stereo", bitRate: 192_000)
        let plan = AudioEncodingPlan.make(for: stream, containerExtension: "mp4", availableEncoders: Self.allEncoders)
        #expect(plan.encoder == "aac_at")
        #expect(plan.bitRate == 192_000)
        #expect(plan.sampleRate == 48_000)
        #expect(plan.channels == 2)
        #expect(plan.channelLayout == "stereo")
    }

    @Test func heAACKeepsItsProfile() {
        let stream = MediaStream(index: 0, kind: .audio, codecName: "aac", profile: "HE-AAC", sampleRate: 44_100, channels: 2)
        let plan = AudioEncodingPlan.make(for: stream, containerExtension: "m4a", availableEncoders: Self.allEncoders)
        #expect(plan.profile == "aac_he")
    }

    @Test func mp3UsesLameAndDownmixesSurround() {
        let stream = MediaStream(index: 0, kind: .audio, codecName: "mp3", sampleRate: 44_100, channels: 6, channelLayout: "5.1")
        let plan = AudioEncodingPlan.make(for: stream, containerExtension: "mp3", availableEncoders: Self.allEncoders)
        #expect(plan.encoder == "libmp3lame")
        #expect(plan.channels == 2)
        #expect(plan.channelLayout == nil)
        #expect(plan.bitRate == 192_000)
    }

    @Test func highResolutionFLACStays24Bit() {
        let stream = MediaStream(index: 0, kind: .audio, codecName: "flac", sampleRate: 96_000, channels: 2, sampleFormat: "s32", bitsPerRawSample: 24)
        let plan = AudioEncodingPlan.make(for: stream, containerExtension: "flac", availableEncoders: Self.allEncoders)
        #expect(plan.encoder == "flac")
        #expect(plan.sampleFormat == "s32")
        #expect(plan.bitRate == nil)
        #expect(plan.sampleRate == 96_000)
    }

    @Test func pcmCodecIsKeptExactly() {
        let stream = MediaStream(index: 0, kind: .audio, codecName: "pcm_s24le", sampleRate: 48_000, channels: 2)
        let plan = AudioEncodingPlan.make(for: stream, containerExtension: "wav", availableEncoders: Self.allEncoders)
        #expect(plan.encoder == "pcm_s24le")
        #expect(plan.bitRate == nil)
    }

    @Test func codecWithoutEncoderFallsBackForTheContainer() {
        let amr = MediaStream(index: 0, kind: .audio, codecName: "amr_nb", sampleRate: 8_000, channels: 1)
        #expect(AudioEncodingPlan.make(for: amr, containerExtension: "3gp", availableEncoders: Self.allEncoders).encoder == "aac_at")
        let truehd = MediaStream(index: 0, kind: .audio, codecName: "truehd", sampleRate: 48_000, channels: 8)
        let webm = AudioEncodingPlan.make(for: truehd, containerExtension: "webm", availableEncoders: Self.allEncoders)
        #expect(webm.encoder == "opus")
        #expect(webm.channels == 2)
        #expect(webm.sampleRate == 48_000)
    }

    @Test func containerRestrictionsWinOverSourceCodec() {
        // FLAC audio in an .m4a can't be re-encoded as FLAC there.
        let stream = MediaStream(index: 0, kind: .audio, codecName: "flac", sampleRate: 44_100, channels: 2)
        #expect(AudioEncodingPlan.make(for: stream, containerExtension: "m4a", availableEncoders: Self.allEncoders).encoder == "aac_at")
    }

    @Test func opusIsResampledTo48kHz() {
        let stream = MediaStream(index: 0, kind: .audio, codecName: "opus", sampleRate: 44_100, channels: 2)
        let plan = AudioEncodingPlan.make(for: stream, containerExtension: "mkv", availableEncoders: Self.allEncoders)
        #expect(plan.encoder == "opus")
        #expect(plan.sampleRate == 48_000)
    }

    @Test func plainAACWhenAudioToolboxIsMissing() {
        let stream = MediaStream(index: 0, kind: .audio, codecName: "aac", sampleRate: 48_000, channels: 2)
        #expect(AudioEncodingPlan.make(for: stream, containerExtension: "mov", availableEncoders: ["aac"]).encoder == "aac")
    }
}

struct FFmpegCommandsTests {
    static let media = MediaInfo(
        url: URL(filePath: "/in/movie.mov"),
        formatName: "mov,mp4,m4a,3gp,3g2,mj2",
        duration: 10,
        startTime: 0,
        streams: [
            MediaStream(index: 0, kind: .video, codecName: "h264"),
            MediaStream(index: 1, kind: .audio, codecName: "aac", sampleRate: 48_000, channels: 2, channelLayout: "stereo", isDefault: true),
            MediaStream(index: 2, kind: .data, codecName: "none"),
            MediaStream(index: 3, kind: .audio, codecName: "aac", sampleRate: 44_100, channels: 1, channelLayout: "mono", startTime: 0.5),
        ]
    )

    @Test func decodeKeepsChannelsAndResamples() {
        let stream = Self.media.streams[1]
        let args = FFmpegCommands.decodeArguments(input: Self.media.url, stream: stream, sampleRate: 44_100, output: URL(filePath: "/tmp/a.f32"))
        #expect(args.contains("0:1"))
        #expect(args.containsSequence(["-ar", "44100"]))
        #expect(args.containsSequence(["-f", "f32le"]))
        #expect(!args.contains("-ac"))
        #expect(args.last == "/tmp/a.f32")
    }

    @Test func muxReplacesAudioInOriginalOrder() {
        let tracks = [
            ProcessedAudioTrack(source: Self.media.streams[1], url: URL(filePath: "/tmp/t0.f32"), sampleRate: 44_100, channels: 2),
            ProcessedAudioTrack(source: Self.media.streams[3], url: URL(filePath: "/tmp/t1.f32"), sampleRate: 44_100, channels: 1),
        ]
        let plans = tracks.map {
            AudioEncodingPlan.make(for: $0.source, containerExtension: "mov", availableEncoders: ["aac_at"])
        }
        let args = FFmpegCommands.muxArguments(
            input: Self.media.url, media: Self.media, tracks: tracks, plans: plans, policy: .everything, output: URL(filePath: "/out/movie.mov")
        )
        #expect(args.containsSequence(["-f", "f32le", "-ar", "44100", "-ch_layout", "stereo", "-i", "/tmp/t0.f32"]))
        #expect(args.containsSequence(["-itsoffset", "0.500000", "-f", "f32le", "-ar", "44100", "-ch_layout", "mono", "-i", "/tmp/t1.f32"]))
        #expect(args.containsSequence(["-map", "0:0", "-map", "1:a:0", "-map", "0:2", "-map", "2:a:0"]))
        #expect(args.containsSequence(["-c:a:0", "aac_at", "-ar:a:0", "48000", "-ch_layout:a:0", "stereo"]))
        #expect(args.containsSequence(["-c:a:1", "aac_at", "-ar:a:1", "44100", "-ch_layout:a:1", "mono"]))
        #expect(args.containsSequence(["-map_metadata:s:a:1", "0:s:3", "-disposition:a:1", "0"]))
        #expect(args.containsSequence(["-disposition:a:0", "default"]))
        #expect(args.last == "/out/movie.mov")
        // Copying must come before the per-stream audio codecs so they win.
        let copyIndex = args.firstIndex(of: "copy") ?? .max
        let codecIndex = args.firstIndex(of: "-c:a:0") ?? .min
        #expect(copyIndex < codecIndex)
    }

    @Test func fallbackPoliciesDropDataThenSubtitles() {
        #expect(StreamCopyPolicy.everything.includes(.data))
        #expect(!StreamCopyPolicy.withoutData.includes(.data))
        #expect(StreamCopyPolicy.withoutData.includes(.subtitle))
        #expect(!StreamCopyPolicy.withoutDataOrSubtitles.includes(.subtitle))
        #expect(StreamCopyPolicy.withoutDataOrSubtitles.includes(.video))
        #expect(!StreamCopyPolicy.everything.includes(.audio))
    }

    @Test func parsesProgressLines() {
        #expect(FFmpegCommands.progressSeconds(fromLine: "out_time_us=2500000") == 2.5)
        #expect(FFmpegCommands.progressSeconds(fromLine: "out_time_ms=1000000") == 1)
        #expect(FFmpegCommands.progressSeconds(fromLine: "out_time=00:00:02.50") == nil)
        #expect(FFmpegCommands.progressSeconds(fromLine: "out_time_us=N/A") == nil)
        #expect(FFmpegCommands.progressSeconds(fromLine: "progress=continue") == nil)
    }

    @Test func suggestedNameKeepsExtension() {
        #expect(ScratchOutput.suggestedFileName(for: URL(filePath: "/a/My Clip.mkv")) == "My Clip (No Speech).mkv")
    }
}

extension Array where Element: Equatable {
    /// True if `sequence` appears contiguously.
    func containsSequence(_ sequence: [Element]) -> Bool {
        guard !sequence.isEmpty, sequence.count <= count else { return sequence.isEmpty }
        return (0...(count - sequence.count)).contains { Array(self[$0..<($0 + sequence.count)]) == sequence }
    }
}
