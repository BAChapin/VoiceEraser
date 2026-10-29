import Foundation

/// Output of a finished child process.
struct ProcessResult: Sendable {
    var status: Int32
    var standardOutput: Data
    var standardError: Data

    var standardErrorText: String { String(data: standardError, encoding: .utf8) ?? "" }
}

/// Runs command-line tools (ffmpeg, ffprobe) as child processes.
enum ProcessRunner {
    /// Runs `executable` to completion and returns its exit status and output.
    ///
    /// - Parameter onOutputLine: called with each line written to standard
    ///   output as it arrives (used for `ffmpeg -progress pipe:1`).
    /// - Throws: `CancellationError` if the task is cancelled; the process is
    ///   terminated first.
    static func run(
        _ executable: URL,
        arguments: [String],
        onOutputLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let stdout = LineCollector(onLine: onOutputLine)
        let stderr = LineCollector(onLine: nil)
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            stdout.append(handle.availableData)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            stderr.append(handle.availableData)
        }

        let box = UncheckedSendable(process)
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.value.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try box.value.run()
                } catch {
                    box.value.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if box.value.isRunning {
                box.value.terminate()
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        stdout.append(outPipe.fileHandleForReading.readDataToEndOfFile())
        stderr.append(errPipe.fileHandleForReading.readDataToEndOfFile())
        stdout.finish()

        try Task.checkCancellation()
        return ProcessResult(status: status, standardOutput: stdout.data, standardError: stderr.data)
    }
}

/// Thread-safe accumulator for a pipe's output that also splits it into lines.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var pendingLine = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    var data: Data {
        lock.withLock { buffer }
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        var lines: [String] = []
        lock.withLock {
            buffer.append(chunk)
            guard onLine != nil else { return }
            pendingLine.append(chunk)
            while let newline = pendingLine.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pendingLine[pendingLine.startIndex..<newline]
                lines.append(String(data: Data(line), encoding: .utf8) ?? "")
                pendingLine.removeSubrange(pendingLine.startIndex...newline)
            }
        }
        if let onLine {
            lines.forEach(onLine)
        }
    }

    func finish() {
        let rest: String? = lock.withLock {
            defer { pendingLine.removeAll() }
            return pendingLine.isEmpty ? nil : String(data: pendingLine, encoding: .utf8)
        }
        if let rest, let onLine {
            onLine(rest)
        }
    }
}

/// Wraps a non-Sendable value that is only touched in ways known to be safe
/// (for example a `Process` that is configured before it starts and only
/// terminated afterwards).
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
