# GitHub Write-back and Options Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Edit labels, milestone, status, priority, target date, title and body from the app, push each edit to GitHub, keep failed edits locally with Retry/Resync, and cache org/repo options for pickers.

**Architecture:** `RemoteEdit` (Codable) describes one GitHub change and is stored on the log entry so it can be retried. `GitHubClient.apply(_:repo:number:)` performs it. `AppStore.edit(...)` applies the change locally, logs a `pending` entry, pushes, then marks it `synced`/`failed`; failures add the field to `Ticket.unsynced`, which `copyContent` respects so sync never overwrites it. Org Priority and Target date, and the project Status, are the source of truth when present: sync derives `Ticket.priority`, `dueDate`, `status` from them. Typed setters live in `AppStore+Editing.swift`; options are cached in `AppStore.remoteOptions`. This is plan 2 of 3 (no UI).

**Tech Stack:** Swift 5.9, XCTest (`swift test`), GitHub REST (API version `2026-03-10` for issue fields) and GraphQL.

**Spec:** `docs/superpowers/specs/2026-10-10-ticket-editing-action-log-design.md`
**Builds on:** `docs/superpowers/plans/2026-10-10-action-log-core.md` (done: `record`, `setActionSync`, `failedActions`, `ActionLogEntry`, `Ticket.changes(to:)`).

## Global Constraints

- GitHub issue-field values: `PUT /repos/{o}/{r}/issues/{n}/issue-field-values` with `{"issue_field_values":[{"field_id":Int,"value":String|Number}]}` REPLACES all values, so setting one field must re-send the others. Clearing one uses `DELETE .../issue-field-values/{field_id}`. Header `X-GitHub-Api-Version: 2026-03-10`. Date values are `yyyy-MM-dd`.
- Org field definitions: `GET /orgs/{org}/issue-fields` (`id`, `name`, `data_type`, `options[{id,name,color}]`).
- Labels: `PUT /repos/{r}/issues/{n}/labels` body `{"labels":[...]}`. Milestone/title/body/state: `PATCH /repos/{r}/issues/{n}` (`milestone` is the milestone number or `null`; closing sends `state_reason: "completed"`).
- Project Status is a Projects v2 single-select: mutation value is `{"singleSelectOptionId": id}`, id found through the existing field lookup query.
- A failed push keeps the local value, marks the entry `failed`, adds the log field name to `Ticket.unsynced`, and never reverts. Pull requests are never closed or reopened by status changes.
- Old `data.json` must still load: every new stored property is optional.
- Sync-driven changes are not logged. Tests use `@testable import FocusCore`, `@MainActor` classes, temp store files, throwaway `UserDefaults` suites. Run all tests with `swift test`.
- Shell: `rm` is aliased; use `command rm`.
- Spec deviation: legacy local priority is kept as a fallback until an org Priority field exists (no destructive migration).

---

## File Structure

- Create `Sources/FocusCore/RemoteEdit.swift`: `IssueFieldValue`, `RemoteEdit`, name→enum mappings, `Ticket` helpers.
- Create `Sources/FocusCore/RemoteOptions.swift`: option value types and the cache container.
- Create `Sources/FocusCore/GitHubEdits.swift`: client reads for options, writes, `apply`.
- Create `Sources/FocusCore/AppStore+Editing.swift`: typed setters, option accessors, `loadOptions`.
- Modify `Sources/FocusCore/GitHubClient.swift`: relax `private`, `ProjectFieldValue`, project lookup refactor.
- Modify `Sources/FocusCore/Models.swift`: `Ticket.unsynced`.
- Modify `Sources/FocusCore/ActionLog.swift`: `ActionLogEntry.remote`.
- Modify `Sources/FocusCore/AppStore.swift`: `edit`, `push`, retry/resync, `copyContent`, `setProjectField`, `setStatus`, `start`, snapshot.
- Create tests: `TestSupport.swift`, `RemoteEditTests.swift`, `GitHubEditsTests.swift`, `EditPipelineTests.swift`, `TicketEditingTests.swift`.

---

### Task 1: Edit model, mappings, options types

**Files:**
- Create: `Sources/FocusCore/RemoteEdit.swift`, `Sources/FocusCore/RemoteOptions.swift`, `Tests/FocusCoreTests/TestSupport.swift`, `Tests/FocusCoreTests/RemoteEditTests.swift`
- Modify: `Sources/FocusCore/GitHubClient.swift` (`ProjectFieldValue`), `Sources/FocusCore/AppStore.swift` (`setProjectField` switch), `Sources/FocusCore/Models.swift` (`Ticket`), `Sources/FocusCore/ActionLog.swift` (`ActionLogEntry`, `record`)

**Interfaces:**
- Produces:
  - `enum IssueFieldValue: Codable, Equatable, Sendable { case string(String), number(Double) }`
  - `enum RemoteEdit: Codable, Equatable, Sendable { labels([String]), milestone(number: Int?), title(String), body(String), state(open: Bool), issueField(name: String, value: IssueFieldValue?), projectField(project: String, field: String, value: ProjectFieldValue) }` with `var slot: String`
  - `ProjectFieldValue` becomes `Codable` and gains `.option(String)`
  - `Priority.init(optionName:)`, `TicketStatus.init(optionName:)`
  - `Ticket.unsynced: [String]?`, `Ticket.projectStatusField: CustomField?`
  - `ActionLogEntry.remote: RemoteEdit?`; `AppStore.record(..., remote: RemoteEdit? = nil)`
  - `LabelOption(name,color)`, `MilestoneOption(number,title,isOpen,dueOn)`, `FieldOption(name,color?)`, `IssueFieldDefinition(id,name,dataType,options)`, `RemoteOptions`
  - Test helper `RecordingTransport` (see below)

- [ ] **Step 1: Write the test support and failing tests**

Create `Tests/FocusCoreTests/TestSupport.swift`:

```swift
import Foundation
@testable import FocusCore

final class RecordingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let handler: @Sendable (URLRequest) -> (Int, String)

    init(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) { self.handler = handler }

    private func record(_ request: URLRequest) {
        lock.lock()
        recorded.append(request)
        lock.unlock()
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        record(request)
        let (code, body) = handler(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: [:])!)
    }

    func json(_ index: Int) -> [String: Any]? {
        requests[index].httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

final class Switch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    var isOn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
```

Create `Tests/FocusCoreTests/RemoteEditTests.swift`:

```swift
import XCTest
@testable import FocusCore

final class RemoteEditTests: XCTestCase {
    func testPriorityMapping() {
        XCTAssertEqual(Priority(optionName: "Critical"), .urgent)
        XCTAssertEqual(Priority(optionName: "P1 - High"), .high)
        XCTAssertEqual(Priority(optionName: "Medium"), .medium)
        XCTAssertEqual(Priority(optionName: "Low"), .low)
        XCTAssertEqual(Priority(optionName: "Whenever"), .none)
    }

    func testStatusMapping() {
        XCTAssertEqual(TicketStatus(optionName: "Done"), .done)
        XCTAssertEqual(TicketStatus(optionName: "In Review"), .inReview)
        XCTAssertEqual(TicketStatus(optionName: "In progress"), .inProgress)
        XCTAssertEqual(TicketStatus(optionName: "Not started"), .todo)
        XCTAssertEqual(TicketStatus(optionName: "Backlog"), .backlog)
        XCTAssertEqual(TicketStatus(optionName: "Something else"), .todo)
    }

    func testRemoteEditSlotsAndCodable() throws {
        let edits: [RemoteEdit] = [
            .labels(["a"]), .milestone(number: nil), .title("t"), .body("b"), .state(open: false),
            .issueField(name: "Priority", value: .string("High")), .issueField(name: "Effort", value: nil),
            .projectField(project: "P", field: "Status", value: .option("Done"))
        ]
        for edit in edits {
            let data = try JSONEncoder().encode(edit)
            XCTAssertEqual(try JSONDecoder().decode(RemoteEdit.self, from: data), edit)
        }
        XCTAssertEqual(RemoteEdit.issueField(name: "Priority", value: nil).slot, "issueField:Priority")
        XCTAssertEqual(RemoteEdit.projectField(project: "P", field: "RCA", value: .text("x")).slot, "project:P:RCA")
    }

    func testTicketWithoutUnsyncedDecodes() throws {
        let json = #"{"id":"\#(UUID().uuidString)","title":"t","body":"","status":"todo","priority":0,"labels":[],"createdAt":"2026-10-09T08:00:00Z","updatedAt":"2026-10-09T08:00:00Z"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let ticket = try decoder.decode(Ticket.self, from: Data(json.utf8))
        XCTAssertNil(ticket.unsynced)
        XCTAssertNil(ticket.projectStatusField)
    }

    func testLogEntryKeepsRemoteEdit() throws {
        let entry = ActionLogEntry(kind: .ticketEdit, sync: .failed("x"), remote: .labels(["a"]))
        let data = try JSONEncoder().encode(entry)
        XCTAssertEqual(try JSONDecoder().decode(ActionLogEntry.self, from: data).remote, .labels(["a"]))
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter RemoteEditTests`
Expected: FAIL to compile (`Priority(optionName:)`, `RemoteEdit` missing).

- [ ] **Step 3: Implement**

`Sources/FocusCore/RemoteEdit.swift`:

```swift
import Foundation

public enum IssueFieldValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
}

/// One change to push to GitHub; stored on the log entry so a failed push can be retried.
public enum RemoteEdit: Codable, Equatable, Sendable {
    case labels([String])
    case milestone(number: Int?)
    case title(String)
    case body(String)
    case state(open: Bool)
    case issueField(name: String, value: IssueFieldValue?)
    case projectField(project: String, field: String, value: ProjectFieldValue)

    /// What the edit overwrites; repeated edits of the same slot are coalesced.
    public var slot: String {
        switch self {
        case .labels: "labels"
        case .milestone: "milestone"
        case .title: "title"
        case .body: "body"
        case .state: "state"
        case .issueField(let name, _): "issueField:\(name)"
        case .projectField(let project, let field, _): "project:\(project):\(field)"
        }
    }
}

extension Priority {
    /// Maps an org Priority option name ("P1 - High", "Critical") to the app's levels.
    public init(optionName: String) {
        let n = optionName.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { n.contains($0) } }
        if has(["urgent", "critical", "blocker", "p0"]) { self = .urgent }
        else if has(["high", "p1"]) { self = .high }
        else if has(["medium", "normal", "p2"]) { self = .medium }
        else if has(["low", "minor", "p3"]) { self = .low }
        else { self = .none }
    }
}

extension TicketStatus {
    /// Maps a project Status option name to the app's statuses.
    public init(optionName: String) {
        let n = optionName.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { n.contains($0) } }
        if has(["done", "complete", "closed", "shipped", "released", "merged"]) { self = .done }
        else if has(["review", "qa", "testing"]) { self = .inReview }
        else if has(["not started", "to do", "todo"]) { self = .todo }
        else if has(["progress", "doing", "started", "develop"]) { self = .inProgress }
        else if has(["backlog", "icebox", "triage"]) { self = .backlog }
        else { self = .todo }
    }
}

extension Ticket {
    /// The Projects (v2) single-select named "Status".
    public var projectStatusField: CustomField? {
        (fields ?? []).first { $0.name == "Status" && $0.kind == .select }
    }
}

extension Date {
    /// `yyyy-MM-dd` in the local calendar, the format GitHub date fields use.
    var isoDay: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: self)
    }
}
```

`Sources/FocusCore/RemoteOptions.swift`:

```swift
import Foundation

public struct LabelOption: Codable, Hashable, Sendable {
    public var name: String
    public var color: String
    public init(name: String, color: String) { self.name = name; self.color = color }
}

public struct MilestoneOption: Codable, Hashable, Sendable {
    public var number: Int
    public var title: String
    public var isOpen: Bool
    public var dueOn: Date?
    public init(number: Int, title: String, isOpen: Bool = true, dueOn: Date? = nil) {
        self.number = number; self.title = title; self.isOpen = isOpen; self.dueOn = dueOn
    }
}

public struct FieldOption: Codable, Hashable, Sendable {
    public var name: String
    public var color: String?
    public init(name: String, color: String? = nil) { self.name = name; self.color = color }
}

public struct IssueFieldDefinition: Codable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var dataType: String
    public var options: [FieldOption]
    public init(id: Int, name: String, dataType: String, options: [FieldOption] = []) {
        self.id = id; self.name = name; self.dataType = dataType; self.options = options
    }
}

/// Cached pickers data. Keys: repo and org are lowercased; project is the project title.
public struct RemoteOptions: Codable, Equatable, Sendable {
    public var labels: [String: [LabelOption]] = [:]
    public var milestones: [String: [MilestoneOption]] = [:]
    public var issueFields: [String: [IssueFieldDefinition]] = [:]
    public var projectStatus: [String: [FieldOption]] = [:]
    public init() {}
}
```

`GitHubClient.swift`: change `ProjectFieldValue` to

```swift
public enum ProjectFieldValue: Codable, Equatable, Sendable {
    case text(String)
    case number(Double)
    case option(String)
}
```

In `updateProjectField` add a temporary `case .option: throw GitHubError.invalidResponse` to the value switch (replaced in Task 2). In `AppStore.setProjectField` add to the value switch:

```swift
        case .option(let option):
            text = option
            payload = value
            kind = .select
```

`Models.swift` `Ticket`: add stored `public var unsynced: [String]?` after `isQuickCapture` (doc: "Log field names whose last push to GitHub failed; sync keeps the local value."), an `unsynced: [String]? = nil` init parameter at the end, and `self.unsynced = unsynced`.

`ActionLog.swift` `ActionLogEntry`: add `public var remote: RemoteEdit?`, init parameter `remote: RemoteEdit? = nil` (last), assignment. In `AppStore.record` add parameter `remote: RemoteEdit? = nil` after `detail` and pass `remote: remote` to `ActionLogEntry`.

- [ ] **Step 4: Run to verify pass**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A Sources Tests
git commit -m "feat: RemoteEdit model, option mappings and options types"
```

---

### Task 2: Client reads (options) and project single-select writes

**Files:**
- Create: `Sources/FocusCore/GitHubEdits.swift`
- Modify: `Sources/FocusCore/GitHubClient.swift`
- Test: `Tests/FocusCoreTests/GitHubEditsTests.swift`

**Interfaces:**
- Consumes: option types from Task 1.
- Produces on `GitHubClient`:
  - `fetchLabels(repo:) async throws -> [LabelOption]`
  - `fetchMilestones(repo:) async throws -> [MilestoneOption]`
  - `fetchOrgIssueFields(org:) async throws -> [IssueFieldDefinition]`
  - `fetchProjectOptions(repo:number:field:) async throws -> [String: [FieldOption]]`
  - `updateProjectField(... value: .option(name))` sends `singleSelectOptionId`
  - Internal (no longer `private`): `get`, `send(_:)`, `send(post:body:)`, `request(for:)`, `graphQL`, `issueFieldsAPIVersion`, `FieldLookup`, `fieldLookupQuery`, `setFieldMutation`, `clearFieldMutation`, `projectItems(repo:number:)`

- [ ] **Step 1: Write the failing tests**

Create `Tests/FocusCoreTests/GitHubEditsTests.swift`:

```swift
import XCTest
@testable import FocusCore

final class GitHubEditsTests: XCTestCase {
    private let lookup = """
    {"data":{"repository":{"issue":{"projectItems":{"nodes":[{"id":"PVTI_1","project":{"id":"PVT_1","title":"Board","fields":{"nodes":[
      {"id":"F_RCA","name":"RCA"},
      {"id":"F_ST","name":"Status","options":[{"id":"o1","name":"Todo","color":"GRAY"},{"id":"o2","name":"Done","color":"GREEN"}]}]}}}]}}}}}
    """

    func testOptionReads() async throws {
        let transport = RecordingTransport { request in
            let path = request.url?.path ?? ""
            if path == "/repos/me/a/labels" { return (200, #"[{"name":"bug","color":"d73a4a"},{"name":"ui","color":"0075ca"}]"#) }
            if path == "/repos/me/a/milestones" { return (200, #"[{"number":3,"title":"v3","state":"open","due_on":"2026-12-01T08:00:00Z"},{"number":2,"title":"v2","state":"closed","due_on":null}]"#) }
            if path == "/orgs/me/issue-fields" { return (200, #"[{"id":9,"name":"Priority","data_type":"single_select","options":[{"id":1,"name":"High","color":"red"}]},{"id":8,"name":"Target date","data_type":"date","options":null}]"#) }
            return (200, self.lookup)
        }
        let client = GitHubClient(token: "t", transport: transport)

        let labels = try await client.fetchLabels(repo: "me/a")
        XCTAssertEqual(labels, [LabelOption(name: "bug", color: "d73a4a"), LabelOption(name: "ui", color: "0075ca")])
        let milestones = try await client.fetchMilestones(repo: "me/a")
        XCTAssertEqual(milestones.map(\.title), ["v3", "v2"])
        XCTAssertEqual(milestones.map(\.isOpen), [true, false])
        XCTAssertNotNil(milestones[0].dueOn)
        let defs = try await client.fetchOrgIssueFields(org: "me")
        XCTAssertEqual(defs[0], IssueFieldDefinition(id: 9, name: "Priority", dataType: "single_select", options: [FieldOption(name: "High", color: "red")]))
        XCTAssertEqual(defs[1].options, [])
        let status = try await client.fetchProjectOptions(repo: "me/a", number: 1, field: "Status")
        XCTAssertEqual(status["Board"]?.map(\.name), ["Todo", "Done"])
        XCTAssertEqual(status["Board"]?.first?.color, "gray")
        let state = transport.requests.first { $0.url?.path == "/orgs/me/issue-fields" }
        XCTAssertEqual(state?.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
    }

    func testProjectOptionWriteSendsOptionID() async throws {
        let transport = RecordingTransport { request in
            request.httpBody.flatMap { String(data: $0, encoding: .utf8) }?.contains("updateProjectV2ItemFieldValue") == true
                ? (200, #"{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"x"}}}}"#)
                : (200, self.lookup)
        }
        let client = GitHubClient(token: "t", transport: transport)

        try await client.updateProjectField(repo: "me/a", number: 1, project: "Board", field: "Status", value: .option("Done"))

        let mutation = transport.json(1)
        let variables = mutation?["variables"] as? [String: Any]
        XCTAssertEqual((variables?["value"] as? [String: Any])?["singleSelectOptionId"] as? String, "o2")
        XCTAssertEqual(variables?["field"] as? String, "F_ST")
    }

    func testUnknownOptionThrows() async {
        let client = GitHubClient(token: "t", transport: RecordingTransport { _ in (200, self.lookup) })
        do {
            try await client.updateProjectField(repo: "me/a", number: 1, project: "Board", field: "Status", value: .option("Nope"))
            XCTFail("expected error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Nope"))
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter GitHubEditsTests`
Expected: FAIL to compile.

- [ ] **Step 3: Implement**

In `GitHubClient.swift`:

1. Remove `private` from: `func graphQL`, `func get`, `func send(post:body:)`, `func request(for:apiVersion:)`, `func send(_ request:)`, `static let issueFieldsAPIVersion`, `static let fieldLookupQuery`, `static let setFieldMutation`, `static let clearFieldMutation`, and `struct FieldLookup` (file-level `private struct FieldLookup` becomes `struct FieldLookup`).
2. Replace `fieldLookupQuery`'s fields selection with:
   ```
   project { id title fields(first: 50) { nodes { ... on ProjectV2FieldCommon { id name } ... on ProjectV2SingleSelectField { options { id name color } } } } }
   ```
3. In `FieldLookup.Field` add:
   ```swift
   struct Option: Decodable { let id: String; let name: String; let color: String? }
   let options: [Option]?
   ```
4. Replace the first half of `updateProjectField` (everything up to computing `fieldID`) with a shared helper and use the field node:

```swift
    func projectItems(repo: String, number: Int) async throws -> [FieldLookup.Item] {
        let parts = repo.split(separator: "/")
        guard parts.count == 2 else { throw GitHubError.invalidResponse }
        let data = try await graphQL(Self.fieldLookupQuery, variables: ["owner": String(parts[0]), "name": String(parts[1]), "number": number])
        let lookup = try JSONDecoder().decode(FieldLookup.self, from: data)
        if let message = lookup.errors?.first?.message { throw GitHubError.graphQL(message) }
        return (lookup.data?.repository?.issue?.projectItems.nodes ?? []).compactMap { $0 }
    }

    public func updateProjectField(repo: String, number: Int, project: String, field: String, value: ProjectFieldValue) async throws {
        let items = try await projectItems(repo: repo, number: number)
        guard let item = items.first(where: { $0.project.title == project }) else {
            throw GitHubError.graphQL("This issue is not in the \"\(project)\" project.")
        }
        guard let fieldNode = (item.project.fields.nodes ?? []).compactMap({ $0 }).first(where: { $0.name == field }), let fieldID = fieldNode.id else {
            throw GitHubError.graphQL("The \"\(project)\" project has no \"\(field)\" field.")
        }

        let ids: [String: Any] = ["project": item.project.id, "item": item.id, "field": fieldID]
        let result: Data
        switch value {
        case .text(let text) where text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            result = try await graphQL(Self.clearFieldMutation, variables: ids)
        case .text(let text):
            result = try await graphQL(Self.setFieldMutation, variables: ids.merging(["value": ["text": text]]) { $1 })
        case .number(let number):
            result = try await graphQL(Self.setFieldMutation, variables: ids.merging(["value": ["number": number]]) { $1 })
        case .option(let name):
            guard let optionID = fieldNode.options?.first(where: { $0.name == name })?.id else {
                throw GitHubError.graphQL("The \"\(field)\" field has no \"\(name)\" option.")
            }
            result = try await graphQL(Self.setFieldMutation, variables: ids.merging(["value": ["singleSelectOptionId": optionID]]) { $1 })
        }
        if let message = try JSONDecoder().decode(FieldLookup.self, from: result).errors?.first?.message {
            throw GitHubError.graphQL(message)
        }
    }
```

Create `Sources/FocusCore/GitHubEdits.swift`:

```swift
import Foundation

private struct LabelDTO: Decodable { let name: String; let color: String? }
private struct MilestoneDTO: Decodable { let number: Int; let title: String; let state: String?; let dueOn: Date? }
private struct OrgFieldDTO: Decodable {
    struct Option: Decodable { let name: String; let color: String? }
    let id: Int
    let name: String
    let dataType: String
    let options: [Option]?
}

extension GitHubClient {
    private func getAll<T: Decodable>(_ url: URL, as type: T.Type, maxPages: Int = 20) async throws -> [T] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        var next: URL? = url
        var result: [T] = []
        var pages = 0
        while let current = next, pages < maxPages {
            let (data, response) = try await get(current)
            result += try decoder.decode([T].self, from: data)
            next = Self.nextURL(from: response.value(forHTTPHeaderField: "Link"))
            pages += 1
        }
        return result
    }

    public func fetchLabels(repo: String) async throws -> [LabelOption] {
        guard let url = URL(string: "https://\(Self.apiHost)/repos/\(repo)/labels?per_page=100") else { throw GitHubError.invalidResponse }
        return try await getAll(url, as: LabelDTO.self).map { LabelOption(name: $0.name, color: $0.color ?? "") }
    }

    public func fetchMilestones(repo: String) async throws -> [MilestoneOption] {
        guard let url = URL(string: "https://\(Self.apiHost)/repos/\(repo)/milestones?state=all&per_page=100") else { throw GitHubError.invalidResponse }
        return try await getAll(url, as: MilestoneDTO.self).map {
            MilestoneOption(number: $0.number, title: $0.title, isOpen: $0.state != "closed", dueOn: $0.dueOn)
        }
    }

    /// Organization issue field definitions (Priority, Target date, ...). Fails with 404 for non-org owners.
    public func fetchOrgIssueFields(org: String) async throws -> [IssueFieldDefinition] {
        guard let url = URL(string: "https://\(Self.apiHost)/orgs/\(org)/issue-fields") else { throw GitHubError.invalidResponse }
        let (data, _) = try await get(url, apiVersion: Self.issueFieldsAPIVersion)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([OrgFieldDTO].self, from: data).map { dto in
            IssueFieldDefinition(id: dto.id, name: dto.name, dataType: dto.dataType, options: (dto.options ?? []).map { FieldOption(name: $0.name, color: $0.color) })
        }
    }

    /// Options of the single-select `field` (e.g. "Status") in each project the issue belongs to, keyed by project title.
    public func fetchProjectOptions(repo: String, number: Int, field: String) async throws -> [String: [FieldOption]] {
        var result: [String: [FieldOption]] = [:]
        for item in try await projectItems(repo: repo, number: number) {
            let node = (item.project.fields.nodes ?? []).compactMap { $0 }.first { $0.name == field }
            if let options = node?.options {
                result[item.project.title] = options.map { FieldOption(name: $0.name, color: $0.color?.lowercased()) }
            }
        }
        return result
    }
}
```

- [ ] **Step 4: Run the whole suite**

Run: `swift test`
Expected: PASS (existing `updateProjectField` callers still work).

- [ ] **Step 5: Commit**

```bash
git add -A Sources Tests
git commit -m "feat: fetch labels, milestones, org issue fields and project options"
```

---

### Task 3: Client writes and `apply`

**Files:**
- Modify: `Sources/FocusCore/GitHubEdits.swift`
- Test: `Tests/FocusCoreTests/GitHubEditsTests.swift`

**Interfaces:**
- Produces on `GitHubClient`: `setLabels(repo:number:labels:)`, `patchIssue(repo:number:_:)`, `setIssueField(repo:number:name:value:)`, `apply(_:repo:number:)` — all `async throws`.

- [ ] **Step 1: Write the failing tests**

Append inside `GitHubEditsTests`:

```swift
    private func method(_ t: RecordingTransport, _ i: Int) -> String { t.requests[i].httpMethod ?? "" }

    func testApplyLabelsMilestoneTitleAndState() async throws {
        let transport = RecordingTransport { _ in (200, "{}") }
        let client = GitHubClient(token: "t", transport: transport)

        try await client.apply(.labels(["bug", "ui"]), repo: "me/a", number: 1)
        try await client.apply(.milestone(number: 3), repo: "me/a", number: 1)
        try await client.apply(.milestone(number: nil), repo: "me/a", number: 1)
        try await client.apply(.title("New"), repo: "me/a", number: 1)
        try await client.apply(.state(open: false), repo: "me/a", number: 1)
        try await client.apply(.state(open: true), repo: "me/a", number: 1)

        XCTAssertEqual(method(transport, 0), "PUT")
        XCTAssertEqual(transport.requests[0].url?.path, "/repos/me/a/issues/1/labels")
        XCTAssertEqual(transport.json(0)?["labels"] as? [String], ["bug", "ui"])
        XCTAssertEqual(method(transport, 1), "PATCH")
        XCTAssertEqual(transport.requests[1].url?.path, "/repos/me/a/issues/1")
        XCTAssertEqual(transport.json(1)?["milestone"] as? Int, 3)
        XCTAssertTrue(transport.json(2)?["milestone"] is NSNull)
        XCTAssertEqual(transport.json(3)?["title"] as? String, "New")
        XCTAssertEqual(transport.json(4)?["state"] as? String, "closed")
        XCTAssertEqual(transport.json(4)?["state_reason"] as? String, "completed")
        XCTAssertEqual(transport.json(5)?["state"] as? String, "open")
    }

    func testSetIssueFieldKeepsOtherValuesAndUsesOrgFieldID() async throws {
        let current = """
        [{"issue_field_id":1,"issue_field_name":"Priority","data_type":"single_select","value":"High","single_select_option":{"id":10,"name":"High","color":"red"}},
         {"issue_field_id":5,"issue_field_name":"Points","data_type":"number","value":3}]
        """
        let transport = RecordingTransport { request in
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("GET", let p) where p.hasSuffix("/issue-field-values"): return (200, current)
            case ("GET", "/orgs/me/issue-fields"): return (200, #"[{"id":8,"name":"Target date","data_type":"date","options":null}]"#)
            default: return (200, "[]")
            }
        }
        let client = GitHubClient(token: "t", transport: transport)

        try await client.setIssueField(repo: "me/a", number: 1, name: "Target date", value: .string("2026-12-01"))

        let put = transport.requests.last!
        XCTAssertEqual(put.httpMethod, "PUT")
        XCTAssertEqual(put.url?.path, "/repos/me/a/issues/1/issue-field-values")
        XCTAssertEqual(put.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
        let body = try JSONSerialization.jsonObject(with: put.httpBody!) as! [String: Any]
        let values = body["issue_field_values"] as! [[String: Any]]
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(values.first { ($0["field_id"] as? Int) == 1 }?["value"] as? String, "High")
        XCTAssertEqual(values.first { ($0["field_id"] as? Int) == 5 }?["value"] as? Int, 3)
        XCTAssertEqual(values.first { ($0["field_id"] as? Int) == 8 }?["value"] as? String, "2026-12-01")
    }

    func testClearIssueFieldDeletesOnlyThatValue() async throws {
        let current = #"[{"issue_field_id":4,"issue_field_name":"Target date","data_type":"date","value":"2026-10-20"}]"#
        let transport = RecordingTransport { request in
            request.httpMethod == "GET" ? (200, current) : (204, "")
        }
        let client = GitHubClient(token: "t", transport: transport)

        try await client.apply(.issueField(name: "Target date", value: nil), repo: "me/a", number: 1)

        let last = transport.requests.last!
        XCTAssertEqual(last.httpMethod, "DELETE")
        XCTAssertEqual(last.url?.path, "/repos/me/a/issues/1/issue-field-values/4")
    }

    func testMissingOrgFieldThrows() async {
        let transport = RecordingTransport { request in
            request.url?.path.hasSuffix("/issue-field-values") == true ? (200, "[]") : (200, "[]")
        }
        let client = GitHubClient(token: "t", transport: transport)
        do {
            try await client.setIssueField(repo: "me/a", number: 1, name: "Target date", value: .string("2026-12-01"))
            XCTFail("expected error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Target date"))
        }
    }

    func testApplyProjectFieldForwardsToProjectMutation() async throws {
        let transport = RecordingTransport { request in
            request.httpBody.flatMap { String(data: $0, encoding: .utf8) }?.contains("updateProjectV2ItemFieldValue") == true
                ? (200, #"{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"x"}}}}"#)
                : (200, self.lookup)
        }
        let client = GitHubClient(token: "t", transport: transport)
        try await client.apply(.projectField(project: "Board", field: "Status", value: .option("Done")), repo: "me/a", number: 1)
        XCTAssertEqual(transport.requests.count, 2)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter GitHubEditsTests`
Expected: FAIL to compile (`apply` missing).

- [ ] **Step 3: Implement**

Add to the `GitHubClient` extension in `GitHubEdits.swift`:

```swift
    private func issueURL(_ repo: String, _ number: Int, _ suffix: String = "") throws -> URL {
        guard let url = URL(string: "https://\(Self.apiHost)/repos/\(repo)/issues/\(number)\(suffix)") else { throw GitHubError.invalidResponse }
        return url
    }

    private func send(method: String, _ url: URL, body: [String: Any]?, apiVersion: String = "2022-11-28") async throws -> Data {
        var request = request(for: url, apiVersion: apiVersion)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return try await send(request).0
    }

    /// Replaces all labels on the issue.
    public func setLabels(repo: String, number: Int, labels: [String]) async throws {
        _ = try await send(method: "PUT", issueURL(repo, number, "/labels"), body: ["labels": labels])
    }

    public func patchIssue(repo: String, number: Int, _ body: [String: Any]) async throws {
        _ = try await send(method: "PATCH", issueURL(repo, number), body: body)
    }

    /// Sets (or with nil clears) one organization issue field. GitHub's PUT replaces every value, so the others are re-sent.
    public func setIssueField(repo: String, number: Int, name: String, value: IssueFieldValue?) async throws {
        let valuesURL = try issueURL(repo, number, "/issue-field-values")
        let current = try await send(method: "GET", valuesURL, body: nil, apiVersion: Self.issueFieldsAPIVersion)
        let rows = (try JSONSerialization.jsonObject(with: current) as? [[String: Any]]) ?? []

        var entries: [[String: Any]] = []
        var targetID: Int?
        for row in rows {
            guard let id = row["issue_field_id"] as? Int else { continue }
            if (row["issue_field_name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame {
                targetID = id
                continue
            }
            let kept: Any?
            switch row["data_type"] as? String {
            case "single_select": kept = (row["single_select_option"] as? [String: Any])?["name"]
            case "multi_select": kept = (row["multi_select_options"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
            default: kept = row["value"]
            }
            if let kept { entries.append(["field_id": id, "value": kept]) }
        }

        guard let value else {
            if let targetID {
                _ = try await send(method: "DELETE", valuesURL.appendingPathComponent(String(targetID)), body: nil, apiVersion: Self.issueFieldsAPIVersion)
            }
            return
        }

        if targetID == nil {
            guard let owner = repo.split(separator: "/").first else { throw GitHubError.invalidResponse }
            targetID = try await fetchOrgIssueFields(org: String(owner)).first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
        }
        guard let targetID else { throw GitHubError.graphQL("The organization has no \"\(name)\" issue field.") }

        switch value {
        case .string(let text): entries.append(["field_id": targetID, "value": text])
        case .number(let number): entries.append(["field_id": targetID, "value": number])
        }
        _ = try await send(method: "PUT", valuesURL, body: ["issue_field_values": entries], apiVersion: Self.issueFieldsAPIVersion)
    }

    public func apply(_ edit: RemoteEdit, repo: String, number: Int) async throws {
        switch edit {
        case .labels(let labels):
            try await setLabels(repo: repo, number: number, labels: labels)
        case .milestone(let milestone):
            try await patchIssue(repo: repo, number: number, ["milestone": milestone.map { $0 as Any } ?? NSNull()])
        case .title(let title):
            try await patchIssue(repo: repo, number: number, ["title": title])
        case .body(let body):
            try await patchIssue(repo: repo, number: number, ["body": body])
        case .state(let open):
            try await patchIssue(repo: repo, number: number, open ? ["state": "open"] : ["state": "closed", "state_reason": "completed"])
        case .issueField(let name, let value):
            try await setIssueField(repo: repo, number: number, name: name, value: value)
        case .projectField(let project, let field, let value):
            try await updateProjectField(repo: repo, number: number, project: project, field: field, value: value)
        }
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A Sources Tests
git commit -m "feat: GitHub write endpoints for labels, milestone, state, issue fields"
```

---

### Task 4: Edit pipeline in `AppStore` (push, failure keeps local, retry, resync)

**Files:**
- Modify: `Sources/FocusCore/AppStore.swift`
- Test: `Tests/FocusCoreTests/EditPipelineTests.swift`

**Interfaces:**
- Consumes: `RemoteEdit`, `GitHubClient.apply`, `record(... remote:)`, `setActionSync`.
- Produces on `AppStore`:
  - `func edit(_ id: UUID, _ change: FieldChange, remote: RemoteEdit?, delay: Duration = .zero, apply: (inout Ticket) -> Void)` (internal)
  - `public func retry(_ entryID: UUID) async -> Bool`
  - `public func resyncFailed() async`
  - `func settlePushes() async` (internal, for tests)
  - `setProjectField` now uses `edit` (a failed write keeps the local value; no revert)
  - `copyContent` keeps fields listed in `Ticket.unsynced`, and derives `priority` (org field "Priority"), `dueDate` (org field "Target date"), `status` (project field "Status") from fields

- [ ] **Step 1: Write the failing tests**

Create `Tests/FocusCoreTests/EditPipelineTests.swift`:

```swift
import XCTest
@testable import FocusCore

@MainActor
final class EditPipelineTests: XCTestCase {
    private let issueJSON = #"{"number":1,"title":"A","body":null,"state":"open","html_url":"u","repository_url":"https://api.github.com/repos/me/a","node_id":"I_1","labels":[{"name":"bug","color":"d73a4a"}],"milestone":null}"#

    private func makeStore(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) -> (AppStore, RecordingTransport, UUID) {
        let transport = RecordingTransport(handler)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let store = AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, transport: transport, tokenProvider: { "t" })
        store.insertTicketForTest(Ticket(title: "A", labels: ["bug"], github: GitHubRef(repo: "me/a", number: 1, url: "u")))
        return (store, transport, store.tickets[0].id)
    }

    private func editLabels(_ store: AppStore, _ id: UUID, to labels: [String]) {
        let old = store.ticket(id)!.labels
        store.edit(id, FieldChange(field: "Labels", old: old.joined(separator: ", "), new: labels.joined(separator: ", "), oldList: old, newList: labels), remote: .labels(labels)) { $0.labels = labels }
    }

    func testSuccessfulPushMarksSynced() async {
        let (store, transport, id) = makeStore { _ in (200, "{}") }

        editLabels(store, id, to: ["bug", "ui"])
        XCTAssertEqual(store.actionLog.last?.sync, .pending)
        await store.settlePushes()

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests[0].httpMethod, "PUT")
        if case .synced = store.actionLog.last!.sync {} else { XCTFail("expected synced") }
        XCTAssertNil(store.tickets[0].unsynced?.first)
        XCTAssertEqual(store.actionLog.last?.remote, .labels(["bug", "ui"]))
    }

    func testFailedPushKeepsLocalValueAndSurvivesSync() async {
        let failing = Switch(true)
        let issue = issueJSON
        let (store, _, id) = makeStore { request in
            let path = request.url?.path ?? ""
            if request.httpMethod == "PUT" { return failing.isOn ? (422, #"{"message":"Validation Failed"}"#) : (200, "{}") }
            if path == "/graphql" { return (200, #"{"data":{"nodes":[{"id":"I_1","projectItems":{"nodes":[]}}]}}"#) }
            if path.hasSuffix("/issue-field-values") { return (200, "[]") }
            return (200, issue)
        }

        editLabels(store, id, to: ["bug", "ui"])
        await store.settlePushes()

        XCTAssertEqual(store.failedActions.count, 1)
        XCTAssertEqual(store.tickets[0].labels, ["bug", "ui"])
        XCTAssertEqual(store.tickets[0].unsynced, ["Labels"])

        await store.refreshTicket(id, minimumInterval: 0)
        XCTAssertEqual(store.tickets[0].labels, ["bug", "ui"], "sync must not overwrite an unsynced field")

        failing.isOn = false
        let ok = await store.retry(store.failedActions[0].id)
        XCTAssertTrue(ok)
        XCTAssertTrue(store.failedActions.isEmpty)
        XCTAssertTrue((store.tickets[0].unsynced ?? []).isEmpty)

        await store.refreshTicket(id, minimumInterval: 0)
        XCTAssertEqual(store.tickets[0].labels, ["bug"], "once synced, GitHub is the source again")
    }

    func testResyncRetriesEveryFailedEntry() async {
        let failing = Switch(true)
        let (store, _, id) = makeStore { request in
            request.httpMethod == nil || request.httpMethod == "GET" ? (200, "{}") : (failing.isOn ? (500, "{}") : (200, "{}"))
        }
        editLabels(store, id, to: ["x"])
        await store.settlePushes()
        store.edit(id, FieldChange(field: "Title", old: "A", new: "B"), remote: .title("B")) { $0.title = "B" }
        await store.settlePushes()
        XCTAssertEqual(store.failedActions.count, 2)

        failing.isOn = false
        await store.resyncFailed()

        XCTAssertTrue(store.failedActions.isEmpty)
    }

    func testNewEditSupersedesOlderFailedEntry() async {
        let failing = Switch(true)
        let (store, _, id) = makeStore { _ in failing.isOn ? (500, "{}") : (200, "{}") }
        editLabels(store, id, to: ["x"])
        await store.settlePushes()
        XCTAssertEqual(store.failedActions.count, 1)

        failing.isOn = false
        editLabels(store, id, to: ["y"])
        await store.settlePushes()

        XCTAssertTrue(store.failedActions.isEmpty)
        XCTAssertTrue((store.tickets[0].unsynced ?? []).isEmpty)
    }

    func testRepeatedEditsAreCoalescedIntoOneEntry() {
        let (store, _, id) = makeStore { _ in (200, "{}") }
        store.edit(id, FieldChange(field: "Title", old: "A", new: "B"), remote: .title("B"), delay: .milliseconds(300)) { $0.title = "B" }
        store.edit(id, FieldChange(field: "Title", old: "B", new: "BC"), remote: .title("BC"), delay: .milliseconds(300)) { $0.title = "BC" }

        let entries = store.actionLog.filter { $0.field == "Title" }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].oldValue, "A")
        XCTAssertEqual(entries[0].newValue, "BC")
        XCTAssertEqual(entries[0].remote, .title("BC"))
    }

    func testLocalTicketEditIsNotPushed() async {
        let transport = RecordingTransport { _ in (200, "{}") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let store = AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, transport: transport, tokenProvider: { "t" })
        let t = store.addTicket(title: "Local")
        store.edit(t.id, FieldChange(field: "Title", old: "Local", new: "L2"), remote: .title("L2")) { $0.title = "L2" }
        await store.settlePushes()

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(store.actionLog.last { $0.field == "Title" }?.sync, .notApplicable)
    }

    func testFailedProjectFieldWriteKeepsLocalValue() async {
        let (store, _, id) = makeStore { _ in (200, #"{"errors":[{"message":"nope"}]}"#) }
        store.update(id) { $0.fields = [CustomField(name: "RCA", value: "old", kind: .text, project: "P")] }

        store.setProjectField(id, name: "RCA", project: "P", to: .text("new"))
        await store.settlePushes()

        XCTAssertEqual(store.tickets[0].fields?.first?.value, "new")
        XCTAssertEqual(store.failedActions.first?.field, "RCA")
        XCTAssertEqual(store.tickets[0].unsynced, ["RCA"])
    }

    func testSyncDerivesPriorityDueDateAndStatusFromFields() {
        let target = Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 1))!
        let issue = RemoteIssue(
            repo: "me/a", number: 1, title: "A", url: "u",
            fields: [CustomField(name: "Status", value: "In Review", kind: .select, project: "Board")],
            issueFields: [
                CustomField(name: "Priority", value: "P1 - High", kind: .select, project: CustomField.issueFieldsGroup),
                CustomField(name: "Target date", value: "2026-12-01", kind: .date, project: CustomField.issueFieldsGroup, start: target)
            ]
        )

        let merged = AppStore.merge(existing: [], remote: [issue])[0]

        XCTAssertEqual(merged.priority, .high)
        XCTAssertEqual(merged.dueDate, target)
        XCTAssertEqual(merged.status, .inReview)

        var kept = merged
        kept.unsynced = ["Priority"]
        kept.priority = .low
        let again = AppStore.merge(existing: [kept], remote: [issue])[0]
        XCTAssertEqual(again.priority, .low)
        XCTAssertEqual(again.status, .inReview)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter EditPipelineTests`
Expected: FAIL to compile (`edit`, `retry`, `settlePushes` missing).

- [ ] **Step 3: Implement**

In `AppStore.swift`:

1. Add the pipeline next to the action log section:

```swift
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
            notice = "Couldn't update \(field) on GitHub (\(error.localizedDescription))."
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
```

2. Replace `setProjectField` with:

```swift
    /// Saves a project field locally right away, then writes it to GitHub; a failed write stays local and is retryable from the log.
    public func setProjectField(_ id: UUID, name: String, project: String, to value: ProjectFieldValue, delay: Duration = .zero) {
        let payload: ProjectFieldValue
        let kind: CustomField.Kind
        let text: String
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
        let oldText = ticket(id)?.fields?.first { $0.project == project && $0.name == name }?.value ?? "None"

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
```

3. Replace `copyContent` and add helpers; use them in `merge`'s new-ticket branch:

```swift
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

    /// Remote fields, except those named in `names` which keep their local value.
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
```

In `merge`, replace `result.append(Ticket(...))` with:

```swift
                var created = Ticket(
                    title: issue.title, body: issue.body, status: .todo, labels: issue.labels, labelColors: issue.labelColors,
                    milestone: issue.milestone, fields: issue.fields, issueType: issue.issueType, issueFields: issue.issueFields,
                    createdAt: now, updatedAt: now,
                    github: GitHubRef(repo: issue.repo, number: issue.number, url: issue.url, isPullRequest: issue.isPullRequest)
                )
                deriveFromFields(&created, keep: [])
                result.append(created)
```

- [ ] **Step 4: Run the whole suite**

Run: `swift test`
Expected: PASS. If an existing test relied on `setProjectField` reverting via `refreshTicket`, update it to the keep-local behavior (the spec requires it).

- [ ] **Step 5: Commit**

```bash
git add -A Sources Tests
git commit -m "feat: edit pipeline with push, keep-on-failure, retry and resync"
```

---

### Task 5: Typed editing API, status handling, options cache

**Files:**
- Create: `Sources/FocusCore/AppStore+Editing.swift`
- Modify: `Sources/FocusCore/AppStore.swift` (`remoteOptions` property, snapshot, `setStatus`, `start`)
- Test: `Tests/FocusCoreTests/TicketEditingTests.swift`

**Interfaces:**
- Consumes: `edit`, `RemoteEdit`, `RemoteOptions`.
- Produces on `AppStore`:
  - `public private(set) var remoteOptions: RemoteOptions` (persisted, optional in snapshot)
  - `setTitle(_:_:)`, `setBody(_:_:)`, `setLabels(_:_:)`, `setMilestone(_:_ option: MilestoneOption?)`, `setStatusOption(_:project:option:)`, `setPriorityOption(_:option: String?)`, `setPriority(_:_ priority: Priority)`, `setTargetDate(_:_ date: Date?)`
  - `labelOptions(for ticket: Ticket) -> [LabelOption]`, `milestoneOptions(for:) -> [MilestoneOption]`, `priorityOptions(for ticket: Ticket) -> [FieldOption]`, `statusOptions(for ticket: Ticket) -> [FieldOption]`
  - `setStatus(_:_:)` pushes the matching project Status option for linked tickets and closes/reopens the issue when moving to/from Done (never for pull requests); `start` goes through `setStatus`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FocusCoreTests/TicketEditingTests.swift`:

```swift
import XCTest
@testable import FocusCore

@MainActor
final class TicketEditingTests: XCTestCase {
    private let lookup = """
    {"data":{"repository":{"issue":{"projectItems":{"nodes":[{"id":"PVTI_1","project":{"id":"PVT_1","title":"Board","fields":{"nodes":[
      {"id":"F_ST","name":"Status","options":[{"id":"o1","name":"Todo","color":"GRAY"},{"id":"o2","name":"In Progress","color":"YELLOW"},{"id":"o3","name":"Done","color":"GREEN"}]}]}}}]}}}}}
    """
    private let orgFields = #"[{"id":9,"name":"Priority","data_type":"single_select","options":[{"id":1,"name":"P1 - High","color":"red"},{"id":2,"name":"P3 - Low","color":"green"}]},{"id":8,"name":"Target date","data_type":"date","options":null}]"#

    private func makeStore() -> (AppStore, RecordingTransport, UUID) {
        let lookup = self.lookup
        let orgFields = self.orgFields
        let transport = RecordingTransport { request in
            let path = request.url?.path ?? ""
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if path == "/graphql" { return body.contains("updateProjectV2ItemFieldValue") ? (200, #"{"data":{"updateProjectV2ItemFieldValue":{"projectV2Item":{"id":"x"}}}}"#) : (200, lookup) }
            if path == "/orgs/me/issue-fields" { return (200, orgFields) }
            if path.hasSuffix("/issue-field-values") { return (200, "[]") }
            return (200, "{}")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let store = AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, transport: transport, tokenProvider: { "t" })
        store.insertTicketForTest(Ticket(
            title: "A", labels: ["bug"], labelColors: ["bug": "d73a4a"], milestone: Milestone(title: "v1"),
            fields: [CustomField(name: "Status", value: "Todo", kind: .select, project: "Board")],
            github: GitHubRef(repo: "me/a", number: 1, url: "u")
        ))
        return (store, transport, store.tickets[0].id)
    }

    func testSetLabelsLogsListsAndPushes() async {
        let (store, transport, id) = makeStore()
        store.setLabels(id, ["bug", "ui"])
        await store.settlePushes()

        let entry = store.actionLog.last { $0.field == "Labels" }!
        XCTAssertEqual(entry.oldList, ["bug"])
        XCTAssertEqual(entry.newList, ["bug", "ui"])
        XCTAssertEqual(transport.requests.last?.url?.path, "/repos/me/a/issues/1/labels")
        XCTAssertEqual(store.tickets[0].labels, ["bug", "ui"])
    }

    func testSetMilestoneAndClear() async {
        let (store, transport, id) = makeStore()
        store.setMilestone(id, MilestoneOption(number: 3, title: "v3"))
        await store.settlePushes()
        XCTAssertEqual(store.tickets[0].milestone?.title, "v3")
        XCTAssertEqual(transport.json(transport.requests.count - 1)?["milestone"] as? Int, 3)

        store.setMilestone(id, nil)
        await store.settlePushes()
        XCTAssertNil(store.tickets[0].milestone)
        XCTAssertTrue(transport.json(transport.requests.count - 1)?["milestone"] is NSNull)
        XCTAssertEqual(store.actionLog.last { $0.field == "Milestone" }?.newValue, "None")
    }

    func testSetPriorityOptionUpdatesOrgFieldAndEnum() async {
        let (store, transport, id) = makeStore()
        store.setPriorityOption(id, option: "P1 - High")
        await store.settlePushes()

        XCTAssertEqual(store.tickets[0].priority, .high)
        XCTAssertEqual(store.tickets[0].field(named: "Priority")?.value, "P1 - High")
        let put = transport.requests.last { $0.httpMethod == "PUT" }
        XCTAssertEqual(put?.url?.path, "/repos/me/a/issues/1/issue-field-values")
        if case .synced = store.actionLog.last!.sync {} else { XCTFail("expected synced") }
    }

    func testSetTargetDateWritesOrgFieldAndDueDate() async {
        let (store, transport, id) = makeStore()
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 1))!

        store.setTargetDate(id, date)
        await store.settlePushes()

        XCTAssertEqual(store.tickets[0].dueDate, date)
        XCTAssertEqual(store.tickets[0].field(named: "Target date")?.value, "2026-12-01")
        let put = transport.requests.last { $0.httpMethod == "PUT" }!
        XCTAssertTrue(String(data: put.httpBody!, encoding: .utf8)!.contains("2026-12-01"))
    }

    func testSetStatusOptionPushesProjectFieldAndClosesIssueOnDone() async {
        let (store, transport, id) = makeStore()

        store.setStatusOption(id, project: "Board", option: "Done")
        await store.settlePushes()

        XCTAssertEqual(store.tickets[0].status, .done)
        XCTAssertEqual(store.tickets[0].projectStatusField?.value, "Done")
        let closed = transport.requests.contains { $0.httpMethod == "PATCH" && $0.url?.path == "/repos/me/a/issues/1" }
        XCTAssertTrue(closed)
        XCTAssertEqual(Set(store.actionLog.compactMap(\.field)).isSuperset(of: ["Status", "Issue state"]), true)

        store.setStatusOption(id, project: "Board", option: "In Progress")
        await store.settlePushes()
        XCTAssertEqual(store.tickets[0].status, .inProgress)
        XCTAssertEqual(store.actionLog.last { $0.field == "Issue state" }?.newValue, "Open")
    }

    func testPullRequestsAreNeverClosedByStatus() async {
        let (store, transport, _) = makeStore()
        store.insertTicketForTest(Ticket(title: "PR", github: GitHubRef(repo: "me/a", number: 2, url: "u", isPullRequest: true)))
        let pr = store.tickets[1].id

        store.setStatus(pr, .done)
        await store.settlePushes()

        XCTAssertFalse(transport.requests.contains { $0.httpMethod == "PATCH" })
    }

    func testTitleAndBodyEdits() async {
        let (store, transport, id) = makeStore()
        store.setTitle(id, "  New title ")
        store.setBody(id, "Body")
        await store.settlePushes()

        XCTAssertEqual(store.tickets[0].title, "New title")
        XCTAssertEqual(store.tickets[0].body, "Body")
        XCTAssertEqual(transport.requests.filter { $0.httpMethod == "PATCH" }.count, 2)
        store.setTitle(id, "   ")
        XCTAssertEqual(store.tickets[0].title, "New title")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter TicketEditingTests`
Expected: FAIL to compile.

- [ ] **Step 3: Implement**

In `AppStore.swift`:
- Add `public private(set) var remoteOptions = RemoteOptions()` next to `actionLog`, and `@ObservationIgnored private var lastOptionsLoad: Date?`.
- `Snapshot`: add `var remoteOptions: RemoteOptions?`; `load()`: `remoteOptions = snapshot.remoteOptions ?? RemoteOptions()`; `save()`: pass `remoteOptions: remoteOptions`.
- Make `remoteOptions`'s setter reachable from the extension file by adding to `AppStore.swift`: `func storeOptions(_ options: RemoteOptions) { remoteOptions = options; lastOptionsLoad = Date(); save() }` and `var optionsAreFresh: Bool { lastOptionsLoad.map { Date().timeIntervalSince($0) < 600 } ?? false }`.
- Replace `setStatus`:

```swift
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
```
- In `start(_:)` replace the block that sets `tickets[i].status = .inProgress` / `updatedAt` with:

```swift
        if tickets[i].status == .backlog || tickets[i].status == .todo { setStatus(ticketID, .inProgress) }
```
(keep it after `record(.timer ...)` and before `now = started`).

Create `Sources/FocusCore/AppStore+Editing.swift`:

```swift
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
        edit(id, change, remote: .labels(labels)) { ticket in
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
}
```

The extension file needs `transport` and `tokenProvider`: in `AppStore.swift` change `@ObservationIgnored private let transport` and `@ObservationIgnored private let tokenProvider` to internal (drop `private`).

`loadOptions(force:)` belongs to Task 6; the two tests that need it (`testSetPriorityMapsToOrgOptionWhenCached`, `testSetStatusUsesCachedOptionAndLocalTicketsStayLocal`) are written there.

- [ ] **Step 4: Run the whole suite**

Run: `swift test`
Expected: PASS (existing tests that asserted `start()` sets `.inProgress` still hold via `setStatus`).

- [ ] **Step 5: Commit**

```bash
git add -A Sources Tests
git commit -m "feat: typed ticket editing API with GitHub write-back and status/issue-state sync"
```

---

### Task 6: Load and cache options

**Files:**
- Modify: `Sources/FocusCore/AppStore+Editing.swift` (replace the stub), `Sources/FocusCore/AppStore.swift` (`syncGitHub`)
- Test: `Tests/FocusCoreTests/TicketEditingTests.swift` (add the two deferred tests plus below)

**Interfaces:**
- Produces: `public func loadOptions(force: Bool = false) async` — for every distinct linked repo loads labels and milestones; for every distinct owner the org issue fields; for each project holding a Status field one representative ticket's Status options. Errors per request are ignored (the previous cache is kept). Skips when called again within 10 minutes unless `force`. Saves into `remoteOptions`. `syncGitHub()` calls it after a successful sync.

- [ ] **Step 1: Write the tests**

Add to `TicketEditingTests` (the transport in `makeStore()` must also answer labels and milestones; extend its handler with:
```swift
            if path == "/repos/me/a/labels" { return (200, #"[{"name":"bug","color":"d73a4a"},{"name":"ui","color":"0075ca"}]"#) }
            if path == "/repos/me/a/milestones" { return (200, #"[{"number":3,"title":"v3","state":"open","due_on":null}]"#) }
```
above the `issue-field-values` line), and add:

```swift
    func testLoadOptionsCachesAndPersists() async {
        let (store, _, id) = makeStore()
        await store.loadOptions(force: true)

        let t = store.ticket(id)!
        XCTAssertEqual(store.labelOptions(for: t).map(\.name), ["bug", "ui"])
        XCTAssertEqual(store.milestoneOptions(for: t).map(\.title), ["v3"])
        XCTAssertEqual(store.priorityOptions(for: t).map(\.name), ["P1 - High", "P3 - Low"])
        XCTAssertEqual(store.statusOptions(for: t).map(\.name), ["Todo", "In Progress", "Done"])
    }

    func testLoadOptionsIsThrottledAndTolerantOfFailures() async {
        let (store, transport, _) = makeStore()
        await store.loadOptions(force: true)
        let count = transport.requests.count
        await store.loadOptions()
        XCTAssertEqual(transport.requests.count, count)

        let failing = RecordingTransport { _ in (500, "{}") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        let other = AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, transport: failing, tokenProvider: { "t" })
        other.insertTicketForTest(Ticket(title: "A", github: GitHubRef(repo: "me/a", number: 1, url: "u")))
        await other.loadOptions(force: true)
        XCTAssertEqual(other.remoteOptions, RemoteOptions())
    }

    func testSetPriorityMapsToOrgOptionWhenCached() async {
        let (store, _, id) = makeStore()
        await store.loadOptions(force: true)

        store.setPriority(id, .low)
        await store.settlePushes()

        XCTAssertEqual(store.tickets[0].field(named: "Priority")?.value, "P3 - Low")
        XCTAssertEqual(store.tickets[0].priority, .low)
    }

    func testSetStatusUsesCachedOptionAndLocalTicketsStayLocal() async {
        let (store, transport, id) = makeStore()
        await store.loadOptions(force: true)
        let before = transport.requests.count

        store.setStatus(id, .inProgress)
        await store.settlePushes()
        XCTAssertEqual(store.tickets[0].projectStatusField?.value, "In Progress")
        XCTAssertGreaterThan(transport.requests.count, before)

        let local = store.addTicket(title: "Local")
        let count = transport.requests.count
        store.setStatus(local.id, .done)
        await store.settlePushes()
        XCTAssertEqual(store.ticket(local.id)?.status, .done)
        XCTAssertEqual(transport.requests.count, count)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter TicketEditingTests`
Expected: FAIL (options are empty because `loadOptions` is a stub).

- [ ] **Step 3: Implement**

Replace the stub in `AppStore+Editing.swift`:

```swift
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
```

In `AppStore.syncGitHub()`, after the successful-sync state is set (where `syncState = .succeeded(...)` is assigned), add `await loadOptions()`.

- [ ] **Step 4: Run the whole suite, then build the app**

Run: `swift test` then `swift build`
Expected: PASS, build succeeds. If an existing `syncGitHub` test counts requests, adjust it to ignore the extra option requests (path-based assertions).

- [ ] **Step 5: Commit**

```bash
git add -A Sources Tests
git commit -m "feat: load and cache labels, milestones, org fields and project status options"
```

---

## Self-Review

- Spec coverage: GitHub mapping table (labels, milestone, title/body, Status via project, Priority/Target date via org issue fields, estimate/RCA through the same pipeline) — Tasks 3–5; options cache — Task 6; keep-on-failure, `unsynced`, sync not overwriting, Retry/Resync, supersede — Task 4; priority/due date/status as source of truth plus fallback for local tickets — Tasks 4–5; Done closes/reopens issue, PRs excluded — Task 5. Left for plan 3: pickers/UI, Action Log page and detail sheet, banner with Resync/Dismiss, dashboard card, sidebar badge, "Delete older than 60 days" button, History section.
- Views still call `update(_:)` for priority/due date until plan 3 swaps them to the typed setters, so those edits stay local-only (logged) until then.
- Names used across tasks: `RemoteEdit`, `IssueFieldValue`, `edit`, `push`, `retry`, `resyncFailed`, `settlePushes`, `setUnsynced`, `supersedeFailed`, `syncIssueState`, `storeOptions`, `optionsAreFresh`, `remoteOptions`, `labelOptions/milestoneOptions/priorityOptions/statusOptions(for:)`, `Date.isoDay`, `Ticket.projectStatusField`, `Ticket.unsynced` — consistent.
- Behavior change to call out to the user: starting a timer on a linked ticket in Backlog/Todo now moves it to the matching "In Progress" project option on GitHub (logged), because project Status is the source of truth.
