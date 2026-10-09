import FocusCore
import SwiftUI

/// Milestone plus GitHub Projects fields (Sprint, Estimate, RCA, ...), grouped per project.
struct GitHubFieldsSection: View {
    let ticket: Ticket

    var body: some View {
        if let milestone = ticket.milestone {
            Section("Milestone") {
                LabeledContent {
                    Text(milestone.isOpen ? "Open" : "Closed").foregroundStyle(.secondary)
                } label: {
                    Label(milestone.title, systemImage: "flag.checkered")
                }
                if let due = milestone.dueOn {
                    LabeledContent("Due", value: due.formatted(date: .abbreviated, time: .omitted))
                }
            }
        }

        let groups = Dictionary(grouping: ticket.allFields.filter { $0 != ticket.estimateField }, by: \.project)
        ForEach(Self.ordered(groups.keys), id: \.self) { project in
            Section(project.isEmpty ? "Project fields" : project) {
                ForEach(groups[project] ?? [], id: \.self) { field in
                    if Self.isEditable(field) {
                        EditableTextField(ticketID: ticket.id, field: field)
                    } else {
                        LabeledContent(field.name) {
                            VStack(alignment: .trailing, spacing: 2) {
                                value(of: field)
                                if let range = Self.range(field) {
                                    Text(range).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func isEditable(_ field: CustomField) -> Bool {
        field.kind == .text && field.project != CustomField.issueFieldsGroup
            && field.name.caseInsensitiveCompare(CustomField.rcaName) == .orderedSame
    }

    @ViewBuilder
    private func value(of field: CustomField) -> some View {
        switch field.kind {
        case .select, .date, .iteration:
            FieldChip(field: field)
        case .number, .text:
            Text(field.value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }

    /// Issue fields first, then projects alphabetically.
    private static func ordered(_ keys: Dictionary<String, [CustomField]>.Keys) -> [String] {
        keys.sorted { a, b in
            if a == CustomField.issueFieldsGroup { return true }
            if b == CustomField.issueFieldsGroup { return false }
            return a < b
        }
    }

    private static func range(_ field: CustomField) -> String? {
        guard field.kind == .iteration, let start = field.start, let end = field.end else { return nil }
        let last = Calendar.current.date(byAdding: .day, value: -1, to: end) ?? end
        return "\(start.formatted(date: .abbreviated, time: .omitted)) – \(last.formatted(date: .abbreviated, time: .omitted))"
    }
}

/// Multi-line editor for a text project field; Save writes it to GitHub.
private struct EditableTextField: View {
    @Environment(AppStore.self) private var store
    let ticketID: UUID
    let field: CustomField
    @State private var draft: String

    init(ticketID: UUID, field: CustomField) {
        self.ticketID = ticketID
        self.field = field
        _draft = State(initialValue: field.value)
    }

    private var isDirty: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines) != field.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(field.name)
            TextEditor(text: $draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 90)
                .padding(6)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack {
                Text(isDirty ? "Unsaved changes" : "Saved to GitHub when you press Save")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Revert") { draft = field.value }
                    .disabled(!isDirty)
                Button("Save") {
                    store.setProjectField(ticketID, name: field.name, project: field.project, to: .text(draft))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!isDirty)
            }
        }
        .onChange(of: field.value) { old, new in
            if draft == old { draft = new }
        }
    }
}
