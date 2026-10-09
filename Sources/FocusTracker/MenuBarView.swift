import AppKit
import FocusCore
import SwiftUI

struct MenuBarView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var capturing = false
    @State private var captureKind: QuickCaptureKind = .bug
    @State private var captureTitle = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            let candidates = store.tickets
                .filter { $0.status == .inProgress || $0.status == .todo }
                .filter { !store.isTracking($0.id) }
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(6)

            if !candidates.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("START")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 2)
                    ForEach(Array(candidates)) { ticket in
                        Button { store.start(ticket.id) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill").font(.caption).foregroundStyle(Theme.accent)
                                Text(ticket.title).lineLimit(1)
                                Spacer()
                            }
                        }
                        .buttonStyle(HoverRowStyle())
                    }
                }
            }

            Button { capturing.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill").font(.caption).foregroundStyle(Theme.warning)
                    Text("Unplanned work")
                    Spacer()
                    Image(systemName: capturing ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(HoverRowStyle())

            if capturing {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Type", selection: $captureKind) {
                        ForEach(QuickCaptureKind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    TextField("What came up?", text: $captureTitle)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(startCapture)
                    Button("Start timer", action: startCapture)
                        .buttonStyle(.primary)
                        .disabled(captureTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, 4)
            }

            Divider()
            HStack {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                        window.makeKeyAndOrderFront(nil)
                    } else {
                        openWindow(id: "main")
                    }
                } label: { Label("Open App", systemImage: "macwindow") }
                Button { Task { await store.syncGitHub() } } label: { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 320)
    }

    private func startCapture() {
        guard store.addQuickCapture(kind: captureKind, title: captureTitle) != nil else { return }
        captureTitle = ""
        capturing = false
    }

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
}
