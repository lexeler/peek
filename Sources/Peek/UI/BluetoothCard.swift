import SwiftUI

struct BluetoothCard: View {
    @Environment(BluetoothService.self) private var bluetooth

    var body: some View {
        // No header: the headphone glyphs say it, and four devices fit without scrolling.
        content
            .padding(7)
        .frame(width: 200)
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
    }

    @ViewBuilder private var content: some View {
        switch bluetooth.access {
        case .denied:
            message("Нет доступа к Bluetooth", action: ("Разрешить", bluetooth.openSystemSettings))
        case .poweredOff:
            message("Bluetooth выключен", action: nil)
        case .unknown where bluetooth.devices.isEmpty:
            message("Жду разрешения…", action: nil)
        default:
            if bluetooth.devices.isEmpty {
                message("Нет сопряжённых наушников", action: nil)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(bluetooth.devices) { device in
                            DeviceRow(device: device) { bluetooth.toggle(device) }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private func message(_ text: String, action: (String, () -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(PressableStyle())
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct DeviceRow: View {
    let device: BluetoothService.Device
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: device.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(device.isConnected ? .primary : .secondary)
                Text(device.name)
                    .font(.system(size: 12, weight: device.isConnected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                trailing
            }
            .padding(.horizontal, 7)
            .frame(height: 23)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.09 : (device.isConnected ? 0.05 : 0)))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.spring(duration: 0.3, bounce: 0.2), value: device)
        .help(device.isConnected ? "Отключить" : "Подключить")
    }

    @ViewBuilder private var trailing: some View {
        if device.isBusy {
            ProgressView().controlSize(.mini)
        } else if device.isConnected {
            HStack(spacing: 5) {
                if let battery = device.battery {
                    Text("\(battery)%")
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Circle().fill(Palette.green).frame(width: 5, height: 5)
            }
            .transition(.scale.combined(with: .opacity))
        }
    }
}
