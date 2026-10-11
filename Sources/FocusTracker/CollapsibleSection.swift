import FocusCore
import SwiftUI

/// A Form section whose header toggles the content; `content` receives whether it is expanded.
struct CollapsibleSection<Accessory: View, Content: View>: View {
    let title: String
    var count: Int?
    @State private var expanded: Bool
    private let accessory: Accessory
    private let content: (Bool) -> Content

    init(
        title: String, count: Int? = nil, defaultExpanded: Bool = true,
        @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: @escaping (Bool) -> Content
    ) {
        self.title = title
        self.count = count
        _expanded = State(initialValue: defaultExpanded)
        self.accessory = accessory()
        self.content = content
    }

    var body: some View {
        Section {
            content(expanded)
        } header: {
            HStack(spacing: 6) {
                Button { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 10)
                        Text(title)
                        if let count {
                            Text("\(count)")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(expanded ? "expanded" : "collapsed")")
                Spacer()
                accessory
            }
        }
    }
}
