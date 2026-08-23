import PhotosUI
import SwiftUI

/// One agent, in full: the terminal it is sitting in, and the box you answer
/// it from.
///
/// The board is for deciding *which* agent needs you; this is for dealing with
/// the one you picked. Putting the reply box here rather than on the board
/// means answering happens next to the thing being answered — a briefing is a
/// summary, and the moment you doubt a summary the only useful thing is what
/// actually scrolled past.
struct SessionDetailView: View {
    let entry: BoardEntry
    @EnvironmentObject private var client: CommandCenterClient
    @FocusState private var composerFocused: Bool
    @State private var photoPick: PhotosPickerItem?
    /// What has been attached to this draft, so you can see *which* picture
    /// went — a path in the box proves something happened, not that it was the
    /// right thing.
    @State private var attachedPreviews: [UIImage] = []
    @State private var showingHistory = false

    /// Wrapped by default.
    ///
    /// Terminal output is written for an 80-to-240-column window and a phone
    /// has about 50 at a readable size, so the honest default is to fold the
    /// lines rather than ask someone to pan a page-wide canvas with a thumb.
    /// Off is still worth having: a table or a diff only means anything with
    /// its columns intact.
    /// Formatted by default.
    ///
    /// The raw view is the terminal exactly as it was drawn, which is the right
    /// answer when you doubt the formatting and the wrong one the rest of the
    /// time: it arrives hard-wrapped to a pane forty columns wide, so a phone
    /// re-wraps text that was wrapped once already.
    /// Summary is the default view.
    ///
    /// It is the same thing the Mac's overview pane shows — what you asked,
    /// what it said, what it is waiting on — which is what you came to find
    /// out. The terminal is underneath it for the times the summary is the
    /// thing you doubt.
    @AppStorage("DetailMode") private var mode = DetailMode.summary
    @AppStorage("OverviewSectionsRaw") private var sectionsRaw = OverviewSections.default.rawValue
    @AppStorage("OverviewBionic") private var bionic = false
    @State private var viewedTurn: Int?

    @AppStorage("ScrollbackFormatted") private var formatted = true
    @AppStorage("ScrollbackWrap") private var wrap = true
    @AppStorage("ScrollbackFontSize") private var fontSize = 12.0

    private static let sizeRange = 8.0...20.0
    private static let bottomAnchor = "trm.scrollback.bottom"

    enum DetailMode: String { case summary, terminal }

    private var sections: OverviewSections {
        get { OverviewSections(rawValue: sectionsRaw) }
        nonmutating set { sectionsRaw = newValue.rawValue }
    }

    private var overview: AgentOverview? { client.overview(for: entry) }

    private var link: MachineLink? { client.link(for: entry) }
    private var text: String { link?.scrollback[entry.id] ?? "" }
    private var note: String? { link?.scrollbackNote[entry.id] }
    private var isLoading: Bool { link?.loadingScrollback.contains(entry.id) ?? false }

    var body: some View {
        Group {
            if mode == .summary {
                summary
            } else {
                content
            }
        }
        .navigationTitle(entry.watermark)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .onAppear {
            client.requestOverview(for: entry)
            client.requestScrollback(for: entry)
        }
    }

    @ViewBuilder
    private var content: some View {
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
        } else if formatted {
            formattedScrollback
        } else {
            terminal
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            // Summary or terminal — the two things you might have come for.
            Button {
                mode = mode == .summary ? .terminal : .summary
                if mode == .summary { client.requestOverview(for: entry, turn: viewedTurn) }
            } label: {
                Image(systemName: mode == .summary ? "text.append" : "terminal")
            }
            .accessibilityLabel(mode == .summary ? "Summary" : "Terminal")

            // Wrapping only means anything in the raw terminal; the formatted
            // view always wraps, because rejoining the lines is the point.
            if mode == .terminal, !formatted {
                Button { wrap.toggle() } label: {
                    Image(systemName: wrap ? "arrow.turn.down.left" : "arrow.left.and.right")
                }
                .accessibilityLabel(wrap ? "Wrapping on" : "Wrapping off")
            }

            Menu {
                if mode == .summary {
                    Section("Show") {
                        ForEach(OverviewSections.allCases, id: \.section.rawValue) { item in
                            Toggle(isOn: Binding(
                                get: { sections.contains(item.section) },
                                set: { isOn in
                                    var next = sections
                                    if isOn { next.insert(item.section) }
                                    else { next.remove(item.section) }
                                    sections = next
                                }
                            )) {
                                Text(item.title)
                            }
                        }
                        Button("Show Everything") { sections = .all }
                    }
                    Section("Reading") {
                        Toggle("Bionic", isOn: Binding(
                            get: { bionic }, set: { bionic = $0 }))
                    }
                } else {
                    Section("Terminal") {
                        Toggle("Formatted", isOn: Binding(
                            get: { formatted }, set: { formatted = $0 }))
                    }
                }

                // A stepper rather than pinch-to-zoom: the text is selectable,
                // and a pinch that sometimes zooms and sometimes starts a
                // selection is worse than a control you can find.
                Button { bump(+1) } label: { Label("Larger", systemImage: "textformat.size.larger") }
                    .disabled(fontSize >= Self.sizeRange.upperBound)
                Button { bump(-1) } label: { Label("Smaller", systemImage: "textformat.size.smaller") }
                    .disabled(fontSize <= Self.sizeRange.lowerBound)
                Divider()
                Button { fontSize = 12 } label: {
                    Label("Reset Size", systemImage: "arrow.counterclockwise")
                }
            } label: {
                Image(systemName: "textformat.size")
            }

            Button {
                if mode == .summary {
                    client.requestOverview(for: entry, turn: viewedTurn)
                } else {
                    client.requestScrollback(for: entry)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(mode == .summary ? client.isLoadingOverview(entry) : isLoading)
        }
    }

    private func bump(_ delta: Double) {
        fontSize = min(Self.sizeRange.upperBound, max(Self.sizeRange.lowerBound, fontSize + delta))
    }

    /// The scrollback rejoined into paragraphs, with the pane's furniture
    /// removed. Prose is set proportionally — it is prose — while code keeps
    /// the monospace and the line breaks that carry its meaning.
    private var formattedScrollback: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(ScrollbackFormatter.format(text)) { block in
                        switch block {
                        case .prose(let body):
                            Text(body)
                                .font(.system(size: fontSize + 2))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        case .code(let body):
                            Text(body)
                                .font(.system(size: fontSize, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(Color.primary.opacity(0.06))
                                )
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onAppear { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            .onChange(of: text) { _ in proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        }
    }

    // MARK: - Summary

    /// The turn, laid out the way the Mac's overview pane lays it out.
    @ViewBuilder
    private var summary: some View {
        if let overview {
            if let note = overview.note {
                ContentUnavailableView {
                    Label("No summary", systemImage: "text.append")
                } description: {
                    Text(note)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if sections.contains(.prompt), let prompt = overview.prompt,
                           !prompt.isEmpty {
                            section("What I Asked") {
                                prose(prompt)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if sections.contains(.questions), !overview.questions.isEmpty {
                            section("Questions") {
                                ForEach(overview.questions) { question in
                                    VStack(alignment: .leading, spacing: 4) {
                                        if let header = question.header, !header.isEmpty {
                                            Text(header)
                                                .font(.system(size: fontSize, weight: .semibold))
                                        }
                                        prose(question.text)
                                        ForEach(Array(question.options.enumerated()), id: \.offset) {
                                            _, option in
                                            Text("• " + option)
                                                .font(.system(size: fontSize))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }

                        if sections.contains(.reply), !overview.blocks.isEmpty {
                            section("What Claude Said") {
                                ForEach(overview.blocks) { block in
                                    switch block.kind {
                                    case .code:
                                        codeBlock(block.text)
                                    case .image:
                                        Label("image", systemImage: "photo")
                                            .font(.system(size: fontSize))
                                            .foregroundStyle(.tertiary)
                                    case .paragraph:
                                        prose(block.text)
                                    }
                                }
                            }
                        }

                        // Last, and off by default: it is a list you can get
                        // from the terminal, and putting it above the reply
                        // pushes what was said off the screen.
                        if sections.contains(.activity), !overview.activity.isEmpty {
                            section("Recent Activity") {
                                ForEach(overview.activity) { call in
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Image(systemName: call.isError
                                              ? "exclamationmark.triangle.fill"
                                              : (call.finished ? "checkmark" : "circle.dotted"))
                                            .font(.system(size: 9))
                                            .foregroundStyle(
                                                call.isError ? AnyShapeStyle(Color.red)
                                                             : AnyShapeStyle(.tertiary))
                                        Text(call.name)
                                            .font(.system(size: fontSize - 1, weight: .medium,
                                                          design: .monospaced))
                                        Text(call.detail ?? "")
                                            .font(.system(size: fontSize - 1, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .safeAreaInset(edge: .top, spacing: 0) { turnBar(overview) }
            }
        } else if client.isLoadingOverview(entry) {
            ProgressView("Reading the conversation…")
        } else {
            ContentUnavailableView {
                Label("No summary yet", systemImage: "text.append")
            } description: {
                Text("Nothing has been said in this session yet.")
            }
        }
    }

    /// Where you are in the conversation, and how to move.
    private func turnBar(_ overview: AgentOverview) -> some View {
        HStack(spacing: 10) {
            Button {
                step(to: overview.turn + 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!overview.hasOlder)

            Text("turn \(overview.turnCount - overview.turn) of \(overview.turnCount)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

            Button {
                step(to: overview.turn - 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(overview.isLatest)

            Spacer()

            // Only offered when it would do something: on the newest turn it
            // is a button that cannot change anything.
            if !overview.isLatest {
                Button("Latest") { step(to: 0) }
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func step(to turn: Int) {
        let target = max(0, turn)
        viewedTurn = target
        client.requestOverview(for: entry, turn: target)
    }

    @ViewBuilder
    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Prose, optionally bionic.
    @ViewBuilder
    private func prose(_ text: String) -> some View {
        if bionic {
            Text(BionicText.attributed(text, size: fontSize + 2))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(text)
                .font(.system(size: fontSize + 2))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func codeBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(size: fontSize, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
    }

    private var terminal: some View {
        ScrollViewReader { proxy in
            ScrollView(wrap ? [.vertical] : [.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    // One Text rather than a line per row: the terminal is one
                    // block of preformatted output, and splitting it lets
                    // SwiftUI reflow lines that must not be reflowed.
                    Text(text)
                        .font(.system(size: fontSize, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: !wrap, vertical: true)
                        .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
            }
            // The newest output is why you opened this; the top of a 400-line
            // dump is the wrong place to start.
            .onAppear { proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            .onChange(of: text) { _ in proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
            // Re-anchor after a reflow, or the view keeps an offset that meant
            // something at the old width and nothing at the new one.
            .onChange(of: wrap) { _ in proxy.scrollTo(Self.bottomAnchor, anchor: .bottom) }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 0) {
            Divider()

            if !attachedPreviews.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(attachedPreviews.enumerated()), id: \.offset) { index, image in
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    // Removing a thumbnail forgets the picture,
                                    // not the path already in the draft — the
                                    // file is on the Mac and the text is yours.
                                    Button {
                                        attachedPreviews.remove(at: index)
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
                    .padding(.top, 6)
            }

            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $photoPick, matching: .images) {
                    Image(systemName: client.isAttaching(entry)
                          ? "photo.badge.arrow.down" : "photo.on.rectangle")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
                .disabled(client.isAttaching(entry))
                .padding(.bottom, 6)

                // Pasting is how a screenshot usually arrives: copied
                // somewhere else and wanted here, without a trip through the
                // photo library. Offered only when there is one to paste.
                if UIPasteboard.general.hasImages {
                    Button { pasteImage() } label: {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                    .disabled(client.isAttaching(entry))
                    .padding(.bottom, 7)
                }

                // A button rather than a double-tap on the box. A hidden
                // gesture on a text field competes with placing the cursor and
                // selecting a word, and nothing about it announces that the
                // history is there at all.
                if !entry.promptHistory.isEmpty {
                    Button {
                        showingHistory = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 6)
                }

                TextField("Reply to \(entry.watermark)…", text: draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .font(.system(size: 14, design: .monospaced))
                    .focused($composerFocused)
                    // The key inserts a newline on a vertical-axis field
                    // rather than submitting, so labelling it "send" was the
                    // control lying about itself.
                    .submitLabel(.return)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                    )

                Button { send() } label: {
                    Image(systemName: client.isSending(entry)
                          ? "arrow.up.circle" : "arrow.up.circle.fill")
                        .font(.system(size: 26))
                }
                .disabled(trimmedDraft.isEmpty)
                .padding(.bottom, 2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // The bar has to run to the bottom of the screen, under the home
        // indicator and behind the keyboard. Left inside the safe area it stops
        // short, and the gap shows as a strip of page beneath the composer's
        // corners — worse with the keyboard up, because the strip then sits
        // between the box and the keys.
        .background(.bar, ignoresSafeAreaEdges: .bottom)
        .sheet(isPresented: $showingHistory) { historySheet }
        .onChange(of: photoPick) { item in
            guard let item else { return }
            Task { await sendPickedPhoto(item) }
        }
        .onReceive(client.objectWillChange) { _ in
            // The path lands asynchronously; consume it once.
            if let path = client.takeAttachedPath(for: entry) {
                let trimmed = (client.drafts[entry.id] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                client.drafts[entry.id] = trimmed.isEmpty ? path + " " : trimmed + " " + path + " "
            }
        }
    }

    /// What has already been asked of this agent, newest first.
    ///
    /// Tapping one puts it in the box rather than sending it outright. A
    /// message worth repeating is usually worth a word changed first, and a
    /// list where one wrong tap fires something at an agent is a list you use
    /// carefully instead of quickly.
    private var historySheet: some View {
        NavigationStack {
            List {
                ForEach(Array(entry.promptHistory.reversed().enumerated()), id: \.offset) { _, past in
                    Button {
                        client.drafts[entry.id] = past
                        showingHistory = false
                        composerFocused = true
                    } label: {
                        Text(past)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Sent to \(entry.watermark)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingHistory = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var draft: Binding<String> {
        Binding(
            get: { client.drafts[entry.id] ?? "" },
            set: { client.drafts[entry.id] = $0 }
        )
    }

    private var trimmedDraft: String {
        (client.drafts[entry.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send() {
        let text = trimmedDraft
        guard !text.isEmpty else { return }
        client.send(text: text, to: entry)
        client.drafts[entry.id] = ""
        attachedPreviews = []
        composerFocused = false
    }

    private func pasteImage() {
        guard let image = UIPasteboard.general.image else { return }
        attach(image, named: "pasted.jpg")
    }

    private func sendPickedPhoto(_ item: PhotosPickerItem) async {
        defer { photoPick = nil }
        guard let raw = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: raw) else { return }
        let name = (item.itemIdentifier?.prefix(8)).map { "photo-\($0).jpg" } ?? "photo.jpg"
        attach(image, named: name)
    }

    /// Downscale an image and hand it to the Mac, showing it beside the box.
    ///
    /// Downscaled because the wire is one JSON line and a modern phone photo is
    /// eight megabytes before base64; nothing about reading a screenshot needs
    /// the full sensor. 2000px on the long edge stays legible for a terminal
    /// grab or a diagram, at a fraction of the bytes.
    private func attach(_ image: UIImage, named name: String) {
        let longEdge = max(image.size.width, image.size.height)
        let scale = longEdge > 2000 ? 2000 / longEdge : 1
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let rendered = UIGraphicsImageRenderer(size: target).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let jpeg = rendered.jpegData(compressionQuality: 0.8) else { return }
        attachedPreviews.append(rendered)
        client.attach(data: jpeg, name: name, to: entry)
    }
}
