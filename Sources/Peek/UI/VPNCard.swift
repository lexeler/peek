import SwiftUI

struct VPNCard: View {
    @Environment(VPNService.self) private var vpn

    private var isOn: Bool { vpn.state.isOn }

    private var statusText: String {
        switch vpn.state {
        case .connected: "Включён"
        case .connecting: "Подключение…"
        case .disconnecting: "Отключение…"
        case .disconnected: "Выключен"
        case .unavailable: "Не найден"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Button(action: vpn.toggle) {
                ZStack {
                    Circle()
                        .fill(isOn
                              ? AnyShapeStyle(LinearGradient(colors: [Palette.green.mix(with: .white, by: 0.15), Palette.green],
                                                             startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle(Color.primary.opacity(0.1)))
                    Circle()
                        .strokeBorder(.white.opacity(isOn ? 0.4 : 0.12), lineWidth: 0.5)
                    if vpn.state.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Image(systemName: "power")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(isOn ? Color.white : Color.primary.opacity(0.85))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 54, height: 54)
                .shadow(color: isOn ? Palette.green.opacity(0.55) : .clear, radius: 14, y: 2)
                .contentShape(Circle())
            }
            .buttonStyle(PressableStyle(scale: 0.9))
            .disabled(vpn.state == .unavailable)
            .help(isOn ? "Выключить VPN" : "Включить VPN")

            Text(vpn.displayName)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .padding(.top, 9)
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(isOn ? AnyShapeStyle(Palette.green) : AnyShapeStyle(.secondary))
                .contentTransition(.opacity)
                .padding(.top, 1)
            Spacer(minLength: 0)
        }
        .frame(width: 112)
        .frame(maxHeight: .infinity)
        .card()
        .animation(.spring(duration: 0.35, bounce: 0.2), value: vpn.state)
    }
}
