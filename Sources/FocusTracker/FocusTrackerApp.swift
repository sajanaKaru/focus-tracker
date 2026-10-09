import AppKit
import FocusCore
import SwiftUI

@main
struct FocusTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup("Focus Tracker", id: "main") {
            RootView()
                .environment(store)
                .tint(Theme.accent)
                .frame(minWidth: 960, minHeight: 600)
                .task { store.startAutoSync() }
        }

        MenuBarExtra {
            MenuBarView().environment(store).tint(Theme.accent)
        } label: {
            MenuBarLabel(delegate: delegate).environment(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(store).tint(Theme.accent)
        }
    }
}

/// Always alive while the app runs, so it hands the delegate a way to reopen the main window after it was closed.
private struct MenuBarLabel: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let delegate: AppDelegate

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: store.activeEntry == nil && store.activeActivity == nil ? "timer" : "record.circle.fill")
            if store.activeEntry != nil || store.activeActivity != nil { Text(store.menuBarTitle).monospacedDigit() }
        }
        .task { delegate.openMainWindow = { openWindow(id: "main") } }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var openMainWindow: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        if let minimized = NSApp.windows.first(where: { $0.isMiniaturized }) {
            minimized.deminiaturize(nil)
        } else {
            openMainWindow?()
        }
        NSApp.activate(ignoringOtherApps: true)
        return false
    }
}
