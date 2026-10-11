import FocusCore
import SwiftUI

/// Today differs by role; Dev keeps the original page.
struct TodayView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedTicketID: UUID?
    @Binding var filter: TicketFilter

    var body: some View {
        switch store.role {
        case .dev: DevTodayView(selectedTicketID: $selectedTicketID, filter: $filter)
        case .qa: QATodayView(selectedTicketID: $selectedTicketID)
        case .pm: PMTodayView(selectedTicketID: $selectedTicketID)
        }
    }
}
