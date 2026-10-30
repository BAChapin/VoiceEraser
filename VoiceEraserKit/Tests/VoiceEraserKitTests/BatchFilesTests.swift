import Foundation
import Testing
@testable import VoiceEraserKit

struct OutputNamingTests {
    let original = URL(filePath: "/clips/Interview.mov")
    let folder = URL(filePath: "/out", directoryHint: .isDirectory)

    @Test func usesTheNoSpeechNameWhenFree() {
        let destination = OutputNaming.uniqueDestination(for: original, in: folder) { _ in false }
        #expect(destination.path(percentEncoded: false) == "/out/Interview (No Speech).mov")
    }

    @Test func numbersTheNameInsteadOfOverwriting() {
        let taken: Set<String> = ["Interview (No Speech).mov", "Interview (No Speech 2).mov"]
        let destination = OutputNaming.uniqueDestination(for: original, in: folder) { taken.contains($0.lastPathComponent) }
        #expect(destination.lastPathComponent == "Interview (No Speech 3).mov")
    }

    @Test func handlesFilesWithoutExtension() {
        let destination = OutputNaming.uniqueDestination(for: URL(filePath: "/clips/raw"), in: folder) { _ in false }
        #expect(destination.lastPathComponent == "raw (No Speech)")
    }
}

struct MediaFileCollectorTests {
    @Test func expandsFoldersToMediaFilesAndKeepsExplicitFiles() throws {
        let fileManager = FileManager.default
        let root = try TestEnvironment.makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: root) }
        let nested = root.appending(path: "Season 1", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        for path in ["b.mp4", "a.wav", "notes.txt", ".hidden.mp3", "Season 1/episode.mkv"] {
            try Data().write(to: root.appending(path: path))
        }
        let outside = try TestEnvironment.makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: outside) }
        let explicit = outside.appending(path: "readme.txt")
        try Data().write(to: explicit)

        let collected = MediaFileCollector.collect([root, explicit, root.appending(path: "a.wav")])
        #expect(collected.map(\.lastPathComponent) == ["a.wav", "b.mp4", "episode.mkv", "readme.txt"])
    }

    @Test func skipsMissingFiles() {
        #expect(MediaFileCollector.collect([URL(filePath: "/definitely/not/here.mp4")]).isEmpty)
    }

    @Test func recognizesFormatsMacOSMayNotType() {
        #expect(MediaFileCollector.isMediaFile(URL(filePath: "/a/clip.MKV"), contentType: nil))
        #expect(MediaFileCollector.isMediaFile(URL(filePath: "/a/song.opus"), contentType: nil))
        #expect(!MediaFileCollector.isMediaFile(URL(filePath: "/a/notes.txt"), contentType: .plainText))
    }
}
