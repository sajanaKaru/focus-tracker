# Modern UI Refresh — Design

## Goal

Make the app look modern while keeping the native macOS feel: a polished, consistent visual language applied across every screen, driven by shared design tokens.

## Scope

In: color palette, gradients, surfaces, cards, chips, buttons, sidebar, stat cards, timer bar, ticket rows, board, Plan card, Reports, ticket detail, Plan page, menu bar popover, Settings, light and dark mode, subtle motion.

Out: layout or information changes, new features, custom window chrome (native title bar and toolbar stay), app icon.

## Design tokens (`Theme.swift`, single source of truth)

- Accent: indigo `#6366F1` to violet `#8B5CF6`. Applied app-wide with `.tint(Theme.accent)` on the root view, the menu bar popover and Settings. A gradient variant is used for the timer bar, capacity bar and primary buttons.
- Status colors: Backlog slate `#94A3B8`, Todo blue `#3B82F6`, In Progress amber `#F59E0B`, In Review violet `#8B5CF6`, Done green `#10B981`.
- Priority colors: Low teal, Medium amber, High orange, Urgent rose.
- Surfaces (adaptive via dynamic colors): page background light `#F6F6FB` / dark `#14141C`; card background light white / dark `#1C1C26`.
- Cards: corner radius 16, hairline border, soft diffuse shadow in light mode and none in dark mode.
- Chips and badges: tinted pill with a small colored dot.

## Elements

- Sidebar: keeps the translucent macOS material; custom rows with a tinted icon tile and a rounded accent selection pill; sync status becomes a compact card.
- Stat cards (Today, Reports): icon in a gradient rounded tile, large number, small caption, subtle hover lift.
- Active timer bar: gradient bar, softly pulsing dot, large monospaced clock, round stop button.
- Ticket rows and board cards: status dot, title, tinted chips; faint hover highlight; selected = accent border plus tint. Board columns are rounded tinted lanes with a colored header dot and count.
- Plan card: gradient capsule capacity bar that shifts to amber/orange when over capacity; round checkboxes; reason chips use the status palette.
- Buttons and filters: gradient prominent style for primary actions, quiet rounded style for secondary; filter pills match the chip style.
- Menu bar popover: same cards and a gradient timer header.
- Motion: short spring animations on hover and selection, disabled when macOS Reduce Motion is on.

## Implementation approach

- Shared styles live in `Theme.swift` (or a new file next to it if it grows too large): primary button style, stat card, status pill, hover effect. Views use these and never raw colors.
- Existing helpers (`cardStyle`, `Chip`, `StatCard`, `SectionTitle`, `StatusBadge`, `PriorityBadge`) keep their names and signatures and take on the new look, so most call sites do not change.
- Replace remaining hard-coded `Color.accentColor`, `.orange`, `.red` uses with tokens (found in `BoardView`, `DayPlanCard`, `FilterBar`, `MenuBarView`, `PlanView`, `ReportsView`, `TicketsView`, `TodayView`).
- Status and priority color mapping stays a plain lookup (`TicketStatus.color`, `Priority.color`).

## Order of work

1. Tokens, shared styles, app-wide tint.
2. Sidebar and page/header chrome.
3. Today: stat cards, timer bar, Plan card.
4. Tickets list and Board.
5. Reports, ticket detail inspector, Plan page.
6. Menu bar popover and Settings.
7. Cleanup of leftover raw colors, then a full light/dark pass.

Each step must build and leave the app usable.

## Testing

No unit tests for pure styling. Verify by building and running the app: every screen in light and dark mode, Reduce Motion on and off, and the 960px minimum window width. Existing tests (`swift test`) must keep passing.
