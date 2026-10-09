import FocusCore
import SwiftUI

struct QuickCaptureSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var kind: QuickCaptureKind = .bug
    @State private var title = ""

    private var canStart: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        Form {
            Section { Text("Unplanned work").font(.title2.weight(.bold)) }

            Picker("Type", selection: $kind) {
                ForEach(QuickCaptureKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)

            TextField("Title", text: $title, prompt: Text("e.g. Login fails on Safari"))

            HStack {
                Spacer()
                Button(role: .cancel) { dismiss() } label: { ShortcutLabel(title: "Cancel", keys: "⎋") }
                    .keyboardShortcut(.cancelAction)
                Button(action: start) { ShortcutLabel(title: "Start timer", keys: "↩") }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding()
    }

    private func start() {
        store.addQuickCapture(kind: kind, title: title)
        dismiss()
    }
}
