import FocusCore
import SwiftUI

// MARK: - Test cases

struct TicketTestCasesTab: View {
    @Environment(AppStore.self) private var store
    let ticket: Ticket
    @State private var environment: DeploymentEnvironment?
    @State private var loaded = false
    @State private var editingCase: TestCase?
    @State private var addingCase = false
    @State private var drafting = false
    @State private var verdict: VerdictOutcome?
    @State private var reportingBug = false

    var body: some View {
        let cases = store.testCases(for: ticket.id)
        VStack(alignment: .leading, spacing: 16) {
            if ticket.github == nil {
                EmptyTabState(
                    symbol: "arrow.triangle.pull", title: "Test cases need a GitHub ticket",
                    message: "Verdicts and bug reports are posted to the linked issue, so test cases are available for synced tickets."
                )
            } else {
                environmentPicker
                summaryCard(caseCount: cases.count)
                actions(hasCases: !cases.isEmpty)
                if cases.isEmpty {
                    EmptyTabState(
                        symbol: "checklist", title: "No test cases yet",
                        message: "Write them by hand, or let AI draft them from the ticket and its pull requests."
                    ) {
                        Button { addingCase = true } label: { Label("Add test case", systemImage: "plus") }.buttonStyle(.primary)
                        Button { drafting = true } label: { Label("Draft with AI", systemImage: "sparkles") }
                            .buttonStyle(.secondary)
                            .disabled(!store.hasAIKey)
                    }
                } else {
                    ForEach(Array(cases.enumerated()), id: \.element.id) { index, testCase in
                        TestCaseCard(number: index + 1, testCase: testCase, environment: environment) { editingCase = testCase }
                    }
                }
                let bugs = store.bugs(for: ticket.id)
                if !bugs.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Bugs").font(.headline)
                        ForEach(bugs) { BugRow(bug: $0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardStyle(padding: 16)
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            environment = ticket.environment
        }
        .onChange(of: ticket.environment) { environment = ticket.environment }
        .sheet(isPresented: $addingCase) { TestCaseSheet(ticketID: ticket.id, existing: nil) }
        .sheet(isPresented: $drafting) { DraftCasesSheet(ticket: ticket) }
        .sheet(item: $editingCase) { TestCaseSheet(ticketID: ticket.id, existing: $0) }
        .sheet(item: $verdict) { VerdictSheet(ticket: ticket, environment: environment, outcome: $0) }
        .sheet(isPresented: $reportingBug) { BugSheet(ticket: ticket, defaultEnvironment: environment) }
    }

    private var environmentPicker: some View {
        HStack(spacing: 12) {
            Text("Environment").font(.callout.weight(.medium))
            Picker("Environment", selection: $environment) {
                Text("None").tag(DeploymentEnvironment?.none)
                ForEach(DeploymentEnvironment.allCases) { Text($0.title).tag(DeploymentEnvironment?.some($0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)
            Spacer()
        }
    }

    private func summaryCard(caseCount: Int) -> some View {
        let summary = store.qaSummary(ticketID: ticket.id, environment: environment)
        let state = store.qaState(ticketID: ticket.id, environment: environment)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Chip(text: state.title, color: state.color)
                Text(summary.text).font(.callout).foregroundStyle(.secondary)
                Spacer()
                if let mark = ticket.deployment {
                    Text("Moved to “\(mark.statusName)” \(mark.movedAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if caseCount > 0 {
                ResultBar(summary: summary)
                HStack(spacing: 14) {
                    legend("Passed", summary.pass, Theme.success)
                    legend("Failed", summary.fail, Theme.danger)
                    legend("Blocked", summary.blocked, Theme.warning)
                    legend("Skipped", summary.skipped, Theme.slate)
                    legend("Not run", summary.notRun, Color.secondary)
                }
                .font(.caption)
            }
            if let last = store.latestVerdict(ticketID: ticket.id, environment: environment) {
                Text("Last verdict: \(last.outcome.title) by @\(last.tester) · \(last.testedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 16)
    }

    private func legend(_ title: String, _ count: Int, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(count) \(title)").foregroundStyle(.secondary)
        }
    }

    private func actions(hasCases: Bool) -> some View {
        FlowLayout {
            Button { addingCase = true } label: { Label("Add test case", systemImage: "plus") }.buttonStyle(.primary)
            Button { drafting = true } label: { Label("Draft with AI", systemImage: "sparkles") }
                .buttonStyle(.secondary)
                .disabled(!store.hasAIKey)
                .help(store.hasAIKey ? "Draft cases from the ticket and its pull requests" : "Set up an AI provider in Settings")
            Button { verdict = .pass } label: { Label("Mark passed", systemImage: "checkmark.circle") }
                .buttonStyle(.secondary)
                .disabled(!hasCases)
            Button { verdict = .fail } label: { Label("Mark failed", systemImage: "xmark.circle") }
                .buttonStyle(.secondary)
                .disabled(!hasCases)
            Button { reportingBug = true } label: { Label("Report bug", systemImage: "ladybug") }.buttonStyle(.secondary)
        }
    }
}

private struct ResultBar: View {
    let summary: QASummary

    var body: some View {
        GeometryReader { proxy in
            let total = max(summary.total, 1)
            HStack(spacing: 2) {
                segment(summary.pass, Theme.success, proxy.size.width, total)
                segment(summary.fail, Theme.danger, proxy.size.width, total)
                segment(summary.blocked, Theme.warning, proxy.size.width, total)
                segment(summary.skipped, Theme.slate, proxy.size.width, total)
                segment(summary.notRun, Color.primary.opacity(0.12), proxy.size.width, total)
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityLabel(summary.text)
    }

    @ViewBuilder
    private func segment(_ count: Int, _ color: Color, _ width: CGFloat, _ total: Int) -> some View {
        if count > 0 {
            Rectangle().fill(color).frame(width: max(width * CGFloat(count) / CGFloat(total) - 2, 2))
        }
    }
}

private struct TestCaseCard: View {
    @Environment(AppStore.self) private var store
    let number: Int
    let testCase: TestCase
    let environment: DeploymentEnvironment?
    let edit: () -> Void
    @State private var note = ""

    var body: some View {
        let current = store.latestResult(caseID: testCase.id, environment: environment)
        let accent = current?.status.color ?? Color.secondary
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(number)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(accent)
                    .frame(width: 24, height: 24)
                    .background(accent.opacity(0.15), in: Circle())
                Text(testCase.title).font(.headline).textSelection(.enabled)
                Spacer()
                Chip(text: current?.status.title ?? "Not run", color: accent)
                Button(action: edit) { Image(systemName: "pencil") }.buttonStyle(.borderless).help("Edit")
                DeleteButton(title: "Delete this test case?") { store.deleteTestCase(testCase.id) }
            }
            if !testCase.steps.isEmpty { detail("Steps", testCase.steps) }
            if !testCase.expected.isEmpty { detail("Expected result", testCase.expected) }
            Divider()
            HStack(spacing: 8) {
                ForEach(TestResultStatus.allCases) { status in
                    let selected = current?.status == status
                    Button { store.setResult(caseID: testCase.id, environment: environment, status: status, note: note) } label: {
                        Label(status.title, systemImage: status.symbol).labelStyle(.titleAndIcon).font(.callout)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(selected ? status.color.opacity(0.2) : Color.primary.opacity(0.06), in: Capsule())
                    .foregroundStyle(selected ? status.color : Color.primary)
                }
                Spacer()
                if let tested = current?.testedAt {
                    Text(tested.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
            }
            TextField("Note about this result", text: $note)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if let status = current?.status { store.setResult(caseID: testCase.id, environment: environment, status: status, note: note) }
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(padding: 16)
        .onAppear { note = current?.note ?? "" }
        .onChange(of: environment) { note = store.latestResult(caseID: testCase.id, environment: environment)?.note ?? "" }
    }

    private func detail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Plans

struct TicketPlansTab: View {
    @Environment(AppStore.self) private var store
    let ticket: Ticket
    @State private var showingPost = false

    var body: some View {
        let comments = store.planComments(for: ticket.id)
        let pending = comments.filter { $0.postedAt == nil }
        VStack(alignment: .leading, spacing: 16) {
            if ticket.github != nil, !pending.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "paperplane.fill").foregroundStyle(Theme.accent)
                    Text("\(pending.count) draft\(pending.count == 1 ? "" : "s") ready to post to GitHub").font(.callout.weight(.medium))
                    Spacer()
                    Button("Review & Post…") { showingPost = true }.buttonStyle(.primary)
                }
                .cardStyle(padding: 14)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("New plan comment").font(.headline)
                PlanCommentComposer(ticketID: ticket.id).id(ticket.id)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle(padding: 16)

            if comments.isEmpty {
                EmptyTabState(
                    symbol: "list.bullet.clipboard", title: "No plan yet",
                    message: "Write the steps, notes and questions for this ticket above. Drafts can be posted to GitHub when ready."
                )
            } else {
                ForEach(comments) { comment in
                    PlanCommentRow(comment: comment, canPost: ticket.github != nil) { store.deletePlanComment(comment.id) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardStyle(padding: 16)
                }
            }
        }
        .sheet(isPresented: $showingPost) { PostPlanSheet(ticketID: ticket.id) }
    }
}

// MARK: - Notes

struct TicketNotesTab: View {
    @Environment(AppStore.self) private var store
    let ticket: Ticket

    var body: some View {
        let notes = store.notes.filter { $0.ticketID == ticket.id }.sorted { $0.createdAt > $1.createdAt }
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("New note").font(.headline)
                NoteComposer(ticketID: ticket.id).id(ticket.id)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardStyle(padding: 16)

            if notes.isEmpty {
                EmptyTabState(symbol: "note.text", title: "No notes yet", message: "Notes stay on this Mac and are never sent to GitHub.")
            } else {
                ForEach(notes) { note in
                    NoteRow(note: note) { store.deleteNote(note.id) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .cardStyle(padding: 14)
                }
            }
        }
    }
}

// MARK: - Shared

struct EmptyTabState<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack(spacing: 10) { actions }.padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

extension EmptyTabState where Actions == EmptyView {
    init(symbol: String, title: String, message: String) {
        self.init(symbol: symbol, title: title, message: message) { EmptyView() }
    }
}
