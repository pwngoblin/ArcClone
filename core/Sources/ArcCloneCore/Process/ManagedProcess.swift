import Foundation

/// A supervised child process speaking a line-oriented protocol on stdio.
/// Restarts with exponential backoff after unexpected exits; gives up after
/// `maxConsecutiveFailures` quick crashes.
@MainActor
public final class ManagedProcess {
    public struct Spec: Sendable {
        public var executable: URL
        public var arguments: [String]
        public var environment: [String: String]
        public var workingDirectory: URL?

        public init(executable: URL, arguments: [String], environment: [String: String] = [:], workingDirectory: URL? = nil) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.workingDirectory = workingDirectory
        }
    }

    public enum State: Equatable, Sendable {
        case stopped
        case running(pid: Int32)
        case restarting(attempt: Int, delay: TimeInterval)
        case failed(String)

        public var label: String {
            switch self {
            case .stopped: return "stopped"
            case .running: return "running"
            case .restarting: return "restarting"
            case .failed: return "failed"
            }
        }
    }

    public let name: String
    public var spec: Spec
    public var maxConsecutiveFailures = 8
    public var stableUptime: TimeInterval = 60

    public var onLine: (@MainActor (String) -> Void)?
    public var onStateChange: (@MainActor (State) -> Void)?

    public private(set) var state: State = .stopped {
        didSet { if oldValue != state { onStateChange?(state) } }
    }

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var launchedAt = Date.distantPast
    private var consecutiveFailures = 0
    private var wantsRunning = false
    private var restartWork: DispatchWorkItem?

    public init(name: String, spec: Spec) {
        self.name = name
        self.spec = spec
    }

    public func start() {
        wantsRunning = true
        restartWork?.cancel()
        guard process == nil else { return }
        launch()
    }

    public func stop() {
        wantsRunning = false
        restartWork?.cancel()
        restartWork = nil
        guard let process else {
            state = .stopped
            return
        }
        try? stdinHandle?.close() // well-behaved children exit when stdin closes
        let pid = process.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if process.isRunning {
                Log.process.info("Terminating \(self.name, privacy: .public) (pid \(pid))")
                process.terminate()
            }
        }
    }

    public func send(line: String) throws {
        guard let stdinHandle, case .running = state else {
            throw IPCError.unavailable("\(name) is not running")
        }
        var data = Data(line.utf8)
        data.append(0x0A)
        try stdinHandle.write(contentsOf: data)
    }

    /// Children get a minimal environment, never the app's own: variables such as NODE_OPTIONS
    /// or DYLD_INSERT_LIBRARIES would let whoever launched the app inject code into them
    /// (the hardened runtime strips DYLD_* for the app itself, but not for unhardened children).
    nonisolated static let inheritedKeys: Set<String> = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "TZ"]

    nonisolated static func childEnvironment(parent: [String: String], spec: [String: String]) -> [String: String] {
        var env = parent.filter { inheritedKeys.contains($0.key) }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return env.merging(spec) { _, new in new }
    }

    private func launch() {
        let p = Process()
        p.executableURL = spec.executable
        p.arguments = spec.arguments
        p.environment = Self.childEnvironment(parent: ProcessInfo.processInfo.environment, spec: spec.environment)
        if let wd = spec.workingDirectory { p.currentDirectoryURL = wd }

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr

        // Handlers fire on a background queue; hop to main in FIFO order to keep line ordering.
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consumeStdout(data) } }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consumeStderr(data) } }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let reason = proc.terminationReason
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handleExit(status: status, reason: reason) } }
        }

        do {
            try p.run()
        } catch {
            Log.process.error("Failed to launch \(self.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            state = .failed("Launch failed: \(error.localizedDescription)")
            return
        }
        process = p
        stdinHandle = stdin.fileHandleForWriting
        stdoutBuffer.removeAll()
        launchedAt = Date()
        state = .running(pid: p.processIdentifier)
        Log.process.info("Launched \(self.name, privacy: .public) pid \(p.processIdentifier)")
    }

    private func consumeStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<nl]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            let line = String(decoding: lineData, as: UTF8.self)
            if !line.isEmpty { onLine?(line) }
        }
    }

    private func consumeStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        stderrBuffer.append(data)
        while let nl = stderrBuffer.firstIndex(of: 0x0A) {
            let line = String(decoding: stderrBuffer[stderrBuffer.startIndex..<nl], as: UTF8.self)
            stderrBuffer.removeSubrange(stderrBuffer.startIndex...nl)
            Log.process.info("[\(self.name, privacy: .public)] \(line, privacy: .public)")
        }
    }

    private func handleExit(status: Int32, reason: Process.TerminationReason) {
        if let p = process {
            (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            (p.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        }
        process = nil
        stdinHandle = nil
        let uptime = Date().timeIntervalSince(launchedAt)
        Log.process.info("\(self.name, privacy: .public) exited status \(status) after \(Int(uptime))s")

        guard wantsRunning else {
            state = .stopped
            return
        }
        consecutiveFailures = uptime >= stableUptime ? 1 : consecutiveFailures + 1
        guard consecutiveFailures <= maxConsecutiveFailures else {
            state = .failed("Exited \(consecutiveFailures) times in a row (last status \(status))")
            return
        }
        let delay = min(30, 0.5 * pow(2, Double(consecutiveFailures - 1)))
        state = .restarting(attempt: consecutiveFailures, delay: delay)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.wantsRunning, self.process == nil else { return }
                self.launch()
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

public enum Executables {
    /// GUI apps don't inherit the login shell's PATH, so look in the usual places.
    /// The `ARCCLONE_<NAME>` override and `$PATH` are honoured only in development builds.
    public static func find(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                            allowOverrides: Bool = !AppInfo.isPackaged) -> URL? {
        var dirs: [String] = []
        if allowOverrides {
            if let override = environment["ARCCLONE_\(name.uppercased())"], FileManager.default.isExecutableFile(atPath: override) {
                return URL(fileURLWithPath: override)
            }
            dirs = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", NSHomeDirectory() + "/.volta/bin", NSHomeDirectory() + "/.local/bin"]
        let nvm = NSHomeDirectory() + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            dirs += versions.sorted().reversed().map { "\(nvm)/\($0)/bin" }
        }
        for dir in dirs {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }
}
