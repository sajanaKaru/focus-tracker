import AppKit
import FocusCore
import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case today = "Today"
    case tickets = "Tickets"
    case board = "Board"
    case pullRequests = "Pull Requests"
    case reports = "Reports"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .tickets: "list.bullet.rectangle"
        case .board: "rectangle.split.3x1"
        case .pullRequests: "arrow.triangle.pull"
        case .reports: "chart.bar"
        }
    }
}

private struct SidebarRow: View {
    let item: SidebarItem
    let selected: Bool
    var badge: Int?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                    .frame(width: 20)
                Text(item.rawValue).font(.system(size: 13.5, weight: selected ? .semibold : .medium))
                Spacer(minLength: 0)
                if let badge, badge > 0 {
                    Text(badge.formatted())
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(selected ? Theme.accent : Color.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(selected ? Theme.accent.opacity(0.15) : Color.primary.opacity(0.07), in: Capsule())
                }
            }
            .foregroundStyle(selected ? Theme.accent : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.13) : Color.primary.opacity(hovering ? 0.06 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Paints the whole title bar (window buttons and toolbar) in the sidebar colour with a border underneath.
private struct TitleBarStrip: View {
    var body: some View {
        GeometryReader { proxy in
            let height = proxy.safeAreaInsets.top > 0 ? proxy.safeAreaInsets.top : 52
            Theme.sidebarBackground
                .frame(height: height)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1) }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var selection: SidebarItem? = .today
    @State private var selectedTicketID: UUID?
    @State private var planTicketID: UUID?
    @State private var showingNewTicket = false
    @State private var filter = TicketFilter()
    @State private var appliedDefaultSprint = false
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func openTicket(_ ticket: Ticket) {
        planTicketID = nil
        selectedTicketID = ticket.id
        searchText = ""
        searchFocused = false
    }

    /// Return opens the best match: the first ticket, else the first pull request.
    private func submitSearch() {
        let hits = SearchHits.find(searchText, in: store)
        if let ticket = hits.tickets.first {
            openTicket(ticket)
        } else if let item = hits.pullRequests.first, let url = URL(string: item.url), url.scheme == "https" {
            NSWorkspace.shared.open(url)
            searchText = ""
        }
    }

    var body: some View {
        NavigationSplitView {
            HStack(spacing: 0) {
                WorkspaceRail()
                sidebarColumn
            }
            .background(Theme.sidebarBackground.ignoresSafeArea())
            .navigationSplitViewColumnWidth(min: 280, ideal: 290)
        } detail: {
            VStack(spacing: 0) {
                NoticeBanner()
                ActiveTimerBar()
                content
            }
            .background(Theme.pageBackground)
            .overlay(alignment: .top) {
                if isSearching {
                    SearchResultsOverlay(query: searchText, openTicket: openTicket) { searchText = "" }
                }
            }
            .inspector(isPresented: inspectorShown) {
                if let id = selectedTicketID {
                    TicketDetailView(ticketID: id) { planTicketID = id }
                        .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
                }
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .overlay(alignment: .top) { TitleBarStrip() }
        .background {
            Button("Search") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                GlobalSearchField(query: $searchText, focused: $searchFocused, onSubmit: submitSearch)
            }
            ToolbarItemGroup {
                Button { showingNewTicket = true } label: { Label("New Ticket", systemImage: "plus") }
                    .keyboardShortcut("n", modifiers: .command)
                    .help("New Ticket (⌘N)")
                Button { Task { await store.syncGitHub() } } label: {
                    if store.syncState == .syncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Sync GitHub", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Sync GitHub (⌘R)")
                .disabled(store.syncState == .syncing)
                if selectedTicketID != nil {
                    Button { selectedTicketID = nil } label: { Label("Close Details", systemImage: "sidebar.trailing") }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                        .help("Close ticket details (⌥⌘I)")
                }
            }
        }
        .sheet(isPresented: $showingNewTicket) {
            NewTicketSheet { selectedTicketID = $0 }
        }
        .onChange(of: selection) { planTicketID = nil }
        .onChange(of: store.activeWorkspace) {
            filter.repo = nil
            selectedTicketID = nil
        }
    }

    private var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                IconTile(symbol: "scope", size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Focus Tracker").font(.system(size: 14, weight: .semibold))
                    Text(store.activeWorkspace.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 10)
            ForEach(SidebarItem.allCases) { item in
                SidebarRow(item: item, selected: (selection ?? .today) == item, badge: badge(for: item)) { selection = item }
            }
            Spacer()
            SyncStatusView().padding(.bottom, 12)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func badge(for item: SidebarItem) -> Int? {
        switch item {
        case .tickets: store.workspaceTickets.filter { $0.status != .done }.count
        case .pullRequests: store.workspacePullRequests.count
        default: nil
        }
    }

    private var inspectorShown: Binding<Bool> {
        Binding(get: { selectedTicketID != nil && planTicketID == nil }, set: { if !$0 { selectedTicketID = nil } })
    }

    @ViewBuilder
    private var content: some View {
        if let id = planTicketID {
            PlanPage(ticketID: id) { planTicketID = nil }
        } else {
            sidebarContent
        }
    }

    @ViewBuilder
    private var sidebarContent: some View {
        switch selection ?? .today {
        case .today: TodayView(selectedTicketID: $selectedTicketID)
        case .tickets:
            filtered { TicketsView(selectedTicketID: $selectedTicketID, filter: filter) }
        case .board:
            filtered { BoardView(selectedTicketID: $selectedTicketID, filter: filter) }
        case .pullRequests: PullRequestsView()
        case .reports: ReportsView()
        }
    }

    private func filtered<Content: View>(@ViewBuilder _ view: () -> Content) -> some View {
        VStack(spacing: 0) {
            FilterBar(filter: $filter)
            Divider()
            view()
        }
        .task(id: store.hasCurrentSprint) { applyDefaultSprint() }
    }

    /// Once per launch, when a current sprint is known, start on it; later changes are the user's.
    private func applyDefaultSprint() {
        guard !appliedDefaultSprint, store.hasCurrentSprint else { return }
        appliedDefaultSprint = true
        if filter.sprint == .any { filter.sprint = .current }
    }
}

struct SyncStatusView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8).padding(.top, 4)
            Group {
                switch store.syncState {
                case .idle: Text("GitHub: not synced yet")
                case .syncing: Text("GitHub: syncing…")
                case .succeeded(let date, let count):
                    Text("GitHub: \(count) assigned · \(date.formatted(date: .omitted, time: .shortened))")
                case .failed(let message):
                    Text(message).foregroundStyle(Theme.danger)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .cardStyle(padding: 10)
    }

    private var color: Color {
        switch store.syncState {
        case .idle: Theme.slate
        case .syncing: Theme.warning
        case .succeeded: Theme.success
        case .failed: Theme.danger
        }
    }
}

struct NoticeBanner: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let notice = store.notice {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill").foregroundStyle(Theme.warning)
                Text(notice).font(.callout)
                Spacer()
                Button("Dismiss") { store.notice = nil }.buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.warning.opacity(0.12))
        }
    }
}

struct TimerBanner: View {
    let symbol: String
    let title: String
    let subtitle: String
    let seconds: TimeInterval
    let gradient: LinearGradient
    let stop: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.title3).symbolEffect(.pulse, isActive: !reduceMotion)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).opacity(0.8)
            }
            Spacer()
            Text(Format.clock(seconds)).font(.title2.weight(.semibold).monospacedDigit())
            Button(action: stop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 32, height: 32)
                    .background(.white.opacity(0.22), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Stop timer")
            .accessibilityLabel("Stop")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(gradient)
    }
}

struct ActiveTimerBar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if let entry = store.activeEntry, let ticket = store.ticket(entry.ticketID) {
            TimerBanner(
                symbol: "record.circle.fill", title: ticket.title, subtitle: ticket.displayKey,
                seconds: entry.duration(at: store.now), gradient: Theme.accentGradient
            ) { store.stop() }
        } else if let activity = store.activeActivity {
            TimerBanner(
                symbol: activity.kind.symbol, title: activity.title, subtitle: activity.kind.title,
                seconds: activity.duration(at: store.now), gradient: Theme.activityGradient
            ) { store.stopActivity() }
        }
    }
}

struct NewTicketSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var priority: Priority = .none
    var onCreate: (UUID) -> Void

    var body: some View {
        Form {
            Section { Text("New Ticket").font(.title2.weight(.bold)) }
            TextField("Title", text: $title)
            Picker("Priority", selection: $priority) {
                ForEach(Priority.allCases) { Text($0.title).tag($0) }
            }
            HStack {
                Spacer()
                Button(role: .cancel) { dismiss() } label: { ShortcutLabel(title: "Cancel", keys: "⎋") }
                    .keyboardShortcut(.cancelAction)
                Button {
                    let ticket = store.addTicket(title: title.trimmingCharacters(in: .whitespaces), priority: priority)
                    onCreate(ticket.id)
                    dismiss()
                } label: { ShortcutLabel(title: "Create", keys: "↩") }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}
