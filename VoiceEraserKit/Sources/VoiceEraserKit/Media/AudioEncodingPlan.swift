import Foundation

/// How one processed audio track is encoded back into the output file.
public struct AudioEncodingPlan: Sendable, Equatable {
    /// FFmpeg encoder name, for example `aac_at` or `libmp3lame`.
    public var encoder: String
    public var sampleRate: Int
    public var channels: Int
    /// Channel layout to tag the output with, when the channel count is
    /// unchanged and the source layout is known.
    public var channelLayout: String?
    /// Target bitrate for lossy encoders.
    public var bitRate: Int?
    public var sampleFormat: String?
    public var profile: String?

    /// Chooses an encoder and settings for `stream` in an output file with
    /// extension `containerExtension`, using only encoders this ffmpeg build
    /// has. Keeps the source codec when possible, otherwise falls back to the
    /// container's usual codec.
    public static func make(
        for stream: MediaStream,
        containerExtension: String,
        availableEncoders: Set<String>
    ) -> AudioEncodingPlan {
        let ext = containerExtension.lowercased()
        let sourceCodec = stream.codecName ?? ""
        let encoder = preferredEncoders(forCodec: sourceCodec).first { availableEncoders.contains($0) && isAllowed($0, in: ext) }
            ?? fallbackEncoders(forExtension: ext).first { availableEncoders.contains($0) }
            ?? "aac"
        let keptSourceCodec = preferredEncoders(forCodec: sourceCodec).contains(encoder)

        let sourceChannels = max(stream.channels ?? 2, 1)
        let channels = min(sourceChannels, maxChannels(for: encoder))
        let sampleRate = supportedSampleRate(for: encoder, preferred: stream.sampleRate ?? 48_000)

        var plan = AudioEncodingPlan(
            encoder: encoder,
            sampleRate: sampleRate,
            channels: channels,
            channelLayout: channels == sourceChannels ? stream.channelLayout : nil
        )
        if isLossy(encoder) {
            let sourceBitRate = keptSourceCodec ? stream.bitRate : nil
            plan.bitRate = sourceBitRate.map { clampBitRate($0, encoder: encoder) } ?? defaultBitRate(for: encoder, channels: channels)
        }
        plan.sampleFormat = sampleFormat(for: encoder, bitsPerRawSample: stream.bitsPerRawSample, sourceFormat: stream.sampleFormat)
        if encoder == "aac_at", keptSourceCodec {
            plan.profile = audioToolboxAACProfile(for: stream.profile, channels: channels)
        }
        return plan
    }

    // MARK: - Tables

    /// Encoders that produce `codec`, best first.
    static func preferredEncoders(forCodec codec: String) -> [String] {
        switch codec {
        case "aac": ["aac_at", "aac"]
        case "mp3": ["libmp3lame"]
        case "opus": ["libopus", "opus"]
        case "vorbis": ["libvorbis", "vorbis"]
        case "dts": ["dca"]
        case "alac": ["alac", "alac_at"]
        case "pcm_alaw": ["pcm_alaw", "pcm_alaw_at"]
        case "pcm_mulaw": ["pcm_mulaw", "pcm_mulaw_at"]
        case "ilbc": ["ilbc_at"]
        case "": []
        default: [codec]
        }
    }

    /// Container-appropriate encoders to use when the source codec can't be
    /// re-encoded, best first.
    static func fallbackEncoders(forExtension ext: String) -> [String] {
        switch ext {
        case "webm", "opus": ["libopus", "opus", "libvorbis", "vorbis"]
        case "ogg", "oga": ["libvorbis", "vorbis", "libopus", "opus", "flac"]
        case "mp3": ["libmp3lame"]
        case "wav", "w64": ["pcm_s16le"]
        case "aif", "aiff", "aifc": ["pcm_s16be"]
        case "flac": ["flac"]
        case "wma", "wmv", "asf": ["wmav2"]
        case "avi": ["libmp3lame", "ac3", "pcm_s16le"]
        case "ac3": ["ac3"]
        case "mpg", "mpeg", "vob": ["mp2", "ac3"]
        default: ["aac_at", "aac"]
        }
    }

    /// Encoders a container can't hold even though FFmpeg has them.
    static func isAllowed(_ encoder: String, in ext: String) -> Bool {
        switch ext {
        case "webm": ["libopus", "opus", "libvorbis", "vorbis"].contains(encoder)
        case "opus": ["libopus", "opus"].contains(encoder)
        case "m4a", "m4b": ["aac_at", "aac", "alac", "alac_at"].contains(encoder)
        case "mp3": encoder == "libmp3lame"
        default: true
        }
    }

    static func maxChannels(for encoder: String) -> Int {
        switch encoder {
        case "libmp3lame", "mp2", "vorbis", "opus", "wmav1", "wmav2", "ilbc_at": 2
        case "ac3", "eac3", "dca": 6
        default: 8
        }
    }

    static func supportedSampleRate(for encoder: String, preferred: Int) -> Int {
        let allowed: [Int]
        switch encoder {
        case "libopus", "opus": allowed = [48_000]
        case "ac3", "eac3": allowed = [32_000, 44_100, 48_000]
        case "libmp3lame", "mp2": allowed = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]
        case "aac_at", "aac": allowed = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000, 64_000, 88_200, 96_000]
        default: return preferred
        }
        if allowed.contains(preferred) { return preferred }
        // Nearest rate at or above the source, else the highest allowed.
        return allowed.first { $0 >= preferred } ?? allowed.last ?? preferred
    }

    static func isLossy(_ encoder: String) -> Bool {
        [
            "aac_at", "aac", "libmp3lame", "mp2", "libopus", "opus", "libvorbis", "vorbis",
            "ac3", "eac3", "dca", "wmav1", "wmav2",
        ].contains(encoder)
    }

    static func defaultBitRate(for encoder: String, channels: Int) -> Int {
        switch encoder {
        case "libmp3lame", "mp2": channels == 1 ? 128_000 : 192_000
        case "ac3", "eac3": channels > 2 ? 448_000 : 192_000
        case "dca": 768_000
        case "libopus", "opus": min(64_000 * channels, 510_000)
        default: min(96_000 * channels, 512_000)
        }
    }

    static func clampBitRate(_ bitRate: Int, encoder: String) -> Int {
        switch encoder {
        case "libmp3lame", "mp2": min(max(bitRate, 32_000), 320_000)
        case "libopus", "opus": min(max(bitRate, 6_000), 510_000)
        default: max(bitRate, 16_000)
        }
    }

    /// Keeps high-resolution sources at high resolution for lossless and PCM
    /// encoders that would otherwise default to 16-bit.
    static func sampleFormat(for encoder: String, bitsPerRawSample: Int?, sourceFormat: String?) -> String? {
        let highResolution = (bitsPerRawSample ?? 0) > 16 || ["s32", "s32p", "flt", "fltp", "dbl", "dblp"].contains(sourceFormat ?? "")
        switch encoder {
        case "flac": return highResolution ? "s32" : "s16"
        case "alac": return highResolution ? "s32p" : "s16p"
        default: return nil
        }
    }

    static func audioToolboxAACProfile(for profile: String?, channels: Int) -> String? {
        switch profile {
        case "HE-AAC": "aac_he"
        case "HE-AACv2": channels == 2 ? "aac_he_v2" : "aac_he"
        default: nil
        }
    }
}
