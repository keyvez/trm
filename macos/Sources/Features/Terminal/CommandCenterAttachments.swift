import AppKit
import Foundation
import UniformTypeIdentifiers
import os

/// Getting a file from the Mac into an agent's hands.
///
/// Agents read from disk — you give one a path and it opens it, whether that's
/// a screenshot, a log, or a diff. So anything dropped or pasted into a reply
/// box becomes a file on the machine the agent runs on and a path in the
/// message: something you can see before you send it, edit around, and use
/// again later. Nothing is smuggled into the terminal as bytes.
///
/// The wrinkle is remote panes. A path only means something on the machine
/// holding the file, so for those the file is copied across first and the
/// *remote* path goes in the message — which is what makes a screenshot taken
/// here openable by an agent over there.
enum CommandCenterAttachments {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.trm",
        category: "CommandCenterAttachments"
    )

    /// Where dropped files are kept, on either machine. Inside `~/.trm` so it
    /// is obvious where they came from and easy to sweep up.
    static let directoryName = ".trm/dropped-files"

    /// Files above this are refused rather than copied: a reply box is not a
    /// file transfer tool, and pushing a gigabyte over SSH because someone
    /// dragged the wrong thing is worse than saying no.
    static let sizeLimit = 64 * 1024 * 1024

    enum AttachError: Error {
        case tooLarge(name: String, bytes: Int)
        case unreadable(String)
        case writeFailed(String)
        case copyFailed(String)

        var message: String {
            switch self {
            case .tooLarge(let name, let bytes):
                let mb = Double(bytes) / 1024 / 1024
                return "\(name) is \(String(format: "%.0f", mb)) MB — too big to attach."
            case .unreadable(let reason): return "Couldn't read that file: \(reason)"
            case .writeFailed(let reason): return "Couldn't save the attachment: \(reason)"
            case .copyFailed(let reason): return "Couldn't copy it to the remote machine: \(reason)"
            }
        }
    }

    /// One thing to attach: its bytes and the name to give it.
    struct Payload {
        let data: Data
        /// Preserved from the original where there was one, so an agent can
        /// tell a `.png` from a `.log` without opening it.
        let filename: String
    }

    /// Everything worth attaching from a paste or a drag.
    ///
    /// Files come first and keep their own names: a dragged `build.log` should
    /// arrive as `build.log`, not as anonymous bytes. Raw image data — a
    /// screenshot, a copy out of Preview — has no name, so it gets one.
    static func payloads(from pasteboard: NSPasteboard, now: Date = Date()) -> [Payload] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return urls.compactMap { url in
                guard url.isFileURL, let data = try? Data(contentsOf: url) else { return nil }
                return Payload(data: data, filename: uniqueName(for: url.lastPathComponent, now: now))
            }
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return [Payload(data: png, filename: generatedName(ext: "png", now: now))]
        }
        if let png = pasteboard.data(forType: .png) {
            return [Payload(data: png, filename: generatedName(ext: "png", now: now))]
        }
        return []
    }

    /// Write `data` where the agent behind `surface` can read it, and return
    /// the path to put in the message.
    ///
    /// Local panes get a path on this Mac. Remote panes get the file copied to
    /// the same place on the other machine and the remote path back — the
    /// agent is over there, and a local path would just be a file it can't
    /// open.
    static func stage(
        _ payload: Payload,
        for surface: Ghostty.SurfaceView
    ) async -> Result<String, AttachError> {
        guard payload.data.count <= sizeLimit else {
            return .failure(.tooLarge(name: payload.filename, bytes: payload.data.count))
        }
        let data = payload.data
        let name = payload.filename
        let localDirectory = NSHomeDirectory() + "/" + directoryName
        let localPath = localDirectory + "/" + name

        do {
            try FileManager.default.createDirectory(
                atPath: localDirectory, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: localPath))
        } catch {
            return .failure(.writeFailed(error.localizedDescription))
        }

        guard let host = surface.remoteHost else { return .success(localPath) }

        // `$HOME` is expanded on the far side: the two machines rarely share a
        // user name, so a literal local path would land in the wrong place.
        let remoteDirectory = "$HOME/" + directoryName
        let command = "mkdir -p \(remoteDirectory) && cat > \(remoteDirectory)/\(name)"
        let result = await Task.detached(priority: .userInitiated) {
            copyOverSSH(data: data, host: host, command: command)
        }.value
        if let error = result {
            return .failure(.copyFailed(error))
        }
        // The path as the remote shell will see it. `~` rather than an
        // absolute path for the same reason.
        return .success("~/" + directoryName + "/" + name)
    }

    /// A name for data that arrived without one.
    static func generatedName(ext: String, now: Date) -> String {
        let safeExt = ext.isEmpty ? "bin" : ext
        return "trm-\(stamp(now))-\(nonce()).\(safeExt)"
    }

    /// A dragged file's own name, stamped so two drags of `screenshot.png`
    /// don't overwrite each other. Anything a shell would have to be quoted
    /// for is replaced, so the path can go into a message unquoted.
    static func uniqueName(for original: String, now: Date) -> String {
        let url = URL(fileURLWithPath: original)
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let safeBase = base.unicodeScalars.map { scalar -> String in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_"
                ? String(scalar) : "-"
        }.joined()
        let stem = safeBase.isEmpty ? "file" : safeBase
        let suffix = ext.isEmpty ? "" : ".\(ext.lowercased())"
        return "\(stem)-\(stamp(now))-\(nonce())\(suffix)"
    }

    private static func stamp(_ now: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: now)
    }

    private static func nonce() -> String {
        String(format: "%04x", UInt16.random(in: 0...UInt16.max))
    }

    /// Append a path to a draft, keeping whatever the user has already typed.
    /// Pure, so the spacing rules are testable.
    static func draft(_ draft: String, appending path: String) -> String {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return path + " " }
        return trimmed + " " + path + " "
    }

    private static func copyOverSSH(data: Data, host: String, command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, command]
        let stdin = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return error.localizedDescription
        }
        stdin.fileHandleForWriting.write(data)
        try? stdin.fileHandleForWriting.close()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            logger.error("Image copy to \(host, privacy: .public) failed: \(message)")
            return message.isEmpty ? "ssh exited \(process.terminationStatus)" : message
        }
        return nil
    }
}
