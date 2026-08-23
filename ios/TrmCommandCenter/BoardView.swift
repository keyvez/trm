import SwiftUI

/// The board: one section per paired Mac, one card per agent inside it.
///
/// Grouped by machine rather than merged into one flat list, because a
/// watermark ("trm", "pe") is only unique within the machine that issued it,
/// and because a machine that can't be reached is itself something you need to
/// see. A flat list would render "the mini is unreachable" and "the mini has
/// nothing running" as the same empty space.
///
/// Tapping a card opens that agent in full — its terminal, and the box you
/// answer it from. The board decides *which* agent needs you; dealing with the
/// one you picked happens on its own screen, beside the output you are judging.
/// A reply box on the board was the wrong shape twice over: it spent a third of
/// every card on a control that is empty almost always, and it made the card's
/// tap ambiguous, which is what stopped the terminal opening at all.
struct BoardView: View {
    @EnvironmentObject private var client: CommandCenterClient
    @State private var showingPairing = false

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
                                        NavigationLink {
                                            SessionDetailView(entry: entry)
                                                .environmentObject(client)
                                        } label: {
                                            card(entry)
                                        }
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
                Text(entry.watermark)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(entry.status.color)
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

            // A reply written for this agent and left behind: said here,
            // because the box lives a screen away now and a draft you cannot
            // see is a draft you will write twice.
            if let draft = client.drafts[entry.id], !draft.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty {
                Label(draft, systemImage: "pencil")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(entry.status.color.opacity(entry.status == .idle ? 0.04 : 0.10))
        )
    }
}
