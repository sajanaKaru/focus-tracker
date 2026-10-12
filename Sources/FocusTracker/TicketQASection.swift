import FocusCore
import SwiftUI

struct TicketQASection: View {
    @Environment(AppStore.self) private var store
    let ticket: Ticket
    @State private var environment: DeploymentEnvironment?
    @State private var casesLoaded = false
    @State private var editingCase: TestCase?
    @State private var addingCase = false
    @State private var drafting = false
    @State private var verdict: VerdictOutcome?
    @State private var reportingBug = false

    var body: some View {
        let cases = store.testCases(for: ticket.id)
        let state = store.qaState(ticketID: ticket.id, environment: environment)
        let summary = store.qaSummary(ticketID: ticket.id, environment: environment)
        Section("QA") {
            Picker("Environment", selection: $environment) {
                Text("No environment").tag(DeploymentEnvironment?.none)
                ForEach(DeploymentEnvironment.allCases) { Text($0.title).tag(DeploymentEnvironment?.some($0)) }
            }
            if let mark = ticket.deployment {
                Text("Moved to “\(mark.statusName)” on \(mark.movedAt.formatted(date: .abbreviated, time: .omitted))\(mark.movedBy.map { " by @\($0)" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Chip(text: state.title, color: state.color)
                Text(summary.text).font(.callout).foregroundStyle(.secondary)
            }
            if let last = store.latestVerdict(ticketID: ticket.id, environment: environment) {
                Text("Last verdict: \(last.outcome.title) by @\(last.tester) · \(last.testedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ForEach(cases) { testCase in
                TestCaseRow(testCase: testCase, environment: environment) { editingCase = testCase }
            }
            Button { addingCase = true } label: { Label("Add test case", systemImage: "plus") }
            Button { drafting = true } label: { Label("Draft test cases with AI", systemImage: "sparkles") }
                .disabled(!store.hasAIKey)
                .help(store.hasAIKey ? "Draft cases from the ticket and its pull requests" : "Add an AI API key in Settings")

            HStack {
                Button { verdict = .pass } label: { Label("Mark passed", systemImage: "checkmark.circle") }
                Button { verdict = .fail } label: { Label("Mark failed", systemImage: "xmark.circle") }
            }
            .disabled(cases.isEmpty)
            .help(cases.isEmpty ? "Add a test case first" : "Post a verdict to GitHub")

            ForEach(store.bugs(for: ticket.id)) { BugRow(bug: $0) }
            Button { reportingBug = true } label: { Label("Report bug", systemImage: "ladybug") }
        }
        .onAppear {
            guard !casesLoaded else { return }
            casesLoaded = true
            environment = ticket.environment
        }
        .onChange(of: ticket.environment) { environment = ticket.environment }
        .sheet(isPresented: $addingCase) { TestCaseSheet(ticketID: ticket.id, existing: nil) }
        .sheet(isPresented: $drafting) { DraftCasesSheet(ticket: ticket) }
        .sheet(item: $editingCase) { TestCaseSheet(ticketID: ticket.id, existing: $0) }
        .sheet(item: $verdict) { VerdictSheet(ticket: ticket, environment: environment, outcome: $0) }
        .sheet(isPresented: $reportingBug) { BugSheet(ticket: ticket, defaultEnvironment: environment) }
    }
}

extension VerdictOutcome: Identifiable {
    public var id: String { rawValue }
}

private struct TestCaseRow: View {
    @Environment(AppStore.self) private var store
    let testCase: TestCase
    let environment: DeploymentEnvironment?
    let edit: () -> Void
    @State private var note = ""

    var body: some View {
        let current = store.latestResult(caseID: testCase.id, environment: environment)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(testCase.title).font(.callout.weight(.medium))
                Spacer()
                Button(action: edit) { Image(systemName: "pencil") }.buttonStyle(.borderless).help("Edit")
                DeleteButton(title: "Delete this test case?") { store.deleteTestCase(testCase.id) }
            }
            if !testCase.steps.isEmpty { Text(testCase.steps).font(.caption).foregroundStyle(.secondary) }
            if !testCase.expected.isEmpty { Text("Expected: \(testCase.expected)").font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 6) {
                ForEach(TestResultStatus.allCases) { status in
                    let selected = current?.status == status
                    Button { store.setResult(caseID: testCase.id, environment: environment, status: status, note: note) } label: {
                        Label(status.title, systemImage: status.symbol).labelStyle(.titleAndIcon).font(.caption)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(selected ? status.color.opacity(0.2) : Color.primary.opacity(0.06), in: Capsule())
                    .foregroundStyle(selected ? status.color : Color.primary)
                }
                if current == nil { Text("Not run").font(.caption).foregroundStyle(.secondary) }
            }
            TextField("Note", text: $note)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit {
                    if let status = current?.status { store.setResult(caseID: testCase.id, environment: environment, status: status, note: note) }
                }
        }
        .padding(.vertical, 2)
        .onAppear { note = current?.note ?? "" }
        .onChange(of: environment) { note = store.latestResult(caseID: testCase.id, environment: environment)?.note ?? "" }
    }
}

extension TestResultStatus {
    var color: Color {
        switch self {
        case .pass: Theme.success
        case .fail: Theme.danger
        case .blocked: Theme.warning
        case .skipped: Theme.slate
        }
    }
}

private struct BugRow: View {
    @Environment(AppStore.self) private var store
    let bug: BugReport
    @State private var retrying = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "ladybug.fill").foregroundStyle(Theme.danger)
            VStack(alignment: .leading, spacing: 3) {
                Text(bug.title).font(.callout.weight(.medium))
                HStack(spacing: 6) {
                    Chip(text: bug.severity.title, color: bug.severity == .critical || bug.severity == .high ? Theme.danger : Theme.warning)
                    if let environment = bug.environment { Chip(text: environment.title, color: environment.color) }
                }
                switch bug.state {
                case .draft:
                    ProgressView().controlSize(.small)
                case .created:
                    if let number = bug.issueNumber, let url = bug.issueURL.flatMap(URL.init(string:)) {
                        Link("#\(number) on GitHub", destination: url).font(.caption)
                    }
                case .failed(let message):
                    Text(message).font(.caption).foregroundStyle(Theme.danger)
                    Button(retrying ? "Retrying…" : "Retry") {
                        retrying = true
                        Task { await store.retryBug(bug.id); retrying = false }
                    }
                    .disabled(retrying)
                    .controlSize(.small)
                }
            }
        }
    }
}

struct TestCaseSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let ticketID: UUID
    let existing: TestCase?
    @State private var title = ""
    @State private var steps = ""
    @State private var expected = ""

    var body: some View {
        SheetScaffold(title: existing == nil ? "New test case" : "Edit test case", width: 600) {
            Form {
                TextField("Title", text: $title, prompt: Text("e.g. User can sign in"))
                VStack(alignment: .leading) {
                    Text("Steps").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $steps).frame(height: 140)
                }
                TextField("Expected result", text: $expected)
            }
        } footer: {
            Button(role: .cancel) { dismiss() } label: { ShortcutLabel(title: "Cancel", keys: "⎋") }
                .buttonStyle(.secondary)
                .keyboardShortcut(.cancelAction)
            Button(action: save) { ShortcutLabel(title: "Save", keys: "↩") }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .onAppear {
            guard let existing else { return }
            title = existing.title
            steps = existing.steps
            expected = existing.expected
        }
    }

    private func save() {
        if let existing {
            store.updateTestCase(existing.id, title: title, steps: steps, expected: expected)
        } else {
            store.addTestCase(ticketID: ticketID, title: title, steps: steps, expected: expected)
        }
        dismiss()
    }
}

struct VerdictSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let ticket: Ticket
    let environment: DeploymentEnvironment?
    let outcome: VerdictOutcome
    @State private var build = ""
    @State private var returnToInProgress = true

    private var preview: String {
        QA.verdictComment(
            outcome: outcome, environment: environment, tester: store.githubLogin ?? "qa", date: Date(), build: build,
            cases: store.testCases(for: ticket.id), results: store.testResults.filter { $0.ticketID == ticket.id },
            bugNumbers: store.bugs(for: ticket.id).filter { $0.environment == environment }.compactMap(\.issueNumber)
        )
    }

    var body: some View {
        SheetScaffold(title: "Mark \(outcome.title.lowercased())\(environment.map { " on \($0.title)" } ?? "")", width: 640) {
            Form {
                TextField("Build / version", text: $build, prompt: Text("optional"))
                if outcome == .fail {
                    Toggle("Move the ticket back to In Progress", isOn: $returnToInProgress)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Comment posted to \(ticket.displayKey)").font(.caption).foregroundStyle(.secondary)
                    ScrollView { Text(preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(height: 200)
                        .padding(8)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    Text("Also sets the label \(QA.label(environment: environment, outcome: outcome)).").font(.caption).foregroundStyle(.secondary)
                }
            }
        } footer: {
            Button(role: .cancel) { dismiss() } label: { ShortcutLabel(title: "Cancel", keys: "⎋") }
                .buttonStyle(.secondary)
                .keyboardShortcut(.cancelAction)
            Button(action: post) { ShortcutLabel(title: "Post", keys: "↩") }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func post() {
        store.postVerdict(ticketID: ticket.id, environment: environment, outcome: outcome, build: build, returnToInProgress: returnToInProgress)
        dismiss()
    }
}

struct BugSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let ticket: Ticket
    let defaultEnvironment: DeploymentEnvironment?
    @State private var title = ""
    @State private var severity: BugSeverity = .medium
    @State private var environment: DeploymentEnvironment?
    @State private var build = ""
    @State private var steps = ""
    @State private var expected = ""
    @State private var actual = ""
    @State private var links = ""
    @State private var busy = false

    var body: some View {
        SheetScaffold(title: "Report a bug", width: 680) {
            Form {
                TextField("Title", text: $title, prompt: Text("e.g. Save crashes with empty name"))
                Picker("Severity", selection: $severity) {
                    ForEach(BugSeverity.allCases) { Text($0.title).tag($0) }
                }
                Picker("Environment", selection: $environment) {
                    Text("No environment").tag(DeploymentEnvironment?.none)
                    ForEach(DeploymentEnvironment.allCases) { Text($0.title).tag(DeploymentEnvironment?.some($0)) }
                }
                TextField("Build / version", text: $build, prompt: Text("optional"))
                editor("Steps to reproduce", text: $steps, height: 110)
                editor("Expected", text: $expected, height: 64)
                editor("Actual", text: $actual, height: 64)
                TextField("Links / screenshots", text: $links, prompt: Text("Paste image or recording URLs"))
                Text("Creates a new issue in \(ticket.github?.repo ?? "the ticket's repo"), linked to \(ticket.displayKey).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } footer: {
            Button(role: .cancel) { dismiss() } label: { ShortcutLabel(title: "Cancel", keys: "⎋") }
                .buttonStyle(.secondary)
                .keyboardShortcut(.cancelAction)
            Button(action: submit) { ShortcutLabel(title: busy ? "Creating…" : "Create issue", keys: "⌘↩") }
                .buttonStyle(.primary)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
        }
        .onAppear { environment = defaultEnvironment }
    }

    private func editor(_ label: String, text: Binding<String>, height: CGFloat = 70) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextEditor(text: text).frame(height: height)
        }
    }

    private func submit() {
        busy = true
        Task {
            let bug = await store.reportBug(
                ticketID: ticket.id, environment: environment, title: title, severity: severity, build: build,
                steps: steps, expected: expected, actual: actual, links: links
            )
            busy = false
            if bug != nil { dismiss() }
        }
    }
}
