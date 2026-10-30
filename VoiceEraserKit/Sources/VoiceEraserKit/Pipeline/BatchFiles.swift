import Foundation
import UniformTypeIdentifiers

/// Turns what the user opened or dropped into a list of media files.
public enum MediaFileCollector {
    /// Extensions FFmpeg reads that macOS may not map to an audio or video
    /// type.
    static let extraMediaExtensions: Set<String> = [
        "mkv", "mka", "webm", "opus", "ogg", "oga", "ogv", "flac", "wv", "ape", "dts", "ac3", "eac3",
        "mts", "m2ts", "ts", "vob", "flv", "wmv", "wma", "asf", "amr", "caf", "w64",
    ]

    /// Files are kept as given; folders are searched recursively (skipping
    /// hidden files and packages) for files that look like audio or video.
    /// Duplicates are dropped and the original order kept.
    public static func collect(_ urls: [URL], fileManager: FileManager = .default) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        func add(_ url: URL) {
            // Symlinks resolved, so /var/… and /private/var/… are one file.
            let key = url.resolvingSymlinksInPath().path(percentEncoded: false)
            if seen.insert(key).inserted {
                result.append(url.standardizedFileURL)
            }
        }

        for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else {
                add(url)
                continue
            }
            let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey]
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            var found: [URL] = []
            for case let file as URL in enumerator {
                let values = try? file.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true, isMediaFile(file, contentType: values?.contentType) else { continue }
                found.append(file)
            }
            found.sorted { $0.path(percentEncoded: false).localizedStandardCompare($1.path(percentEncoded: false)) == .orderedAscending }
                .forEach(add)
        }
        return result
    }

    static func isMediaFile(_ url: URL, contentType: UTType?) -> Bool {
        if let contentType, contentType.conforms(to: .audiovisualContent) {
            return true
        }
        return extraMediaExtensions.contains(url.pathExtension.lowercased())
    }
}

/// Where a batch puts processed files when it isn't replacing originals.
public enum OutputNaming {
    /// `<folder>/<name> (No Speech).<ext>`, or `<name> (No Speech 2).<ext>`,
    /// `(No Speech 3)`, … if a file with that name already exists. Files are
    /// moved into place one at a time, so earlier outputs of the same batch
    /// count as existing.
    public static func uniqueDestination(
        for original: URL,
        in folder: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    ) -> URL {
        let name = original.deletingPathExtension().lastPathComponent
        let ext = original.pathExtension
        var attempt = 1
        while true {
            let suffix = attempt == 1 ? "No Speech" : "No Speech \(attempt)"
            let fileName = ext.isEmpty ? "\(name) (\(suffix))" : "\(name) (\(suffix)).\(ext)"
            let candidate = folder.appending(path: fileName, directoryHint: .notDirectory)
            if !fileExists(candidate) {
                return candidate
            }
            attempt += 1
        }
    }
}
