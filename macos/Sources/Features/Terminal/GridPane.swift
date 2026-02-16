import SwiftUI
import GhosttyKit

/// A sum type representing a single pane in the grid layout.
///
/// Each cell in `TrmGridView` is either a terminal surface or an inline webview.
enum GridPane: Identifiable {
    case terminal(Ghostty.SurfaceView)
    case webview(WebViewPane)

    var id: ObjectIdentifier {
        switch self {
        case .terminal(let surface): return ObjectIdentifier(surface)
        case .webview(let pane): return ObjectIdentifier(pane)
        }
    }
}
