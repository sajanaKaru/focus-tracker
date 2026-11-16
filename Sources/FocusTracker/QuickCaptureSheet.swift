import FocusCore
import SwiftUI

struct QuickCaptureSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var kind: QuickCaptureKind = .bug
    @State private var title = ""

    private var canStart: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        SheetScaffold(title: "Unplanned work") {
            Form {
                Picker("Type", selection: $kind) {
                    ForEach(QuickCaptureKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)

                TextField("Title", text: $title, prompt: Text("e.g. Login fails on Safari"))
            }
        } footer: {
            Button(role: .cancel) { dismiss() } label: { ShortcutLabel(title: "Cancel", keys: "⎋") }
                .buttonStyle(.secondary)
                .keyboardShortcut(.cancelAction)
            Button(action: start) { ShortcutLabel(title: "Start timer", keys: "↩") }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
        }
        .onAppear { kind = store.role.profile.captureKind }
    }

    private func start() {
        store.addQuickCapture(kind: kind, title: title)
        dismiss()
    }
}
