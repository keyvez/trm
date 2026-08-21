import SwiftUI

/// The board: one section per paired Mac, one card per agent inside it.
///
/// Grouped by machine rather than merged into one flat list, because a
/// watermark ("trm", "pe") is only unique within the machine that issued it,
/// and because a machine that can't be reached is itself something you need to
/// see. A flat list would render "the mini is unreachable" and "the mini has
/// nothing running" as the same empty space.
struct BoardView: View {
    @EnvironmentObject private var client: CommandCenterClient
    @State private var showingPairing = false
    @State private var drafts: [String: String] = [:]
    @FocusState private var focusedDraft: String?

    var body: some View {
        NavigationStack {
            Group {
                if !client.isPaired {
                    unpaired
                } else {
                    List {
                        ForEach(client.links) { link in
                            Section {
                                if link.entries.isEmpty {
                                    placeholder(for: link)
                                } else {
                                    ForEach(link.entries) { entry in
                                        card(entry)
                                            .listRowInsets(EdgeInsets(
                                                top: 10, leading: 14, bottom: 10, trailing: 14))
                                    }
                                }
                            } header: {
                                header(for: link)
                            }
                        }
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
                        Image(systemName: client.isPaired ? "gearshape" : "qrcode.viewfinder")
                    }
                }
            }
            .sheet(isPresented: $showingPairing) {
                PairingView().environmentObject(client)
            }
        }
    }

    /// One machine, or the app's name when several are on screen and no single
    /// one owns the title.
    private var title: String {
        client.links.count == 1 ? client.links[0].name : "trm"
    }

    // MARK: - States

    private var unpaired: some View {
        ContentUnavailableView {
            Label("Not paired", systemImage: "qrcode.viewfinder")
        } description: {
            Text("On your Mac, choose View → Pair iPhone… and scan the code. "
                 + "Pair each machine you run agents on — they're dialled separately.")
        } actions: {
            Button("Scan Code") { showingPairing = true }
                .buttonStyle(.borderedProminent)
        }
    }

    /// The machine's name and what its own connection is doing. Per machine
    /// and not global: one Mac being asleep says nothing about the others.
    private func header(for link: MachineLink) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(tint(for: link.state))
                .frame(width: 7, height: 7)
            Text(link.name)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .textCase(nil)
            Spacer()
            Text(stateLabel(for: link))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textCase(nil)
        }
    }

    /// What to show inside a machine's section when it has no rows. "Can't
    /// reach it", "still asking" and "nothing running" are three different
    /// answers and each one is worth its own words.
    @ViewBuilder
    private func placeholder(for link: MachineLink) -> some View {
        switch link.state {
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Can't reach \(link.name)", systemImage: "wifi.exclamationmark")
                    .font(.system(size: 13, weight: .medium))
                Text(message)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("Try Again") { client.refresh() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .padding(.vertical, 4)
        case .connected:
            Text("No agents running.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        case .connecting, .idle:
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking for agents…")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func stateLabel(for link: MachineLink) -> String {
        switch link.state {
        case .connected:
            let count = link.entries.count
            return count == 1 ? "1 agent" : "\(count) agents"
        case .connecting: return "connecting"
        case .idle: return "idle"
        case .failed: return "offline"
        }
    }

    private func tint(for state: LinkState) -> Color {
        switch state {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed: return .red
        case .idle: return .secondary
        }
    }

    // MARK: - Card

    private func card(_ entry: BoardEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(entry.status.color)
                    .frame(width: 8, height: 8)
                // The watermark opens the terminal behind the row. A card
                // summarises; sometimes the summary is the thing you doubt,
                // and then the only answer is what actually scrolled past.
                // On the watermark rather than the whole card, because the
                // card's own job is the reply box and a tap that navigates
                // away mid-sentence would be the wrong one.
                NavigationLink {
                    SessionScrollbackView(entry: entry)
                        .environmentObject(client)
                } label: {
                    HStack(spacing: 3) {
                        Text(entry.watermark)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(entry.status.color.opacity(0.6))
                    }
                    .foregroundStyle(entry.status.color)
                }
                .buttonStyle(.plain)
                Text(entry.status.rawValue.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(entry.status.color.opacity(0.9))
                Text(entry.agent)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                // A session with no window open on it is still a live agent —
                // this only says there is nothing to walk over and look at.
                if entry.detached {
                    Text("DETACHED")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
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
            get: { drafts[entry.id] ?? "" },
            set: { drafts[entry.id] = $0 }
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
                .focused($focusedDraft, equals: entry.id)
                .submitLabel(.send)
                .onSubmit { send(entry) }

            Button {
                send(entry)
            } label: {
                Image(systemName: client.isSending(entry)
                      ? "arrow.up.circle" : "arrow.up.circle.fill")
                    .font(.system(size: 22))
            }
            .disabled(binding.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func send(_ entry: BoardEntry) {
        let text = (drafts[entry.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        client.send(text: text, to: entry)
        drafts[entry.id] = ""
        focusedDraft = nil
    }
}
