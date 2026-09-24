import Foundation
import Testing

/// A pane has one header bar: the grid's `SubPaneBar`.
///
/// Upstream Ghostty draws its own hover-revealed "…" grab handle across the
/// top of every surface. In trm it stacked directly under `SubPaneBar`, so
/// every pane showed two bars. It was deleted, and has come back before;
/// these fail if an upstream merge (or anyone) restores it.
struct GrabHandleRemovalTests {
    private static let surfaceViewDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Grid
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // macos
        .appendingPathComponent("Sources/Ghostty/Surface View")

    @Test func theGrabHandleFileIsGone() {
        let path = Self.surfaceViewDir.appendingPathComponent("SurfaceGrabHandle.swift").path
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func noSurfaceDrawsAGrabHandle() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: Self.surfaceViewDir, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(!source.contains("SurfaceGrabHandle("), "\(file.lastPathComponent) draws SurfaceGrabHandle")
        }
    }
}
