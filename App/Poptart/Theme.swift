import SwiftUI

/// The window surfaces share the Indicator's vocabulary: one ink, one ground, silhouettes instead
/// of colour. Semantic system colours keep that true in dark mode.
enum Theme {
    static let sectionSpacing: CGFloat = 12
    static let labelWidth: CGFloat = 120
    static let controlWidth: CGFloat = 220
    static let cornerRadius: CGFloat = 7
}

/// A small uppercase section label, the only heading a settings section gets.
struct SectionLabel: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .medium))
            .tracking(0.66)
            .foregroundStyle(.secondary)
    }
}

/// A label lane and a control, so every row in a window lines up on the same vertical edge.
struct LabeledRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .frame(width: Theme.labelWidth, alignment: .leading)
            content
        }
    }
}

/// Ink outline on the window ground: the ordinary button.
struct OutlinedButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .foregroundStyle(.primary)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .stroke(.primary, lineWidth: 1)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }
}

/// Filled ink: the one emphasised action on a surface.
struct FilledButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 12)
            .frame(height: 24)
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .background(RoundedRectangle(cornerRadius: Theme.cornerRadius).fill(.primary))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
            .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }
}

extension ButtonStyle where Self == OutlinedButtonStyle {
    static var outlined: OutlinedButtonStyle { .init() }
}

extension ButtonStyle where Self == FilledButtonStyle {
    static var filled: FilledButtonStyle { .init() }
}

/// A hairline between sections, drawn in the separator colour like the Indicator's edge.
struct SectionDivider: View {
    var body: some View {
        Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
    }
}
