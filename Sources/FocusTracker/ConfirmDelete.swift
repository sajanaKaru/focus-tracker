import SwiftUI

extension View {
    /// Asks before running a destructive action; the dialog's confirm button is red and Cancel leaves everything as it was.
    func confirmDestructive(
        _ isPresented: Binding<Bool>, title: String, message: String? = "This can't be undone.",
        confirmLabel: String = "Delete", action: @escaping () -> Void
    ) -> some View {
        confirmationDialog(title, isPresented: isPresented, titleVisibility: .visible) {
            Button(confirmLabel, role: .destructive, action: action)
            Button("Cancel", role: .cancel) {}
        } message: {
            if let message { Text(message) }
        }
    }
}

/// A trash icon button that confirms before deleting.
struct DeleteButton: View {
    let title: String
    var help = "Delete"
    let action: () -> Void
    @State private var asking = false

    var body: some View {
        Button { asking = true } label: { Image(systemName: "trash") }
            .buttonStyle(.borderless)
            .help(help)
            .accessibilityLabel(help)
            .confirmDestructive($asking, title: title, action: action)
    }
}
