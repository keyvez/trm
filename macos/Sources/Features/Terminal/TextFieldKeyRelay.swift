import AppKit

/// Hands the standard editing shortcuts to a focused text field in a window
/// that also holds a terminal.
///
/// A terminal surface answers `performKeyEquivalent` for the whole window's
/// view tree, not just when it is first responder in the AppKit sense — and it
/// claims ⌘C and ⌘V for the terminal's own copy and paste. That is right when
/// you are working in the terminal and wrong when you are typing in a reply
/// box beside it: the keystrokes reached the field, but ⌘C and ⌘V went to the
/// terminal, so text could be typed and never copied or pasted.
///
/// A local key monitor runs *before* `performKeyEquivalent`, so relaying the
/// command to the responder chain from there gets the field its own shortcuts
/// back without touching how the terminal behaves when it really is focused.
enum TextFieldKeyRelay {

    /// The editing commands worth rescuing, by key code.
    private static let commands: [UInt16: Selector] = [
        8: #selector(NSText.copy(_:)),        // C
        9: #selector(NSText.paste(_:)),       // V
        7: #selector(NSText.cut(_:)),         // X
        0: #selector(NSText.selectAll(_:)),   // A
        6: Selector(("undo:")),               // Z
    ]

    /// Send `event` to whatever text has focus. Returns true when it was
    /// handled, in which case the caller should swallow the event.
    static func handle(_ event: NSEvent) -> Bool {
        editingCommand(event) || navigation(event)
    }

    /// ⌘C, ⌘V, ⌘X, ⌘A, ⌘Z.
    ///
    /// Only plain ⌘ combinations: ⌘⇧Z is redo, ⌘⌥C is something else again,
    /// and neither belongs here.
    private static func editingCommand(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, let selector = commands[event.keyCode] else { return false }
        return NSApp.sendAction(selector, to: nil, from: nil)
    }

    /// Everything a Mac text field is supposed to do with ⌥ and ⌘ held: skip a
    /// word, jump to the start or end of the line, extend a selection while
    /// doing it, delete back to the start.
    ///
    /// Not a table of key codes to selectors — AppKit already has that. The
    /// event goes to the field editor and `interpretKeyEvents` maps it, so ⌥⇧←
    /// and ⌘⌫ behave exactly as they do in every other text field, without
    /// this file having an opinion about each one.
    private static func navigation(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Plain keys already reach the field; only the modified ones are being
        // taken by the terminal's key equivalents.
        guard flags.contains(.command) || flags.contains(.option) else { return false }
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return false }
        switch event.keyCode {
        case 123, 124, 125, 126,  // arrows
             51, 117:             // delete, forward delete
            editor.interpretKeyEvents([event])
            return true
        default:
            return false
        }
    }
}
