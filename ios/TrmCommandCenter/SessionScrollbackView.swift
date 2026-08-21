import SwiftUI

/// The terminal behind a board row: what the pane would be showing if you were
/// sitting in front of it.
///
/// A briefing says what an agent concluded, which is the right thing to read
/// ninety percent of the time and useless the other ten — when the conclusion
/// is the thing you doubt, the only way to judge it is to read what actually
/// scrolled past. This is that, over the same connection, without needing the
/// Mac in front of you.
///
/// Read-only on purpose. Answering an agent already has a place — the reply box
/// on the card — and a full terminal you can type into is a different, much
/// larger thing than a window you can look at.
struct SessionScrollbackView: View {
    let entry: BoardEntry
    @EnvironmentObject private var client: CommandCenterClient

    /// Anchor for the scroll-to-bottom: the newest output is the reason you
    /// opened this, and starting at the top of a 400-line dump is starting in
    /// the wrong place.
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    client.requestScrollback(for: entry)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
        .onAppear { client.requestScrollback(for: entry) }
    }

    private var terminal: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    // One Text rather than a line-per-row list: the terminal is
                    // one block of preformatted output, and splitting it lets
                    // SwiftUI reflow lines that must not reflow.
                    Text(text)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
            }
            .onAppear { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            .onChange(of: text) { _ in
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
    }
}
