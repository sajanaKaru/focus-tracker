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

    func testInDevCountsAsInProgressInAnyDecoration() {
        for name in ["In Dev", "🏃 In Dev", "In Dev 🏃", "in dev", "Dev", "Development"] {
            XCTAssertEqual(TicketStatus(optionName: name), .inProgress, name)
        }
        XCTAssertEqual(TicketStatus(optionName: "🏃 In Progress"), .inProgress)
        XCTAssertEqual(TicketStatus(optionName: "Dev Review"), .inReview)
        XCTAssertEqual(TicketStatus(optionName: "Devices queue"), .todo, "only the word Dev counts")
    }

    func testSyncPutsInDevTicketsInProgress() {
        let issue = RemoteIssue(
            repo: "me/a", number: 1, title: "A", url: "u",
            fields: [CustomField(name: "Status", value: "🏃 In Dev", kind: .select, project: "Board")]
        )
        XCTAssertEqual(AppStore.merge(existing: [], remote: [issue])[0].status, .inProgress)
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
