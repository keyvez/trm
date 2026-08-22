import PhotosUI
import SwiftUI

/// The board: one section per paired Mac, one card per agent inside it.
///
/// Grouped by machine rather than merged into one flat list, because a
/// watermark ("trm", "pe") is only unique within the machine that issued it,
/// and because a machine that can't be reached is itself something you need to
/// see. A flat list would render "the mini is unreachable" and "the mini has
/// nothing running" as the same empty space.
///
/// One reply box, docked at the bottom, addressed to whichever card you tapped
/// — not a box per card. A box on every card spends a third of each card on a
/// control that is empty almost always, pushes the cards apart so fewer fit on
/// a phone screen, and puts eight identical text fields on one screen where
/// only one can be in use. Tapping a card aims the single box at it.
struct BoardView: View {
    @EnvironmentObject private var client: CommandCenterClient
    @State private var showingPairing = false
    @State private var drafts: [String: String] = [:]
    /// Which row the docked box is addressed to. Stored by id rather than by
    /// entry: a snapshot arrives every second and replaces every value, so
    /// holding the struct would aim the box at a stale copy.
    @State private var replyTargetID: String?
    @FocusState private var composerFocused: Bool
    @State private var photoPick: PhotosPickerItem?
    /// Thumbnails of what has been attached to each row's draft, so you can
    /// see *which* photo went — a bare path in the box proves something
    /// happened but not that it was the right thing.
    @State private var attachedPreviews: [String: [UIImage]] = [:]

    /// The live row the box is aimed at, or nil when it is closed. Resolving
    /// through `client` each time is what keeps the header's status dot and
    /// watermark current while you are typing.
    private var replyTarget: BoardEntry? {
        guard let replyTargetID else { return nil }
        return client.entries.first { $0.id == replyTargetID }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !client.isPaired {
                    unpaired
                } else {
                    ScrollViewReader { proxy in
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
                    // An inset rather than an overlay, so the last card can
                    // still be scrolled clear of the box instead of sitting
                    // underneath it.
                    .safeAreaInset(edge: .bottom, spacing: 0) { composer }
                    // Bring the card you tapped to rest directly on top of the
                    // box. Answering means reading the thing you are answering,
                    // and the card is as likely to be off-screen as not — the
                    // one you tap is often the last one down a long board.
                    // `.bottom` against the inset-adjusted area is what puts it
                    // above the box rather than behind it.
                    .onChange(of: replyTargetID) { id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                    // The keyboard resizes the safe area *after* the tap, so a
                    // single scroll lands short by the height of the keyboard.
                    // Settling again once it is up is what actually leaves the
                    // card sitting on the box.
                    .onChange(of: composerFocused) { focused in
                        guard focused, let id = replyTargetID else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(id, anchor: .bottom)
                            }
                        }
                    }
                    }
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
        let isTarget = entry.id == replyTargetID
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(entry.status.color)
                    .frame(width: 8, height: 8)
                // The watermark opens the terminal behind the row. A card
                // summarises; sometimes the summary is the thing you doubt,
                // and then the only answer is what actually scrolled past.
                NavigationLink {
                    SessionScrollbackView(entry: entry)
                        .environmentObject(client)
                } label: {
                    HStack(spacing: 4) {
                        Text(entry.watermark)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        // A terminal glyph rather than a bare chevron: the
                        // chevron read as decoration on a card that is already
                        // tappable, so nobody could tell the one thing that
                        // opens the scrollback from the rest of the header.
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(entry.status.color)
                    .padding(.vertical, 4)
                    .padding(.trailing, 4)
                    .contentShape(Rectangle())
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

            // A draft written for this card and left behind when you tapped
            // another one: said here, because the docked box can only show the
            // one it is currently aimed at and silently losing the rest would
            // be worse than not keeping them.
            if !isTarget, let draft = drafts[entry.id], !draft.isEmpty {
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
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(entry.status.color.opacity(isTarget ? 0.9 : 0), lineWidth: 2)
        )
        // The whole card, not just a strip of it: the padding, the status dot
        // and the empty space beside a short headline are all places a thumb
        // aims at when it means "this one".
        //
        // `simultaneousGesture` rather than `onTapGesture`, because the latter
        // is a *parent* gesture over a NavigationLink and won the race for the
        // watermark's taps — so the one control that opens the terminal did
        // nothing, and every tap anywhere aimed the reply box instead. Sharing
        // the gesture lets the link fire and still aims the box.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { aim(at: entry) })
    }

    // MARK: - Docked composer

    @ViewBuilder
    private var composer: some View {
        if let entry = replyTarget {
            VStack(spacing: 0) {
                Divider()
                HStack(alignment: .bottom, spacing: 8) {
                    // Which agent this is going to, in the same colours the
                    // card uses. One box for eight agents is only safe if it
                    // never leaves you guessing which one is listening.
                    VStack(spacing: 2) {
                        Circle()
                            .fill(entry.status.color)
                            .frame(width: 7, height: 7)
                        Text(entry.watermark)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(entry.status.color)
                        if client.links.count > 1 {
                            Text(entry.machine)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.bottom, 6)

                    PhotosPicker(selection: $photoPick, matching: .images) {
                        Image(systemName: client.isAttaching(entry)
                              ? "photo.badge.arrow.down" : "photo.on.rectangle")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                    }
                    .disabled(client.isAttaching(entry))
                    .padding(.bottom, 6)

                    // Pasting is how a screenshot usually arrives: you copy it
                    // somewhere else and want it here, without a trip through
                    // the photo library. Only offered when the pasteboard
                    // actually holds one.
                    if UIPasteboard.general.hasImages {
                        Button {
                            pasteImage(into: entry)
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 18))
                                .foregroundStyle(.secondary)
                        }
                        .disabled(client.isAttaching(entry))
                        .padding(.bottom, 7)
                    }

                    TextField("Reply to \(entry.watermark)…", text: draftBinding(entry), axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .font(.system(size: 14, design: .monospaced))
                        .focused($composerFocused)
                        // The key inserts a newline on a vertical-axis
                        // field rather than submitting, so labelling it "send"
                        // was the control lying about itself.
                        .submitLabel(.return)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.primary.opacity(0.08))
                        )

                    Button {
                        send(entry)
                    } label: {
                        Image(systemName: client.isSending(entry)
                              ? "arrow.up.circle" : "arrow.up.circle.fill")
                            .font(.system(size: 26))
                    }
                    .disabled(trimmedDraft(entry).isEmpty)
                    .padding(.bottom, 2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                if let shots = attachedPreviews[entry.id], !shots.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(shots.enumerated()), id: \.offset) { index, image in
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .overlay(alignment: .topTrailing) {
                                        // Removing the thumbnail only forgets
                                        // the picture, not the path already in
                                        // the draft — the file is on the Mac
                                        // and the text is yours to edit.
                                        Button {
                                            attachedPreviews[entry.id]?.remove(at: index)
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 13))
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, .black.opacity(0.6))
                                        }
                                        .offset(x: 4, y: -4)
                                    }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    }
                }

                if let problem = client.attachError(for: entry) {
                    Text(problem)
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                }
            }
            .background(.bar)
            .transition(.move(edge: .bottom))
            // A picked photo is downscaled and sent as soon as it is chosen;
            // the Mac writes it and answers with a path, which goes into the
            // draft for you to write a sentence around.
            .onChange(of: photoPick) { item in
                guard let item else { return }
                Task { await sendPickedPhoto(item, to: entry) }
            }
            .onReceive(client.objectWillChange) { _ in
                // The path lands asynchronously; consume it once.
                if let path = client.takeAttachedPath(for: entry) {
                    let current = drafts[entry.id] ?? ""
                    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    drafts[entry.id] = trimmed.isEmpty ? path + " " : trimmed + " " + path + " "
                }
            }
        }
    }

    // MARK: - Actions

    /// Point the docked box at a card, or put it away when the same card is
    /// tapped again — the second tap on a thing you already chose reads as
    /// "never mind" far more often than as "yes, again".
    private func aim(at entry: BoardEntry) {
        if replyTargetID == entry.id {
            replyTargetID = nil
            composerFocused = false
            return
        }
        replyTargetID = entry.id
        composerFocused = true
    }

    private func draftBinding(_ entry: BoardEntry) -> Binding<String> {
        Binding(
            get: { drafts[entry.id] ?? "" },
            set: { drafts[entry.id] = $0 }
        )
    }

    private func trimmedDraft(_ entry: BoardEntry) -> String {
        (drafts[entry.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Attach whatever image is on the pasteboard.
    private func pasteImage(into entry: BoardEntry) {
        guard let image = UIPasteboard.general.image else { return }
        attach(image, named: "pasted.jpg", to: entry)
    }

    private func sendPickedPhoto(_ item: PhotosPickerItem, to entry: BoardEntry) async {
        defer { photoPick = nil }
        guard let raw = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: raw) else { return }
        let name = (item.itemIdentifier?.prefix(8)).map { "photo-\($0).jpg" } ?? "photo.jpg"
        attach(image, named: name, to: entry)
    }

    /// Downscale an image and hand it to the Mac, showing it beside the box.
    ///
    /// Downscaled because the wire is one JSON line and a modern phone photo is
    /// eight megabytes before base64; nothing about reading a screenshot needs
    /// the full sensor. 2000px on the long edge stays legible for a terminal
    /// grab or a diagram, at a fraction of the bytes.
    private func attach(_ image: UIImage, named name: String, to entry: BoardEntry) {
        let longEdge = max(image.size.width, image.size.height)
        let scale = longEdge > 2000 ? 2000 / longEdge : 1
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let rendered = UIGraphicsImageRenderer(size: target).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let jpeg = rendered.jpegData(compressionQuality: 0.8) else { return }
        attachedPreviews[entry.id, default: []].append(rendered)
        client.attach(data: jpeg, name: name, to: entry)
    }

    private func send(_ entry: BoardEntry) {
        let text = trimmedDraft(entry)
        guard !text.isEmpty else { return }
        client.send(text: text, to: entry)
        drafts[entry.id] = ""
        attachedPreviews[entry.id] = nil
        composerFocused = false
        replyTargetID = nil
    }
}
