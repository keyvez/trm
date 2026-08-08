import Foundation
import os

extension Notification.Name {
    /// Posted when the installed/enabled extension set changes; controllers
    /// respond by reloading their service plugins.
    static let trmExtensionsChanged = Notification.Name("trmExtensionsChanged")
}

/// Discovers and manages trm extensions on disk.
///
/// Extensions live at `~/Library/Application Support/trm/extensions/<name>/`
/// with an `extension.toml` manifest (see `ExtensionManifest`). The manager
/// scans the directory, validates manifests, tracks per-extension enabled
/// flags (UserDefaults), and hot-reloads on filesystem changes.
@MainActor
final class ExtensionsManager {

    static let shared = ExtensionsManager()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.trm",
        category: "ExtensionsManager"
    )

    /// Parse errors from the last scan, keyed by extension directory name.
    /// Surfaced in logs and by the extension builder UI.
    private(set) var lastErrors: [String: String] = [:]

    private var dirWatcher: DispatchSourceFileSystemObject?
    private var manifestWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private var reloadDebounce: DispatchWorkItem?
    private var cachedExtensions: [ExtensionManifest]? = nil

    private init() {}

    /// Directory holding installed extensions.
    static var extensionsDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let dir = appSupport
            .appendingPathComponent("trm", isDirectory: true)
            .appendingPathComponent("extensions", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - Discovery

    /// All valid installed extensions (enabled or not). Cached until the
    /// directory watcher invalidates.
    func installedExtensions() -> [ExtensionManifest] {
        if let cached = cachedExtensions { return cached }
        let fm = FileManager.default
        let dir = Self.extensionsDirectory
        var result: [ExtensionManifest] = []
        var errors: [String: String] = [:]

        let entries = (try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let dirName = entry.lastPathComponent
            guard fm.fileExists(atPath: entry.appendingPathComponent("extension.toml").path)
            else { continue }
            do {
                let manifest = try ExtensionManifest.load(fromDirectory: entry)
                result.append(manifest)
            } catch {
                // A malformed manifest must never break the scan.
                errors[dirName] = "\(error)"
                Self.logger.error("extension \(dirName) failed to load: \(String(describing: error))")
            }
        }

        lastErrors = errors
        result.sort { $0.name < $1.name }
        cachedExtensions = result
        refreshManifestWatchers(for: result)
        return result
    }

    /// Installed extensions that are enabled.
    func enabledExtensions() -> [ExtensionManifest] {
        installedExtensions().filter { isEnabled($0.name) }
    }

    // MARK: - Enable/Disable

    private func enabledKey(_ name: String) -> String { "trm.ext.enabled.\(name)" }

    /// Extensions are enabled by default once installed.
    func isEnabled(_ name: String) -> Bool {
        UserDefaults.standard.object(forKey: enabledKey(name)) as? Bool ?? true
    }

    func setEnabled(_ name: String, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey(name))
        notifyChanged()
    }

    // MARK: - Install

    /// Install (or replace) an extension from manifest content plus optional
    /// extra files. Used by the extension builder. Returns the directory.
    @discardableResult
    func install(
        name: String,
        manifestContent: String,
        files: [String: Data] = [:]
    ) throws -> URL {
        let sanitized = Self.sanitizeName(name)
        guard !sanitized.isEmpty else {
            throw ExtensionManifest.ParseError.invalidValue(key: "name", value: name)
        }
        let dir = Self.extensionsDirectory.appendingPathComponent(sanitized, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try manifestContent.write(
            to: dir.appendingPathComponent("extension.toml"),
            atomically: true, encoding: .utf8)
        for (filename, data) in files {
            let fileURL = dir.appendingPathComponent(filename)
            try data.write(to: fileURL)
            // Program entry points must be executable.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: fileURL.path)
        }
        notifyChanged()
        return dir
    }

    func uninstall(name: String) {
        let dir = Self.extensionsDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        UserDefaults.standard.removeObject(forKey: enabledKey(name))
        notifyChanged()
    }

    static func sanitizeName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .unicodeScalars
            .filter { allowed.contains($0) }
            .map(String.init)
            .joined()
    }

    // MARK: - Hot Reload

    /// Start watching the extensions directory. Safe to call repeatedly.
    func startWatching() {
        guard dirWatcher == nil else { return }
        let dir = Self.extensionsDirectory
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.debounceNotify()
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        dirWatcher = source
    }

    /// Watch each installed extension's manifest so edits inside extension
    /// folders (not just add/remove of folders) trigger a hot reload.
    private func refreshManifestWatchers(for manifests: [ExtensionManifest]) {
        var live: Set<String> = []
        for manifest in manifests {
            guard let dir = manifest.directory else { continue }
            let path = dir.appendingPathComponent("extension.toml").path
            live.insert(path)
            guard manifestWatchers[path] == nil else { continue }
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                // Atomic saves replace the file; drop the watcher and let the
                // next scan re-create it against the new inode.
                if source.data.contains(.delete) || source.data.contains(.rename) {
                    self.manifestWatchers[path]?.cancel()
                    self.manifestWatchers[path] = nil
                }
                self.debounceNotify()
            }
            source.setCancelHandler { Darwin.close(fd) }
            source.resume()
            manifestWatchers[path] = source
        }
        // Drop watchers for uninstalled extensions.
        for (path, watcher) in manifestWatchers where !live.contains(path) {
            watcher.cancel()
            manifestWatchers[path] = nil
        }
    }

    private func debounceNotify() {
        reloadDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.notifyChanged()
        }
        reloadDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500), execute: item)
    }

    private func notifyChanged() {
        cachedExtensions = nil
        NotificationCenter.default.post(name: .trmExtensionsChanged, object: nil)
    }
}
