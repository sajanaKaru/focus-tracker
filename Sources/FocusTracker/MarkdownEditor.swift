import AppKit
import FocusCore
import SwiftUI

/// Bridges toolbar buttons to the NSTextView that holds the selection.
@MainActor
final class MarkdownEditorController {
    weak var textView: NSTextView?

    func apply(_ action: MarkdownAction) {
        guard let textView, let edit = MarkdownFormatter.edit(action, in: textView.string, selection: textView.selectedRange()) else { return }
        perform(edit, in: textView)
    }

    /// Goes through the text view so the change is undoable and reaches the SwiftUI binding.
    func perform(_ edit: TextEdit, in textView: NSTextView) {
        textView.insertText(edit.replacement, replacementRange: edit.range)
        textView.setSelectedRange(edit.selection)
        textView.window?.makeFirstResponder(textView)
    }
}

struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    let controller: MarkdownEditorController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        let textView = scroll.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.string = text
        controller.textView = textView
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        controller.textView = textView
        if textView.string != text { textView.string = text }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextEditor

        init(_ parent: MarkdownTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let text = textView.string
            let selection = textView.selectedRange()
            let edit: TextEdit?
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                edit = MarkdownFormatter.newline(in: text, selection: selection)
            case #selector(NSResponder.insertTab(_:)):
                edit = MarkdownFormatter.indent(in: text, selection: selection, outdent: false, onlyLists: true)
            case #selector(NSResponder.insertBacktab(_:)):
                edit = MarkdownFormatter.indent(in: text, selection: selection, outdent: true, onlyLists: true)
            default:
                edit = nil
            }
            guard let edit else { return false }
            parent.controller.perform(edit, in: textView)
            return true
        }
    }
}

/// Formatting buttons for the Markdown editor: headings, inline styles, lists and indentation.
struct MarkdownToolbar: View {
    let controller: MarkdownEditorController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                button("H1", help: "Heading", .heading(1))
                button("H2", help: "Sub-heading", .heading(2))
                button("H3", help: "Small heading", .heading(3))
                separator
                button(symbol: "bold", help: "Bold (⌘B)", .bold, key: "b")
                button(symbol: "italic", help: "Italic (⌘I)", .italic, key: "i")
                button(symbol: "strikethrough", help: "Strikethrough", .strikethrough)
                button(symbol: "chevron.left.forwardslash.chevron.right", help: "Inline code", .code)
                button(symbol: "link", help: "Link (⌘K)", .link, key: "k")
                separator
                button(symbol: "list.bullet", help: "Bulleted list", .bullet)
                button(symbol: "list.number", help: "Numbered list", .numbered)
                button(symbol: "checklist", help: "Checklist", .checkbox)
                button(symbol: "text.quote", help: "Quote", .quote)
                button(symbol: "curlybraces", help: "Code block", .codeBlock)
                separator
                button(symbol: "decrease.indent", help: "Outdent (⇧Tab)", .outdent)
                button(symbol: "increase.indent", help: "Indent for sub-items (Tab)", .indent)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
    }

    private var separator: some View {
        Divider().frame(height: 16).padding(.horizontal, 4)
    }

    private func button(_ title: String? = nil, symbol: String? = nil, help: String, _ action: MarkdownAction, key: KeyEquivalent? = nil) -> some View {
        FormatButton(title: title, symbol: symbol, help: help, key: key) { controller.apply(action) }
    }
}

private struct FormatButton: View {
    let title: String?
    let symbol: String?
    let help: String
    let key: KeyEquivalent?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                } else {
                    Text(title ?? "").font(.system(size: 12, weight: .bold, design: .rounded))
                }
            }
            .frame(width: 28, height: 26)
            .background(Color.primary.opacity(hovering ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .modifier(OptionalShortcut(key: key))
    }
}

private struct OptionalShortcut: ViewModifier {
    let key: KeyEquivalent?

    func body(content: Content) -> some View {
        if let key { content.keyboardShortcut(key, modifiers: .command) } else { content }
    }
}
