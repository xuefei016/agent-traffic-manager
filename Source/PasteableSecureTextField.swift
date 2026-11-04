import AppKit

/// Menu-bar apps may have no Edit menu to route Command-V.
final class PasteableSecureTextField: NSSecureTextField {
    var pasteboard: NSPasteboard = .general

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v": pasteKey(nil); return true
        case "a": selectText(nil); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    @objc func pasteKey(_ sender: Any?) {
        guard let text = pasteboard.string(forType: .string) else { return }
        insertPastedText(text)
    }

    func insertPastedText(_ text: String) {
        if let editor = currentEditor() as? NSTextView {
            editor.insertText(text, replacementRange: editor.selectedRange())
        } else {
            stringValue = text
        }
    }
}
