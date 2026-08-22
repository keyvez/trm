import SwiftUI

/// The terminal behind a board row: what the pane would be showing if you were
/// sitting in front of it.
///
/// A briefing says what an agent concluded, which is the right thing to read
/// almost always and useless exactly when the conclusion is the thing you
/// doubt — then the only answer is what actually scrolled past. This is that,
/// over the same connection, without needing the Mac in front of you.
///
/// Read-only on purpose. Answering an agent already has a place — the docked
/// box on the board — and a full terminal you can type into is a different,
/// much larger thing than a window you can look at.
struct SessionScrollbackView: View {
    let entry: BoardEntry
    @EnvironmentObject private var client: CommandCenterClient

    /// Wrapped by default.
    ///
    /// Terminal output is written for an 80-to-240-column window and a phone
    /// has about 50 at a readable size, so the honest default is to fold the
    /// lines rather than ask someone to pan a page-width canvas with a thumb.
    /// Off is still worth having: a table or a diff only means anything with
    /// its columns intact.
    @AppStorage("ScrollbackWrap") private var wrap = true
    /// Persisted, because the size that suits your eyes doesn't change between
    /// one session and the next.
    @AppStorage("ScrollbackFontSize") private var fontSize = 12.0

    private static let sizeRange = 8.0...20.0
    private static let bottomAnchor = "trm.scrollback.bottom"

    private var link: MachineLink? { client.link(for: entry) }
    private var text: String { link?.scrollback[entry.id] ?? "" }
    private var note: String? { link?.scrollbackNote[entry.id] }
    private var isLoading: Bool { link?.loadingScrollback.contains(entry.id) ?? false }

    var body: some View {
        Group {
            if let note {
                ContentUnavailableView {
                    Label("No scrollback here", systemImage: "rectangle.on.rectangle.slash")
                } description: {
                    Text(note)
                }
            } else if text.isEmpty {
                if isLoading {
                    ProgressView("Reading the session…")
                } else {
                    ContentUnavailableView {
                        Label("Nothing yet", systemImage: "terminal")
                    } description: {
                        Text("This session hasn't printed anything.")
                    }
                }
            } else {
                terminal
            }
        }
        .navigationTitle(entry.watermark)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .onAppear { client.requestScrollback(for: entry) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                wrap.toggle()
            } label: {
                Image(systemName: wrap
                      ? "text.alignleft"
                      : "arrow.left.and.right.text.vertical")
            }
            .accessibilityLabel(wrap ? "Wrapping on" : "Wrapping off")

            Menu {
                // A stepper rather than pinch-to-zoom: the text is selectable,
                // and a pinch that sometimes zooms and sometimes starts a
                // selection is worse than a control you can find.
                Button { bump(+1) } label: { Label("Larger", systemImage: "textformat.size.larger") }
                    .disabled(fontSize >= Self.sizeRange.upperBound)
                Button { bump(-1) } label: { Label("Smaller", systemImage: "textformat.size.smaller") }
                    .disabled(fontSize <= Self.sizeRange.lowerBound)
                Divider()
                Button { fontSize = 12 } label: { Label("Reset Size", systemImage: "arrow.counterclockwise") }
            } label: {
                Image(systemName: "textformat.size")
            }

            Button {
                client.requestScrollback(for: entry)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(isLoading)
        }
    }

    private func bump(_ delta: Double) {
        fontSize = min(Self.sizeRange.upperBound, max(Self.sizeRange.lowerBound, fontSize + delta))
    }

    private var terminal: some View {
        ScrollViewReader { proxy in
            ScrollView(wrap ? [.vertical] : [.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    // One Text rather than a line per row: the terminal is one
                    // block of preformatted output, and splitting it lets
                    // SwiftUI reflow across lines that must not be reflowed.
                    Text(text)
                        .font(.system(size: fontSize, design: .monospaced))
                        .textSelection(.enabled)
                        // Wrapped: fold long lines, never widen past the screen.
                        // Unwrapped: keep every line whole and let the view pan.
                        .fixedSize(horizontal: !wrap, vertical: true)
                        .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
            }
            // The newest output is why you opened this; the top of a 400-line
            // dump is the wrong place to start.
            .onAppear { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            .onChange(of: text) { _ in proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            // Re-anchor after a reflow, or the view keeps a scroll offset that
            // meant something at the old width and nothing at the new one.
            .onChange(of: wrap) { _ in proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        }
    }
}
