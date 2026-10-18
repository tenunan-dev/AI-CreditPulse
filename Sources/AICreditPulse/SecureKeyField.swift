import SwiftUI

/// A native `NSSecureTextField`-backed secret input. SwiftUI's `SecureField`
/// proved flaky in the grouped-form context (dots not drawn while typing —
/// indistinguishable from a dead field), so the behavior-critical control wraps
/// AppKit directly:
///  - typed characters ALWAYS mask,
///  - the caret starts at the LEFT edge when the field gains focus,
///  - Return triggers the provided submit,
///  - every keystroke flows through the binding.
struct SecureKeyField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Credential"
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> KeyTextField {
        let field = KeyTextField()
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.placeholderString = placeholder
        field.font = NSFont.userFixedPitchFont(ofSize: NSFont.systemFontSize)
        field.delegate = context.coordinator
        field.onSubmitHandler = { [weak coordinatorBox = context.coordinator] in
            coordinatorBox?.parent.onSubmit()
        }
        return field
    }

    func updateNSView(_ field: KeyTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.onSubmitHandler = onSubmit
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SecureKeyField
        init(_ parent: SecureKeyField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? KeyTextField else { return }
            parent.text = field.stringValue
        }
    }
}

/// NSSecureTextField with the two behavioral extras: caret-at-left on focus
/// and a submit hook. Target/action based (nib-free).
final class KeyTextField: NSSecureTextField {
    var onSubmitHandler: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became, let editor = currentEditor() {
            // "Start from the left": caret the beginning of the value.
            editor.selectedRange = NSRange(location: 0, length: 0)
        }
        return became
    }

    override func textDidChange(_ notification: Notification) {
        // Sync already flows through the NSTextFieldDelegate; nothing extra.
    }

    override func insertNewline(_ sender: Any?) {
        window?.makeFirstResponder(nil)   // blur first, then submit
        onSubmitHandler?()
    }
}
