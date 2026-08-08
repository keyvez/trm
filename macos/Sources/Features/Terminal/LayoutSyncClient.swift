import Foundation
import Darwin

/// A Text Tap socket client used by mirror windows to follow the primary
/// UI's layout live.
///
/// Connects to the primary's unix socket, sends a `layout_subscribe` for one
/// window, and reads newline-delimited `layout_update` JSON messages on a
/// background thread. Full-snapshot TOML payloads are delivered on the main
/// thread. If the primary goes away the client reconnects with backoff and
/// re-subscribes (the primary pushes a fresh snapshot to new subscribers), so
/// a mirror that outlives a primary restart resyncs automatically.
final class LayoutSyncClient {
    private let socketPath: String
    private let windowId: String

    /// Called on the main thread with each new layout snapshot (TOML text,
    /// revision). Revisions are monotonic per connection; the counter resets
    /// on reconnect so a restarted primary's snapshots are never ignored.
    var onLayoutUpdate: ((String, Int) -> Void)?

    private let lock = NSLock()
    private var stopped = false
    private var currentFd: Int32 = -1
    private var thread: Thread?

    init(socketPath: String, windowId: String) {
        self.socketPath = socketPath
        self.windowId = windowId
    }

    func start() {
        let t = Thread { [weak self] in self?.runLoop() }
        t.name = "trm.layout-sync"
        t.qualityOfService = .utility
        thread = t
        t.start()
    }

    /// Stop the client. Safe to call from any thread; unblocks a pending read.
    func stop() {
        lock.lock()
        stopped = true
        if currentFd >= 0 {
            shutdown(currentFd, SHUT_RDWR)
        }
        lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func runLoop() {
        var backoff: TimeInterval = 0.5
        while !isStopped {
            if let fd = connectAndSubscribe() {
                lock.lock()
                currentFd = fd
                let alreadyStopped = stopped
                lock.unlock()
                if alreadyStopped {
                    close(fd)
                    return
                }
                backoff = 0.5
                readLoop(fd: fd)
                lock.lock()
                currentFd = -1
                lock.unlock()
                close(fd)
            }
            if isStopped { return }
            Thread.sleep(forTimeInterval: backoff)
            backoff = min(backoff * 2, 5.0)
        }
    }

    private func connectAndSubscribe() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= maxPath else {
            close(fd)
            return nil
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            pathBytes.withUnsafeBytes { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src.prefix(dst.count)))
            }
        }

        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, len)
            }
        }
        guard result == 0 else {
            close(fd)
            return nil
        }

        // Subscribe to this window's layout updates. The window id is a UUID
        // string, so no JSON escaping is needed.
        let sub = "{\"type\": \"layout_subscribe\", \"window\": \"\(windowId)\"}\n"
        let sent = sub.withCString { send(fd, $0, strlen($0), 0) }
        guard sent > 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    private func readLoop(fd: Int32) {
        var buffer = Data()
        var lastRevision = -1
        var lastEpoch: String? = nil
        var chunk = [UInt8](repeating: 0, count: 65536)
        while !isStopped {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return } // Disconnect, error, or shutdown from stop().
            buffer.append(contentsOf: chunk[0..<n])

            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<nl])
                buffer = Data(buffer[buffer.index(after: nl)...])
                handleLine(line, lastRevision: &lastRevision, lastEpoch: &lastEpoch)
            }

            // An unterminated line this large means a torn or hostile
            // stream; drop it rather than growing without bound.
            if buffer.count > 8 << 20 {
                buffer.removeAll(keepingCapacity: false)
            }
        }
    }

    private func handleLine(_ data: Data, lastRevision: inout Int, lastEpoch: inout String?) {
        guard !data.isEmpty,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String, type == "layout_update",
              let window = obj["window"] as? String, window == windowId,
              let revision = obj["revision"] as? Int,
              let toml = obj["toml"] as? String
        else { return }
        // The epoch identifies one broadcasting controller instance. The
        // primary window can be closed and reopened (same window_id, same
        // process, same socket) with its revision counter starting over —
        // a new epoch resets the monotonic guard so those snapshots are
        // not silently discarded.
        let epoch = obj["epoch"] as? String
        if epoch != lastEpoch {
            lastEpoch = epoch
            lastRevision = -1
        }
        // A torn/dropped message self-heals here: every update is a full
        // snapshot, so we only require revisions to move forward.
        guard revision > lastRevision else { return }
        lastRevision = revision
        DispatchQueue.main.async { [weak self] in
            self?.onLayoutUpdate?(toml, revision)
        }
    }
}
