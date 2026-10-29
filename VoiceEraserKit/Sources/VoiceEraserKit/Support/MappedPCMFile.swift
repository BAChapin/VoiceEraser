import Darwin
import Foundation

/// A raw interleaved 32-bit float PCM file mapped into memory, so engines can
/// read and write any position without loading hour-long tracks into RAM.
public final class MappedPCMFile: @unchecked Sendable {
    public let url: URL
    public let channels: Int
    public let frameCount: Int
    public let isWritable: Bool
    private let base: UnsafeMutablePointer<Float>?
    private let byteCount: Int

    /// Opens an existing file for reading.
    public convenience init(readingFrom url: URL, channels: Int) throws {
        try self.init(url: url, channels: channels, frameCount: nil)
    }

    /// Creates (or truncates) a zero-filled file of `frameCount` frames for
    /// writing.
    public convenience init(creating url: URL, channels: Int, frameCount: Int) throws {
        try self.init(url: url, channels: channels, frameCount: frameCount)
    }

    private init(url: URL, channels: Int, frameCount newFrameCount: Int?) throws {
        precondition(channels > 0, "channels must be positive")
        self.url = url
        self.channels = channels
        isWritable = newFrameCount != nil
        let path = url.path(percentEncoded: false)
        let stride = MemoryLayout<Float>.size * channels

        let descriptor = isWritable ? open(path, O_RDWR | O_CREAT | O_TRUNC, 0o644) : open(path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }

        if let newFrameCount {
            frameCount = newFrameCount
            byteCount = newFrameCount * stride
            guard ftruncate(descriptor, off_t(byteCount)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } else {
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            frameCount = Int(info.st_size) / stride
            byteCount = frameCount * stride
        }

        guard byteCount > 0 else {
            base = nil
            return
        }
        let protection = isWritable ? PROT_READ | PROT_WRITE : PROT_READ
        let mapping = mmap(nil, byteCount, protection, MAP_SHARED, descriptor, 0)
        guard let mapping, mapping != UnsafeMutableRawPointer(bitPattern: -1) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOMEM) }
        base = mapping.bindMemory(to: Float.self, capacity: byteCount / MemoryLayout<Float>.size)
    }

    deinit {
        if let base {
            if isWritable { msync(base, byteCount, MS_SYNC) }
            munmap(base, byteCount)
        }
    }

    /// Interleaved samples (`frameCount * channels`).
    public var samples: UnsafeBufferPointer<Float> {
        UnsafeBufferPointer(start: base, count: base == nil ? 0 : frameCount * channels)
    }

    /// Writable interleaved samples. Only valid for files opened for writing.
    public var mutableSamples: UnsafeMutableBufferPointer<Float> {
        precondition(isWritable, "file is read-only")
        return UnsafeMutableBufferPointer(start: base, count: base == nil ? 0 : frameCount * channels)
    }

    /// Copies `count` frames of `channel` starting at `start` into
    /// `destination`. Frames outside the file read as zero.
    public func read(channel: Int, from start: Int, count: Int, into destination: UnsafeMutablePointer<Float>) {
        let source = samples
        for offset in 0..<count {
            let frame = start + offset
            destination[offset] = (frame >= 0 && frame < frameCount) ? source[frame * channels + channel] : 0
        }
    }

    /// Writes `count` frames of `channel` starting at `start` from `source`,
    /// ignoring frames outside the file.
    public func write(channel: Int, at start: Int, count: Int, from source: UnsafePointer<Float>) {
        let destination = mutableSamples
        for offset in 0..<count {
            let frame = start + offset
            guard frame >= 0, frame < frameCount else { continue }
            destination[frame * channels + channel] = source[offset]
        }
    }

    /// Flushes written samples to disk.
    public func synchronize() {
        if let base, isWritable { msync(base, byteCount, MS_SYNC) }
    }
}
