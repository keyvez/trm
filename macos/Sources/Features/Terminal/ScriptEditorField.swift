import SwiftUI
import AppKit

/// An `NSViewRepresentable` wrapping `NSTextView` with `#` autocomplete for pane references.
/// When the user types `#`, a popover appears showing available panes with their
/// watermark, process name, and detected URLs.
struct ScriptEditorField: NSViewRepresentable {
    @Binding var text: String
    let availablePanes: [PanePickerItem]

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, availablePanes: availablePanes)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.delegate = context.coordinator
        textView.font = .systemFont(ofSize: 12)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.string = text
        textView.textContainerInset = NSSize(width: 4, height: 4)

        context.coordinator.textView = textView

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.availablePanes = availablePanes
        if textView.string != text {
            textView.string = text
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        var availablePanes: [PanePickerItem]
        weak var textView: NSTextView?

        private var popover: NSPopover?
        private var popoverController: PanePickerPopoverController?

        init(text: Binding<String>, availablePanes: [PanePickerItem]) {
            _text = text
            self.availablePanes = availablePanes
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string

            // Check if user just typed '#'
            let cursorLocation = textView.selectedRange().location
            guard cursorLocation > 0 else {
                dismissPopover()
                return
            }

            let nsString = textView.string as NSString
            let charBeforeCursor = nsString.substring(with: NSRange(location: cursorLocation - 1, length: 1))

            if charBeforeCursor == "#" {
                showPanePopover(at: cursorLocation, in: textView)
            } else if popover?.isShown == true {
                // If popover is showing, update filter based on text after #
                updatePopoverFilter(cursorLocation: cursorLocation, in: textView)
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                if popover?.isShown == true {
                    dismissPopover()
                    return true
                }
            }
            // Let arrow keys and return pass through to the popover if shown
            if popover?.isShown == true {
                if commandSelector == #selector(NSResponder.moveDown(_:)) ||
                   commandSelector == #selector(NSResponder.moveUp(_:)) ||
                   commandSelector == #selector(NSResponder.insertNewline(_:)) {
                    popoverController?.handleKeyCommand(commandSelector)
                    return true
                }
            }
            return false
        }

        // MARK: - Popover Management

        private func showPanePopover(at cursorLocation: Int, in textView: NSTextView) {
            dismissPopover()

            guard !availablePanes.isEmpty else { return }

            let controller = PanePickerPopoverController(
                panes: availablePanes,
                onSelect: { [weak self] item in
                    self?.insertPaneReference(item, at: cursorLocation, in: textView)
                    self?.dismissPopover()
                }
            )
            popoverController = controller

            let popover = NSPopover()
            popover.contentViewController = controller
            popover.behavior = .transient
            popover.animates = true
            self.popover = popover

            // Position at the cursor
            let glyphIndex = textView.layoutManager?.glyphIndexForCharacter(at: cursorLocation - 1) ?? 0
            var rect = textView.layoutManager?.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textView.textContainer!) ?? .zero
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y

            popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
        }

        private func updatePopoverFilter(cursorLocation: Int, in textView: NSTextView) {
            let nsString = textView.string as NSString

            // Find the last '#' before cursor
            var hashPos = cursorLocation - 1
            while hashPos >= 0 {
                let ch = nsString.substring(with: NSRange(location: hashPos, length: 1))
                if ch == "#" { break }
                if ch == " " || ch == "\n" {
                    dismissPopover()
                    return
                }
                hashPos -= 1
            }

            guard hashPos >= 0 else {
                dismissPopover()
                return
            }

            let filterLength = cursorLocation - hashPos - 1
            if filterLength > 0 {
                let filterText = nsString.substring(with: NSRange(location: hashPos + 1, length: filterLength))
                popoverController?.filterText = filterText
            } else {
                popoverController?.filterText = ""
            }
        }

        private func insertPaneReference(_ item: PanePickerItem, at cursorLocation: Int, in textView: NSTextView) {
            let nsString = textView.string as NSString

            // Find the '#' that started this reference
            var hashPos = cursorLocation - 1
            while hashPos >= 0 {
                let ch = nsString.substring(with: NSRange(location: hashPos, length: 1))
                if ch == "#" { break }
                hashPos -= 1
            }
            guard hashPos >= 0 else { return }

            // Replace from '#' to cursor with '#<paneId>'
            let replaceRange = NSRange(location: hashPos, length: textView.selectedRange().location - hashPos)
            let replacement = "#\(item.id)"

            textView.shouldChangeText(in: replaceRange, replacementString: replacement)
            textView.replaceCharacters(in: replaceRange, with: replacement)
            textView.didChangeText()
            text = textView.string
        }

        private func dismissPopover() {
            popover?.close()
            popover = nil
            popoverController = nil
        }
    }
}

// MARK: - Pane Picker Popover Controller

/// An `NSViewController` hosting a table of pane picker items for the `#` autocomplete.
private class PanePickerPopoverController: NSViewController {
    private let allPanes: [PanePickerItem]
    private let onSelect: (PanePickerItem) -> Void
    private var tableView: NSTableView!
    private var selectedRow: Int = 0

    var filterText: String = "" {
        didSet { reloadData() }
    }

    private var filteredPanes: [PanePickerItem] {
        if filterText.isEmpty { return allPanes }
        let lower = filterText.lowercased()
        return allPanes.filter { pane in
            if "\(pane.id)".hasPrefix(lower) { return true }
            if let wm = pane.watermark, wm.lowercased().contains(lower) { return true }
            if pane.title.lowercased().contains(lower) { return true }
            if let proc = pane.processName, proc.lowercased().contains(lower) { return true }
            return false
        }
    }

    init(panes: [PanePickerItem], onSelect: @escaping (PanePickerItem) -> Void) {
        self.allPanes = panes
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        tableView = NSTableView()
        tableView.headerView = nil
        tableView.rowHeight = 28
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .regular
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pane"))
        column.isEditable = false
        tableView.addTableColumn(column)

        scrollView.documentView = tableView

        let rowCount = min(filteredPanes.count, 6)
        let height = CGFloat(max(rowCount, 1)) * 30 + 4
        scrollView.frame = NSRect(x: 0, y: 0, width: 280, height: height)

        self.view = scrollView
        self.preferredContentSize = NSSize(width: 280, height: height)

        if !filteredPanes.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    private func reloadData() {
        tableView?.reloadData()
        let rowCount = min(filteredPanes.count, 6)
        let height = CGFloat(max(rowCount, 1)) * 30 + 4
        preferredContentSize = NSSize(width: 280, height: height)
        view.frame.size = preferredContentSize

        if !filteredPanes.isEmpty {
            selectedRow = 0
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    @objc private func rowDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < filteredPanes.count else { return }
        onSelect(filteredPanes[row])
    }

    func handleKeyCommand(_ selector: Selector) {
        let panes = filteredPanes
        guard !panes.isEmpty else { return }

        if selector == #selector(NSResponder.moveDown(_:)) {
            selectedRow = min(selectedRow + 1, panes.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedRow)
        } else if selector == #selector(NSResponder.moveUp(_:)) {
            selectedRow = max(selectedRow - 1, 0)
            tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
            tableView.scrollRowToVisible(selectedRow)
        } else if selector == #selector(NSResponder.insertNewline(_:)) {
            guard selectedRow >= 0, selectedRow < panes.count else { return }
            onSelect(panes[selectedRow])
        }
    }
}

extension PanePickerPopoverController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredPanes.count
    }
}

extension PanePickerPopoverController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < filteredPanes.count else { return nil }
        let pane = filteredPanes[row]

        let cellId = NSUserInterfaceItemIdentifier("PanePickerCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellId

            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            textField.lineBreakMode = .byTruncatingTail
            cell.addSubview(textField)
            cell.textField = textField

            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        // Build attributed string: bold pane ID, regular rest
        let attrStr = NSMutableAttributedString()
        let boldFont = NSFont.boldSystemFont(ofSize: 12)
        let regularFont = NSFont.systemFont(ofSize: 12)

        attrStr.append(NSAttributedString(string: "#\(pane.id)", attributes: [.font: boldFont]))

        if let wm = pane.watermark, !wm.isEmpty {
            attrStr.append(NSAttributedString(string: " — \(wm)", attributes: [.font: regularFont]))
        } else if !pane.title.isEmpty {
            attrStr.append(NSAttributedString(string: " — \(pane.title)", attributes: [.font: regularFont]))
        }

        if let proc = pane.processName, !proc.isEmpty {
            attrStr.append(NSAttributedString(string: " (\(proc))", attributes: [
                .font: regularFont,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }

        let portStrings = pane.detectedURLs.compactMap { url -> String? in
            guard let port = url.port else { return nil }
            return ":\(port)"
        }
        if !portStrings.isEmpty {
            attrStr.append(NSAttributedString(string: " " + portStrings.joined(separator: " "), attributes: [
                .font: regularFont,
                .foregroundColor: NSColor.systemOrange,
            ]))
        }

        cell.textField?.attributedStringValue = attrStr
        return cell
    }
}
