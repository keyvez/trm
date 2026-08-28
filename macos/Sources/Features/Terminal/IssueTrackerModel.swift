import AppKit
import Combine
import Foundation

/// A repository that opts into trm's issue board by keeping an issue index
/// beside a per-issue directory. The host travels with the path: a remote pane
/// reports a perfectly useful cwd, but that path belongs to the machine on the
/// other end of its SSH connection rather than to this Mac.
struct IssueTrackerProject: Hashable, Sendable, Identifiable {
    let rootPath: String
    let indexFileName: String
    let remoteHost: String?

    var id: String { "\(remoteHost ?? "local")|\(rootPath)" }
    var name: String { (rootPath as NSString).lastPathComponent }
    var locationLabel: String {
        guard let remoteHost else { return rootPath }
        return "\(remoteHost):\(rootPath)"
    }
}

/// What a restored remote pane is actually attached to. Ghostty's `pwd`
/// action is not replayed by zmx, so restored panes need to recover this from
/// the shell process that owns the remote session.
struct IssueTrackerRemotePaneContext: Sendable {
    let cwd: String
    let project: IssueTrackerProject?
}

enum TrackedIssueStatus: String, CaseIterable, Codable, Sendable {
    case open = "OPEN"
    case staged = "STAGED"
    case deployed = "DEPLOYED"
    case unverified = "UNVERIFIED"

    var label: String { rawValue.capitalized }
}

struct IssueArtifact: Identifiable, Hashable, Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case image
        case text
        case other
    }

    let relativePath: String
    let name: String
    let size: Int64
    let modifiedAt: TimeInterval
    let kind: Kind

    var id: String { relativePath }
    var loadID: String { "\(relativePath)|\(modifiedAt)|\(size)" }
}

struct TrackedIssue: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let status: TrackedIssueStatus
    let detailStatus: TrackedIssueStatus?
    let section: String
    let report: String
    let detail: String
    let detailModifiedAt: TimeInterval?
    let artifacts: [IssueArtifact]

    var statusIsOutOfSync: Bool {
        guard let detailStatus else { return false }
        return detailStatus != status
    }

    var mostRecentChange: TimeInterval? {
        ([detailModifiedAt] + artifacts.map { Optional($0.modifiedAt) })
            .compactMap { $0 }
            .max()
    }

    var summary: String {
        let source = report.isEmpty ? detail : report
        let lines = source.components(separatedBy: .newlines)
        var result: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                if !result.isEmpty { break }
                continue
            }
            guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix("**Status:") else { continue }
            result.append(trimmed.replacingOccurrences(of: "`", with: ""))
            if result.joined(separator: " ").count >= 240 { break }
        }
        let joined = result.joined(separator: " ")
        guard joined.count > 260 else { return joined }
        return String(joined.prefix(259)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

struct IssueTrackerSnapshot: Sendable {
    let issues: [TrackedIssue]
}

/// Pure parsing kept separate from I/O so a hand-written tracker remains the
/// source of truth. There is no hidden database to get out of step with it.
enum IssueTrackerParser {
    private static let issueLine = try! NSRegularExpression(
        pattern: #"^([A-Za-z]+-[0-9]+)[ \t]+(.+?)[ \t]+(DEPLOYED|STAGED|OPEN|UNVERIFIED)[ \t]*$"#)
    private static let detailStatus = try! NSRegularExpression(
        pattern: #"\*\*Status:\*\*[ \t]*(DEPLOYED|STAGED|OPEN|UNVERIFIED)"#,
        options: [.caseInsensitive])

    static func parse(
        index: String,
        documents: [String: (content: String, modifiedAt: TimeInterval)],
        artifacts: [IssueArtifact]
    ) -> [TrackedIssue] {
        let lines = index.components(separatedBy: .newlines)
        var rows: [(id: String, title: String, status: TrackedIssueStatus,
                    section: String, report: String)] = []
        var section = "Issues"
        var lineIndex = 0

        while lineIndex < lines.count {
            let line = lines[lineIndex]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("SECTION ") || trimmed.hasPrefix("APPENDIX ") {
                section = trimmed
            }

            if let parsed = parseIndexLine(line) {
                var reportLines: [String] = []
                var cursor = lineIndex + 1
                while cursor < lines.count {
                    let candidate = lines[cursor]
                    if parseIndexLine(candidate) != nil { break }
                    let candidateTrimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                    if candidateTrimmed.hasPrefix("SECTION ")
                        || candidateTrimmed.hasPrefix("APPENDIX ")
                        || candidateTrimmed.allSatisfy({ $0 == "=" }) {
                        break
                    }
                    // An issue's body is deliberately indented in the index.
                    // A blank line belongs to it only until the next top-level
                    // heading or issue, both handled above.
                    if candidate.isEmpty || candidate.first?.isWhitespace == true {
                        reportLines.append(candidate.trimmingCharacters(in: .whitespaces))
                        cursor += 1
                        continue
                    }
                    break
                }
                rows.append((parsed.id, parsed.title, parsed.status, section,
                             trimBlankLines(reportLines).joined(separator: "\n")))
                lineIndex = max(lineIndex + 1, cursor)
                continue
            }
            lineIndex += 1
        }

        var seen = Set<String>()
        var result: [TrackedIssue] = rows.map { row in
            seen.insert(row.id)
            return makeIssue(row: row, document: documents[row.id], artifacts: artifacts)
        }

        // A record file should never silently disappear because somebody
        // forgot the matching index row. Surface it at the end with an honest
        // fallback status, and let the out-of-sync warning point at the drift.
        for id in documents.keys.sorted() where !seen.contains(id) {
            guard id.range(of: #"^[A-Za-z]+-[0-9]+$"#, options: .regularExpression) != nil,
                  let document = documents[id] else { continue }
            let title = firstHeading(in: document.content) ?? id
            let status = status(in: document.content) ?? .open
            result.append(makeIssue(
                row: (id, title, status, "Not present in the index", ""),
                document: document,
                artifacts: artifacts))
        }
        return result
    }

    private static func makeIssue(
        row: (id: String, title: String, status: TrackedIssueStatus,
              section: String, report: String),
        document: (content: String, modifiedAt: TimeInterval)?,
        artifacts: [IssueArtifact]
    ) -> TrackedIssue {
        let ownArtifacts = artifacts
            .filter { $0.relativePath.hasPrefix("issues/artifacts/\(row.id)/") }
            .sorted { lhs, rhs in
                if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        return TrackedIssue(
            id: row.id,
            title: row.title,
            status: row.status,
            detailStatus: document.flatMap { status(in: $0.content) },
            section: row.section,
            report: row.report,
            detail: document?.content ?? "No `issues/\(row.id).md` record exists yet.",
            detailModifiedAt: document?.modifiedAt,
            artifacts: ownArtifacts)
    }

    private static func parseIndexLine(
        _ line: String
    ) -> (id: String, title: String, status: TrackedIssueStatus)? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = issueLine.firstMatch(in: line, range: range),
              let idRange = Range(match.range(at: 1), in: line),
              let titleRange = Range(match.range(at: 2), in: line),
              let statusRange = Range(match.range(at: 3), in: line),
              let status = TrackedIssueStatus(rawValue: String(line[statusRange]).uppercased())
        else { return nil }
        return (
            String(line[idRange]).uppercased(),
            String(line[titleRange]).trimmingCharacters(in: .whitespaces),
            status)
    }

    private static func status(in text: String) -> TrackedIssueStatus? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = detailStatus.firstMatch(in: text, range: range),
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        return TrackedIssueStatus(rawValue: String(text[valueRange]).uppercased())
    }

    private static func firstHeading(in text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("# ") else { continue }
            let heading = String(trimmed.dropFirst(2))
            if let divider = heading.range(of: " — ") {
                return String(heading[divider.upperBound...])
            }
            return heading
        }
        return nil
    }

    private static func trimBlankLines(_ lines: [String]) -> [String] {
        guard let first = lines.firstIndex(where: { !$0.isEmpty }),
              let last = lines.lastIndex(where: { !$0.isEmpty }) else { return [] }
        return Array(lines[first...last])
    }
}

/// Filesystem/SSH adapter for the tracker. Remote operations send a small
/// Python program over stdin, with the request itself base64-encoded inside
/// it. Paths and response text never become shell syntax.
enum IssueTrackerStore {
    private static let imageExtensions = Set([
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp",
    ])
    private static let textExtensions = Set([
        "md", "txt", "log", "json", "jsonl", "toml", "yaml", "yml", "csv", "diff", "patch",
    ])
    static let artifactSizeLimit: Int64 = 20 * 1_024 * 1_024

    static func discover(cwd: String, remoteHost: String?) async -> IssueTrackerProject? {
        await Task.detached(priority: .utility) {
            do {
                if let remoteHost {
                    let response = try remote(request: ["op": "discover", "cwd": cwd], host: remoteHost)
                    guard let root = response.root, let index = response.indexFileName else { return nil }
                    return IssueTrackerProject(
                        rootPath: root, indexFileName: index, remoteHost: remoteHost)
                }
                return discoverLocal(cwd: cwd)
            } catch {
                return nil
            }
        }.value
    }

    /// Resolve every zmx session on one host in a single SSH round trip. The
    /// pane chrome asks for these concurrently after a restore; probing once
    /// per pane would otherwise create a burst of SSH processes and make the
    /// checklist arrive at a different time in every cell.
    static func remotePaneContexts(host: String) throws -> [String: IssueTrackerRemotePaneContext] {
        let response = try remote(request: ["op": "discover_sessions"], host: host)
        if let error = response.error { throw StoreError.message(error) }
        return (response.sessions ?? [:]).mapValues { context in
            let project: IssueTrackerProject?
            if let root = context.root, let index = context.indexFileName {
                project = IssueTrackerProject(
                    rootPath: root, indexFileName: index, remoteHost: host)
            } else {
                project = nil
            }
            return IssueTrackerRemotePaneContext(cwd: context.cwd, project: project)
        }
    }

    static func snapshot(_ project: IssueTrackerProject) throws -> IssueTrackerSnapshot {
        if let host = project.remoteHost {
            let response = try remote(request: [
                "op": "snapshot",
                "root": project.rootPath,
                "index": project.indexFileName,
            ], host: host)
            if let error = response.error { throw StoreError.message(error) }
            guard let index = response.index,
                  let remoteDocuments = response.documents else {
                throw StoreError.message("The remote tracker returned no issue index.")
            }
            let documents = remoteDocuments.mapValues { ($0.content, $0.modifiedAt) }
            let artifacts = (response.artifacts ?? []).map { artifact in
                IssueArtifact(
                    relativePath: artifact.relativePath,
                    name: artifact.name,
                    size: artifact.size,
                    modifiedAt: artifact.modifiedAt,
                    kind: kind(for: artifact.name))
            }
            return IssueTrackerSnapshot(issues: IssueTrackerParser.parse(
                index: index, documents: documents, artifacts: artifacts))
        }

        let root = URL(fileURLWithPath: project.rootPath, isDirectory: true)
        let indexURL = root.appendingPathComponent(project.indexFileName)
        let index = try String(contentsOf: indexURL, encoding: .utf8)
        let issuesURL = root.appendingPathComponent("issues", isDirectory: true)
        let fm = FileManager.default
        var documents: [String: (content: String, modifiedAt: TimeInterval)] = [:]
        for url in try fm.contentsOfDirectory(
            at: issuesURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) where url.pathExtension.lowercased() == "md" {
            let id = url.deletingPathExtension().lastPathComponent
            guard id.range(of: #"^[A-Za-z]+-[0-9]+$"#, options: .regularExpression) != nil else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            documents[id.uppercased()] = (
                try String(contentsOf: url, encoding: .utf8),
                values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }
        let artifacts = localArtifacts(root: root)
        return IssueTrackerSnapshot(issues: IssueTrackerParser.parse(
            index: index, documents: documents, artifacts: artifacts))
    }

    static func readArtifact(
        _ artifact: IssueArtifact, project: IssueTrackerProject
    ) throws -> Data {
        guard artifact.size <= artifactSizeLimit else {
            throw StoreError.message("\(artifact.name) is too large to preview inline.")
        }
        if let host = project.remoteHost {
            let response = try remote(request: [
                "op": "read_artifact",
                "root": project.rootPath,
                "relative": artifact.relativePath,
                "limit": String(artifactSizeLimit),
            ], host: host)
            if let error = response.error { throw StoreError.message(error) }
            guard let encoded = response.data, let data = Data(base64Encoded: encoded) else {
                throw StoreError.message("The remote artifact could not be decoded.")
            }
            return data
        }
        let url = URL(fileURLWithPath: project.rootPath, isDirectory: true)
            .appendingPathComponent(artifact.relativePath)
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    /// Append the human's guidance to the issue's gitignored working folder.
    /// This happens before delivery to the terminal, so every instruction has
    /// a durable record even if the agent exits between the two operations.
    static func appendResponse(
        project: IssueTrackerProject,
        issueID: String,
        text: String,
        delivery: String,
        now: Date = Date()
    ) throws -> String {
        guard issueID.range(of: #"^[A-Za-z]+-[0-9]+$"#, options: .regularExpression) != nil else {
            throw StoreError.message("Invalid issue id \(issueID).")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: now)
        let block = "## \(timestamp) — You\n\n\(text)\n\n_Delivery: \(delivery)_\n"

        if let host = project.remoteHost {
            let response = try remote(request: [
                "op": "append_response",
                "root": project.rootPath,
                "issue_id": issueID.uppercased(),
                "block": block,
            ], host: host)
            if let error = response.error { throw StoreError.message(error) }
            return response.relativePath ?? "issues/artifacts/\(issueID)/responses.md"
        }

        let directory = URL(fileURLWithPath: project.rootPath, isDirectory: true)
            .appendingPathComponent("issues/artifacts/\(issueID.uppercased())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("responses.md")
        let exists = FileManager.default.fileExists(atPath: url.path)
        let payload = (exists ? "\n" : "# Issue responses — \(issueID.uppercased())\n\n") + block
        if exists {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(payload.utf8))
        } else {
            try Data(payload.utf8).write(to: url, options: .atomic)
        }
        return "issues/artifacts/\(issueID.uppercased())/responses.md"
    }

    // MARK: Local

    private static func discoverLocal(cwd: String) -> IssueTrackerProject? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        var candidate = (cwd as NSString).standardizingPath
        if fm.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue {
            candidate = (candidate as NSString).deletingLastPathComponent
        }
        while !candidate.isEmpty {
            let issuesDirectory = (candidate as NSString).appendingPathComponent("issues")
            var issuesIsDirectory: ObjCBool = false
            if fm.fileExists(atPath: issuesDirectory, isDirectory: &issuesIsDirectory),
               issuesIsDirectory.boolValue {
                for index in ["issues.md", "ISSUES.md"] where fm.fileExists(
                    atPath: (candidate as NSString).appendingPathComponent(index)) {
                    return IssueTrackerProject(
                        rootPath: candidate, indexFileName: index, remoteHost: nil)
                }
            }
            let parent = (candidate as NSString).deletingLastPathComponent
            if parent == candidate || parent.isEmpty { break }
            candidate = parent
        }
        return nil
    }

    private static func localArtifacts(root: URL) -> [IssueArtifact] {
        let artifactsRoot = root.appendingPathComponent("issues/artifacts", isDirectory: true)
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: artifactsRoot,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [IssueArtifact] = []
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
            guard url.path.hasPrefix(prefix) else { continue }
            let relative = String(url.path.dropFirst(prefix.count))
            result.append(IssueArtifact(
                relativePath: relative,
                name: url.lastPathComponent,
                size: Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0,
                kind: kind(for: url.lastPathComponent)))
        }
        return result
    }

    private static func kind(for name: String) -> IssueArtifact.Kind {
        let ext = (name as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if textExtensions.contains(ext) { return .text }
        return .other
    }

    // MARK: Remote

    private struct RemoteDocument: Decodable {
        let content: String
        let modifiedAt: TimeInterval

        enum CodingKeys: String, CodingKey {
            case content
            case modifiedAt = "modified"
        }
    }

    private struct RemoteArtifact: Decodable {
        let relativePath: String
        let name: String
        let size: Int64
        let modifiedAt: TimeInterval

        enum CodingKeys: String, CodingKey {
            case relativePath = "relative"
            case name, size
            case modifiedAt = "modified"
        }
    }

    private struct RemoteSessionContext: Decodable {
        let cwd: String
        let root: String?
        let indexFileName: String?

        enum CodingKeys: String, CodingKey {
            case cwd, root
            case indexFileName = "index_file"
        }
    }

    private struct RemoteResponse: Decodable {
        let error: String?
        let root: String?
        let indexFileName: String?
        let index: String?
        let documents: [String: RemoteDocument]?
        let artifacts: [RemoteArtifact]?
        let data: String?
        let relativePath: String?
        let sessions: [String: RemoteSessionContext]?

        enum CodingKeys: String, CodingKey {
            case error, root, index, documents, artifacts, data, sessions
            case indexFileName = "index_file"
            case relativePath = "relative"
        }
    }

    private enum StoreError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let message): return message }
        }
    }

    private static func remote(request: [String: String], host: String) throws -> RemoteResponse {
        guard validHost(host) else { throw StoreError.message("Invalid SSH host \(host).") }
        let requestData = try JSONSerialization.data(withJSONObject: request)
        let encoded = requestData.base64EncodedString()
        let source = "REQUEST_B64 = \"\(encoded)\"\n" + remoteHelper

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=6", host, "/usr/bin/python3 -",
        ]
        let input = Pipe(), output = Pipe(), error = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        do {
            try process.run()
        } catch {
            throw StoreError.message(error.localizedDescription)
        }
        input.fileHandleForWriting.write(Data(source.utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw StoreError.message(message.isEmpty
                ? "SSH exited \(process.terminationStatus)." : message)
        }
        do {
            return try JSONDecoder().decode(RemoteResponse.self, from: data)
        } catch {
            let body = String(decoding: data.prefix(500), as: UTF8.self)
            throw StoreError.message("Could not decode the remote tracker response: \(body)")
        }
    }

    private static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 255 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-@"))
        guard host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        let parts = host.split(separator: "@", omittingEmptySubsequences: false)
        return (parts.count == 1 && !parts[0].isEmpty)
            || (parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty)
    }

    /// One dependency-free helper for discovery, snapshots, previews and
    /// append-only responses. Every requested path is resolved and checked
    /// against the project root before it is read or written.
    private static let remoteHelper = #"""
import base64
import json
import os
import re
import subprocess

request = json.loads(base64.b64decode(REQUEST_B64).decode("utf-8"))

def respond(value):
    print(json.dumps(value, ensure_ascii=False))

def within(path, parent):
    path = os.path.realpath(path)
    parent = os.path.realpath(parent)
    return path == parent or path.startswith(parent + os.sep)

def find_tracker(start):
    candidate = os.path.realpath(os.path.expanduser(start))
    if not os.path.isdir(candidate):
        candidate = os.path.dirname(candidate)
    while candidate and candidate != os.path.dirname(candidate):
        if os.path.isdir(os.path.join(candidate, "issues")):
            for index_name in ("issues.md", "ISSUES.md"):
                if os.path.isfile(os.path.join(candidate, index_name)):
                    return {"root": candidate, "index_file": index_name}
        candidate = os.path.dirname(candidate)
    return None

try:
    op = request.get("op")
    if op == "discover":
        respond(find_tracker(request["cwd"]) or {})

    elif op == "discover_sessions":
        zmx = "/Applications/trm.app/Contents/MacOS/zmx"
        tmp = os.environ.get("TMPDIR", "/tmp").rstrip("/")
        directories = [
            os.path.expanduser("~/.trm/zmx"),
            os.path.join(os.environ.get("XDG_RUNTIME_DIR", ""), "zmx"),
            os.path.join(tmp, "zmx-" + str(os.getuid())),
        ]
        sessions = {}
        if os.path.isfile(zmx) and os.access(zmx, os.X_OK):
            for directory in directories:
                if not directory or directory == "zmx" or not os.path.isdir(directory):
                    continue
                env = dict(os.environ)
                env["ZMX_DIR"] = directory
                try:
                    listed = subprocess.run(
                        [zmx, "list"], env=env, text=True,
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                        timeout=5, check=False).stdout
                except (OSError, subprocess.TimeoutExpired):
                    continue
                for line in listed.splitlines():
                    fields = {}
                    for token in line.split():
                        if "=" in token:
                            key, value = token.split("=", 1)
                            fields[key] = value
                    name, pid = fields.get("name"), fields.get("pid")
                    if not name or name in sessions or not (pid or "").isdigit():
                        continue
                    try:
                        opened = subprocess.run(
                            ["/usr/sbin/lsof", "-a", "-p", pid, "-d", "cwd", "-Fn"],
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            timeout=3, check=False).stdout
                    except (OSError, subprocess.TimeoutExpired):
                        continue
                    cwd = next(
                        (row[1:] for row in opened.splitlines()
                         if row.startswith("n/") and len(row) > 2), None)
                    if not cwd:
                        continue
                    context = {"cwd": cwd}
                    tracker = find_tracker(cwd)
                    if tracker:
                        context.update(tracker)
                    sessions[name] = context
        respond({"sessions": sessions})

    elif op == "snapshot":
        root = os.path.realpath(os.path.expanduser(request["root"]))
        index_name = request["index"]
        index_path = os.path.realpath(os.path.join(root, index_name))
        issues_root = os.path.realpath(os.path.join(root, "issues"))
        if not within(index_path, root) or not within(issues_root, root):
            raise ValueError("Tracker paths leave the project root")
        with open(index_path, "r", encoding="utf-8") as handle:
            index = handle.read()
        documents = {}
        for name in os.listdir(issues_root):
            if not re.match(r"^[A-Za-z]+-[0-9]+\.md$", name):
                continue
            path = os.path.realpath(os.path.join(issues_root, name))
            if not within(path, issues_root) or not os.path.isfile(path):
                continue
            with open(path, "r", encoding="utf-8") as handle:
                documents[os.path.splitext(name)[0].upper()] = {
                    "content": handle.read(), "modified": os.path.getmtime(path)
                }
        artifacts = []
        artifacts_root = os.path.realpath(os.path.join(issues_root, "artifacts"))
        if os.path.isdir(artifacts_root):
            for directory, names, files in os.walk(artifacts_root, followlinks=False):
                names[:] = [name for name in names if not name.startswith(".")]
                for name in files:
                    if name.startswith("."):
                        continue
                    path = os.path.realpath(os.path.join(directory, name))
                    if not within(path, artifacts_root) or not os.path.isfile(path):
                        continue
                    relative = os.path.relpath(path, root).replace(os.sep, "/")
                    stat = os.stat(path)
                    artifacts.append({
                        "relative": relative, "name": name,
                        "size": stat.st_size, "modified": stat.st_mtime
                    })
        respond({"index": index, "documents": documents, "artifacts": artifacts})

    elif op == "read_artifact":
        root = os.path.realpath(os.path.expanduser(request["root"]))
        artifacts_root = os.path.realpath(os.path.join(root, "issues", "artifacts"))
        path = os.path.realpath(os.path.join(root, request["relative"]))
        limit = int(request["limit"])
        if not within(path, artifacts_root) or not os.path.isfile(path):
            raise ValueError("Artifact is outside this issue tracker")
        if os.path.getsize(path) > limit:
            raise ValueError("Artifact is too large to preview inline")
        with open(path, "rb") as handle:
            respond({"data": base64.b64encode(handle.read()).decode("ascii")})

    elif op == "append_response":
        root = os.path.realpath(os.path.expanduser(request["root"]))
        issue_id = request["issue_id"].upper()
        if not re.match(r"^[A-Za-z]+-[0-9]+$", issue_id):
            raise ValueError("Invalid issue id")
        artifacts_root = os.path.realpath(os.path.join(root, "issues", "artifacts"))
        directory = os.path.realpath(os.path.join(artifacts_root, issue_id))
        if not within(directory, artifacts_root):
            raise ValueError("Response path leaves the issue tracker")
        os.makedirs(directory, exist_ok=True)
        path = os.path.join(directory, "responses.md")
        exists = os.path.exists(path)
        with open(path, "a", encoding="utf-8") as handle:
            if not exists:
                handle.write("# Issue responses — " + issue_id + "\n\n")
            else:
                handle.write("\n")
            handle.write(request["block"])
        respond({"relative": os.path.relpath(path, root).replace(os.sep, "/")})

    else:
        raise ValueError("Unknown issue tracker operation")
except Exception as error:
    respond({"error": str(error)})
"""#
}

/// Coalesces pane-chrome discovery. A restored window can contain a dozen
/// panes in one project; they should not produce a dozen simultaneous SSH
/// probes merely to decide whether to draw the same button.
actor IssueTrackerDiscoveryCache {
    static let shared = IssueTrackerDiscoveryCache()
    private var values: [String: (checkedAt: Date, project: IssueTrackerProject?)] = [:]
    private var projectTasks: [String: Task<IssueTrackerProject?, Never>] = [:]
    private var remoteValues: [
        String: (checkedAt: Date, contexts: [String: IssueTrackerRemotePaneContext])
    ] = [:]
    private var remoteTasks: [
        String: Task<(contexts: [String: IssueTrackerRemotePaneContext], error: String?), Never>
    ] = [:]
    private let lifetime: TimeInterval = 30

    func project(
        cwd: String?, remoteHost: String?, remoteSession: String? = nil
    ) async -> IssueTrackerProject? {
        // A restored remote surface has no Ghostty pwd. Its persisted zmx
        // session is the authoritative identity, and one host-wide probe
        // resolves every pane without an SSH stampede.
        if let remoteHost, let remoteSession {
            let contexts = await remoteContexts(host: remoteHost)
            if let context = contexts[remoteSession] { return context.project }
        }

        guard let cwd, !cwd.isEmpty else { return nil }
        let key = "\(remoteHost ?? "local")|\(cwd)"
        if let cached = values[key], Date().timeIntervalSince(cached.checkedAt) < lifetime {
            return cached.project
        }

        if let task = projectTasks[key] { return await task.value }
        let task = Task {
            await IssueTrackerStore.discover(cwd: cwd, remoteHost: remoteHost)
        }
        projectTasks[key] = task
        let project = await task.value
        projectTasks[key] = nil
        values[key] = (Date(), project)
        return project
    }

    func remoteContexts(host: String) async -> [String: IssueTrackerRemotePaneContext] {
        if let cached = remoteValues[host],
           Date().timeIntervalSince(cached.checkedAt) < lifetime {
            return cached.contexts
        }
        if let task = remoteTasks[host] { return await task.value.contexts }

        let task = Task.detached(priority: .utility) {
            () -> (contexts: [String: IssueTrackerRemotePaneContext], error: String?) in
            do {
                return (
                    contexts: try IssueTrackerStore.remotePaneContexts(host: host),
                    error: nil)
            } catch {
                return (contexts: [:], error: error.localizedDescription)
            }
        }
        remoteTasks[host] = task
        let loaded = await task.value
        remoteTasks[host] = nil
        // Retry a failed host sooner. A laptop waking or an SSH agent becoming
        // available should not hide the affordance for a full cache lifetime.
        let checkedAt = loaded.error == nil ? Date() : Date().addingTimeInterval(-20)
        remoteValues[host] = (checkedAt, loaded.contexts)
        if let error = loaded.error {
            TrmDiagnostics.log("[issue-tracker] remote pane discovery on \(host) failed: \(error)")
        }
        return loaded.contexts
    }
}

@MainActor
final class IssueTrackerModel: ObservableObject {
    struct AgentAssignments {
        let projectAgents: [CommandCenterMonitor.Entry]
        let byIssue: [String: [CommandCenterMonitor.Entry]]
        let unassigned: [CommandCenterMonitor.Entry]
    }

    let project: IssueTrackerProject
    @Published private(set) var issues: [TrackedIssue] = []
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var artifactData: [String: Data] = [:]
    @Published private(set) var artifactErrors: [String: String] = [:]
    @Published private(set) var submissionStatus: [String: String] = [:]
    @Published private(set) var remoteWorkingDirectories: [String: String] = [:]

    private weak var sourceSurface: Ghostty.SurfaceView?
    private var timer: Timer?
    private var refreshInFlight = false
    private var remoteContextRefreshInFlight = false
    private var artifactVersions: [String: String] = [:]

    init(project: IssueTrackerProject, sourceSurface: Ghostty.SurfaceView?) {
        self.project = project
        self.sourceSurface = sourceSurface
    }

    func updateSource(_ surface: Ghostty.SurfaceView) {
        sourceSurface = surface
    }

    func start() {
        CommandCenterMonitor.shared.subscribe()
        refresh()
        guard timer == nil else { return }
        let interval: TimeInterval = project.remoteHost == nil ? 2 : 5
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        CommandCenterMonitor.shared.unsubscribe()
    }

    func refresh() {
        refreshRemotePaneContexts()
        guard !refreshInFlight else { return }
        refreshInFlight = true
        let project = project
        let startedAt = Date()
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try IssueTrackerStore.snapshot(project) }
            }.value
            guard let self else { return }
            self.refreshInFlight = false
            let wasInitialLoad = self.isLoading
            self.isLoading = false
            switch result {
            case .success(let snapshot):
                // Publishing an identical 65-item value tree forces SwiftUI
                // to reconcile the whole board even though no file changed.
                // The polling interval is intentionally short for live work;
                // make the no-change path correspondingly cheap.
                if self.issues != snapshot.issues {
                    self.issues = snapshot.issues
                }
                self.errorMessage = nil
                if wasInitialLoad {
                    let elapsed = Date().timeIntervalSince(startedAt)
                    TrmDiagnostics.log(
                        "[issue-tracker] loaded \(snapshot.issues.count) issues from "
                            + "\(project.locationLabel) in \(String(format: "%.2f", elapsed))s")
                }
            case .failure(let error):
                self.errorMessage = error.localizedDescription
                if wasInitialLoad {
                    TrmDiagnostics.log(
                        "[issue-tracker] initial load failed for \(project.locationLabel): "
                            + error.localizedDescription)
                }
            }
        }
    }

    private func refreshRemotePaneContexts() {
        guard let host = project.remoteHost, !remoteContextRefreshInFlight else { return }
        remoteContextRefreshInFlight = true
        Task { [weak self] in
            let contexts = await IssueTrackerDiscoveryCache.shared.remoteContexts(host: host)
            guard let self else { return }
            self.remoteContextRefreshInFlight = false
            let directories = contexts.mapValues(\.cwd)
            if self.remoteWorkingDirectories != directories {
                self.remoteWorkingDirectories = directories
            }
        }
    }

    func loadArtifact(_ artifact: IssueArtifact) {
        guard artifact.kind != .other,
              artifact.size <= IssueTrackerStore.artifactSizeLimit,
              artifactVersions[artifact.id] != artifact.loadID else { return }
        // Mark in flight with this version as well: repeated SwiftUI body
        // evaluation must not open multiple SSH transfers for one image.
        artifactVersions[artifact.id] = artifact.loadID
        let project = project
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try IssueTrackerStore.readArtifact(artifact, project: project) }
            }.value
            guard let self else { return }
            switch result {
            case .success(let data):
                self.artifactData[artifact.id] = data
                self.artifactErrors[artifact.id] = nil
            case .failure(let error):
                self.artifactErrors[artifact.id] = error.localizedDescription
                self.artifactVersions[artifact.id] = nil
            }
        }
    }

    func projectAgents(_ entries: [CommandCenterMonitor.Entry]) -> [CommandCenterMonitor.Entry] {
        entries.filter { entry in
            guard let surface = entry.surface else { return false }
            if surface.remoteHost != project.remoteHost { return false }
            let cwd = AgentOverviewPane.workingDirectory(for: surface)
                ?? surface.remoteZmxSession.flatMap { remoteWorkingDirectories[$0] }
            guard let cwd else { return false }
            return Self.path(cwd, isWithin: project.rootPath)
        }
    }

    func agents(
        for issue: TrackedIssue, entries: [CommandCenterMonitor.Entry]
    ) -> [CommandCenterMonitor.Entry] {
        projectAgents(entries).filter {
            activeIssueIDs(for: $0).contains(issue.id)
        }
    }

    /// Build the board's routing index in one pass. The original view asked
    /// `agents(for:)` independently for every card, and that method scans all
    /// issue IDs in each agent transcript. With fasmac's 65 issues the board
    /// repeated the same scan thousands of times on every streaming update.
    func agentAssignments(_ entries: [CommandCenterMonitor.Entry]) -> AgentAssignments {
        let candidates = projectAgents(entries)
        var byIssue: [String: [CommandCenterMonitor.Entry]] = [:]
        var assigned = Set<ObjectIdentifier>()
        for entry in candidates {
            let issueIDs = activeIssueIDs(for: entry)
            if !issueIDs.isEmpty { assigned.insert(entry.id) }
            for issueID in issueIDs {
                byIssue[issueID, default: []].append(entry)
            }
        }
        return AgentAssignments(
            projectAgents: candidates,
            byIssue: byIssue,
            unassigned: candidates.filter { !assigned.contains($0.id) })
    }

    func submit(
        issue: TrackedIssue,
        text rawText: String,
        entries: [CommandCenterMonitor.Entry]
    ) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let route = routingAgent(for: issue, entries: entries)
        let delivery = route.map { "forwarded to \($0.kind?.displayName ?? "agent") in \($0.watermark)" }
            ?? "saved only — no live project agent was available"
        submissionStatus[issue.id] = "Saving…"
        let project = project
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    try IssueTrackerStore.appendResponse(
                        project: project,
                        issueID: issue.id,
                        text: text,
                        delivery: delivery)
                }
            }.value
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.submissionStatus[issue.id] = "Not sent: \(error.localizedDescription)"
            case .success:
                if let routeID = route?.id,
                   let current = CommandCenterMonitor.shared.entries.first(where: { $0.id == routeID }),
                   let surface = current.surface {
                    if Self.send("[Issue \(issue.id)] \(text)", to: surface) {
                        self.submissionStatus[issue.id] = "Saved and sent to \(current.watermark)"
                    } else {
                        self.submissionStatus[issue.id] =
                            "Saved in issues/artifacts/\(issue.id)/responses.md; agent pane disappeared"
                    }
                } else {
                    self.submissionStatus[issue.id] = "Saved in issues/artifacts/\(issue.id)/responses.md"
                }
                self.refresh()
            }
        }
    }

    private func routingAgent(
        for issue: TrackedIssue,
        entries: [CommandCenterMonitor.Entry]
    ) -> CommandCenterMonitor.Entry? {
        if let explicit = agents(for: issue, entries: entries).first { return explicit }
        let projectEntries = projectAgents(entries)
        if let sourceSurface,
           let source = projectEntries.first(where: { $0.surface === sourceSurface }) {
            return source
        }
        return projectEntries.count == 1 ? projectEntries[0] : nil
    }

    /// The newest issue reference wins, but a single prompt may intentionally
    /// name more than one issue. Looking at every historical prompt made an
    /// agent that had handled ten tickets appear live on all ten cards; walk
    /// back only until the most recent prompt containing any current ID.
    private func activeIssueIDs(for entry: CommandCenterMonitor.Entry) -> Set<String> {
        let current = [entry.prompt, Optional(entry.message)]
            .compactMap { $0 }
            .joined(separator: "\n")
        let currentIDs = Set(issues.compactMap {
            Self.containsIssueID($0.id, in: current) ? $0.id : nil
        })
        if !currentIDs.isEmpty { return currentIDs }

        for prompt in entry.promptHistory.reversed() {
            let ids = Set(issues.compactMap {
                Self.containsIssueID($0.id, in: prompt) ? $0.id : nil
            })
            if !ids.isEmpty { return ids }
        }
        return []
    }

    @discardableResult
    private static func send(_ text: String, to surface: Ghostty.SurfaceView) -> Bool {
        guard let controller = TerminalController.all.first(where: { controller in
            controller.surfaceTree.contains(where: { $0 === surface })
        }) else { return false }
        controller.sendMessageToSurface(surface, text: text)
        return true
    }

    nonisolated static func containsIssueID(_ issueID: String, in text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: issueID)
        return text.range(
            of: "(?i)(?<![A-Z0-9])\(escaped)(?![A-Z0-9])",
            options: .regularExpression) != nil
    }

    nonisolated static func path(_ path: String, isWithin root: String) -> Bool {
        let normalizedPath = (path as NSString).standardizingPath
        let normalizedRoot = (root as NSString).standardizingPath
        return normalizedPath == normalizedRoot || normalizedPath.hasPrefix(normalizedRoot + "/")
    }
}
