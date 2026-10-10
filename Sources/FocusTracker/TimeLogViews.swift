import FocusCore
import SwiftUI

struct NoteComposer: View {
    @Environment(AppStore.self) private var store
    let ticketID: UUID
    @State private var draft = ""

    private var isEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextEditor(text: $draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 80, maxHeight: 160)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Add a note…")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
            Button(action: submit) { ShortcutLabel(title: "Add note", keys: "⌘↩") }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isEmpty)
        }
    }

    private func submit() {
        guard !isEmpty else { return }
        store.addNote(ticketID: ticketID, text: draft)
        draft = ""
    }
}

struct NoteRow: View {
    let note: TicketNote
    var ticketTitle: String?
    var onDelete: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "note.text").foregroundStyle(Theme.warning).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if let ticketTitle { Text(ticketTitle).lineLimit(1) }
                    Text(note.createdAt.formatted(date: ticketTitle == nil ? .abbreviated : .omitted, time: .shortened))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let onDelete {
                DeleteButton(title: "Delete this note?", help: "Delete note", action: onDelete)
            }
        }
        .font(.callout)
    }
}
