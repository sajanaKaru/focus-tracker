import FocusCore
import SwiftUI

// The ticket page's Test cases tab (TicketPageTabs.swift) uses these sheets and rows.

extension VerdictOutcome: Identifiable {
    public var id: String { rawValue }
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

struct BugRow: View {
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
    var startsAsRegression = false
    @State private var title = ""
    @State private var steps = ""
    @State private var expected = ""
    @State private var risk = ""
    @State private var isRegression = false

    var body: some View {
        SheetScaffold(title: existing == nil ? "New test case" : "Edit test case", width: 600) {
            Form {
                TextField("Title", text: $title, prompt: Text("e.g. User can sign in"))
                Toggle("Regression case", isOn: $isRegression)
                if isRegression {
                    TextField("Risk", text: $risk, prompt: Text("What existing behavior could break, and why"))
                }
                VStack(alignment: .leading) {
                    Text(isRegression ? "Steps to reproduce" : "Steps").font(.caption).foregroundStyle(.secondary)
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
            guard let existing else { isRegression = startsAsRegression; return }
            title = existing.title
            steps = existing.steps
            expected = existing.expected
            risk = existing.risk
            isRegression = existing.isRegression
        }
    }

    private func save() {
        if let existing {
            store.updateTestCase(existing.id, title: title, steps: steps, expected: expected, risk: isRegression ? risk : "", isRegression: isRegression)
        } else {
            store.addTestCase(ticketID: ticketID, title: title, steps: steps, expected: expected, risk: isRegression ? risk : "", isRegression: isRegression)
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
