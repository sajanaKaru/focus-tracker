# Modern UI Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give every screen a modern, consistent look (indigo/violet accent, soft cards, gradient highlights, subtle motion) while keeping the native macOS structure.

**Architecture:** `Theme.swift` becomes the single source of design tokens; a new `DesignSystem.swift` holds shared styles (color helpers, button styles, icon tile, hover lift, round checkbox). Existing helpers (`cardStyle`, `Chip`, `StatCard`, `SectionTitle`, `PageHeader`) keep their names and signatures and take the new look, so most call sites stay unchanged. Screens are then updated in the order of the spec.

**Tech Stack:** SwiftUI (macOS 14+), AppKit dynamic colors, Swift Charts. Swift 5.9 language mode.

**Spec:** `docs/superpowers/specs/2026-10-09-modern-ui-refresh-design.md`

## Global Constraints

- Accent: indigo `#6366F1` to violet `#8B5CF6`. Status: Backlog `#94A3B8`, Todo `#3B82F6`, In Progress `#F59E0B`, In Review `#8B5CF6`, Done `#10B981`. Danger `#F43F5E`, orange `#F97316`, teal `#14B8A6`.
- Surfaces: page background light `#F6F6FB` / dark `#14141C`; card background light `#FFFFFF` / dark `#1C1C26`.
- Cards: radius 16, hairline border, soft shadow in light mode, none in dark mode.
- Views use tokens (`Theme.*`), never raw `.red`, `.orange`, `.purple`, `.green`, `Color.accentColor`.
- Motion is disabled when `accessibilityReduceMotion` is on.
- No layout or information changes, no new features, native title bar/toolbar stay, no app icon change.
- No git repo: "checkpoint" steps run `swift test` and `./scripts/build-app.sh` instead of committing.
- Existing tests (`swift test`) must keep passing. There are no unit tests for styling; each task is verified by building and looking at the app.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/FocusTracker/DesignSystem.swift` (new) | `Color(hex:)`, `Color.adaptive`, `PrimaryButtonStyle`, `SecondaryButtonStyle`, `IconTile`, `HoverLift`, `RoundCheckStyle` |
| `Sources/FocusTracker/Theme.swift` (modify) | tokens, status/priority colors, card style, chips, stat card, page chrome |
| `Sources/FocusTracker/FocusTrackerApp.swift` (modify) | app-wide tint |
| `Sources/FocusTracker/RootView.swift` (modify) | sidebar, sync card, notice banner, timer banner |
| `Sources/FocusTracker/TodayView.swift`, `DayPlanCard.swift` (modify) | Today screen |
| `Sources/FocusTracker/TicketsView.swift`, `BoardView.swift`, `FilterBar.swift` (modify) | tickets, board, filters |
| `Sources/FocusTracker/ReportsView.swift`, `TicketDetailView.swift`, `PlanView.swift` (modify) | reports, inspector, plan page |
| `Sources/FocusTracker/MenuBarView.swift` (modify) | menu bar popover |

Build check used by every task: `swift build 2>&1 | tail -5` (expected: `Build complete!`).

---

### Task 1: Tokens, shared styles, app-wide tint

**Files:**
- Create: `Sources/FocusTracker/DesignSystem.swift`
- Modify: `Sources/FocusTracker/Theme.swift`, `Sources/FocusTracker/FocusTrackerApp.swift`
- Modify (mechanical rename): `FilterBar.swift`, `MenuBarView.swift`, `PlanView.swift`, `ReportsView.swift`, `TicketsView.swift`, `DayPlanCard.swift`, `TodayView.swift`

**Interfaces:**
- Produces:
  - `Color.init(hex: UInt32)`, `Color.adaptive(light: UInt32, dark: UInt32) -> Color`
  - `Theme.accent`, `accentEnd`, `success`, `warning`, `danger`, `info`, `orange`, `teal`, `slate` (`Color`); `Theme.accentGradient`, `warningGradient`, `activityGradient` (`LinearGradient`); `Theme.pageBackground`, `cardBackground` (`Color`); `Theme.radius: CGFloat = 16`
  - `ButtonStyle` statics: `.primary` (`PrimaryButtonStyle`), `.secondary` (`SecondaryButtonStyle`)
  - `IconTile(symbol: String, tint: Color = Theme.accent, size: CGFloat = 40)`
  - `View.hoverLift()`
  - `RoundCheckStyle: ToggleStyle`

- [ ] **Step 1: Create `DesignSystem.swift`**

```swift
import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// Resolves to `light` or `dark` with the effective appearance.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var gradient = Theme.accentGradient

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(gradient, in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06), in: Capsule())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

struct IconTile: View {
    let symbol: String
    var tint: Color = Theme.accent
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [tint, tint.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            )
    }
}

struct HoverLift: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .offset(y: hovering && !reduceMotion ? -1 : 0)
            .shadow(color: .black.opacity(hovering ? 0.10 : 0), radius: 8, y: 3)
            .animation(reduceMotion ? nil : .spring(duration: 0.25), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    func hoverLift() -> some View { modifier(HoverLift()) }
}

struct RoundCheckStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(configuration.isOn ? Theme.accent : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: Replace the `Theme` enum and status/priority colors in `Theme.swift`**

Replace the two `extension TicketStatus { var color ... }` / `extension Priority { var color ... }` blocks and the `enum Theme { ... }` block with:

```swift
extension TicketStatus {
    var color: Color {
        switch self {
        case .backlog: Theme.slate
        case .todo: Theme.info
        case .inProgress: Theme.warning
        case .inReview: Theme.accentEnd
        case .done: Theme.success
        }
    }
}

extension Priority {
    var color: Color {
        switch self {
        case .none: Theme.slate
        case .low: Theme.teal
        case .medium: Theme.warning
        case .high: Theme.orange
        case .urgent: Theme.danger
        }
    }
}

enum Theme {
    static let accent = Color(hex: 0x6366F1)
    static let accentEnd = Color(hex: 0x8B5CF6)
    static let success = Color(hex: 0x10B981)
    static let warning = Color(hex: 0xF59E0B)
    static let danger = Color(hex: 0xF43F5E)
    static let info = Color(hex: 0x3B82F6)
    static let orange = Color(hex: 0xF97316)
    static let teal = Color(hex: 0x14B8A6)
    static let slate = Color(hex: 0x94A3B8)

    static let accentGradient = LinearGradient(colors: [Theme.accent, Theme.accentEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let warningGradient = LinearGradient(colors: [Theme.warning, Theme.orange], startPoint: .leading, endPoint: .trailing)
    static let activityGradient = LinearGradient(colors: [Theme.teal, Color(hex: 0x06B6D4)], startPoint: .topLeading, endPoint: .bottomTrailing)

    static let pageBackground = Color.adaptive(light: 0xF6F6FB, dark: 0x14141C)
    static let cardBackground = Color.adaptive(light: 0xFFFFFF, dark: 0x1C1C26)
    static let radius: CGFloat = 16
}
```

- [ ] **Step 3: Replace `cardStyle` with a modifier**

Replace the `extension View { func cardStyle ... }` block with:

```swift
private struct CardStyle: ViewModifier {
    var padding: CGFloat
    var selected: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
        content
            .padding(padding)
            .background(Theme.cardBackground, in: shape)
            .background(selected ? Theme.accent.opacity(0.07) : Color.clear, in: shape)
            .overlay(shape.strokeBorder(selected ? Theme.accent : Color.primary.opacity(0.07), lineWidth: selected ? 1.5 : 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06), radius: 10, y: 4)
    }
}

extension View {
    func cardStyle(padding: CGFloat = 14, selected: Bool = false) -> some View {
        modifier(CardStyle(padding: padding, selected: selected))
    }
}
```

- [ ] **Step 4: Restyle `Chip` (tinted pill with a dot when it has no symbol)**

Replace the body of `struct Chip` with:

```swift
    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).imageScale(.small)
            } else {
                Circle().fill(color).frame(width: 6, height: 6)
            }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }
```

- [ ] **Step 5: Move remaining raw colors in `Theme.swift` to tokens**

- `MetaChips`: `milestone.isOpen ? .indigo : .gray` -> `milestone.isOpen ? Theme.accent : Theme.slate`; sprint chip `? .teal : .gray` -> `? Theme.teal : Theme.slate`.
- `FieldChip` `.iteration` case: `? .teal : .gray` -> `? Theme.teal : Theme.slate`.
- `GitHubColor.color`: `"gray","grey"` -> `Theme.slate`, `"blue"` -> `Theme.info`, `"green"` -> `Theme.success`, `"orange"` -> `Theme.orange`, `"red"` -> `Theme.danger`, `"purple"` -> `Theme.accentEnd` (keep `pink`, `yellow`, hex default).
- `GitHubColor.priority`: `.red` -> `Theme.danger`, `.orange` -> `Theme.orange`, `.teal` -> `Theme.teal` (keep the existing yellow-brown medium).

- [ ] **Step 6: Replace `Color.accentColor` everywhere and set the tint**

Run:

```sh
cd "/Volumes/Dev/My Projects/focus-tracker"
sed -i '' 's/Color\.accentColor\.gradient/Theme.accentGradient/g; s/Color\.accentColor/Theme.accent/g' Sources/FocusTracker/*.swift
grep -n "accentColor" Sources/FocusTracker/*.swift
```

For each remaining match replace `.accentColor` with `Theme.accent` (expected: `StatCard` default `tint: Color = .accentColor` in `Theme.swift`, `TodayView.swift` `tint: .accentColor`, `ReportsView.swift` `tint: .accentColor`, `DayPlanCard.swift` `.tint(over ? .orange : .accentColor)` which becomes `.tint(over ? Theme.warning : Theme.accent)`). Re-run the grep; expected: no output.

In `FocusTrackerApp.swift` add `.tint(Theme.accent)` after `.environment(store)` on `RootView()`, `MenuBarView()` and `SettingsView()`:

```swift
            RootView()
                .environment(store)
                .tint(Theme.accent)
                .frame(minWidth: 960, minHeight: 600)
```
```swift
            MenuBarView().environment(store).tint(Theme.accent)
```
```swift
            SettingsView().environment(store).tint(Theme.accent)
```

- [ ] **Step 7: Build and checkpoint**

Run: `swift build 2>&1 | tail -5` — expected `Build complete!`.
Run: `swift test 2>&1 | grep -E "error:|Executed .* tests" | tail -2` — expected 0 failures.
Run: `./scripts/build-app.sh 2>&1 | tail -2 && open build/FocusTracker.app`. Expected: buttons/toggles use indigo, cards are rounder and softer, chips are tinted pills, status colors are the new palette.

---

### Task 2: Sidebar and page chrome

**Files:**
- Modify: `Sources/FocusTracker/RootView.swift` (`RootView.body` sidebar, `SyncStatusView`, `NoticeBanner`)

**Interfaces:**
- Consumes: `IconTile`, `Theme.*` from Task 1.
- Produces: `SidebarRow` (private to `RootView.swift`).

- [ ] **Step 1: Replace the sidebar `List` in `RootView.body`**

Replace

```swift
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .font(.body.weight(.medium))
                    .padding(.vertical, 3)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .safeAreaInset(edge: .bottom) { SyncStatusView().padding(10) }
```

with

```swift
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    IconTile(symbol: "scope", size: 28)
                    Text("Focus Tracker").font(.headline)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
                ForEach(SidebarItem.allCases) { item in
                    SidebarRow(item: item, selected: (selection ?? .today) == item) { selection = item }
                }
                Spacer()
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .bottom) { SyncStatusView().padding(12) }
```

- [ ] **Step 2: Add `SidebarRow` below `SidebarItem`**

```swift
private struct SidebarRow: View {
    let item: SidebarItem
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? Color.white : Theme.accent)
                    .frame(width: 26, height: 26)
                    .background(
                        selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.accent.opacity(0.12)),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                Text(item.rawValue).font(.body.weight(selected ? .semibold : .medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.12) : Color.primary.opacity(hovering ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
```

- [ ] **Step 3: Restyle `SyncStatusView` and `NoticeBanner`**

In `SyncStatusView`: replace `Text(message).foregroundStyle(.red)` with `Text(message).foregroundStyle(Theme.danger)`; replace `.padding(10)` + `.background(Color.primary.opacity(0.05), in: ...)` with `.cardStyle(padding: 10)`; replace the `color` mapping with `.idle: Theme.slate`, `.syncing: Theme.warning`, `.succeeded: Theme.success`, `.failed: Theme.danger`.

In `NoticeBanner`: `Image(systemName: "info.circle.fill").foregroundStyle(Theme.warning)` and `.background(Theme.warning.opacity(0.12))`.

- [ ] **Step 4: Build and look**

Run: `swift build 2>&1 | tail -5` — expected `Build complete!`. Then `./scripts/build-app.sh && open build/FocusTracker.app`. Expected: the sidebar has the app logo, rows with tinted icon tiles and a selected pill, and a sync card at the bottom; clicking rows switches screens.
If the sidebar column looks flat (no translucency), add `.background(.regularMaterial)` to the sidebar `VStack` and rebuild.

- [ ] **Step 5: Checkpoint**

Run: `swift test 2>&1 | grep -E "error:|Executed .* tests" | tail -2` — expected 0 failures.

---

### Task 3: Today — stat cards, timer bar, Plan card

**Files:**
- Modify: `Sources/FocusTracker/Theme.swift` (`StatCard`), `Sources/FocusTracker/RootView.swift` (`ActiveTimerBar`), `Sources/FocusTracker/DayPlanCard.swift`, `Sources/FocusTracker/TodayView.swift`

**Interfaces:**
- Consumes: `IconTile`, `HoverLift`, `RoundCheckStyle`, `SecondaryButtonStyle`, `Theme.*`.
- Produces: `TimerBanner` (in `RootView.swift`, also used by Task 6 pattern).

- [ ] **Step 1: Restyle `StatCard` body in `Theme.swift`**

```swift
    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.title2.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .hoverLift()
    }
```

- [ ] **Step 2: Replace `ActiveTimerBar` with a shared `TimerBanner`**

In `RootView.swift` replace the whole `ActiveTimerBar` struct with:

```swift
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
```

- [ ] **Step 3: Restyle the Plan card (`DayPlanCard.swift`)**

Add `@Environment(\.accessibilityReduceMotion) private var reduceMotion` next to the other properties.

Replace the `ProgressView(...)` + `.tint(...)` lines with `capacityBar(planned: planned, capacity: capacity.capacityMinutes, over: over)` and add:

```swift
    private func capacityBar(planned: Int, capacity: Int, over: Bool) -> some View {
        let fraction = min(Double(planned) / Double(max(capacity, 1)), 1)
        return GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(over ? Theme.warningGradient : Theme.accentGradient)
                    .frame(width: planned > 0 ? max(8, proxy.size.width * fraction) : 0)
            }
        }
        .frame(height: 8)
        .animation(reduceMotion ? nil : .spring(duration: 0.35), value: planned)
        .accessibilityElement()
        .accessibilityLabel("Planned \(text(planned)) of \(text(capacity)) capacity")
    }
```

Change `.foregroundStyle(over ? .orange : .primary)` to `.foregroundStyle(over ? Theme.warning : Color.primary)`, the over-capacity label's `.foregroundStyle(.orange)` to `.foregroundStyle(Theme.warning)`, add `.toggleStyle(RoundCheckStyle())` after `.labelsHidden()` in `row`, add `.buttonStyle(.secondary)` to the "Re-suggest" button, and replace the `PlanReason.color` mapping with:

```swift
        case .dueNow: Theme.danger
        case .dueSoon: Theme.orange
        case .sprintEnding: Theme.teal
        case .carriedOver: Theme.accentEnd
        case .inProgress: Theme.info
        case .priority: Theme.warning
        case .open: Theme.slate
```

- [ ] **Step 4: Today screen (`TodayView.swift`)**

Change the three `StatCard` tints to `tint: Theme.accent`, `tint: Theme.warning` (Active tickets) and `tint: Theme.accentEnd` (Calls & meetings). Add `.buttonStyle(.secondary)` to the "Copy today's summary" button (keep `.controlSize(.large)`) and to the "Today" jump button in `dayNavigator`. Add `.hoverLift()` after `.cardStyle(padding: 10, selected: ...)` on the in-progress ticket cards.

- [ ] **Step 5: Build, test, look**

Run: `swift build 2>&1 | tail -5` — expected `Build complete!`.
Run: `swift test 2>&1 | grep -E "error:|Executed .* tests" | tail -2` — expected 0 failures.
Run: `./scripts/build-app.sh && open build/FocusTracker.app`. Expected on Today: gradient icon tiles on stat cards, gradient capacity bar that turns amber when over, round checkboxes, and a gradient timer bar with a round stop button after starting a timer.

---

### Task 4: Tickets list, Board, filters

**Files:**
- Modify: `Sources/FocusTracker/TicketsView.swift`, `Sources/FocusTracker/BoardView.swift`, `Sources/FocusTracker/FilterBar.swift`

**Interfaces:**
- Consumes: `cardStyle`, `hoverLift`, `Theme.*`.

- [ ] **Step 1: Tickets list as grouped cards**

In `TicketsView.body`, replace the `List(selection: $selectedTicketID) { ... }` block and its `.listStyle(.inset)` / `.scrollContentBackground(.hidden)` lines with:

```swift
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(TicketStatus.allCases.reversed().filter { $0 != .done } + [.done]) { status in
                    let group = visible.filter { $0.status == status }.sorted { $0.updatedAt > $1.updatedAt }
                    if !group.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Circle().fill(status.color).frame(width: 8, height: 8)
                                Text(status.title).font(.subheadline.weight(.semibold))
                                Text("\(group.count)").font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                            }
                            ForEach(group) { ticket in
                                TicketRow(ticket: ticket)
                                    .cardStyle(padding: 10, selected: selectedTicketID == ticket.id)
                                    .hoverLift()
                                    .onTapGesture { selectedTicketID = ticket.id }
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
```

Keep the existing `.background(Theme.pageBackground)`, `.overlay`, `.searchable` and `.toolbar` modifiers that follow. Replace `TimerButton`'s `Color.red` uses with `Theme.danger`.

- [ ] **Step 2: Board lanes and cards**

In `BoardView.column`: change the lane shape radius to 18, the lane background to `targeted ? status.color.opacity(0.14) : status.color.opacity(0.06)`, and add `.hoverLift()` after `.cardStyle(padding: 12, selected: ...)` in `card`.

- [ ] **Step 3: Filter pills**

In `FilterLabel.body` replace the two `.foregroundStyle`/`.background` lines with:

```swift
            .foregroundStyle(active ? Theme.accent : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(active ? Theme.accent.opacity(0.12) : Theme.cardBackground, in: Capsule())
            .overlay(Capsule().strokeBorder(active ? Theme.accent.opacity(0.35) : Color.primary.opacity(0.08)))
```

(remove the original `.padding(.horizontal, 10)` / `.padding(.vertical, 4)` so they are not duplicated).

- [ ] **Step 4: Build, test, look**

Run: `swift build 2>&1 | tail -5` — expected `Build complete!`; `swift test` — 0 failures. Open the app: Tickets shows grouped cards with hover lift and an accent border on the selected card; searching and "Show done" still work; Board lanes are tinted by status and drag-and-drop between lanes still moves tickets.

---

### Task 5: Reports, ticket detail, Plan page

**Files:**
- Modify: `Sources/FocusTracker/ReportsView.swift`, `Sources/FocusTracker/TicketDetailView.swift`, `Sources/FocusTracker/PlanView.swift`, `Sources/FocusTracker/TimeLogViews.swift`

- [ ] **Step 1: Reports**

- Stat tints: `tint: Theme.accent`, `tint: Theme.teal`, `tint: Theme.success`.
- Copy button: replace `.buttonStyle(.borderedProminent)` with `.buttonStyle(.primary)` (keep `.controlSize(.large)`).
- Chart bars: `.foregroundStyle(Theme.accentGradient)` (already set by Task 1's sed).
- Per-ticket bar: `Capsule().fill(Theme.accentGradient)` replacing `Theme.accent.opacity(0.8)`.

- [ ] **Step 2: Remaining raw colors in detail and plan screens**

- `TicketDetailView.swift:28` `.foregroundStyle(.orange)` -> `Theme.warning`; `:75` `? .red : .secondary` -> `? Theme.danger : Color.secondary`.
- `PlanView.swift:89` `.foregroundStyle(.green)` -> `Theme.success`.
- `TimeLogViews.swift:49` `.foregroundStyle(.orange)` -> `Theme.warning`.

- [ ] **Step 3: Build, test, look**

Run: `swift build 2>&1 | tail -5` — expected `Build complete!`; `swift test` — 0 failures. Open Reports, a ticket's detail inspector and a Plan page: colors match the new palette, charts use the gradient.

---

### Task 6: Menu bar popover and Settings

**Files:**
- Modify: `Sources/FocusTracker/MenuBarView.swift`

- [ ] **Step 1: Replace the two timer `VStack` blocks**

Add `@Environment(\.accessibilityReduceMotion) private var reduceMotion` to `MenuBarView`. Replace the `if let entry ... else if let activity ... else { ... }` timer section with:

```swift
            if let entry = store.activeEntry, let ticket = store.ticket(entry.ticketID) {
                timerCard(
                    symbol: "record.circle.fill", label: "Tracking", title: ticket.title, subtitle: ticket.displayKey,
                    seconds: entry.duration(at: store.now), gradient: Theme.accentGradient
                ) { store.stop() }
            } else if let activity = store.activeActivity {
                timerCard(
                    symbol: activity.kind.symbol, label: activity.kind.title, title: activity.title, subtitle: nil,
                    seconds: activity.duration(at: store.now), gradient: Theme.activityGradient
                ) { store.stopActivity() }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "timer").foregroundStyle(.secondary)
                    Text("No timer running").foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
            }
```

and add to `MenuBarView`:

```swift
    private func timerCard(
        symbol: String, label: String, title: String, subtitle: String?,
        seconds: TimeInterval, gradient: LinearGradient, stop: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol).symbolEffect(.pulse, isActive: !reduceMotion)
                Text(label).font(.caption.weight(.semibold))
            }
            Text(title).font(.headline).lineLimit(2)
            if let subtitle { Text(subtitle).font(.caption).opacity(0.8) }
            HStack {
                Text(Format.clock(seconds)).font(.title.weight(.semibold).monospacedDigit())
                Spacer()
                Button(action: stop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 32, height: 32)
                        .background(.white.opacity(0.22), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop")
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(gradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
```

- [ ] **Step 2: Build, test, look**

Run: `swift build 2>&1 | tail -5` — expected `Build complete!`. Open the app, start a timer, and open the menu bar popover: a gradient timer card with a round stop button; the Settings window (⌘,) uses the indigo tint.

---

### Task 7: Cleanup and full pass

**Files:**
- Modify: `Sources/FocusTracker/ActivityViews.swift` and any file the sweep still reports

- [ ] **Step 1: Sweep for raw colors**

Run:

```sh
cd "/Volumes/Dev/My Projects/focus-tracker"
grep -nE "\.(red|orange|purple|green|blue|teal|yellow|indigo)\b|accentColor" Sources/FocusTracker/*.swift | grep -v "Theme.swift"
```

Expected leftovers: `ActivityViews.swift:202` `Chip(... color: .green ...)` -> `Theme.success`; `:249` and `:251` `.purple` -> `Theme.accentEnd`. Replace each and re-run until the output is empty. (`Theme.swift` keeps `pink`/`yellow` in `GitHubColor` for GitHub label colors on purpose.)

- [ ] **Step 2: Full verification**

Run: `swift test 2>&1 | grep -E "error:|Executed .* tests" | tail -2` — expected 0 failures.
Run: `./scripts/build-app.sh 2>&1 | tail -2` — expected `Built build/FocusTracker.app`.

- [ ] **Step 3: Manual light/dark pass**

Run `open build/FocusTracker.app` and check each screen (Today, Tickets, Board, Reports, ticket inspector, Plan page, menu bar popover, Settings) in light mode and in dark mode (System Settings > Appearance), with Reduce Motion on and off (System Settings > Accessibility > Display), and with the window at its 960px minimum width. Expected: readable contrast, no leftover system blue/red/orange, no animations with Reduce Motion on.

---

## Self-Review

- **Spec coverage:** tokens/palette/surfaces/card/chip (Task 1); sidebar with icon tiles, selection pill, sync card (Task 2); stat cards, timer bar, Plan card with gradient capsule and round checkboxes (Task 3); ticket rows, board lanes and cards, filter pills (Task 4); Reports, detail, Plan page (Task 5); menu bar popover and Settings tint (Tasks 1 and 6); raw-color cleanup and light/dark/Reduce Motion pass (Task 7); gradient primary button and quiet secondary button (Tasks 1, 3, 5).
- **Rulings:** the sidebar becomes custom rows (loses arrow-key list navigation; ⌘ shortcuts unchanged), and the Tickets list becomes cards (loses `List` keyboard selection, matching how Today's in-progress cards already work). Both follow the spec's "custom rows" and "ticket rows" direction.
- **Placeholders:** none.
- **Name consistency:** `Theme.accent/accentEnd/success/warning/danger/info/orange/teal/slate`, `accentGradient/warningGradient/activityGradient`, `IconTile`, `hoverLift()`, `RoundCheckStyle`, `.primary`/`.secondary` button styles, `TimerBanner` are used identically across tasks.
