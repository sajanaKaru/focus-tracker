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
    @Environment(\.controlSize) var controlSize
    @Environment(\.isEnabled) var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let large = controlSize == .large
        configuration.label
            .font((large ? Font.body : Font.callout).weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 22 : 14)
            .padding(.vertical, large ? 10 : 7)
            .background(gradient, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.controlSize) var controlSize
    @Environment(\.isEnabled) var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let large = controlSize == .large
        configuration.label
            .font((large ? Font.body : Font.callout).weight(.medium))
            .padding(.horizontal, large ? 20 : 12)
            .padding(.vertical, large ? 10 : 6)
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06), in: Capsule())
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Standard modal: title, scrolling form body, and a footer with the actions.
struct SheetScaffold<Content: View, Footer: View>: View {
    let title: String
    var subtitle: String?
    var width: CGFloat = 560
    var height: CGFloat?
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title.weight(.bold))
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 8)

            content

            Divider()
            HStack(spacing: 12) {
                Spacer()
                footer
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
        }
        .formStyle(.grouped)
        .controlSize(.large)
        .frame(width: width, height: height)
    }
}

/// Date field that opens a full calendar popover; replaces the tiny stock picker.
struct AppDatePicker: View {
    var label: String?
    @Binding var selection: Date
    var upTo: Date?
    var includesTime = false
    @State private var showing = false

    var body: some View {
        if let label {
            LabeledContent(label) { field }
        } else {
            field
        }
    }

    private var field: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: "calendar").foregroundStyle(Theme.accent)
                Text(includesTime ? selection.formatted(date: .abbreviated, time: .shortened) : selection.formatted(date: .abbreviated, time: .omitted))
                    .monospacedDigit()
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .font(.body)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            DatePicker("", selection: $selection, in: Date.distantPast...(upTo ?? .distantFuture), displayedComponents: includesTime ? [.date, .hourAndMinute] : .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(16)
        }
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
