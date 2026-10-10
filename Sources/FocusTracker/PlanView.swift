import FocusCore
import SwiftUI

/// Full-page plan for a ticket: its details, a list of drafted comments, and a final post to GitHub.
struct PlanPage: View {
    @Environment(AppStore.self) private var store
    let ticketID: UUID
    var onBack: () -> Void

    @State private var showingPost = false

    var body: some View {
        if let ticket = store.ticket(ticketID) {
            let comments = store.planComments(for: ticketID)
            let pending = comments.filter { $0.postedAt == nil }
            Form {
                header(ticket)

                if !ticket.body.isEmpty {
                    Section("Description") { DescriptionView(markdown: ticket.body) }
                }

                if ticket.milestone != nil || !ticket.allFields.isEmpty {
                    GitHubFieldsSection(ticket: ticket)
                }

                Section("Plan comments") {
                    if comments.isEmpty {
                        Text("No comments yet. Add the steps, notes and questions for this ticket below.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(comments) { comment in
                        PlanCommentRow(comment: comment) { store.deletePlanComment(comment.id) }
                    }
                    PlanCommentComposer(ticketID: ticketID).id(ticketID)
                }

                if ticket.github != nil {
                    Section("GitHub") {
                        HStack {
                            Text(pending.isEmpty ? "Nothing to post." : "\(pending.count) comment\(pending.count == 1 ? "" : "s") ready to post.")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Review & Post…") { showingPost = true }
                                .buttonStyle(.borderedProminent)
                                .disabled(pending.isEmpty)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
            .background(Theme.pageBackground)
            .task(id: ticketID) { await store.refreshTicket(ticketID) }
            .sheet(isPresented: $showingPost) { PostPlanSheet(ticketID: ticketID) }
        } else {
            ContentUnavailableView("Ticket not found", systemImage: "questionmark.circle")
        }
    }

    private func header(_ ticket: Ticket) -> some View {
        Section {
            Button(action: onBack) { Label("Back to ticket", systemImage: "chevron.left") }
                .buttonStyle(.borderless)
            Text(ticket.title).font(.title2.bold()).textSelection(.enabled)
            FlowLayout {
                StatusBadge(status: ticket.status)
                MetaChips(ticket: ticket)
                LabelChips(ticket: ticket, limit: 8)
            }
            if let gh = ticket.github, let url = URL(string: gh.url) {
                Link(destination: url) { Label("\(gh.repo)#\(gh.number) on GitHub", systemImage: "arrow.up.right.square") }
            }
        }
    }
}

private struct PlanCommentRow: View {
    let comment: PlanComment
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
                if let postedAt = comment.postedAt {
                    Label("Posted \(postedAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                }
                Spacer()
                DeleteButton(title: "Delete this comment?", help: "Delete comment", action: onDelete)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            MarkdownPreview(markdown: comment.text)
        }
        .padding(.vertical, 4)
    }
}

/// Write/Preview editor that adds a comment to the plan.
private struct PlanCommentComposer: View {
    @Environment(AppStore.self) private var store
    let ticketID: UUID

    private enum Mode: String, CaseIterable, Identifiable {
        case write = "Write", preview = "Preview"
        var id: String { rawValue }
    }

    @State private var draft = ""
    @State private var mode = Mode.write
    @State private var controller = MarkdownEditorController()

    private var isEmpty: Bool { draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)

            VStack(spacing: 0) {
                MarkdownToolbar(controller: controller)
                    .disabled(mode != .write)
                    .opacity(mode == .write ? 1 : 0.4)
                Divider()
                Group {
                    switch mode {
                    case .write: editor
                    case .preview: preview
                    }
                }
                .frame(height: 200)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack {
                Text("Markdown · Return continues lists · Tab indents")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(action: submit) { ShortcutLabel(title: "Add comment", keys: "⌘↩") }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isEmpty)
            }
        }
    }

    private var editor: some View {
        MarkdownTextEditor(text: $draft, controller: controller)
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Write a comment… use the toolbar for headings, lists and checkboxes")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 11)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
    }

    private var preview: some View {
        ScrollView {
            Group {
                if isEmpty {
                    Text("Nothing to preview").foregroundStyle(.secondary)
                } else {
                    MarkdownPreview(markdown: draft)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }

    private func submit() {
        guard !isEmpty else { return }
        store.addPlanComment(ticketID: ticketID, text: draft)
        draft = ""
        mode = .write
    }
}

/// Shows the combined comment as it will appear on GitHub before sending it.
private struct PostPlanSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let ticketID: UUID
    @State private var posting = false

    var body: some View {
        let pending = store.unpostedPlanComments(for: ticketID)
        let combined = pending.map(\.text).joined(separator: AppStore.planCommentSeparator)
        VStack(alignment: .leading, spacing: 12) {
            Text("Post to GitHub").font(.title2.weight(.bold))
            Text("This will be posted as a single comment on \(store.ticket(ticketID)?.displayKey ?? "the issue").")
                .foregroundStyle(.secondary)
            ScrollView {
                MarkdownPreview(markdown: combined)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
            HStack {
                Spacer()
                Button(role: .cancel) { dismiss() } label: { ShortcutLabel(title: "Cancel", keys: "⎋") }
                    .keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        posting = true
                        if await store.postPlan(ticketID) { dismiss() }
                        posting = false
                    }
                } label: {
                    if posting { ProgressView().controlSize(.small) } else { Text("Post comment") }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pending.isEmpty || posting)
            }
        }
        .padding()
        .frame(width: 560, height: 420)
    }
}

/// Line-based Markdown preview: headings, nested bullets, numbered lists, task lists, quotes, code blocks and inline styles.
struct MarkdownPreview: View {
    let markdown: String

    private enum Kind {
        case blank, rule
        case heading(Int, String)
        case task(done: Bool, String)
        case bullet(String)
        case numbered(String, String)
        case quote(String)
        case code(String)
        case text(String)
    }

    private struct Row: Identifiable {
        let id: Int
        let indent: CGFloat
        let kind: Kind
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Self.rows(markdown)) { row in
                view(for: row.kind).padding(.leading, row.indent)
            }
        }
        .textSelection(.enabled)
    }

    private static func rows(_ markdown: String) -> [Row] {
        var rows: [Row] = []
        var code: [String]?

        for (index, raw) in markdown.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code {
                    rows.append(Row(id: index, indent: 0, kind: .code(lines.joined(separator: "\n"))))
                    code = nil
                } else {
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(raw)
                continue
            }
            let indent = CGFloat(raw.prefix { $0 == " " || $0 == "\t" }.count) * 5
            rows.append(Row(id: index, indent: indent, kind: kind(of: line)))
        }
        if let lines = code { rows.append(Row(id: -1, indent: 0, kind: .code(lines.joined(separator: "\n")))) }
        return rows
    }

    private static func kind(of line: String) -> Kind {
        if line.isEmpty { return .blank }
        if line == "---" { return .rule }

        let hashes = line.prefix { $0 == "#" }.count
        if (1...6).contains(hashes), line.dropFirst(hashes).first == " " { return .heading(hashes, String(line.dropFirst(hashes + 1))) }

        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            let rest = line.dropFirst(marker.count)
            if rest.hasPrefix("[ ] ") { return .task(done: false, String(rest.dropFirst(4))) }
            if rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ") { return .task(done: true, String(rest.dropFirst(4))) }
            return .bullet(String(rest))
        }

        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") {
            return .numbered(String(digits), String(line.dropFirst(digits.count + 2)))
        }
        if line.hasPrefix("> ") { return .quote(String(line.dropFirst(2))) }
        return .text(line)
    }

    @ViewBuilder
    private func view(for kind: Kind) -> some View {
        switch kind {
        case .blank:
            Color.clear.frame(height: 6)
        case .rule:
            Divider().padding(.vertical, 6)
        case .heading(let level, let text):
            inline(text).font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
        case .task(let done, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: done ? "checkmark.square.fill" : "square").foregroundStyle(done ? Theme.accent : .secondary)
                inline(text).foregroundStyle(done ? .secondary : .primary)
            }
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\u{2022}")
                inline(text)
            }
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
                inline(text)
            }
        case .quote(let text):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.5)).frame(width: 3)
                inline(text).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .text(let text):
            inline(text)
        }
    }

    private func inline(_ text: String) -> some View {
        Text((try? AttributedString(markdown: text)) ?? AttributedString(text))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
