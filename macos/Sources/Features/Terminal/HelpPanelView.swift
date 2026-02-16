import SwiftUI

/// A translucent overlay showing available keyboard shortcuts.
struct HelpPanelView: View {
    @Binding var isPresented: Bool

    private let shortcuts: [(section: String, items: [(keys: String, description: String)])] = [
        ("Panes", [
            ("\u{2318}N", "New Pane (right)"),
            ("\u{2318}\u{21E7}T", "New Row (below)"),
            ("\u{2318}W", "Close Pane"),
        ]),
        ("Navigation", [
            ("\u{2318}\u{21E7}\u{2190}", "Focus Left"),
            ("\u{2318}\u{21E7}\u{2192}", "Focus Right"),
            ("\u{2318}\u{21E7}\u{2191}", "Focus Up"),
            ("\u{2318}\u{21E7}\u{2193}", "Focus Down"),
            ("\u{2318}1-9", "Jump to Pane"),
        ]),
        ("Command Palette", [
            ("\u{2318}\u{21E7}P", "Toggle Command Palette"),
            ("@ prefix", "Search commands"),
            ("! prefix", "Send raw text"),
        ]),
        ("Window", [
            ("\u{2318}\u{21E7}N", "New Window"),
            ("\u{2318}\u{21E7}F", "Toggle Fullscreen"),
            ("\u{2318}\u{21E7}L", "Toggle Live Summary"),
            ("\u{2318}+", "Increase Font"),
            ("\u{2318}-", "Decrease Font"),
            ("\u{2318}0", "Reset Font"),
        ]),
        ("Help", [
            ("\u{2318}/", "Toggle this panel"),
        ]),
    ]

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Keyboard Shortcuts")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 12)

                Divider()
                    .background(Color.white.opacity(0.2))

                // Shortcuts grid
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(shortcuts, id: \.section) { section in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(section.section)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white.opacity(0.5))
                                    .textCase(.uppercase)

                                ForEach(section.items, id: \.keys) { item in
                                    HStack {
                                        Text(item.keys)
                                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                                            .foregroundColor(.white)
                                            .frame(width: 120, alignment: .trailing)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(
                                                RoundedRectangle(cornerRadius: 4)
                                                    .fill(Color.white.opacity(0.1))
                                            )

                                        Text(item.description)
                                            .font(.system(size: 13))
                                            .foregroundColor(.white.opacity(0.85))

                                        Spacer()
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
            }
            .frame(width: 420)
            .frame(maxHeight: 500)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(white: 0.15, opacity: 0.95))
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}
