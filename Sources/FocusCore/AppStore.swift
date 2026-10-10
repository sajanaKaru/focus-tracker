import CoreGraphics
import Foundation
import Observation

public enum PrefKey {
    public static let repos = "githubRepos"
    public static let includePRs = "githubIncludePRs"
    public static let syncMinutes = "githubSyncMinutes"
    public static let idleMinutes = "idleMinutes"
    public static let workingMinutes = "planWorkingMinutes"
    public static let focusPercent = "planFocusPercent"
    public static let defaultEstimateMinutes = "planDefaultEstimateMinutes"
    public static let workDays = "planWorkDays"
    public static let githubLogin = "githubLogin"
    public static let workspace = "selectedWorkspace"
    public static let hiddenWorkspaces = "hiddenWorkspaces"
}

public enum SyncState: Equatable, Sendable {
    case idle
    case syncing
    case succeeded(Date, Int)
    case failed(String)
}

public enum PullRequestsState: Equatable, Sendable {
    case idle
    case loading
    case loaded(Date, total: Int)
    case failed(String)
}

public enum IdleTime {
    public static func current() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}

@MainActor
@Observable
public final class AppStore {
    public private(set) var tickets: [Ticket] = []
    public private(set) var entries: [TimeEntry] = []
    public private(set) var notes: [TicketNote] = []
    public private(set) var planComments: [PlanComment] = []
    public private(set) var activities: [Activity] = []
    public private(set) var dayPlans: [DayPlan] = []
    public private(set) var actionLog: [ActionLogEntry] = []
    public private(set) var dismissedFailureIDs: Set<UUID> = []
    /// GitHub issue comments per ticket; fetched on demand and kept in memory only.
    public private(set) var issueComments: [UUID: [IssueComment]] = [:]
    public private(set) var commentsError: [UUID: String] = [:]
    public private(set) var commentsLoading: Set<UUID> = []
    public private(set) var remoteOptions = RemoteOptions()
    public private(set) var pullRequests: [PullRequestItem] = []
    public private(set) var pullRequestsState: PullRequestsState = .idle
    public private(set) var githubLogin: String?
    /// Workspaces switched off in Settings, as `Workspace.storageValue`.
    public private(set) var hiddenWorkspaces: Set<String> = []
    public var selectedWorkspace: Workspace = .all {
        didSet { defaults.set(selectedWorkspace.storageValue, forKey: PrefKey.workspace) }
    }
    /// Updated every second while a timer runs; views read it to stay live.
    public private(set) var now = Date()
    public private(set) var syncState: SyncState = .idle
    public var notice: String?

    @ObservationIgnored private let storeURL: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let transport: HTTPTransport
    @ObservationIgnored let tokenProvider: () -> String?
    @ObservationIgnored private var lastOptionsLoad: Date?
    @ObservationIgnored private let idleSeconds: () -> TimeInterval
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var autoSyncTask: Task<Void, Never>?
    @ObservationIgnored private var lastRefresh: [UUID: Date] = [:]
    @ObservationIgnored private var lastCommentsLoad: [UUID: Date] = [:]
    @ObservationIgnored private var pendingPushes: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingEntryIDs: [String: UUID] = [:]

    nonisolated public static var defaultStoreURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FocusTracker", isDirectory: true)
            .appendingPathComponent("data.json")
    }

    public init(
        storeURL: URL = AppStore.defaultStoreURL,
        defaults: UserDefaults = .standard,
        transport: HTTPTransport = URLSessionTransport(),
        tokenProvider: @escaping () -> String? = { Keychain.get(account: Keychain.githubAccount) },
        idleSeconds: @escaping () -> TimeInterval = IdleTime.current
    ) {
        self.storeURL = storeURL
        self.defaults = defaults
        self.transport = transport
        self.tokenProvider = tokenProvider
        self.idleSeconds = idleSeconds
        githubLogin = defaults.string(forKey: PrefKey.githubLogin)
        hiddenWorkspaces = Set(defaults.stringArray(forKey: PrefKey.hiddenWorkspaces) ?? [])
        selectedWorkspace = Workspace(storageValue: defaults.string(forKey: PrefKey.workspace))
        load()
        if activeEntry != nil || activeActivity != nil { startTicking() }
    }

    // MARK: - Queries

    public var activeEntry: TimeEntry? { entries.last { $0.end == nil } }

    public var activeActivity: Activity? { activities.last { $0.end == nil } }

    public var activeTicket: Ticket? {
        guard let id = activeEntry?.ticketID else { return nil }
        return ticket(id)
    }

    public func ticket(_ id: UUID) -> Ticket? { tickets.first { $0.id == id } }

    public var hasCurrentSprint: Bool {
        tickets.contains { $0.sprints.contains { $0.isCurrent(at: now) } }
    }

    public func setGitHubLogin(_ login: String) {
        githubLogin = login
        defaults.set(login, forKey: PrefKey.githubLogin)
    }

    /// Personal plus one entry per organization seen in tickets or pull requests; empty until the login is known.
    public var knownWorkspaces: [Workspace] {
        guard let login = githubLogin else { return [] }
        let repos = tickets.compactMap { $0.github?.repo } + pullRequests.map(\.repo)
        let orgs = Set(repos.compactMap { repo -> String? in
            if case .organization(let name) = Workspace.of(repo: repo, login: login) { return name }
            return nil
        })
        let sorted = orgs.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return [.personal] + sorted.map(Workspace.organization)
    }

    public func isWorkspaceVisible(_ workspace: Workspace) -> Bool {
        !hiddenWorkspaces.contains(workspace.storageValue)
    }

    public func setWorkspace(_ workspace: Workspace, visible: Bool) {
        if visible { hiddenWorkspaces.remove(workspace.storageValue) } else { hiddenWorkspaces.insert(workspace.storageValue) }
        defaults.set(hiddenWorkspaces.sorted(), forKey: PrefKey.hiddenWorkspaces)
    }

    /// All, then the visible workspaces; only All until the login is known.
    public var workspaceOptions: [Workspace] {
        [.all] + knownWorkspaces.filter(isWorkspaceVisible)
    }

    /// The selection, or All when it is hidden or no longer exists.
    public var activeWorkspace: Workspace {
        workspaceOptions.contains(selectedWorkspace) ? selectedWorkspace : .all
    }

    /// Resolved once per query: the active workspace scans every ticket, so it must not run per item.
    /// Hidden workspaces are excluded even from All.
    private func workspaceFilter() -> (String?) -> Bool {
        guard let login = githubLogin else { return { _ in true } }
        let active = activeWorkspace
        let hidden = hiddenWorkspaces
        return { repo in
            let owner = repo.map { Workspace.of(repo: $0, login: login) } ?? .personal
            return !hidden.contains(owner.storageValue) && active.contains(repo: repo, login: login)
        }
    }

    public var workspaceTickets: [Ticket] {
        let includes = workspaceFilter()
        return tickets.filter { includes($0.github?.repo) }
    }

    public var workspacePullRequests: [PullRequestItem] {
        let includes = workspaceFilter()
        return pullRequests.filter { includes($0.repo) }
    }

    /// Open tickets in the current sprint, or all open tickets while no sprint is current; used for sidebar badges.
    public var currentSprintTickets: [Ticket] {
        let open = workspaceTickets.filter { $0.status != .done }
        guard hasCurrentSprint else { return open }
        return open.filter { $0.sprints.contains { $0.isCurrent(at: now) } }
    }

    public var openSpecialWorkCount: Int {
        currentSprintTickets.filter { !$0.specialWork.isEmpty }.count
    }

    private var workspaceEntries: [TimeEntry] {
        let ids = Set(workspaceTickets.map(\.id))
        return entries.filter { ids.contains($0.ticketID) }
    }

    private var workspaceNotes: [TicketNote] {
        let ids = Set(workspaceTickets.map(\.id))
        return notes.filter { ids.contains($0.ticketID) }
    }

    /// Calls and meetings belong to no repo, so every workspace shows them.
    private var workspaceActivities: [Activity] { activities }

    public func tickets(matching filter: TicketFilter) -> [Ticket] {
        workspaceTickets.filter { filter.matches($0, now: now) }
    }

    public var repoNames: [String] {
        Set(workspaceTickets.compactMap { $0.github?.repo }).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public var milestoneTitles: [String] {
        Set(workspaceTickets.compactMap { $0.milestone?.title }).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Sprint names, newest iteration first.
    public var sprintNames: [String] {
        var starts: [String: Date] = [:]
        for field in workspaceTickets.flatMap(\.sprints) {
            starts[field.value] = max(starts[field.value] ?? .distantPast, field.start ?? .distantPast)
        }
        return starts.sorted { $0.value > $1.value }.map(\.key)
    }

    public func isTracking(_ ticketID: UUID) -> Bool { activeEntry?.ticketID == ticketID }

    public func trackedTime(for ticketID: UUID) -> TimeInterval {
        entries.filter { $0.ticketID == ticketID }.reduce(0) { $0 + $1.duration(at: now) }
    }

    public func trackedTime(in interval: DateInterval) -> TimeInterval {
        workspaceEntries.reduce(0) { $0 + $1.duration(in: interval, at: now) } + activityTime(in: interval)
    }

    /// Time spent on calls, meetings and other non-ticket activities.
    public func activityTime(in interval: DateInterval) -> TimeInterval {
        workspaceActivities.reduce(0) { $0 + $1.duration(in: interval, at: now) }
    }

    public func trackedTime(for ticketID: UUID, in interval: DateInterval) -> TimeInterval {
        entries.filter { $0.ticketID == ticketID }.reduce(0) { $0 + $1.duration(in: interval, at: now) }
    }

    public func entries(in interval: DateInterval) -> [TimeEntry] {
        workspaceEntries
            .filter { $0.duration(in: interval, at: now) > 0 }
            .sorted { $0.start > $1.start }
    }

    public func entries(for ticketID: UUID) -> [TimeEntry] {
        entries.filter { $0.ticketID == ticketID }.sorted { $0.start > $1.start }
    }

    /// Time entries and notes for a ticket, newest first.
    public func log(for ticketID: UUID) -> [LogItem] {
        let items = entries.filter { $0.ticketID == ticketID }.map(LogItem.time)
            + notes.filter { $0.ticketID == ticketID }.map(LogItem.note)
        return items.sorted { $0.date > $1.date }
    }

    /// Time entries, notes and activities that fall in `interval`, newest first.
    public func log(in interval: DateInterval) -> [LogItem] {
        let items = entries(in: interval).map(LogItem.time)
            + workspaceNotes.filter { interval.contains($0.createdAt) }.map(LogItem.note)
            + workspaceActivities.filter { $0.duration(in: interval, at: now) > 0 }.map(LogItem.activity)
        return items.sorted { $0.date > $1.date }
    }

    public func dailyTotals(days: Int, calendar: Calendar = .current) -> [(day: Date, seconds: TimeInterval)] {
        let today = calendar.startOfDay(for: now)
        return (0..<days).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today),
                  let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            return (day, trackedTime(in: DateInterval(start: day, end: next)))
        }
    }

    /// Tickets with at least a minute tracked (or a note) in `interval`, bucketed by category.
    public func categoryStats(in interval: DateInterval) -> [CategoryStat] {
        let scopedNotes = workspaceNotes
        let worked = workspaceTickets.compactMap { ticket -> CategoryStat.Entry? in
            let seconds = trackedTime(for: ticket.id, in: interval)
            let hasNote = scopedNotes.contains { $0.ticketID == ticket.id && interval.contains($0.createdAt) }
            return seconds >= 60 || hasNote ? CategoryStat.Entry(ticket: ticket, seconds: seconds) : nil
        }.sorted { $0.seconds > $1.seconds }

        var stats = TicketCategory.allCases.map { category in
            CategoryStat(category: category, entries: worked.filter { category.matches($0.ticket) })
        }
        let other = worked.filter { entry in !TicketCategory.allCases.contains { $0.matches(entry.ticket) } }
        if !other.isEmpty { stats.append(CategoryStat(category: nil, entries: other)) }
        return stats
    }

    public var menuBarTitle: String {
        if let active = activeEntry { return Format.clock(active.duration(at: now)) }
        if let active = activeActivity { return Format.clock(active.duration(at: now)) }
        return ""
    }

    /// Calendar-day range containing `day`.
    public func dayRange(for day: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }

    private func dateHeading(_ day: Date) -> String {
        day.formatted(date: .complete, time: .omitted)
    }

    private func ticketLine(_ t: Ticket, in range: DateInterval) -> String? {
        let seconds = trackedTime(for: t.id, in: range)
        let ticketNotes = notes
            .filter { $0.ticketID == t.id && range.contains($0.createdAt) }
            .sorted { $0.createdAt < $1.createdAt }
            .map { "  - \($0.text)" }
        guard seconds >= 60 || !ticketNotes.isEmpty else { return nil }
        let time = seconds >= 60 ? " (\(Format.short(seconds)))" : ""
        return (["- \(t.displayKey) \(t.title)\(time)"] + ticketNotes).joined(separator: "\n")
    }

    private func activityLines(in range: DateInterval) -> [String] {
        workspaceActivities.compactMap { a -> String? in
            let seconds = a.duration(in: range, at: now)
            guard seconds >= 60 else { return nil }
            return "- \(a.kind.title): \(a.title) (\(Format.short(seconds)))"
        }
    }

    /// Worked tickets grouped by their GitHub project Status (else the app status), then activities grouped by kind.
    public func daySummarySections(for day: Date, calendar: Calendar = .current) -> [SummarySection] {
        let range = dayRange(for: day, calendar: calendar)
        var sections: [SummarySection] = []
        func append(_ title: String, _ item: SummaryItem) {
            if let i = sections.firstIndex(where: { $0.title == title }) {
                sections[i].items.append(item)
            } else {
                sections.append(SummarySection(title: title, items: [item]))
            }
        }

        for ticket in workspaceTickets {
            let seconds = trackedTime(for: ticket.id, in: range)
            let ticketNotes = notes
                .filter { $0.ticketID == ticket.id && range.contains($0.createdAt) }
                .sorted { $0.createdAt < $1.createdAt }
                .map(\.text)
            guard seconds >= 60 || !ticketNotes.isEmpty else { continue }
            let category = ticket.field(named: "Status")?.value ?? ticket.status.title
            append(category, SummaryItem(text: ticket.github?.url ?? ticket.title, isLink: ticket.github != nil, notes: ticketNotes))
        }
        for activity in workspaceActivities where activity.duration(in: range, at: now) >= 60 {
            let title = activity.kind == .other ? activity.kind.title : "Meetings"
            append(title, SummaryItem(text: activity.title))
        }
        return sections
    }

    /// Plain-text summary with "- " bullets under each category heading.
    public func daySummaryText(for day: Date, calendar: Calendar = .current, includeDate: Bool = false, includeTomorrow: Bool = false) -> String {
        let sections = daySummarySections(for: day, calendar: calendar)
        let heading = includeDate ? dateHeading(day) + "\n--------\n" : ""
        var text = heading + (sections.isEmpty ? "(nothing tracked)" : sections.map { section in
            ([section.title] + section.items.flatMap { item in
                ["- \(item.text)"] + item.notes.map { "  - \($0)" }
            }).joined(separator: "\n")
        }.joined(separator: "\n"))
        if includeTomorrow {
            let next = tomorrowPlan(after: day, calendar: calendar)
            let lines = next.items.isEmpty ? ["- (nothing planned)"] : next.items.map { "- \($0.text)" }
            text += "\n\n" + ([next.label, "--------"] + lines).joined(separator: "\n")
        }
        return text
    }

    /// Planned tickets for the next working day after `day`; falls back to the suggested picks when no plan exists yet.
    private func tomorrowPlan(after day: Date, calendar: Calendar) -> (label: String, items: [SummaryItem]) {
        let next = planSettings.nextWorkingDay(after: day, calendar: calendar)
        let ids = plan(for: next, calendar: calendar)?.ticketIDs ?? DayPlanner.autoPick(
            planCandidates(for: next, calendar: calendar),
            capacityMinutes: capacity(for: next, calendarBusy: [], calendar: calendar).capacityMinutes
        )
        let items = ids.compactMap { ticket($0) }
            .filter { $0.status != .done }
            .map { SummaryItem(text: $0.github?.url ?? $0.title, isLink: $0.github != nil) }
        let isNextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)).map { calendar.isDate($0, inSameDayAs: next) } ?? false
        return (isNextDay ? "Tomorrow" : next.formatted(.dateTime.weekday(.wide)), items)
    }

    /// The same summary as HTML so pasting into Slack or Mail gives real bullet lists and links.
    public func daySummaryHTML(for day: Date, calendar: Calendar = .current, includeDate: Bool = false, includeTomorrow: Bool = false) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        let sections = daySummarySections(for: day, calendar: calendar)
        let heading = includeDate ? "<div>\(esc(dateHeading(day)))</div><div>--------</div>" : ""
        func list(_ items: [SummaryItem]) -> String {
            "<ul>" + items.map { item -> String in
                let label = item.isLink ? "<a href=\"\(esc(item.text))\">\(esc(item.text))</a>" : esc(item.text)
                let notes = item.notes.isEmpty ? "" : "<ul>" + item.notes.map { "<li>\(esc($0))</li>" }.joined() + "</ul>"
                return "<li>\(label)\(notes)</li>"
            }.joined() + "</ul>"
        }
        var html = heading + (sections.isEmpty
            ? "<p>(nothing tracked)</p>"
            : sections.map { "<div>\(esc($0.title))</div>" + list($0.items) }.joined())
        if includeTomorrow {
            let next = tomorrowPlan(after: day, calendar: calendar)
            html += "<br><div>\(esc(next.label))</div><div>--------</div>"
                + (next.items.isEmpty ? "<p>(nothing planned)</p>" : list(next.items))
        }
        return html
    }

    public func standupText(calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let todayRange = dayRange(for: today, calendar: calendar)
        // Planned tickets come first with any time/notes already logged today.
        let isPlanned: (Ticket) -> Bool = { $0.status == .inProgress || $0.status == .inReview }
        let planned = workspaceTickets.filter(isPlanned)
            .map { ticketLine($0, in: todayRange) ?? "- \($0.displayKey) \($0.title)" }
        let otherWork = workspaceTickets.filter { !isPlanned($0) }.compactMap { ticketLine($0, in: todayRange) }
        let todayLines = planned + otherWork + activityLines(in: todayRange)

        return """
        \(dateHeading(yesterday))
        \(daySummaryText(for: yesterday, calendar: calendar))

        \(dateHeading(today))
        \(todayLines.isEmpty ? "- (nothing planned)" : todayLines.joined(separator: "\n"))
        """
    }

    // MARK: - Ticket mutations

    @discardableResult
    public func addTicket(title: String, priority: Priority = .none) -> Ticket {
        let ticket = Ticket(title: title, priority: priority)
        tickets.append(ticket)
        record(.ticketCreate, ticket: ticket, new: title)
        save()
        return ticket
    }

    public func update(_ id: UUID, _ change: (inout Ticket) -> Void) {
        guard let i = tickets.firstIndex(where: { $0.id == id }) else { return }
        let before = tickets[i]
        change(&tickets[i])
        tickets[i].updatedAt = Date()
        for c in before.changes(to: tickets[i]) {
            record(.ticketEdit, ticket: tickets[i], field: c.field, old: c.old, new: c.new, oldList: c.oldList, newList: c.newList)
        }
        save()
    }

    public func setStatus(_ id: UUID, _ status: TicketStatus) {
        guard let t = ticket(id) else { return }
        if t.status != status {
            if let field = t.projectStatusField,
               let option = remoteOptions.projectStatus[field.project]?.first(where: { TicketStatus(optionName: $0.name) == status }) {
                setStatusOption(id, project: field.project, option: option.name)
            } else {
                update(id) { $0.status = status }
                syncIssueState(id, from: t.status, to: status)
            }
        }
        if status == .done && isTracking(id) { stop() }
    }

    /// Saves a project field locally right away, then writes it to GitHub; a failed write stays local and is retryable from the log.
    public func setProjectField(_ id: UUID, name: String, project: String, to value: ProjectFieldValue, delay: Duration = .zero) {
        let payload: ProjectFieldValue
        let kind: CustomField.Kind
        let text: String
        let oldText = ticket(id)?.fields?.first { $0.project == project && $0.name == name }?.value ?? "None"
        switch value {
        case .text(let raw):
            text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            payload = .text(text)
            kind = .text
        case .number(let number):
            text = number == number.rounded() ? String(Int(number)) : String(number)
            payload = value
            kind = .number
        case .option(let option):
            text = option
            payload = value
            kind = .select
        }

        edit(id, FieldChange(field: name, old: oldText, new: text), remote: .projectField(project: project, field: name, value: payload), delay: delay) { ticket in
            var fields = ticket.fields ?? []
            if let i = fields.firstIndex(where: { $0.project == project && $0.name == name }) {
                fields[i].value = text
            } else {
                fields.append(CustomField(name: name, value: text, kind: kind, project: project))
            }
            ticket.fields = fields
        }
    }

    /// Sets the estimate; when the issue has an estimate field in GitHub Projects, that field is updated too.
    public func setEstimate(_ id: UUID, minutes: Int) {
        update(id) { $0.estimateMinutes = minutes == 0 ? nil : minutes }
        guard let field = ticket(id)?.estimateField else { return }
        setProjectField(id, name: field.name, project: field.project, to: .number(Double(minutes) / 60), delay: .milliseconds(800))
    }

    public func deleteTicket(_ id: UUID) {
        if isTracking(id) { stop() }
        if let ticket = ticket(id) { record(.ticketDelete, ticket: ticket, old: ticket.title) }
        tickets.removeAll { $0.id == id }
        entries.removeAll { $0.ticketID == id }
        notes.removeAll { $0.ticketID == id }
        planComments.removeAll { $0.ticketID == id }
        save()
    }

    // MARK: - Plan comments

    public static let planCommentSeparator = "\n\n---\n\n"

    /// Oldest first, so the plan reads top to bottom.
    public func planComments(for ticketID: UUID) -> [PlanComment] {
        planComments.filter { $0.ticketID == ticketID }.sorted { $0.createdAt < $1.createdAt }
    }

    public func unpostedPlanComments(for ticketID: UUID) -> [PlanComment] {
        planComments(for: ticketID).filter { $0.postedAt == nil }
    }

    public func addPlanComment(ticketID: UUID, text: String, at date: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, ticket(ticketID) != nil else { return }
        planComments.append(PlanComment(ticketID: ticketID, text: trimmed, createdAt: date))
        record(.planComment, ticket: ticket(ticketID), field: "Plan comment added", new: trimmed)
        save()
    }

    public func deletePlanComment(_ id: UUID) {
        if let c = planComments.first(where: { $0.id == id }) {
            record(.planComment, ticket: ticket(c.ticketID), field: "Plan comment deleted", old: c.text)
        }
        planComments.removeAll { $0.id == id }
        save()
    }

    /// Edits a draft; posted comments are locked because GitHub already has the old text.
    @discardableResult
    public func updatePlanComment(_ id: UUID, text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = planComments.firstIndex(where: { $0.id == id }),
              planComments[i].postedAt == nil, planComments[i].text != trimmed else { return false }
        record(.planComment, ticket: ticket(planComments[i].ticketID), field: "Plan comment edited", old: planComments[i].text, new: trimmed)
        planComments[i].text = trimmed
        save()
        return true
    }

    /// Posts the unposted plan comments (or just `commentID`) as one GitHub comment and marks them posted; on failure sets `notice` and returns false.
    @discardableResult
    public func postPlan(_ ticketID: UUID, only commentID: UUID? = nil) async -> Bool {
        let pending = unpostedPlanComments(for: ticketID).filter { commentID == nil || $0.id == commentID }
        guard !pending.isEmpty, let gh = ticket(ticketID)?.github else { return false }
        guard let token = tokenProvider(), !token.isEmpty else {
            notice = "Add a GitHub token in Settings to post comments."
            return false
        }
        let body = pending.map(\.text).joined(separator: Self.planCommentSeparator)
        let entryID = record(
            .planComment, ticket: ticket(ticketID), field: commentID == nil ? "Plan posted to GitHub" : "Plan comment posted to GitHub",
            new: body, sync: .pending
        )
        save()
        do {
            try await GitHubClient(token: token, transport: transport).postComment(repo: gh.repo, number: gh.number, body: body)
        } catch {
            setActionSync(entryID, .failed(error.localizedDescription))
            notice = "Couldn't post the comment (\(error.localizedDescription)). Posting needs a token with issues write access."
            return false
        }
        setActionSync(entryID, .synced(Date()), detail: "Comment posted on \(gh.repo)#\(gh.number)")
        let posted = Set(pending.map(\.id))
        let date = Date()
        for i in planComments.indices where posted.contains(planComments[i].id) { planComments[i].postedAt = date }
        save()
        return true
    }

    // MARK: - Notes

    public func addNote(ticketID: UUID, text: String, at date: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, ticket(ticketID) != nil else { return }
        notes.append(TicketNote(ticketID: ticketID, text: trimmed, createdAt: date))
        record(.note, ticket: ticket(ticketID), field: "Note added", new: trimmed)
        save()
    }

    public func deleteNote(_ id: UUID) {
        if let n = notes.first(where: { $0.id == id }) { record(.note, ticket: ticket(n.ticketID), field: "Note deleted", old: n.text) }
        notes.removeAll { $0.id == id }
        save()
    }

    // MARK: - Time tracking

    public func start(_ ticketID: UUID) {
        guard let i = tickets.firstIndex(where: { $0.id == ticketID }) else { return }
        stop()
        stopActivity()
        let started = Date()
        entries.append(TimeEntry(ticketID: ticketID, start: started))
        record(.timer, ticket: tickets[i], field: "Timer started", at: started)
        if tickets[i].status == .backlog || tickets[i].status == .todo { setStatus(ticketID, .inProgress) }
        now = started
        startTicking()
        save()
    }

    public func stop(at end: Date = Date()) {
        guard let i = entries.lastIndex(where: { $0.end == nil }) else { return }
        entries[i].end = max(end, entries[i].start)
        record(.timer, ticket: ticket(entries[i].ticketID), field: "Timer stopped", new: Self.minutesText(entries[i].end!.timeIntervalSince(entries[i].start)), at: entries[i].end!)
        tickTask?.cancel()
        tickTask = nil
        now = Date()
        save()
    }

    public func toggle(_ ticketID: UUID) {
        isTracking(ticketID) ? stop() : start(ticketID)
    }

    public func addManualEntry(ticketID: UUID, duration: TimeInterval, endingAt end: Date = Date()) {
        guard duration > 0, ticket(ticketID) != nil else { return }
        entries.append(TimeEntry(ticketID: ticketID, start: end.addingTimeInterval(-duration), end: end))
        record(.timeEntry, ticket: ticket(ticketID), field: "Manual entry added", new: Self.minutesText(duration))
        save()
    }

    public func deleteEntry(_ id: UUID) {
        if let e = entries.first(where: { $0.id == id }) {
            record(.timeEntry, ticket: ticket(e.ticketID), field: "Entry deleted", old: Self.minutesText((e.end ?? now).timeIntervalSince(e.start)))
        }
        entries.removeAll { $0.id == id }
        if activeEntry == nil && activeActivity == nil { tickTask?.cancel(); tickTask = nil }
        save()
    }

    /// Changes the times of an entry; `end` is ignored while the entry is still running.
    public func updateEntry(_ id: UUID, start: Date, end: Date?) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let newEnd = entries[i].end == nil ? nil : end
        guard start < (newEnd ?? now) else { return }
        record(
            .timeEntry, ticket: ticket(entries[i].ticketID), field: "Entry edited",
            old: "\(entries[i].start.formatted()) – \((entries[i].end ?? now).formatted())",
            new: "\(start.formatted()) – \((newEnd ?? now).formatted())"
        )
        entries[i].start = start
        entries[i].end = newEnd
        save()
    }

    public func updateActivity(_ id: UUID, kind: Activity.Kind, title: String, start: Date, end: Date?) {
        guard let i = activities.firstIndex(where: { $0.id == id }) else { return }
        let newEnd = activities[i].end == nil ? nil : end
        guard start < (newEnd ?? now) else { return }
        activities[i].kind = kind
        activities[i].title = Self.activityTitle(title, kind: kind)
        activities[i].start = start
        activities[i].end = newEnd
        save()
    }

    // MARK: - Activities (calls, meetings)

    /// Starts a live timer for a non-ticket activity; it replaces any running timer.
    public func startActivity(kind: Activity.Kind, title: String) {
        stop()
        stopActivity()
        let started = Date()
        activities.append(Activity(kind: kind, title: Self.activityTitle(title, kind: kind), start: started))
        record(.activity, field: "Activity started", new: activities.last?.title)
        now = started
        startTicking()
        save()
    }

    public func stopActivity(at end: Date = Date()) {
        guard let i = activities.lastIndex(where: { $0.end == nil }) else { return }
        activities[i].end = max(end, activities[i].start)
        record(.activity, field: "Activity stopped", old: activities[i].title)
        if activeEntry == nil { tickTask?.cancel(); tickTask = nil }
        now = Date()
        save()
    }

    public func addActivity(kind: Activity.Kind, title: String, start: Date, end: Date, calendarEventID: String? = nil) {
        guard end > start else { return }
        if let calendarEventID, activities.contains(where: { $0.calendarEventID == calendarEventID && $0.start == start }) { return }
        activities.append(Activity(kind: kind, title: Self.activityTitle(title, kind: kind), start: start, end: end, calendarEventID: calendarEventID))
        record(.activity, field: "Activity added", new: activities.last?.title)
        save()
    }

    public func deleteActivity(_ id: UUID) {
        if let a = activities.first(where: { $0.id == id }) { record(.activity, field: "Activity deleted", old: a.title) }
        activities.removeAll { $0.id == id }
        if activeEntry == nil && activeActivity == nil { tickTask?.cancel(); tickTask = nil }
        save()
    }

    public func hasImported(calendarEventID: String, start: Date) -> Bool {
        activities.contains { $0.calendarEventID == calendarEventID && $0.start == start }
    }

    private static func activityTitle(_ title: String, kind: Activity.Kind) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.title : trimmed
    }

    func checkIdle() {
        let configured = defaults.object(forKey: PrefKey.idleMinutes) as? Int ?? 10
        guard configured > 0, activeEntry != nil else { return }
        let idle = idleSeconds()
        guard idle >= TimeInterval(configured * 60) else { return }
        stop(at: Date().addingTimeInterval(-idle))
        notice = "Timer stopped after \(Int(idle / 60)) min of inactivity. The idle time was not counted."
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { @MainActor [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.activeEntry != nil || self.activeActivity != nil else { return }
                self.now = Date()
                ticks += 1
                if ticks % 30 == 0 { self.checkIdle() }
            }
        }
    }

    // MARK: - GitHub sync

    public var syncIntervalMinutes: Int {
        max(1, defaults.object(forKey: PrefKey.syncMinutes) as? Int ?? 10)
    }

    public func startAutoSync() {
        guard autoSyncTask == nil else { return }
        autoSyncTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.tokenProvider() != nil { await self.syncGitHub() }
                try? await Task.sleep(for: .seconds(self.syncIntervalMinutes * 60))
            }
        }
    }

    public func syncGitHub() async {
        guard syncState != .syncing else { return }
        guard let token = tokenProvider(), !token.isEmpty else {
            syncState = .failed("Add a GitHub token in Settings.")
            return
        }
        syncState = .syncing
        do {
            let includePRs = defaults.bool(forKey: PrefKey.includePRs)
            let client = GitHubClient(token: token, transport: transport)
            let remote = try await client.fetchAssignedIssues(repos: configuredRepos, includePullRequests: includePRs)
            var enriched = await withProjectFields(remote, client: client)
            let issueFields = await client.fetchIssueFields(for: enriched)
            for i in enriched.indices {
                if let fields = issueFields[enriched[i].key] { enriched[i].issueFields = fields }
            }
            tickets = Self.merge(existing: tickets, remote: enriched)
            syncState = .succeeded(Date(), remote.count)
            save()
        } catch {
            syncState = .failed(error.localizedDescription)
        }
        if case .succeeded = syncState { await loadOptions() }
        await refreshPullRequests()
    }

    /// Lowercased "owner/name" entries from Settings; empty means every repo.
    private var configuredRepos: Set<String> {
        Set(
            (defaults.string(forKey: PrefKey.repos) ?? "")
                .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                .map { $0.lowercased() }
        )
    }

    // MARK: - My pull requests

    public var pullRequestSections: [PullRequestSection] { PullRequestSection.make(from: workspacePullRequests) }

    /// Loads my open pull requests; a failure keeps the previous list and never touches the ticket sync state.
    public func refreshPullRequests() async {
        guard pullRequestsState != .loading else { return }
        guard let token = tokenProvider(), !token.isEmpty else {
            pullRequestsState = .failed("Add a GitHub token in Settings.")
            return
        }
        let previous = pullRequestsState
        pullRequestsState = .loading
        do {
            let client = GitHubClient(token: token, transport: transport)
            let login = try await client.currentUser()
            setGitHubLogin(login)
            let result = try await client.fetchOpenPullRequests(authoredBy: login)
            let repos = configuredRepos
            pullRequests = repos.isEmpty ? result.items : result.items.filter { repos.contains($0.repo.lowercased()) }
            pullRequestsState = .loaded(Date(), total: result.total)
        } catch {
            // A cancelled request (for example the tab closing) is not a failure; keep what was shown.
            pullRequestsState = Self.isCancellation(error) ? previous : .failed(Self.pullRequestMessage(for: error))
        }
    }

    public func refreshPullRequestsIfStale(maxAge: TimeInterval = 120) async {
        if case .loaded(let date, _) = pullRequestsState, Date().timeIntervalSince(date) < maxAge { return }
        await refreshPullRequests()
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func pullRequestMessage(for error: Error) -> String {
        let message = error.localizedDescription
        var needsAccess = message.localizedCaseInsensitiveContains("not accessible")
        if case GitHubError.http(let code) = error, code == 403 || code == 404 { needsAccess = true }
        return needsAccess ? "\(message) Needs Pull requests: Read (and Commit statuses / Checks: Read for CI)." : message
    }

    /// Project fields are optional: if they can't be read, tickets keep their previous values.
    private func withProjectFields(_ issues: [RemoteIssue], client: GitHubClient) async -> [RemoteIssue] {
        let ids = issues.map(\.nodeID).filter { !$0.isEmpty }
        guard !ids.isEmpty else { return issues }
        do {
            let fields = try await client.fetchProjectFields(nodeIDs: ids)
            return issues.map { issue in
                var issue = issue
                issue.fields = fields[issue.nodeID] ?? []
                return issue
            }
        } catch {
            notice = "Couldn't read GitHub Projects fields (\(error.localizedDescription)). Sprint, estimate and RCA need a token with read:project access."
            return issues
        }
    }

    /// Loads the issue's GitHub comments; on failure the previously loaded comments stay and `commentsError` is set.
    public func loadComments(_ id: UUID, minimumInterval: TimeInterval = 30) async {
        guard let gh = ticket(id)?.github, let token = tokenProvider(), !token.isEmpty, !commentsLoading.contains(id) else { return }
        if let last = lastCommentsLoad[id], Date().timeIntervalSince(last) < minimumInterval { return }
        lastCommentsLoad[id] = Date()
        commentsLoading.insert(id)
        defer { commentsLoading.remove(id) }
        do {
            issueComments[id] = try await GitHubClient(token: token, transport: transport).fetchComments(repo: gh.repo, number: gh.number)
            commentsError[id] = nil
        } catch {
            commentsError[id] = error.localizedDescription
        }
    }

    /// Refreshes one GitHub ticket in the background; failures are silent and the cached copy is kept.
    public func refreshTicket(_ id: UUID, minimumInterval: TimeInterval = 30) async {
        guard let gh = ticket(id)?.github, let token = tokenProvider(), !token.isEmpty else { return }
        if let last = lastRefresh[id], Date().timeIntervalSince(last) < minimumInterval { return }
        lastRefresh[id] = Date()

        let client = GitHubClient(token: token, transport: transport)
        guard var issue = try? await client.fetchIssue(repo: gh.repo, number: gh.number) else { return }
        if !issue.nodeID.isEmpty, let fields = try? await client.fetchProjectFields(nodeIDs: [issue.nodeID]) {
            issue.fields = fields[issue.nodeID] ?? []
        }
        if let fields = try? await client.fetchIssueFields(repo: gh.repo, number: gh.number) {
            issue.issueFields = fields
        }
        guard let i = tickets.firstIndex(where: { $0.id == id }) else { return }
        var updated = tickets[i]
        Self.copyContent(from: issue, into: &updated)
        if !issue.isOpen, var ref = updated.github, !ref.remoteClosed {
            ref.remoteClosed = true
            updated.github = ref
            updated.status = .done
        }
        guard updated != tickets[i] else { return }
        tickets[i] = updated
        if updated.status == .done && isTracking(id) { stop() }
        save()
    }

    nonisolated private static func copyContent(from issue: RemoteIssue, into ticket: inout Ticket) {
        let keep = Set(ticket.unsynced ?? [])
        let local = ticket
        if !keep.contains("Title") { ticket.title = issue.title }
        if !keep.contains("Description") { ticket.body = issue.body }
        if !keep.contains("Labels") {
            ticket.labels = issue.labels
            ticket.labelColors = issue.labelColors
        }
        if !keep.contains("Milestone") { ticket.milestone = issue.milestone }
        if let fields = issue.fields { ticket.fields = preserving(fields, keeping: keep, from: local.fields) }
        ticket.issueType = issue.issueType
        if let fields = issue.issueFields { ticket.issueFields = preserving(fields, keeping: keep, from: local.issueFields) }
        deriveFromFields(&ticket, keep: keep)
    }

    /// Remote fields, except those named in `names`, which keep their local value.
    nonisolated private static func preserving(_ remote: [CustomField], keeping names: Set<String>, from local: [CustomField]?) -> [CustomField] {
        guard !names.isEmpty, let local else { return remote }
        var result = remote.map { field in
            names.contains(field.name) ? (local.first { $0.name == field.name && $0.project == field.project } ?? field) : field
        }
        for field in local where names.contains(field.name) && !result.contains(where: { $0.name == field.name && $0.project == field.project }) {
            result.append(field)
        }
        return result
    }

    /// Org Priority, org Target date and project Status are the source of truth when present.
    nonisolated private static func deriveFromFields(_ ticket: inout Ticket, keep: Set<String>) {
        if !keep.contains("Priority"), let field = ticket.field(named: "Priority"), field.kind == .select {
            ticket.priority = Priority(optionName: field.value)
        }
        if !keep.contains("Target date"), let field = ticket.field(named: "Target date"), field.kind == .date, let date = field.start {
            ticket.dueDate = date
        }
        if !keep.contains("Status"), let field = ticket.projectStatusField {
            ticket.status = TicketStatus(optionName: field.value)
        }
    }

    /// Upserts remote issues; local fields (status, priority, estimate) are preserved.
    nonisolated public static func merge(existing: [Ticket], remote: [RemoteIssue], now: Date = Date()) -> [Ticket] {
        var result = existing
        var seen = Set<String>()

        for issue in remote {
            seen.insert(issue.key)
            if let i = result.firstIndex(where: { $0.github?.key == issue.key }) {
                copyContent(from: issue, into: &result[i])
                if result[i].github?.remoteClosed == true && result[i].status == .done {
                    result[i].status = .todo
                }
                result[i].github = GitHubRef(repo: issue.repo, number: issue.number, url: issue.url, isPullRequest: issue.isPullRequest)
                result[i].updatedAt = now
            } else {
                var created = Ticket(
                    title: issue.title,
                    body: issue.body,
                    status: .todo,
                    labels: issue.labels,
                    labelColors: issue.labelColors,
                    milestone: issue.milestone,
                    fields: issue.fields,
                    issueType: issue.issueType,
                    issueFields: issue.issueFields,
                    createdAt: now,
                    updatedAt: now,
                    github: GitHubRef(repo: issue.repo, number: issue.number, url: issue.url, isPullRequest: issue.isPullRequest)
                )
                deriveFromFields(&created, keep: [])
                result.append(created)
            }
        }

        for i in result.indices {
            guard var ref = result[i].github, !ref.remoteClosed, !seen.contains(ref.key) else { continue }
            ref.remoteClosed = true
            result[i].github = ref
            result[i].status = .done
            result[i].updatedAt = now
        }
        return result
    }

    // MARK: - Day plan

    public var planSettings: PlanSettings {
        let working = defaults.object(forKey: PrefKey.workingMinutes) as? Int ?? 480
        let focus = defaults.object(forKey: PrefKey.focusPercent) as? Int ?? 75
        let estimate = defaults.object(forKey: PrefKey.defaultEstimateMinutes) as? Int ?? 60
        let workDays = defaults.object(forKey: PrefKey.workDays) as? Int ?? 5
        return PlanSettings(workingMinutes: working, focusFactor: Double(focus) / 100, defaultEstimateMinutes: estimate, workDays: workDays)
    }

    public func plan(for day: Date, calendar: Calendar = .current) -> DayPlan? {
        dayPlans.first { calendar.isDate($0.day, inSameDayAs: day) }
    }

    /// Ranked suggestions for `day`; tickets from the most recent earlier non-empty plan that are still open rank as carried over.
    /// A day off lists only the tickets already planned on it.
    public func planCandidates(for day: Date, calendar: Calendar = .current) -> [PlanCandidate] {
        let start = calendar.startOfDay(for: day)
        let earlier = dayPlans
            .filter { $0.day < start && !($0.ticketIDs.isEmpty && ($0.deferredTicketIDs ?? []).isEmpty) }
            .max { $0.day < $1.day }
        let earlierIDs = (earlier?.ticketIDs ?? []) + (earlier?.deferredTicketIDs ?? [])
        let carried = Set(earlierIDs.filter { ticket($0).map { $0.status != .done } ?? false })
        let tracked = Dictionary(grouping: entries, by: \.ticketID)
            .mapValues { Int(($0.reduce(0) { $0 + $1.duration(at: now) } / 60).rounded()) }
        // A future day is ranked as of its own start so "due now" means due by then.
        let ranked = DayPlanner.rank(
            tickets: workspaceTickets, carriedOver: carried, now: max(now, start), settings: planSettings, calendar: calendar,
            trackedMinutes: tracked, plannedAheadMinutes: plannedAheadMinutes(before: start, tracked: tracked, calendar: calendar)
        )
        let planned = Set(plan(for: day, calendar: calendar)?.ticketIDs ?? [])
        guard planSettings.isWorkingDay(day, calendar: calendar) else { return ranked.filter { planned.contains($0.id) } }
        // Tickets the earlier planned days are expected to finish drop out, unless already planned on this day.
        return ranked.filter { $0.plannedAheadMinutes == 0 || $0.estimateMinutes > 0 || planned.contains($0.id) }
    }

    /// Work that planned working days from today up to `start` are expected to use of each ticket.
    private func plannedAheadMinutes(before start: Date, tracked: [UUID: Int], calendar: Calendar) -> [UUID: Int] {
        let todayStart = calendar.startOfDay(for: now)
        guard start > todayStart else { return [:] }
        let settings = planSettings
        var remaining: [UUID: Int] = [:]
        for ticket in tickets where ticket.status != .done {
            remaining[ticket.id] = DayPlanner.remainingMinutes(of: ticket, tracked: tracked[ticket.id] ?? 0, settings: settings)
        }
        let todayRange = dayRange(for: todayStart, calendar: calendar)
        let trackedToday = Int((entries.reduce(0) { $0 + $1.duration(in: todayRange, at: now) } / 60).rounded())
        let plans = dayPlans
            .filter { $0.day >= todayStart && $0.day < start && settings.isWorkingDay($0.day, calendar: calendar) }
            .sorted { $0.day < $1.day }
            .map { plan -> (capacityMinutes: Int, ticketIDs: [UUID]) in
                // Meetings on future days are unknown here; only logged activities reduce the capacity.
                let capacity = capacity(for: plan.day, calendarBusy: [], calendar: calendar).capacityMinutes
                let isToday = calendar.isDate(plan.day, inSameDayAs: todayStart)
                return (isToday ? max(0, capacity - trackedToday) : capacity, plan.ticketIDs)
            }
        return DayPlanner.plannedAhead(plans: plans, remaining: remaining)
    }

    public func capacity(for day: Date, calendarBusy: [DateInterval], calendar: Calendar = .current) -> Capacity {
        let logged = activities.compactMap { activity -> DateInterval? in
            let end = activity.end ?? now
            return end > activity.start ? DateInterval(start: activity.start, end: end) : nil
        }
        return DayPlanner.capacity(day: dayRange(for: day, calendar: calendar), busy: calendarBusy + logged, settings: planSettings, calendar: calendar)
    }

    /// Returns the day's plan, creating it from the suggestions the first time there are any.
    @discardableResult
    public func ensurePlan(for day: Date, calendarBusy: [DateInterval], calendar: Calendar = .current) -> DayPlan? {
        plan(for: day, calendar: calendar) ?? suggestPlan(for: day, calendarBusy: calendarBusy, calendar: calendar)
    }

    /// Builds the plan from the ranked suggestions, replacing any existing plan for the day; preserves existing defers.
    @discardableResult
    public func suggestPlan(for day: Date, calendarBusy: [DateInterval], calendar: Calendar = .current) -> DayPlan? {
        let candidates = planCandidates(for: day, calendar: calendar)
        guard !candidates.isEmpty else { return nil }
        let deferredTicketIDs = plan(for: day, calendar: calendar)?.deferredTicketIDs
        let inWorkspace = Set(workspaceTickets.map(\.id))
        let hiddenPlanned = (plan(for: day, calendar: calendar)?.ticketIDs ?? []).filter { !inWorkspace.contains($0) }
        let deferredSet = Set(deferredTicketIDs ?? [])
        let pickable = candidates.filter {
            !deferredSet.contains($0.id) && $0.ticket.isQuickCapture != true
                && !($0.plannedAheadMinutes > 0 && $0.estimateMinutes == 0)
        }
        let capacity = capacity(for: day, calendarBusy: calendarBusy, calendar: calendar)
        var plan = DayPlan(
            day: calendar.startOfDay(for: day),
            ticketIDs: (planSettings.isWorkingDay(day, calendar: calendar)
                ? DayPlanner.autoPick(pickable, capacityMinutes: capacity.capacityMinutes) : []) + hiddenPlanned,
            createdAt: Date()
        )
        plan.deferredTicketIDs = deferredTicketIDs
        dayPlans.removeAll { calendar.isDate($0.day, inSameDayAs: day) }
        dayPlans.append(plan)
        save()
        return plan
    }

    public func togglePlanned(_ ticketID: UUID, on day: Date, calendar: Calendar = .current) {
        if let index = dayPlans.firstIndex(where: { calendar.isDate($0.day, inSameDayAs: day) }) {
            if let position = dayPlans[index].ticketIDs.firstIndex(of: ticketID) {
                dayPlans[index].ticketIDs.remove(at: position)
                record(.dayPlan, ticket: ticket(ticketID), field: "Removed from day plan")
            } else {
                dayPlans[index].ticketIDs.append(ticketID)
                dayPlans[index].deferredTicketIDs?.removeAll { $0 == ticketID }
                record(.dayPlan, ticket: ticket(ticketID), field: "Added to day plan")
            }
        } else {
            dayPlans.append(DayPlan(day: calendar.startOfDay(for: day), ticketIDs: [ticketID]))
            record(.dayPlan, ticket: ticket(ticketID), field: "Added to day plan")
        }
        save()
    }

    // MARK: - Live day

    /// Creates a local ticket for unplanned work and starts its timer; it is not added to the plan.
    @discardableResult
    public func addQuickCapture(kind: QuickCaptureKind, title: String) -> Ticket? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let ticket = Ticket(title: trimmed, labels: [kind.title], isQuickCapture: true)
        tickets.append(ticket)
        record(.ticketCreate, ticket: ticket, new: trimmed)
        start(ticket.id)
        return self.ticket(ticket.id)
    }

    public func dayLoad(for day: Date, calendarBusy: [DateInterval], calendar: Calendar = .current) -> DayLoad {
        DayPlanner.load(
            plannedIDs: Set(plan(for: day, calendar: calendar)?.ticketIDs ?? []),
            tickets: workspaceTickets, entries: workspaceEntries, activities: workspaceActivities,
            capacityMinutes: capacity(for: day, calendarBusy: calendarBusy, calendar: calendar).capacityMinutes,
            day: dayRange(for: day, calendar: calendar), now: now, settings: planSettings
        )
    }

    /// Planned tickets that could be moved to tomorrow to cover today's overload.
    public func deferCandidates(for day: Date, calendarBusy: [DateInterval], calendar: Calendar = .current) -> [UUID] {
        let started = Set(entries.map(\.ticketID)).union(tickets.filter { $0.status == .inProgress }.map(\.id))
        return DayPlanner.deferCandidates(
            planCandidates(for: day, calendar: calendar),
            plannedIDs: Set(plan(for: day, calendar: calendar)?.ticketIDs ?? []),
            startedIDs: started,
            overloadMinutes: dayLoad(for: day, calendarBusy: calendarBusy, calendar: calendar).overloadMinutes
        )
    }

    /// Removes the ticket from the day's plan and records it so it ranks as carried over on the next day.
    public func deferToTomorrow(_ ticketID: UUID, from day: Date, calendar: Calendar = .current) {
        guard let i = dayPlans.firstIndex(where: { calendar.isDate($0.day, inSameDayAs: day) }) else { return }
        dayPlans[i].ticketIDs.removeAll { $0 == ticketID }
        var deferred = dayPlans[i].deferredTicketIDs ?? []
        if !deferred.contains(ticketID) { deferred.append(ticketID) }
        dayPlans[i].deferredTicketIDs = deferred
        let next = planSettings.nextWorkingDay(after: day, calendar: calendar)
        if let j = dayPlans.firstIndex(where: { calendar.isDate($0.day, inSameDayAs: next) }), !dayPlans[j].ticketIDs.contains(ticketID) {
            dayPlans[j].ticketIDs.append(ticketID)
        }
        record(.dayPlan, ticket: ticket(ticketID), field: "Deferred to tomorrow")
        save()
    }

    /// GitHub tickets first synced after the day's plan was created and not yet planned, deferred or ignored.
    public func newSincePlanning(for day: Date, calendar: Calendar = .current) -> [PlanCandidate] {
        guard let plan = plan(for: day, calendar: calendar), let created = plan.createdAt else { return [] }
        let hidden = Set(plan.ticketIDs).union(plan.deferredTicketIDs ?? []).union(plan.ignoredNewTicketIDs ?? [])
        return planCandidates(for: day, calendar: calendar).filter {
            $0.ticket.github != nil && $0.ticket.createdAt > created && !hidden.contains($0.id)
        }
    }

    public func ignoreNew(_ ticketID: UUID, on day: Date, calendar: Calendar = .current) {
        guard let i = dayPlans.firstIndex(where: { calendar.isDate($0.day, inSameDayAs: day) }) else { return }
        var ignored = dayPlans[i].ignoredNewTicketIDs ?? []
        if !ignored.contains(ticketID) { ignored.append(ticketID) }
        dayPlans[i].ignoredNewTicketIDs = ignored
        save()
    }

    func insertTicketForTest(_ ticket: Ticket) { tickets.append(ticket) }

    func storeOptions(_ options: RemoteOptions) {
        remoteOptions = options
        lastOptionsLoad = Date()
        save()
    }

    var optionsAreFresh: Bool { lastOptionsLoad.map { Date().timeIntervalSince($0) < 600 } ?? false }

    /// Applies `apply` locally, logs it, then pushes `remote` to GitHub when the ticket is linked and a token is set.
    func edit(_ id: UUID, _ change: FieldChange, remote: RemoteEdit?, delay: Duration = .zero, apply: (inout Ticket) -> Void) {
        guard let i = tickets.firstIndex(where: { $0.id == id }) else { return }
        apply(&tickets[i])
        tickets[i].updatedAt = Date()
        let ticket = tickets[i]
        let canPush = remote != nil && ticket.github != nil && !(tokenProvider() ?? "").isEmpty
        let key = remote.map { "\(id)|\($0.slot)" }
        if remote != nil { supersedeFailed(ticketID: id, field: change.field) }

        // Debounced edits of the same slot share one pending entry so typing doesn't flood the log.
        if canPush, let key, let existing = pendingEntryIDs[key], let n = actionLog.firstIndex(where: { $0.id == existing }), actionLog[n].sync == .pending {
            actionLog[n].newValue = change.new
            actionLog[n].newList = change.newList
            actionLog[n].remote = remote
            actionLog[n].timestamp = Date()
        } else {
            let entryID = record(
                .ticketEdit, ticket: ticket, field: change.field, old: change.old, new: change.new,
                oldList: change.oldList, newList: change.newList, sync: canPush ? .pending : .notApplicable, remote: remote
            )
            if canPush, let key { pendingEntryIDs[key] = entryID }
        }
        // Flag the field while the push is in flight so a sync can't overwrite it; cleared on success.
        if canPush { setUnsynced(id, field: change.field, to: true) }
        save()

        guard canPush, let key, let remote, let gh = ticket.github, let token = tokenProvider() else { return }
        pendingPushes[key]?.cancel()
        pendingPushes[key] = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self, let entryID = pendingEntryIDs[key] else { return }
            await push(entryID, ticketID: id, field: change.field, edit: remote, repo: gh.repo, number: gh.number, token: token)
            if !Task.isCancelled {
                pendingPushes[key] = nil
                pendingEntryIDs[key] = nil
            }
        }
    }

    private func push(_ entryID: UUID, ticketID: UUID, field: String, edit: RemoteEdit, repo: String, number: Int, token: String) async {
        let client = GitHubClient(token: token, transport: transport)
        do {
            try await client.apply(edit, repo: repo, number: number)
            setActionSync(entryID, .synced(Date()), detail: Self.describe(edit, repo: repo, number: number))
            setUnsynced(ticketID, field: field, to: false)
        } catch {
            if Task.isCancelled { return }
            setActionSync(entryID, .failed(error.localizedDescription), detail: "\(Self.describe(edit, repo: repo, number: number)) failed")
            setUnsynced(ticketID, field: field, to: true)
        }
    }

    private func setUnsynced(_ id: UUID, field: String, to flagged: Bool) {
        guard let i = tickets.firstIndex(where: { $0.id == id }) else { return }
        var names = tickets[i].unsynced ?? []
        names.removeAll { $0 == field }
        if flagged { names.append(field) }
        tickets[i].unsynced = names.isEmpty ? nil : names
        save()
    }

    private func supersedeFailed(ticketID: UUID, field: String) {
        for n in actionLog.indices where actionLog[n].ticketID == ticketID && actionLog[n].field == field {
            if case .failed = actionLog[n].sync {
                actionLog[n].sync = .notApplicable
                actionLog[n].githubDetail = "Superseded by a later edit"
            }
        }
    }

    private static func describe(_ edit: RemoteEdit, repo: String, number: Int) -> String {
        let target = "\(repo)#\(number)"
        switch edit {
        case .labels: return "Set labels on \(target)"
        case .milestone: return "Set milestone on \(target)"
        case .title: return "Set title on \(target)"
        case .body: return "Set description on \(target)"
        case .state(let open): return "\(open ? "Reopened" : "Closed") \(target)"
        case .issueField(let name, _): return "Set issue field \(name) on \(target)"
        case .projectField(let project, let field, _): return "Set \(field) in project \(project) on \(target)"
        }
    }

    /// Re-sends a failed entry's edit. Returns true when it now succeeded.
    @discardableResult
    public func retry(_ entryID: UUID) async -> Bool {
        dismissedFailureIDs.remove(entryID)
        guard let n = actionLog.firstIndex(where: { $0.id == entryID }), case .failed = actionLog[n].sync,
              let edit = actionLog[n].remote, let ticketID = actionLog[n].ticketID, let field = actionLog[n].field,
              let gh = ticket(ticketID)?.github, let token = tokenProvider(), !token.isEmpty else { return false }
        setActionSync(entryID, .pending)
        await push(entryID, ticketID: ticketID, field: field, edit: edit, repo: gh.repo, number: gh.number, token: token)
        return !failedActions.contains { $0.id == entryID }
    }

    /// Retries every failed entry, oldest first.
    public func resyncFailed() async {
        for entry in failedActions { await retry(entry.id) }
    }

    func settlePushes() async {
        for task in Array(pendingPushes.values) { await task.value }
    }

    // MARK: - Action log

    private static func minutesText(_ seconds: TimeInterval) -> String { "\(Int((seconds / 60).rounded())) min" }

    @discardableResult
    func record(
        _ kind: ActionKind, ticket: Ticket? = nil, field: String? = nil, old: String? = nil, new: String? = nil,
        oldList: [String]? = nil, newList: [String]? = nil, sync: ActionSync = .notApplicable,
        detail: String? = nil, remote: RemoteEdit? = nil, at date: Date = Date()
    ) -> UUID {
        let entry = ActionLogEntry(
            timestamp: date, kind: kind, ticketID: ticket?.id, ticketKey: ticket?.displayKey, ticketTitle: ticket?.title,
            field: field, oldValue: old, newValue: new, oldList: oldList, newList: newList, sync: sync, githubDetail: detail, remote: remote
        )
        actionLog.append(entry)
        return entry.id
    }

    public func setActionSync(_ id: UUID, _ sync: ActionSync, detail: String? = nil) {
        guard let i = actionLog.firstIndex(where: { $0.id == id }) else { return }
        actionLog[i].sync = sync
        if let detail { actionLog[i].githubDetail = detail }
        save()
    }

    public var failedActions: [ActionLogEntry] {
        actionLog.filter { if case .failed = $0.sync { true } else { false } }
    }

    public func dismissFailureBanner() {
        dismissedFailureIDs.formUnion(failedActions.map(\.id))
    }

    @discardableResult
    public func deleteActionLog(olderThan cutoff: Date) -> Int {
        let before = actionLog.count
        actionLog.removeAll { $0.timestamp < cutoff }
        save()
        return before - actionLog.count
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var tickets: [Ticket]
        var entries: [TimeEntry]
        var notes: [TicketNote]?
        var planComments: [PlanComment]?
        var activities: [Activity]?
        var dayPlans: [DayPlan]?
        var actionLog: [ActionLogEntry]?
        var remoteOptions: RemoteOptions?
    }

    /// Older files stored one free-text `notes` string per ticket.
    private struct LegacySnapshot: Decodable {
        struct LegacyTicket: Decodable {
            var id: UUID
            var notes: String?
            var updatedAt: Date
        }
        var tickets: [LegacyTicket]
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            tickets = snapshot.tickets
            entries = snapshot.entries
            activities = snapshot.activities ?? []
            planComments = snapshot.planComments ?? []
            dayPlans = snapshot.dayPlans ?? []
            actionLog = snapshot.actionLog ?? []
            remoteOptions = snapshot.remoteOptions ?? RemoteOptions()
            if let saved = snapshot.notes {
                notes = saved
            } else if let legacy = try? decoder.decode(LegacySnapshot.self, from: data) {
                notes = legacy.tickets.compactMap { t in
                    let text = (t.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : TicketNote(ticketID: t.id, text: text, createdAt: t.updatedAt)
                }
            }
        } catch {
            notice = "Could not read saved data: \(error.localizedDescription)"
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(Snapshot(tickets: tickets, entries: entries, notes: notes, planComments: planComments, activities: activities, dayPlans: dayPlans, actionLog: actionLog, remoteOptions: remoteOptions))
            try data.write(to: storeURL, options: .atomic)
        } catch {
            notice = "Could not save data: \(error.localizedDescription)"
        }
    }
}
