import AppKit
import FocusCore
import SwiftUI

/// Shows `content` only while the license is active; otherwise the sign-in or lock screen.
struct LicenseGate<Content: View>: View {
    @Environment(LicenseStore.self) private var license
    @ViewBuilder let content: () -> Content

    var body: some View {
        if license.isActive {
            content()
        } else {
            LicenseLockView()
        }
    }
}

struct LicenseLockView: View {
    @Environment(LicenseStore.self) private var license

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Theme.accent)
            switch license.state {
            case .checking, .active:
                ProgressView("Checking your subscription…")
            case .signedOut:
                SignInForm()
            case .suspended:
                lockMessage(
                    title: "Subscription suspended",
                    detail: "Your subscription is suspended. Contact the administrator. Your data is kept and will be here when access is restored."
                )
            case .unreachable:
                lockMessage(
                    title: "Can't verify your subscription",
                    detail: license.isConfigured
                        ? "Can't reach the license server. Check your internet connection and try again."
                        : "This build has no Firebase API key. Rebuild with FIREBASE_API_KEY set."
                )
            }
        }
        .padding(32)
        .frame(maxWidth: 380, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }

    private var icon: String {
        switch license.state {
        case .suspended: "lock.fill"
        case .unreachable: "wifi.exclamationmark"
        default: "lock.shield"
        }
    }

    private func lockMessage(title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("Retry") { Task { await license.check() } }
                    .buttonStyle(.borderedProminent)
                Button("Sign out") { license.signOut() }
            }
        }
    }
}

private struct SignInForm: View {
    @Environment(LicenseStore.self) private var license
    @State private var email = ""
    @State private var password = ""
    @State private var message: String?
    @State private var busy = false

    private var canSubmit: Bool { !email.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !busy }

    var body: some View {
        VStack(spacing: 12) {
            Text("Sign in to Focus Tracker").font(.title3.weight(.semibold))
            TextField("Email", text: $email)
                .textContentType(.username)
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await signIn() } }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            Button("Sign in") { Task { await signIn() } }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            Button("Forgot password") { Task { await reset() } }
                .buttonStyle(.link)
                .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty || busy)
        }
    }

    private func signIn() async {
        guard canSubmit else { return }
        busy = true
        message = await license.signIn(email: email, password: password)
        busy = false
    }

    private func reset() async {
        busy = true
        message = await license.resetPassword(email: email) ?? "If that account exists, a password reset email is on its way."
        busy = false
    }
}

/// Menu bar popover while the app is locked.
struct LockedMenuView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Focus Tracker is locked", systemImage: "lock.fill").font(.headline)
            Text("Open the app to sign in or check your subscription.").font(.caption).foregroundStyle(.secondary)
            Button("Open Focus Tracker") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 280)
    }
}
