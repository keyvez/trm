import SwiftUI

/// The board: one card per agent, ordered as the Mac orders its panes.
struct BoardView: View {
    @EnvironmentObject private var client: CommandCenterClient
    @State private var showingPairing = false
    @State private var drafts: [Int: String] = [:]
    @FocusState private var focusedDraft: Int?

    var body: some View {
        NavigationStack {
            Group {
                if client.pairing == nil {
                    unpaired
                } else if client.entries.isEmpty {
                    waiting
                } else {
                    List(client.entries) { entry in
                        card(entry)
                            .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
                    }
                    .listStyle(.plain)
                    .refreshable { client.refresh() }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingPairing = true
                    } label: {
                        Image(systemName: client.pairing == nil ? "qrcode.viewfinder" : "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingPairing) {
                PairingView().environmentObject(client)
            }
        }
    }

    private var title: String {
        switch client.state {
        case .connected(let host): return host
        case .connecting: return "Connecting…"
        case .failed: return "Offline"
        case .idle: return "trm"
        }
    }

    // MARK: - States

    private var unpaired: some View {
        ContentUnavailableView {
            Label("Not paired", systemImage: "qrcode.viewfinder")
        } description: {
            Text("On your Mac, choose View → Pair iPhone… and scan the code.")
        } actions: {
            Button("Scan Code") { showingPairing = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var waiting: some View {
        VStack(spacing: 10) {
            if case .failed(let message) = client.state {
                Image(systemName: "wifi.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("Can't reach your Mac")
                    .font(.headline)
                // Monospaced because the second line is an address: at
                // footnote size, telling 51735 from 51733 in a proportional
                // face is exactly the comparison this screen exists to let
                // you make.
                Text(message)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("Try Again") { client.connect() }
                    .buttonStyle(.bordered)
            } else {
                ProgressView()
                Text("Checking for agents…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(30)
    }

    // MARK: - Card

    private func card(_ entry: BoardEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(entry.status.color)
                    .frame(width: 8, height: 8)
                Text(entry.watermark)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(entry.status.color)
                Text(entry.status.rawValue.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(entry.status.color.opacity(0.9))
                Text(entry.agent)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                if let updated = entry.updatedAt {
                    Text(updated, style: .relative)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            if let location = entry.location {
                Text([entry.host, location].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text(entry.headline)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if entry.needsAttention {
                Label("Waiting on your answer.", systemImage: "questionmark.bubble")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } else if entry.errors > 0 {
                Label(
                    entry.errorText.map { "\(entry.errors) errors — \($0)" }
                        ?? "\(entry.errors) errors this turn.",
                    systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            replyBox(entry)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(entry.status.color.opacity(entry.status == .idle ? 0.04 : 0.10))
        )
    }

    private func replyBox(_ entry: BoardEntry) -> some View {
        let binding = Binding(
            get: { drafts[entry.pane] ?? "" },
            set: { drafts[entry.pane] = $0 }
        )
        return HStack(spacing: 8) {
            TextField("Reply…", text: binding, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .focused($focusedDraft, equals: entry.pane)
                .submitLabel(.send)
                .onSubmit { send(entry) }

            Button {
                send(entry)
            } label: {
                Image(systemName: client.sending.contains(entry.pane)
                      ? "arrow.up.circle" : "arrow.up.circle.fill")
                    .font(.system(size: 22))
            }
            .disabled(binding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func send(_ entry: BoardEntry) {
        let text = (drafts[entry.pane] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        client.send(text: text, toPane: entry.pane)
        drafts[entry.pane] = ""
        focusedDraft = nil
    }
}
