import SwiftUI
import AppKit

/// A real macOS combo box: a text field you can type into, with a dropdown of suggestions.
struct ComboBoxField: NSViewRepresentable {
    @Binding var text: String
    var items: [String]
    var placeholder: String = ""

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSComboBox {
        let box = NSComboBox()
        box.isEditable = true
        box.completes = true
        box.numberOfVisibleItems = 12
        box.placeholderString = placeholder
        box.delegate = context.coordinator
        box.addItems(withObjectValues: items)
        box.stringValue = text
        return box
    }

    func updateNSView(_ box: NSComboBox, context: Context) {
        context.coordinator.parent = self
        let current = box.objectValues as? [String] ?? []
        if current != items {
            box.removeAllItems()
            box.addItems(withObjectValues: items)
        }
        if box.stringValue != text {
            box.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: ComboBoxField

        init(_ parent: ComboBoxField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            if let box = obj.object as? NSComboBox {
                parent.text = box.stringValue
            }
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            if let box = notification.object as? NSComboBox, let chosen = box.objectValueOfSelectedItem as? String {
                parent.text = chosen
            }
        }
    }
}
