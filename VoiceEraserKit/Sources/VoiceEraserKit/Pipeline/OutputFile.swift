import Foundation

/// A processed file waiting in a scratch folder until it replaces the
/// original or is saved somewhere else.
public struct ScratchOutput: Sendable, Equatable {
    public let url: URL
    private let directory: URL

    /// A scratch file with `original`'s extension, on the same volume as
    /// `original` when possible so replacing it is an atomic rename.
    public init(near original: URL) throws {
        let fileManager = FileManager.default
        let directory: URL
        if let replacement = try? fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: original, create: true) {
            directory = replacement
        } else {
            directory = fileManager.temporaryDirectory.appending(path: "VoiceEraser-out-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        self.directory = directory
        let name = original.deletingPathExtension().lastPathComponent
        url = directory.appending(path: original.pathExtension.isEmpty ? name : "\(name).\(original.pathExtension)", directoryHint: .notDirectory)
    }

    /// Atomically replaces `original` with the processed file, keeping the
    /// original's file attributes, then removes the scratch folder.
    @discardableResult
    public func replace(_ original: URL) throws -> URL {
        defer { discard() }
        return try FileManager.default.replaceItemAt(original, withItemAt: url) ?? original
    }

    /// Moves the processed file to `destination`, replacing any file there
    /// (the save panel has already asked), then removes the scratch folder.
    public func move(to destination: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: url)
        } else {
            try fileManager.moveItem(at: url, to: destination)
        }
        discard()
    }

    /// Deletes the scratch folder and anything left in it.
    public func discard() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// `<name> (No Speech).<ext>` for the save panel.
    public static func suggestedFileName(for original: URL) -> String {
        let name = original.deletingPathExtension().lastPathComponent
        let ext = original.pathExtension
        return ext.isEmpty ? "\(name) (No Speech)" : "\(name) (No Speech).\(ext)"
    }
}
