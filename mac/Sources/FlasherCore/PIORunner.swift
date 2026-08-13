import Foundation

public struct PIOError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Finds the `pio` executable.
///
/// Harder in a Mac app than in a terminal, and worth spelling out: a process
/// launched from Finder inherits `PATH=/usr/bin:/bin:/usr/sbin:/sbin` and nothing
/// else. Every place PlatformIO actually installs itself -- Homebrew, pipx, a
/// framework Python, its own bundled virtualenv -- is outside that. Searching
/// `PATH` alone would report "PlatformIO not found" on a machine where `pio`
/// works perfectly in Terminal.
public enum PlatformIO {
    private static let overrideKey = "platformIOPath"

    /// A path the user picked by hand, when discovery guessed wrong.
    public static var overridePath: String? {
        get { UserDefaults.standard.string(forKey: overrideKey) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: overrideKey)
            } else {
                UserDefaults.standard.removeObject(forKey: overrideKey)
            }
        }
    }

    public static func find() throws -> String {
        if let overridePath, isExecutable(overridePath) { return overridePath }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates = [
            // PlatformIO's own virtualenv, which the VS Code extension creates
            // and which is the single most likely place to find it.
            "\(home)/.platformio/penv/bin/pio",
            "/opt/homebrew/bin/pio",
            "/usr/local/bin/pio",
            "\(home)/.local/bin/pio",
        ]
        candidates += frameworkPythonCandidates()

        for candidate in candidates where isExecutable(candidate) { return candidate }

        // Last resort: ask the user's login shell, which is the only thing that
        // knows what their profile puts on PATH.
        if let fromShell = loginShellLookup("pio"), isExecutable(fromShell) { return fromShell }

        throw PIOError(
            "PlatformIO not found.\n\n"
            + "Install it with `pip3 install platformio`, or open this project "
            + "once in VS Code with the PlatformIO extension. If it is already "
            + "installed somewhere unusual, set the path in Settings."
        )
    }

    /// python.org installs land here, and the version is not predictable.
    private static func frameworkPythonCandidates() -> [String] {
        let base = "/Library/Frameworks/Python.framework/Versions"
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: base) else {
            return []
        }
        return versions.sorted(by: >).map { "\(base)/\($0)/bin/pio" }
    }

    private static func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    /// `PATH` as the user's own login shell builds it.
    ///
    /// Cached: it costs a shell startup, and it cannot change while the app runs.
    public static var loginShellPath: String? { LoginShell.shared.path }

    private static func loginShellLookup(_ command: String) -> String? {
        LoginShell.shared.run("command -v \(command)")
    }

    /// The environment a build should run in.
    ///
    /// PlatformIO shells out to git, to its own toolchains and to Python, so it
    /// needs a real `PATH` even once `pio` itself has been located.
    public static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let shellPath = loginShellPath, !shellPath.isEmpty {
            let existing = env["PATH"] ?? ""
            env["PATH"] = existing.isEmpty ? shellPath : "\(shellPath):\(existing)"
        }
        // Otherwise PlatformIO emits ANSI colour codes, which show up as escape
        // sequences in the log pane.
        env["PLATFORMIO_NO_ANSI"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    /// The command line for one build, mirroring what the README documents.
    public static func arguments(
        environment: String, upload: Bool, uploadPort: String?
    ) -> [String] {
        var argv = ["run", "-e", environment]
        if upload {
            argv += ["-t", "upload"]
            if let uploadPort, !uploadPort.isEmpty {
                argv += ["--upload-port", uploadPort]
            }
        }
        return argv
    }
}

/// Runs a command in the user's login shell to recover their real environment.
final class LoginShell: @unchecked Sendable {
    static let shared = LoginShell()

    private let lock = NSLock()
    private var cachedPath: String??

    var path: String? {
        lock.lock()
        if let cachedPath {
            lock.unlock()
            return cachedPath
        }
        lock.unlock()

        let value = run("echo $PATH")
        lock.lock()
        cachedPath = value
        lock.unlock()
        return value
    }

    /// One line of output, or nil. Never throws: every caller has a fallback,
    /// and a broken login shell should degrade rather than stop the app.
    func run(_ command: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -l so the profile that sets PATH is actually read.
        process.arguments = ["-l", "-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output.components(separatedBy: "\n").last
    }
}

/// A running command whose output is delivered line by line as it arrives.
///
/// One at a time, enforced by the caller. Flashing two boards at once over the
/// same USB bus is not something the UI should make easy, and two builds in one
/// project directory would collide on PlatformIO's own lock anyway.
public final class CommandRunner: @unchecked Sendable {
    private let process = Process()
    private let pipe = Pipe()
    private let lock = NSLock()
    private var pending = Data()
    private var finished = false

    public init(
        executable: String,
        arguments: [String],
        directory: URL,
        environment: [String: String]
    ) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
    }

    /// Streams output to `onLine` and reports the exit status exactly once.
    public func start(
        onLine: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            for line in self.take(data) { onLine(line) }
        }

        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.pipe.fileHandleForReading.readabilityHandler = nil
            // The readability handler can still have unread data queued when the
            // process exits; draining here is what keeps the last few lines --
            // usually the ones saying whether it worked -- from being lost.
            let rest = self.pipe.fileHandleForReading.readDataToEndOfFile()
            for line in self.take(rest) { onLine(line) }
            if let last = self.flush() { onLine(last) }
            onExit(process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            throw PIOError("failed to start: \(error.localizedDescription)")
        }
    }

    public func cancel() {
        guard process.isRunning else { return }
        process.terminate()
    }

    public var isRunning: Bool { process.isRunning }

    /// Complete lines from `data`, buffering any partial trailing one.
    private func take(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            lines.append(String(decoding: line, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r")))
        }
        return lines
    }

    /// Whatever is left when the stream ends without a final newline.
    private func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        let line = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return line.isEmpty ? nil : line
    }
}
