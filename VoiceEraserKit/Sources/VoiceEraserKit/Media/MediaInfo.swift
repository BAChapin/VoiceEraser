import Foundation

/// What ffprobe reports about a media file.
public struct MediaInfo: Sendable, Equatable {
    public var url: URL
    /// FFmpeg demuxer name(s), for example `mov,mp4,m4a,3gp,3g2,mj2`.
    public var formatName: String
    public var formatLongName: String?
    public var duration: Double?
    public var startTime: Double?
    public var streams: [MediaStream]

    public var audioStreams: [MediaStream] { streams.filter { $0.kind == .audio } }

    /// True if the file has a real video track (cover art doesn't count).
    public var hasVideo: Bool {
        streams.contains { $0.kind == .video && !$0.isAttachedPicture }
    }

    /// Longest known duration, from the container or any audio stream.
    public var effectiveDuration: Double? {
        ([duration] + audioStreams.map(\.duration)).compactMap(\.self).max()
    }
}

public struct MediaStream: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case audio, video, subtitle, data, attachment, unknown
    }

    /// Absolute stream index in the file (`0:<index>` in FFmpeg terms).
    public var index: Int
    public var kind: Kind
    public var codecName: String?
    public var codecLongName: String?
    public var profile: String?
    public var sampleRate: Int?
    public var channels: Int?
    public var channelLayout: String?
    public var sampleFormat: String?
    public var bitRate: Int?
    public var bitsPerRawSample: Int?
    public var startTime: Double?
    public var duration: Double?
    public var isDefault: Bool
    public var isAttachedPicture: Bool

    public init(
        index: Int,
        kind: Kind,
        codecName: String? = nil,
        codecLongName: String? = nil,
        profile: String? = nil,
        sampleRate: Int? = nil,
        channels: Int? = nil,
        channelLayout: String? = nil,
        sampleFormat: String? = nil,
        bitRate: Int? = nil,
        bitsPerRawSample: Int? = nil,
        startTime: Double? = nil,
        duration: Double? = nil,
        isDefault: Bool = false,
        isAttachedPicture: Bool = false
    ) {
        self.index = index
        self.kind = kind
        self.codecName = codecName
        self.codecLongName = codecLongName
        self.profile = profile
        self.sampleRate = sampleRate
        self.channels = channels
        self.channelLayout = channelLayout
        self.sampleFormat = sampleFormat
        self.bitRate = bitRate
        self.bitsPerRawSample = bitsPerRawSample
        self.startTime = startTime
        self.duration = duration
        self.isDefault = isDefault
        self.isAttachedPicture = isAttachedPicture
    }
}

/// Reads media information with ffprobe.
public enum MediaProbe {
    public static func probe(_ url: URL, tools: FFmpegTools) async throws -> MediaInfo {
        let arguments = [
            "-v", "error",
            "-print_format", "json",
            "-show_format", "-show_streams",
            url.path(percentEncoded: false),
        ]
        let result = try await ProcessRunner.run(tools.ffprobe, arguments: arguments)
        guard result.status == 0 else {
            throw FFmpegError.toolFailed(tool: "ffprobe", status: result.status, message: result.standardErrorText)
        }
        return try parse(result.standardOutput, url: url)
    }

    /// Parses `ffprobe -print_format json -show_format -show_streams` output.
    public static func parse(_ json: Data, url: URL) throws -> MediaInfo {
        let report: ProbeReport
        do {
            report = try JSONDecoder().decode(ProbeReport.self, from: json)
        } catch {
            throw FFmpegError.unreadableProbeOutput(error.localizedDescription)
        }
        let streams = (report.streams ?? []).map { stream in
            MediaStream(
                index: stream.index,
                kind: MediaStream.Kind(rawValue: stream.codecType ?? "") ?? .unknown,
                codecName: stream.codecName,
                codecLongName: stream.codecLongName,
                profile: stream.profile,
                sampleRate: stream.sampleRate.flatMap { Int($0) },
                channels: stream.channels,
                channelLayout: stream.channelLayout,
                sampleFormat: stream.sampleFmt,
                bitRate: stream.bitRate.flatMap { Int($0) },
                bitsPerRawSample: stream.bitsPerRawSample.flatMap { Int($0) },
                startTime: stream.startTime.flatMap { Double($0) },
                duration: stream.duration.flatMap { Double($0) },
                isDefault: stream.disposition?["default"] == 1,
                isAttachedPicture: stream.disposition?["attached_pic"] == 1
            )
        }
        return MediaInfo(
            url: url,
            formatName: report.format?.formatName ?? "",
            formatLongName: report.format?.formatLongName,
            duration: report.format?.duration.flatMap { Double($0) },
            startTime: report.format?.startTime.flatMap { Double($0) },
            streams: streams
        )
    }
}

/// ffprobe's JSON. Numeric values other than `index` and `channels` are
/// reported as strings.
private struct ProbeReport: Decodable {
    var streams: [ProbeStream]?
    var format: ProbeFormat?
}

private struct ProbeStream: Decodable {
    var index: Int
    var codecName: String?
    var codecLongName: String?
    var profile: String?
    var codecType: String?
    var sampleFmt: String?
    var sampleRate: String?
    var channels: Int?
    var channelLayout: String?
    var bitsPerRawSample: String?
    var bitRate: String?
    var startTime: String?
    var duration: String?
    var disposition: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case index
        case codecName = "codec_name"
        case codecLongName = "codec_long_name"
        case profile
        case codecType = "codec_type"
        case sampleFmt = "sample_fmt"
        case sampleRate = "sample_rate"
        case channels
        case channelLayout = "channel_layout"
        case bitsPerRawSample = "bits_per_raw_sample"
        case bitRate = "bit_rate"
        case startTime = "start_time"
        case duration
        case disposition
    }
}

private struct ProbeFormat: Decodable {
    var formatName: String?
    var formatLongName: String?
    var startTime: String?
    var duration: String?

    enum CodingKeys: String, CodingKey {
        case formatName = "format_name"
        case formatLongName = "format_long_name"
        case startTime = "start_time"
        case duration
    }
}
