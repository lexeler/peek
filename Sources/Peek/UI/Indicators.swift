import SwiftUI

enum Palette {
    /// A calm, slightly minty green — reads as "on" without looking like a neon LED.
    static let green = Color(red: 0.24, green: 0.84, blue: 0.47)
    static let gray = Color(white: 0.6)

    static func status(_ state: VPNService.State) -> Color {
        switch state {
        case .connected: green
        case .connecting, .disconnecting: green.opacity(0.55)
        case .disconnected, .unavailable: gray.opacity(0.75)
        }
    }
}

/// The only thing visible while the island is closed: a quiet VPN status hint.
/// Every style is static between state changes — no idle animation, no idle cost.
struct CollapsedIndicator: View {
    let geometry: IslandGeometry
    let style: IndicatorStyle
    let state: VPNService.State
    let peeking: Bool

    /// The "rim": the notch looks a hair larger, black melting into colour at its edge.
    struct RimTuning { var width: CGFloat; var blur: CGFloat; var on: Double; var off: Double }
    #if PEEK_DEBUG
    nonisolated(unsafe) static var rim = RimTuning(width: 5, blur: 4, on: 0.75, off: 0.5)
    #else
    static let rim = RimTuning(width: 5, blur: 4, on: 0.75, off: 0.5)
    #endif

    private var color: Color { Palette.status(state) }
    private var on: Bool { state == .connected }

    var body: some View {
        Group {
            if geometry.hasNotch {
                notchIndicator
            } else if style != .none {
                islandRim
            }
        }
        .animation(.smooth(duration: 0.45), value: state)
        .animation(Motion.peek, value: peeking)
        .allowsHitTesting(false)
    }

    // MARK: - Notch styles

    private var size: CGSize { geometry.collapsedSize(ear: style.usesEar, peeking: peeking) }
    private var shape: IslandShape { geometry.collapsedShape(peeking: peeking) }

    @ViewBuilder private var notchIndicator: some View {
        switch style {
        case .rim:
            rim
        case .edge:
            // Light catching the lower edge: strongest along the bottom, fading up the sides.
            shape
                .stroke(LinearGradient(colors: [color.opacity(0), color.opacity(on ? 0.95 : 0.6)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1.2)
                .frame(width: size.width + 1.2, height: size.height + 0.6)
        case .led:
            // Centre of the visible part of the ear (between the hardware notch and the ear's edge).
            led
                .offset(x: size.width / 2 - geometry.collapsedFlare, y: size.height / 2 - 2.5)
        case .line:
            Capsule()
                .fill(LinearGradient(colors: [color.opacity(0), color, color.opacity(0)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: geometry.notch.width * 0.62, height: 1.5)
                .shadow(color: color.opacity(on ? 0.7 : 0), radius: 2.5)
                .offset(y: size.height + 3.5)
        case .glow:
            // A faint light spilling from under the notch — kept tight so it never washes over windows.
            Ellipse()
                .fill(RadialGradient(colors: [color.opacity(on ? 0.42 : 0.22), color.opacity(0)],
                                     center: .center, startRadius: 0, endRadius: (geometry.notch.width + 16) / 2))
                .frame(width: geometry.notch.width + 16, height: 20)
                .offset(y: size.height - 10)
        case .none:
            EmptyView()
        }
    }

    /// The user's idea: the notch "grows" a few points on each side; the extra band is a smooth
    /// gradient from the notch's black into the status colour at its crisp outer edge.
    /// Drawn under the island: the solid black island covers the centre.
    private var rim: some View {
        let tuning = Self.rim
        let width = tuning.width
        return ZStack(alignment: .top) {
            shape
                .fill(rimColor)
                .frame(width: size.width + 2 * width, height: size.height + width)
            // Black bleeding outwards over the band → black-to-colour gradient.
            shape
                .fill(Color.black)
                .frame(width: size.width, height: size.height)
                .blur(radius: tuning.blur)
                .mask(alignment: .top) {
                    shape.frame(width: size.width + 2 * width, height: size.height + width)
                }
        }
    }

    /// Opaque, so the rim reads as "the notch got a little bigger" on any wallpaper —
    /// a translucent tint turns muddy over bright menu bars.
    private var rimColor: Color {
        let tuning = Self.rim
        switch state {
        case .connected: return Palette.green.mix(with: .black, by: 1 - tuning.on)
        case .connecting, .disconnecting: return Palette.green.mix(with: .black, by: 1 - tuning.on * 0.6)
        case .disconnected, .unavailable: return Palette.gray.mix(with: .black, by: 1 - tuning.off)
        }
    }

    /// A tiny lit LED inside a black "ear" to the right of the notch.
    private var led: some View {
        ZStack {
            Circle()
                .fill(on
                      ? AnyShapeStyle(RadialGradient(colors: [.white.opacity(0.95), color],
                                                     center: .init(x: 0.38, y: 0.35), startRadius: 0, endRadius: 3.2))
                      : AnyShapeStyle(color))
            if state.isBusy {
                Circle().fill(Color.black).padding(1.3)
            }
        }
        .frame(width: 5, height: 5)
        .shadow(color: on ? color.opacity(0.9) : .clear, radius: 3)
        .phaseAnimator([1, 1.4, 1], trigger: state) { content, scale in
            content.scaleEffect(scale)
        } animation: { _ in .spring(duration: 0.28, bounce: 0.3) }
    }

    // MARK: - Virtual island (screens without a notch)

    private var islandRim: some View {
        let width = Self.rim.width - 1
        return ZStack {
            Capsule()
                .fill(rimColor)
                .frame(width: size.width + 2 * width, height: size.height + 2 * width)
            Capsule()
                .fill(Color.black)
                .frame(width: size.width, height: size.height)
                .blur(radius: Self.rim.blur - 1)
                .mask {
                    Capsule().frame(width: size.width + 2 * width, height: size.height + 2 * width)
                }
        }
        .offset(y: -width)
    }
}
