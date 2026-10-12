import Foundation

public enum CopilotLocator {
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var url: URL?
        var value: URL? {
            get { lock.withLock { url } }
            set { lock.withLock { url = newValue } }
        }
    }

    private static let cache = Cache()

    /// The Settings override wins; otherwise the CLI found through the user's login shell, then common install folders.
    public static func locate(override: String?) async -> URL? {
        if let path = override?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        if let cached = cache.value, FileManager.default.isExecutableFile(atPath: cached.path) { return cached }
        let found = await Task.detached { detect() }.value
        cache.value = found
        return found
    }

    /// Shell start-up files may print banners, so only the last absolute path counts.
    static func path(fromShellOutput output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
    }

    private static func detect() -> URL? {
        if let path = shellLookup(), FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        let fallbacks = ["/opt/homebrew/bin/copilot", "/usr/local/bin/copilot", NSHomeDirectory() + "/.local/bin/copilot"]
        return fallbacks.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Interactive login shell, so `.zshrc` (where nvm usually lives) is loaded. A Finder-launched app has no such PATH.
    private static func shellLookup() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", "command -v copilot"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return path(fromShellOutput: String(decoding: data, as: UTF8.self))
    }
}

/// Runs `copilot --acp` as a child process and exposes its stdout as JSON lines.
final class ProcessACPChannel: ACPChannel, @unchecked Sendable {
    let lines: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()

    init(executable: URL, directory: URL) throws {
        var captured: AsyncThrowingStream<Data, Error>.Continuation!
        lines = AsyncThrowingStream { captured = $0 }
        continuation = captured
        let stream = captured!

        process.executableURL = executable
        process.arguments = ["--acp", "--no-auto-update"]
        process.currentDirectoryURL = directory
        // The launcher is a Node script (`#!/usr/bin/env node`); a GUI app's PATH does not include nvm's node.
        var environment = ProcessInfo.processInfo.environment
        let extra = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"]
        environment["PATH"] = (extra + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        try process.run()
        // A write to a dead child must throw EPIPE, not raise SIGPIPE and kill the app.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        var buffer = Data()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stream.finish()
                return
            }
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                stream.yield(Data(buffer[buffer.startIndex..<newline]))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
    }

    func send(_ line: Data) throws {
        try input.fileHandleForWriting.write(contentsOf: line + Data([0x0A]))
    }

    func close() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
        continuation.finish()
    }
}
