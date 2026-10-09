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
            HStack(spacing: 4) {
                Image(systemName: store.activeEntry == nil && store.activeActivity == nil ? "timer" : "record.circle.fill")
                if store.activeEntry != nil || store.activeActivity != nil { Text(store.menuBarTitle).monospacedDigit() }
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(store).tint(Theme.accent)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
