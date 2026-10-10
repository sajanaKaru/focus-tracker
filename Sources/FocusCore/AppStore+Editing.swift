import Foundation

extension AppStore {
    private func listText(_ items: [String]) -> String { items.isEmpty ? "None" : items.joined(separator: ", ") }

    private func upsert(_ fields: inout [CustomField], _ field: CustomField?, named name: String) {
        let index = fields.firstIndex { $0.name == name }
        switch (index, field) {
        case (let i?, let f?): fields[i] = f
        case (let i?, nil): fields.remove(at: i)
        case (nil, let f?): fields.append(f)
        case (nil, nil): break
        }
    }

    // MARK: Text and labels

    public func setTitle(_ id: UUID, _ title: String) {
        let new = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let t = ticket(id), !new.isEmpty, new != t.title else { return }
        edit(id, FieldChange(field: "Title", old: t.title, new: new), remote: .title(new), delay: .milliseconds(600)) { $0.title = new }
    }

    public func setBody(_ id: UUID, _ body: String) {
        guard let t = ticket(id), body != t.body else { return }
        edit(id, FieldChange(field: "Description", old: t.body, new: body), remote: .body(body), delay: .milliseconds(600)) { $0.body = body }
    }

    public func setLabels(_ id: UUID, _ labels: [String]) {
        guard let t = ticket(id), labels != t.labels else { return }
        let known = Dictionary(labelOptions(for: t).map { ($0.name, $0.color) }, uniquingKeysWith: { first, _ in first })
        let change = FieldChange(field: "Labels", old: listText(t.labels), new: listText(labels), oldList: t.labels, newList: labels)
        edit(id, change, remote: .labels(labels), delay: .milliseconds(800)) { ticket in
            ticket.labels = labels
            var colors = ticket.labelColors ?? [:]
            for label in labels where colors[label] == nil {
                if let color = known[label], !color.isEmpty { colors[label] = color }
            }
            ticket.labelColors = colors
        }
    }

    public func setMilestone(_ id: UUID, _ option: MilestoneOption?) {
        guard let t = ticket(id), option?.title != t.milestone?.title else { return }
        let change = FieldChange(field: "Milestone", old: t.milestone?.title ?? "None", new: option?.title ?? "None")
        edit(id, change, remote: .milestone(number: option?.number)) { ticket in
            ticket.milestone = option.map { Milestone(title: $0.title, isOpen: $0.isOpen, dueOn: $0.dueOn) }
        }
    }

    // MARK: Status, priority, target date

    public func setStatusOption(_ id: UUID, project: String, option: String) {
        guard let t = ticket(id) else { return }
        let status = TicketStatus(optionName: option)
        let color = remoteOptions.projectStatus[project]?.first { $0.name == option }?.color
        let change = FieldChange(field: "Status", old: t.projectStatusField?.value ?? t.status.title, new: option)
        edit(id, change, remote: .projectField(project: project, field: "Status", value: .option(option))) { ticket in
            var fields = ticket.fields ?? []
            upsert(&fields, CustomField(name: "Status", value: option, kind: .select, project: project, color: color), named: "Status")
            ticket.fields = fields
            ticket.status = status
        }
        syncIssueState(id, from: t.status, to: status)
    }

    /// Closes the issue when a ticket becomes Done and reopens it when it leaves Done; pull requests are untouched.
    func syncIssueState(_ id: UUID, from old: TicketStatus, to new: TicketStatus) {
        guard let gh = ticket(id)?.github, !gh.isPullRequest, (old == .done) != (new == .done) else { return }
        let open = new != .done
        let change = FieldChange(field: "Issue state", old: open ? "Closed" : "Open", new: open ? "Open" : "Closed")
        edit(id, change, remote: .state(open: open)) { $0.github?.remoteClosed = !open }
    }

    public func setPriorityOption(_ id: UUID, option: String?) {
        guard let t = ticket(id) else { return }
        let color = priorityOptions(for: t).first { $0.name == option }?.color
        let change = FieldChange(field: "Priority", old: t.field(named: "Priority")?.value ?? t.priority.title, new: option ?? "None")
        edit(id, change, remote: .issueField(name: "Priority", value: option.map { .string($0) })) { ticket in
            var fields = ticket.issueFields ?? []
            upsert(&fields, option.map { CustomField(name: "Priority", value: $0, kind: .select, project: CustomField.issueFieldsGroup, color: color) }, named: "Priority")
            ticket.issueFields = fields
            ticket.priority = option.map { Priority(optionName: $0) } ?? .none
        }
    }

    /// Linked tickets with an org Priority field use its matching option; everything else keeps a local priority.
    public func setPriority(_ id: UUID, _ priority: Priority) {
        guard let t = ticket(id) else { return }
        let options = priorityOptions(for: t)
        if t.github != nil, !options.isEmpty {
            setPriorityOption(id, option: priority == .none ? nil : options.first { Priority(optionName: $0.name) == priority }?.name)
        } else {
            update(id) { $0.priority = priority }
        }
    }

    public func setTargetDate(_ id: UUID, _ date: Date?) {
        guard let t = ticket(id) else { return }
        guard t.github != nil else {
            update(id) { $0.dueDate = date }
            return
        }
        let change = FieldChange(field: "Target date", old: t.field(named: "Target date")?.value ?? t.dueDate?.isoDay ?? "None", new: date?.isoDay ?? "None")
        edit(id, change, remote: .issueField(name: "Target date", value: date.map { .string($0.isoDay) })) { ticket in
            var fields = ticket.issueFields ?? []
            upsert(&fields, date.map { CustomField(name: "Target date", value: $0.isoDay, kind: .date, project: CustomField.issueFieldsGroup, start: $0) }, named: "Target date")
            ticket.issueFields = fields
            ticket.dueDate = date
        }
    }

    // MARK: Option accessors

    private func owner(of ticket: Ticket) -> String {
        ticket.github?.repo.split(separator: "/").first.map { String($0).lowercased() } ?? ""
    }

    public func labelOptions(for ticket: Ticket) -> [LabelOption] {
        remoteOptions.labels[ticket.github?.repo.lowercased() ?? ""] ?? []
    }

    public func milestoneOptions(for ticket: Ticket) -> [MilestoneOption] {
        remoteOptions.milestones[ticket.github?.repo.lowercased() ?? ""] ?? []
    }

    public func priorityOptions(for ticket: Ticket) -> [FieldOption] {
        remoteOptions.issueFields[owner(of: ticket)]?.first { $0.name.caseInsensitiveCompare("Priority") == .orderedSame }?.options ?? []
    }

    public func statusOptions(for ticket: Ticket) -> [FieldOption] {
        ticket.projectStatusField.flatMap { remoteOptions.projectStatus[$0.project] } ?? []
    }

    /// Refreshes the cached pickers data for every linked repo; failed requests keep the previous cache.
    public func loadOptions(force: Bool = false) async {
        guard let token = tokenProvider(), !token.isEmpty, force || !optionsAreFresh else { return }
        let client = GitHubClient(token: token, transport: transport)
        var options = remoteOptions
        var repos: [String: String] = [:]
        for gh in tickets.compactMap(\.github) { repos[gh.repo.lowercased()] = gh.repo }

        var owners = Set<String>()
        for (key, repo) in repos {
            if let labels = try? await client.fetchLabels(repo: repo) { options.labels[key] = labels }
            if let milestones = try? await client.fetchMilestones(repo: repo) { options.milestones[key] = milestones }
            if let owner = repo.split(separator: "/").first { owners.insert(String(owner)) }
        }
        for owner in owners {
            if let defs = try? await client.fetchOrgIssueFields(org: owner) { options.issueFields[owner.lowercased()] = defs }
        }

        var seenProjects = Set<String>()
        for ticket in tickets {
            guard let gh = ticket.github, let field = ticket.projectStatusField, seenProjects.insert(field.project).inserted else { continue }
            if let found = try? await client.fetchProjectOptions(repo: gh.repo, number: gh.number, field: "Status") {
                for (project, statuses) in found { options.projectStatus[project] = statuses }
            }
        }
        storeOptions(options)
    }
}
