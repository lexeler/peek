import AppKit
import SwiftUI
@preconcurrency import Translation

/// A regular window for preferences. Created on demand and released when closed.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private unowned let environment: AppEnvironment
    private var window: NSWindow?

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    func show() {
        if window == nil {
            let view = SettingsView()
                .environment(environment.settings)
                .environment(environment.vpn)
                .environment(environment.translator)
            // Fixed-size window. Content-driven window sizing (preferredContentSize) re-enters
            // layout on macOS 26 when the window's corner safe-area insets change and AppKit
            // aborts with an "Update Constraints" loop exception — so the size never follows content.
            let controller = NSHostingController(rootView: view)
            controller.sizingOptions = []
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: SettingsView.size),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.contentViewController = controller
            window.setContentSize(SettingsView.size)
            window.title = "Peek"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window?.delegate = nil
        window = nil
    }
}

struct SettingsView: View {
    static let size = CGSize(width: 500, height: 700)

    @Environment(Settings.self) private var settings
    @Environment(VPNService.self) private var vpn
    @Environment(TranslatorService.self) private var translator

    @State private var launchAtLogin = LaunchAgent.isInstalled

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(IndicatorStyle.allCases) { style in
                        IndicatorTile(style: style, selected: settings.indicator == style, state: vpn.state) {
                            withAnimation(.spring(duration: 0.3, bounce: 0.2)) { settings.indicator = style }
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Индикатор VPN у чёлки")
            } footer: {
                Text("Зелёный — VPN включён, серый — выключен. Меняется сразу, можно примерить прямо на чёлке.")
            }

            Section("Панель") {
                Picker("Материал", selection: $settings.glass) {
                    ForEach(GlassStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Прозрачность") {
                    HStack(spacing: 8) {
                        Image(systemName: "circle.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                        Slider(value: $settings.transparency, in: 0...1)
                            .frame(width: 170)
                        Image(systemName: "circle").font(.system(size: 9)).foregroundStyle(.secondary)
                        Text("\(Int((settings.transparency * 100).rounded()))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                Picker("Верх у чёлки", selection: $settings.topStyle) {
                    ForEach(TopStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Задержка открытия") {
                    HStack {
                        Slider(value: $settings.hoverDelay, in: 0...0.5, step: 0.05)
                            .frame(width: 160)
                        Text("\(Int(settings.hoverDelay * 1000)) мс")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }

            Section {
                Toggle("Динамический остров", isOn: $settings.islandEnabled)
                LabeledContent("Смещение") {
                    HStack {
                        Slider(value: $settings.islandOffset, in: -600...600, step: 10)
                            .frame(width: 160)
                        Button("По центру") { settings.islandOffset = 0 }
                            .disabled(settings.islandOffset == 0)
                    }
                }
                .disabled(!settings.islandEnabled)
            } header: {
                Text("Мониторы без чёлки")
            } footer: {
                Text("На внешних мониторах и с закрытой крышкой появится аккуратный остров сверху.")
            }

            Section("VPN") {
                if vpn.services.isEmpty {
                    Text("VPN-профили не найдены").foregroundStyle(.secondary)
                } else {
                    Picker("Профиль", selection: Binding(
                        get: { vpn.current },
                        set: { if let service = $0 { vpn.select(service) } }
                    )) {
                        ForEach(vpn.services) { Text($0.displayName).tag(Optional($0)) }
                    }
                }
            }

            Section("Переводчик") {
                LabeledContent {
                    if translator.languagesReady {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green)
                    } else if translator.isDownloading {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Скачать", action: translator.startDownload)
                    }
                } label: {
                    Text(translator.languagesReady ? "Русский и английский скачаны"
                         : translator.isDownloading ? "Скачивается… окно можно закрыть" : "Языки не скачаны")
                    Text("Перевод работает офлайн, прямо на Mac")
                }
            }

            Section {
                Toggle("Запускать при входе и перезапускать при сбое", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        if enabled { LaunchAgent.install() } else { LaunchAgent.uninstall(stopRunning: false) }
                    }
                HStack {
                    Text("Peek 1.0").foregroundStyle(.secondary)
                    Spacer()
                    Button("Выйти из Peek") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.size.width, height: Self.size.height)
        .translationTask(translator.downloadRequest) { session in
            await translator.prepareDownload(using: session)
        }
        .task { await translator.checkLanguages() }
    }
}

/// Live preview tile for an indicator style.
private struct IndicatorTile: View {
    let style: IndicatorStyle
    let selected: Bool
    let state: VPNService.State
    let action: () -> Void

    private let geometry = IslandGeometry(hasNotch: true, notch: CGSize(width: 64, height: 18), topInset: 0)

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                LinearGradient(colors: [Color(red: 0.24, green: 0.27, blue: 0.4), Color(red: 0.42, green: 0.32, blue: 0.45)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(height: 50)
                    .overlay(alignment: .top) { preview } // overlay: never changes the tile's layout size
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2 : 0.5)
                )
                Text(style.title)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle(scale: 0.96))
        .focusEffectDisabled()
    }

    /// Same geometry and layering as the real notch.
    private var preview: some View {
        let ear = style.usesEar
        let indicator = CollapsedIndicator(geometry: geometry, style: style,
                                           state: state == .unavailable ? .connected : state, peeking: false)
        let size = geometry.collapsedSize(ear: ear, peeking: false)
        return ZStack(alignment: .top) {
            if style.drawsBelowIsland { indicator }
            geometry.collapsedShape(peeking: false)
                .fill(.black)
                .frame(width: size.width, height: size.height)
                .offset(x: geometry.collapsedOffset(ear: ear))
            if !style.drawsBelowIsland { indicator }
        }
    }
}
