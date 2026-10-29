import Foundation

/// A processed audio track waiting to be muxed: raw interleaved 32-bit float
/// PCM in `url`, replacing `source` in the output.
public struct ProcessedAudioTrack: Sendable, Equatable {
    public var source: MediaStream
    public var url: URL
    public var sampleRate: Int
    public var channels: Int

    public init(source: MediaStream, url: URL, sampleRate: Int, channels: Int) {
        self.source = source
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// Which non-audio streams to carry into the output. Muxing is retried with
/// each policy in turn when a container rejects a stream.
public enum StreamCopyPolicy: CaseIterable, Sendable {
    case everything
    case withoutData
    case withoutDataOrSubtitles

    func includes(_ kind: MediaStream.Kind) -> Bool {
        switch (self, kind) {
        case (_, .video): true
        case (_, .audio), (_, .unknown): false
        case (.everything, _): true
        case (.withoutData, .data), (.withoutData, .attachment): false
        case (.withoutData, .subtitle): true
        case (.withoutDataOrSubtitles, _): false
        }
    }
}

/// Builds ffmpeg argument lists.
public enum FFmpegCommands {
    private static let common = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y"]

    /// Decodes one audio stream to raw interleaved float32 PCM at
    /// `sampleRate`, keeping the stream's channel count and order (stereo if
    /// ffprobe didn't report a channel count).
    public static func decodeArguments(input: URL, stream: MediaStream, sampleRate: Int, output: URL) -> [String] {
        var args = common + [
            "-i", input.path(percentEncoded: false),
            "-map", "0:\(stream.index)",
            "-c:a", "pcm_f32le",
            "-ar", String(sampleRate),
        ]
        if stream.channels == nil {
            args += ["-ac", "2"]
        }
        return args + ["-f", "f32le", "-progress", "pipe:1", "-nostats", output.path(percentEncoded: false)]
    }

    /// Channel count of the raw PCM `decodeArguments` produces.
    public static func decodedChannelCount(for stream: MediaStream) -> Int {
        stream.channels ?? 2
    }

    /// Writes `output`: every stream of `input` that `policy` keeps, copied,
    /// in the original order, with each audio stream replaced by its
    /// processed track and re-encoded according to `plans` (parallel to
    /// `tracks`).
    public static func muxArguments(
        input: URL,
        media: MediaInfo,
        tracks: [ProcessedAudioTrack],
        plans: [AudioEncodingPlan],
        policy: StreamCopyPolicy,
        output: URL
    ) -> [String] {
        precondition(tracks.count == plans.count, "one encoding plan per track")
        var args = common + ["-i", input.path(percentEncoded: false)]

        let baseStart = media.startTime ?? 0
        for track in tracks {
            let offset = (track.source.startTime ?? baseStart) - baseStart
            if abs(offset) > 0.000_5 {
                args += ["-itsoffset", String(format: "%.6f", offset)]
            }
            args += ["-f", "f32le", "-ar", String(track.sampleRate)]
            if let layout = track.source.channelLayout, (track.source.channels ?? track.channels) == track.channels {
                args += ["-ch_layout", layout]
            } else {
                args += ["-ac", String(track.channels)]
            }
            args += ["-i", track.url.path(percentEncoded: false)]
        }

        args += ["-map_metadata", "0", "-map_chapters", "0"]
        let trackByStream = Dictionary(uniqueKeysWithValues: tracks.enumerated().map { ($1.source.index, $0) })
        for stream in media.streams {
            if let trackNumber = trackByStream[stream.index] {
                args += ["-map", "\(trackNumber + 1):a:0"]
            } else if policy.includes(stream.kind) {
                args += ["-map", "0:\(stream.index)"]
            }
        }

        args += ["-c", "copy"]
        let outputAudioOrder = media.streams.compactMap { trackByStream[$0.index] }
        for (audioIndex, trackNumber) in outputAudioOrder.enumerated() {
            let plan = plans[trackNumber]
            let source = tracks[trackNumber].source
            let spec = "a:\(audioIndex)"
            args += ["-c:\(spec)", plan.encoder, "-ar:\(spec)", String(plan.sampleRate)]
            if let layout = plan.channelLayout {
                args += ["-ch_layout:\(spec)", layout]
            } else {
                args += ["-ac:\(spec)", String(plan.channels)]
            }
            if let bitRate = plan.bitRate {
                args += ["-b:\(spec)", String(bitRate)]
            }
            if let sampleFormat = plan.sampleFormat {
                args += ["-sample_fmt:\(spec)", sampleFormat]
            }
            if let profile = plan.profile {
                args += ["-profile:\(spec)", profile]
            }
            args += [
                "-map_metadata:s:\(spec)", "0:s:\(source.index)",
                "-disposition:\(spec)", source.isDefault ? "default" : "0",
            ]
        }

        args += ["-strict", "experimental", "-progress", "pipe:1", "-nostats", output.path(percentEncoded: false)]
        return args
    }

    /// Parses an `ffmpeg -progress` line, returning the output position in
    /// seconds for `out_time_us=` / `out_time_ms=` lines (both are in
    /// microseconds).
    public static func progressSeconds(fromLine line: String) -> Double? {
        let parts = line.split(separator: "=", maxSplits: 1)
        guard parts.count == 2, parts[0] == "out_time_us" || parts[0] == "out_time_ms",
              let micros = Double(parts[1].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return max(micros / 1_000_000, 0)
    }
}
