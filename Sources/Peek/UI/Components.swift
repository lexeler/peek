import SwiftUI

/// Springy press feedback.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.92

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(duration: 0.22, bounce: 0.3), value: configuration.isPressed)
    }
}

/// Icon button used for media controls and small actions.
struct IconButton: View {
    let symbol: String
    var size: CGFloat = 14
    var weight: Font.Weight = .semibold
    var frame: CGFloat = 26
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .contentTransition(.symbolEffect(.replace.downUp))
                .frame(width: frame, height: frame)
                .contentShape(Rectangle())
                .opacity(hovering ? 1 : 0.88)
        }
        .buttonStyle(PressableStyle(scale: 0.82))
        .onHover { hovering = $0 }
    }
}

extension View {
    /// Inner card on the glass: hierarchy without stacking glass on glass.
    /// `quiet` is the barely-there variant (the resting translator line).
    func card(radius: CGFloat = 16, quiet: Bool = false) -> some View {
        modifier(CardBackground(radius: radius, quiet: quiet))
    }

    /// Staggered entrance: fade + de-blur + slight scale from the top.
    func staggeredAppear(_ index: Int) -> some View {
        modifier(StaggeredAppear(index: index))
    }
}

private struct CardBackground: ViewModifier {
    let radius: CGFloat
    let quiet: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let dark = scheme == .dark
        // Light, glassy cards; the transparency slider handles legibility over busy backdrops.
        let fill = dark ? Color.white.opacity(quiet ? 0.04 : 0.07) : Color.white.opacity(quiet ? 0.18 : 0.32)
        let edge = dark ? Color.white.opacity(quiet ? 0.06 : 0.09) : Color.black.opacity(quiet ? 0.05 : 0.07)
        return content
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(edge, lineWidth: 0.5))
    }
}

private struct StaggeredAppear: ViewModifier {
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        // Opacity + a short slide only: a blur here forced offscreen passes on every frame.
        let reduce = Motion.reduce
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduce ? 0 : -6)
            .onAppear {
                withAnimation(.smooth(duration: 0.22).delay(0.04 + Double(index) * 0.025)) {
                    shown = true
                }
            }
    }
}
