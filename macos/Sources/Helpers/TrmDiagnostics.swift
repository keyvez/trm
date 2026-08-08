import Foundation
import Darwin
import OSLog

/// Persistent crash + memory diagnostics for trm.
///
/// The macOS crash reporter does not reliably catch Zig `panic`/`abort`
/// (they exit without producing an `.ips`), and a release app launched from
/// Finder has no terminal capturing stderr. This installs:
///
///   1. POSIX signal handlers (SIGSEGV/SIGABRT/SIGILL/SIGBUS/SIGTRAP/SIGFPE)
///   2. an NSException uncaught-exception handler
///   3. a periodic memory-footprint sampler
///   4. a file-backed sink for `[*-trace]` style logging
///
/// Everything is written to `~/Library/Logs/trm/` so it survives the crash
/// and is available no matter how the app was launched.
enum TrmDiagnostics {
    /// `~/Library/Logs/trm`
    static let logDirectory: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        let dir = base.appendingPathComponent("Logs/trm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let signpostLog = OSLog(subsystem: "app.roj.trm", category: "diagnostics")

    /// Serial queue so file writes from multiple threads don't interleave.
    private static let ioQueue = DispatchQueue(label: "app.roj.trm.diagnostics")

    /// Open file handle for the rolling session/trace log.
    private static var sessionHandle: FileHandle?

    /// Memory sampler timer. Held so it isn't deallocated.
    private static var memoryTimer: DispatchSourceTimer?

    private static var started = false

    // MARK: - Startup

    /// Install everything. Safe to call exactly once, as early as possible
    /// (from `main.swift`, before `NSApplicationMain`).
    static func start() {
        guard !started else { return }
        started = true

        rotateIfNeeded()
        openSessionLog()
        installSignalHandlers()
        installExceptionHandler()
        startMemorySampler()

        log("=== trm session started pid=\(getpid()) ===")
        log("build: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") " +
            "(\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
    }

    // MARK: - Trace logging (file-persisted)

    /// Append a line to the session log AND emit an os_log signpost so it is
    /// visible in Console.app. Replaces scattered `NSLog` trace calls.
    static func log(_ message: String) {
        os_log("%{public}@", log: signpostLog, type: .info, message)

        let line = "\(timestamp()) [\(threadLabel())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        ioQueue.async {
            sessionHandle?.write(data)
        }
    }

    // MARK: - Memory sampling

    /// Current resident footprint in bytes, or nil if the query fails.
    static func memoryFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    private static func startMemorySampler() {
        let timer = DispatchSource.makeTimerSource(queue: ioQueue)
        // First sample after 60s, then every 60s.
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler {
            guard let bytes = memoryFootprint() else { return }
            let mb = Double(bytes) / 1024.0 / 1024.0
            let line = "\(timestamp()) footprint=\(String(format: "%.1f", mb))MB\n"
            if let data = line.data(using: .utf8) {
                memoryHandle?.write(data)
            }
            // Loud warning if we cross a threshold — the 86GB leak would
            // have tripped this hours before the crash.
            if mb > 4096 {
                os_log("%{public}@", log: signpostLog, type: .fault,
                       "HIGH MEMORY: footprint \(String(format: "%.0f", mb))MB")
                log("WARNING high memory footprint=\(String(format: "%.0f", mb))MB")
            }
        }
        timer.resume()
        memoryTimer = timer
    }

    private static let memoryHandle: FileHandle? = {
        let url = logDirectory.appendingPathComponent("memory.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        return handle
    }()

    // MARK: - Crash handlers

    private static func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            var report = "=== UNCAUGHT NSEXCEPTION ===\n"
            report += "name: \(exception.name.rawValue)\n"
            report += "reason: \(exception.reason ?? "(none)")\n"
            report += "callStack:\n"
            report += exception.callStackSymbols.joined(separator: "\n")
            report += "\n"
            TrmDiagnostics.writeCrashReport(report)
        }
    }

    private static func installSignalHandlers() {
        let signals: [Int32] = [SIGSEGV, SIGABRT, SIGILL, SIGBUS, SIGTRAP, SIGFPE]
        for sig in signals {
            signal(sig) { caught in
                // Async-signal-safe-ish: we deliberately keep this minimal.
                // Backtrace via the Darwin API, format, write, re-raise default.
                var callstack = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
                let frames = backtrace(&callstack, 32)
                let symbols = backtrace_symbols(&callstack, frames)

                var report = "=== FATAL SIGNAL \(caught) ===\n"
                if let symbols {
                    for i in 0..<Int(frames) {
                        if let sym = symbols[i] {
                            report += String(cString: sym) + "\n"
                        }
                    }
                }
                TrmDiagnostics.writeCrashReport(report)

                // Restore default handler and re-raise so the OS still
                // produces whatever report it can.
                signal(caught, SIG_DFL)
                raise(caught)
            }
        }
    }

    /// Write a crash report to its own timestamped file. Kept synchronous and
    /// dependency-free because it may run inside a signal handler.
    private static func writeCrashReport(_ body: String) {
        let name = "crash-\(fileTimestamp()).log"
        let url = logDirectory.appendingPathComponent(name)
        var full = body
        if let mb = memoryFootprint().map({ Double($0) / 1024.0 / 1024.0 }) {
            full += "footprint at crash: \(String(format: "%.1f", mb))MB\n"
        }
        full += "time: \(timestamp())\n"
        try? full.data(using: .utf8)?.write(to: url)

        // Also append to the session log so there is a single timeline.
        if let data = ("\n" + full).data(using: .utf8) {
            sessionHandle?.write(data)
        }
    }

    // MARK: - Session log file management

    private static func openSessionLog() {
        let url = logDirectory.appendingPathComponent("session.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
        sessionHandle = handle
    }

    /// Roll `session.log` and `memory.log` if they exceed 10 MB so they do
    /// not themselves become a disk problem.
    private static func rotateIfNeeded() {
        for name in ["session.log", "memory.log"] {
            let url = logDirectory.appendingPathComponent(name)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? UInt64, size > 10 * 1024 * 1024 else { continue }
            let rolled = logDirectory.appendingPathComponent(name + ".1")
            try? FileManager.default.removeItem(at: rolled)
            try? FileManager.default.moveItem(at: url, to: rolled)
        }
    }

    // MARK: - Formatting helpers

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private static func timestamp() -> String { formatter.string(from: Date()) }

    private static func fileTimestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date())
    }

    private static func threadLabel() -> String {
        Thread.isMainThread ? "main" : "bg"
    }
}
