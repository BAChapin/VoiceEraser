import Foundation

/// Removes speech from decoded audio.
public protocol SpeechRemovalEngine: Sendable {
    /// Sample rate the engine works at. Tracks are resampled to it before
    /// processing and back to their original rate when encoding.
    var sampleRate: Int { get }

    /// Reads `input` and writes the same audio without speech to `output`
    /// (same channel count and length; `output` starts zero-filled).
    func removeSpeech(
        input: MappedPCMFile,
        output: MappedPCMFile,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws
}

/// The user-selectable engines.
public enum SpeechRemovalEngineKind: String, CaseIterable, Identifiable, Sendable {
    case demucs
    case appleVoiceIsolation

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .demucs: "High Quality (Demucs)"
        case .appleVoiceIsolation: "Fast (Apple Voice Isolation)"
        }
    }

    public var summary: String {
        switch self {
        case .demucs:
            "On-device neural source separation. Best at keeping music and effects intact; takes roughly real time or longer."
        case .appleVoiceIsolation:
            "Uses macOS's built-in Voice Isolation to find speech, then masks it out. Much faster, but leaves more speech behind."
        }
    }
}

public enum SpeechRemovalError: LocalizedError, Equatable {
    case modelMissing
    case modelOutputMissing(String)
    case voiceIsolationUnavailable
    case audioUnitFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelMissing:
            "The Demucs model isn't included in this build of VoiceEraser."
        case let .modelOutputMissing(name):
            "The Demucs model didn't return \(name)."
        case .voiceIsolationUnavailable:
            "Apple Voice Isolation isn't available on this Mac."
        case let .audioUnitFailed(detail):
            "Apple Voice Isolation failed: \(detail)"
        }
    }
}

extension MappedPCMFile {
    /// Pairs of channels for engines that work in stereo. An odd channel out
    /// is paired with itself.
    var stereoChannelPairs: [(left: Int, right: Int)] {
        Swift.stride(from: 0, to: channels, by: 2).map { ($0, min($0 + 1, channels - 1)) }
    }
}
