import Foundation

/// Locations of the `ffmpeg` and `ffprobe` executables.
public struct FFmpegTools: Sendable, Equatable {
    public let ffmpeg: URL
    public let ffprobe: URL

    public init(directory: URL) {
        ffmpeg = directory.appending(path: "ffmpeg", directoryHint: .notDirectory)
        ffprobe = directory.appending(path: "ffprobe", directoryHint: .notDirectory)
    }

    /// The copies embedded in an app bundle's `Contents/Helpers` folder.
    public static func bundled(in bundle: Bundle = .main) -> FFmpegTools? {
        let helpers = bundle.bundleURL.appending(path: "Contents/Helpers", directoryHint: .isDirectory)
        return FFmpegTools(directory: helpers).existing
    }

    /// Tools in the directory named by the `VOICEERASER_FFMPEG_DIR` environment
    /// variable (used by tests and command-line runs).
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> FFmpegTools? {
        guard let path = environment["VOICEERASER_FFMPEG_DIR"], !path.isEmpty else { return nil }
        return FFmpegTools(directory: URL(filePath: path, directoryHint: .isDirectory)).existing
    }

    /// `self` if both executables exist, otherwise `nil`.
    public var existing: FFmpegTools? {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: ffmpeg.path(percentEncoded: false)),
              fileManager.isExecutableFile(atPath: ffprobe.path(percentEncoded: false)) else {
            return nil
        }
        return self
    }

    /// Names of the audio encoders this ffmpeg build provides.
    public func audioEncoders() async throws -> Set<String> {
        let result = try await ProcessRunner.run(ffmpeg, arguments: ["-hide_banner", "-encoders"])
        guard result.status == 0 else {
            throw FFmpegError.toolFailed(tool: "ffmpeg", status: result.status, message: result.standardErrorText)
        }
        return Self.parseAudioEncoders(String(data: result.standardOutput, encoding: .utf8) ?? "")
    }

    /// Parses `ffmpeg -encoders` output. Encoder lines look like
    /// ` A....D aac                  AAC (Advanced Audio Coding)`; the first
    /// flag column is `A` for audio.
    static func parseAudioEncoders(_ output: String) -> Set<String> {
        var names = Set<String>()
        var pastHeader = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("------") {
                pastHeader = true
                continue
            }
            guard pastHeader else { continue }
            let fields = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count >= 2, let flags = fields.first, flags.first == "A" else { continue }
            names.insert(String(fields[1]))
        }
        return names
    }
}

public enum FFmpegError: LocalizedError, Equatable {
    case toolsMissing
    case toolFailed(tool: String, status: Int32, message: String)
    case unreadableProbeOutput(String)
    case noAudioStreams

    public var errorDescription: String? {
        switch self {
        case .toolsMissing:
            "FFmpeg is missing from the app bundle."
        case let .toolFailed(tool, status, message):
            "\(tool) failed (exit code \(status)). \(Self.summary(of: message))"
        case let .unreadableProbeOutput(detail):
            "Couldn't read the file's media information: \(detail)"
        case .noAudioStreams:
            "This file has no audio track."
        }
    }

    /// The last few non-empty lines of a tool's error output.
    static func summary(of message: String, lines: Int = 4) -> String {
        message
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(lines)
            .joined(separator: "\n")
    }
}
