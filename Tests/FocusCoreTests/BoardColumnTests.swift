import XCTest
@testable import FocusCore

@MainActor
final class BoardColumnTests: XCTestCase {
    private func makeStore() -> AppStore {
        let transport = RecordingTransport { _ in (200, "{}") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ft-\(UUID().uuidString).json")
        return AppStore(storeURL: url, defaults: UserDefaults(suiteName: "ft-\(UUID().uuidString)")!, transport: transport, tokenProvider: { "t" })
    }

    private func statusTicket(_ value: String, project: String = "Board", number: Int = 1) -> Ticket {
        Ticket(
            title: "T\(number)",
            fields: [CustomField(name: "Status", value: value, kind: .select, project: project)],
            github: GitHubRef(repo: "me/a", number: number, url: "u")
        )
    }

    func testDefaultsToFiveStatuses() {
        let store = makeStore()
        XCTAssertEqual(store.boardColumns.map(\.name), TicketStatus.allCases.map(\.title))
    }

    func testColumnsFollowProjectOptionsAndMergeProjects() {
        let store = makeStore()
        store.insertTicketForTest(statusTicket("Todo", project: "Board", number: 1))
        store.insertTicketForTest(statusTicket("Review", project: "Ops", number: 2))
        var options = RemoteOptions()
        options.projectStatus["Board"] = [FieldOption(name: "Todo", color: "gray"), FieldOption(name: "In Progress", color: "yellow"), FieldOption(name: "Done", color: "green")]
        options.projectStatus["Ops"] = [FieldOption(name: "todo"), FieldOption(name: "Review")]
        options.projectStatus["Unused"] = [FieldOption(name: "Nope")]
        store.storeOptions(options)

        let columns = store.boardColumns
        XCTAssertEqual(columns.map(\.name), ["Todo", "In Progress", "Done", "Review"])
        XCTAssertEqual(columns.map(\.status), [.todo, .inProgress, .done, .inReview])
        XCTAssertEqual(columns[0].color, "gray")
    }

    func testTicketColumnAndMove() async {
        let store = makeStore()
        store.insertTicketForTest(statusTicket("In Progress"))
        store.insertTicketForTest(Ticket(title: "Local", status: .done))
        var options = RemoteOptions()
        options.projectStatus["Board"] = [FieldOption(name: "Todo"), FieldOption(name: "In Progress"), FieldOption(name: "Done")]
        store.storeOptions(options)
        let columns = store.boardColumns

        XCTAssertEqual(store.column(for: store.tickets[0], in: columns), "In Progress")
        XCTAssertEqual(store.column(for: store.tickets[1], in: columns), "Done")

        let remoteID = store.tickets[0].id
        store.moveTicket(remoteID, toColumn: columns[0])
        await store.settlePushes()
        XCTAssertEqual(store.ticket(remoteID)?.projectStatusField?.value, "Todo")
        XCTAssertEqual(store.ticket(remoteID)?.status, .todo)

        let localID = store.tickets[1].id
        store.moveTicket(localID, toColumn: columns[1])
        XCTAssertEqual(store.ticket(localID)?.status, .inProgress)
    }
}
