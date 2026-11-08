import SwiftUI

struct NotchRootView: View {
    let model: NotchModel
    let actions: IslandActions

    @Environment(Settings.self) private var settings
    @Environment(VPNService.self) private var vpn
    @Environment(TranslatorService.self) private var translator

    private var geometry: IslandGeometry { model.geometry }
    private var expanded: Bool { model.phase == .expanded }
    private var peeking: Bool { model.phase == .peeking }

    var body: some View {
        ZStack(alignment: .top) {
            // Rim/glow (and the virtual island's rim) only show around the island, so they sit
            // under it; dots and strokes are drawn on top.
            if !expanded, indicatorBelow { indicator }
            island
                .padding(.top, geometry.topInset)
            if !expanded, !indicatorBelow { indicator }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea()
    }

    private var indicator: some View {
        CollapsedIndicator(geometry: geometry, style: settings.indicator, state: vpn.state, peeking: peeking)
            .padding(.top, geometry.topInset)
            .transition(.opacity.animation(.easeOut(duration: 0.12)))
    }

    // MARK: - Island

    private var shape: IslandShape {
        if expanded {
            return IslandShape(flare: geometry.expandedFlare, topRadius: geometry.expandedTopRadius,
                               bottomRadius: geometry.expandedBottomRadius)
        }
        return geometry.collapsedShape(peeking: peeking)
    }

    private var indicatorBelow: Bool { !geometry.hasNotch || settings.indicator.drawsBelowIsland }

    private var usesEar: Bool { geometry.hasNotch && settings.indicator.usesEar }

    private var collapsedSize: CGSize { geometry.collapsedSize(ear: usesEar, peeking: peeking) }

    /// Changes in content height (e.g. a translation appearing) animate the whole island.
    private var contentKey: String {
        "\(translator.output.isEmpty)-\(translator.phase)-\(translator.output.count / 40)"
    }

    private var island: some View {
        let shape = self.shape
        return ZStack(alignment: .top) {
            if expanded {
                ExpandedContent(model: model, actions: actions)
                    .transition(.asymmetric(insertion: .identity,
                                            removal: .opacity.animation(.easeOut(duration: 0.1))))
            }
        }
        .frame(width: expanded ? geometry.expandedTotalWidth : collapsedSize.width,
               height: expanded ? nil : collapsedSize.height,
               alignment: .top)
        .background {
            IslandBackground(shape: shape, glassActive: model.glassActive, expanded: expanded,
                             geometry: geometry, material: settings.glass,
                             transparency: settings.transparency, top: settings.topStyle)
        }
        .clipShape(shape)
        .contentShape(shape)
        .onHover(perform: actions.hover)
        .gesture(TapGesture().onEnded { actions.open() }, including: expanded ? .subviews : .all)
        .contextMenu {
            Button("Настройки…", action: actions.openSettings)
            Divider()
            Button("Выйти из Peek", action: actions.quit)
        }
        .offset(x: expanded ? 0 : geometry.collapsedOffset(ear: usesEar))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if model.phase == .expanded { model.reportHeight(height) }
        }
        .animation(Motion.resize, value: contentKey)
    }
}

/// Closed: solid black, indistinguishable from the hardware notch.
/// Opening: the black cross-fades away with the same spring that grows the shape, so the notch
/// melts into Liquid Glass instead of switching. How the glass meets the camera is `TopStyle`.
private struct IslandBackground: View {
    let shape: IslandShape
    let glassActive: Bool
    let expanded: Bool
    let geometry: IslandGeometry
    let material: GlassStyle
    /// 0 = dense … 1 = fully clear (user slider).
    let transparency: Double
    let top: TopStyle

    @Environment(\.colorScheme) private var scheme

    /// A neutral veil over the glass: the transparency slider controls how much of it there is.
    private var veil: Color { scheme == .dark ? Color(white: 0.07) : Color(white: 0.97) }

    var body: some View {
        ZStack(alignment: .top) {
            if glassActive {
                Color.clear.glassEffect(material.glass, in: shape)
                shape.fill(veil.opacity((1 - transparency) * 0.85))
                if geometry.hasNotch { topTreatment }
            }
            shape.fill(Color.black).opacity(expanded ? 0 : 1)
        }
    }

    @ViewBuilder private var topTreatment: some View {
        switch top {
        case .melt:
            // A soft shadow hugging the camera housing: no band, the notch just dissolves into glass.
            let core = geometry.collapsedShape(peeking: false)
            let size = geometry.collapsedSize(ear: false, peeking: false)
            ZStack(alignment: .top) {
                core.fill(Color.black)
                    .frame(width: size.width + 10, height: size.height + 6)
                    .blur(radius: 9)
                core.fill(Color.black)
                    .frame(width: size.width, height: size.height)
            }
        case .band:
            VStack(spacing: 0) {
                Color.black.frame(height: geometry.bandHeight)
                LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 18)
                Spacer(minLength: 0)
            }
        case .glass:
            EmptyView()
        }
    }
}

// MARK: - Expanded layout

private struct ExpandedContent: View {
    let model: NotchModel
    let actions: IslandActions

    var body: some View {
        let geometry = model.geometry
        VStack(spacing: 0) {
            TopBand(height: geometry.bandHeight, openSettings: actions.openSettings)
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    MusicCard().staggeredAppear(0)
                    VPNCard().staggeredAppear(1)
                    BluetoothCard().staggeredAppear(2)
                }
                .frame(height: 112)
                TranslatorCard(focusToken: model.focusToken, onEscape: actions.close,
                               openSettings: actions.openSettings)
                    .staggeredAppear(3)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
        .padding(.horizontal, geometry.expandedFlare)
        .frame(width: geometry.expandedTotalWidth)
    }
}

private struct TopBand: View {
    let height: CGFloat
    let openSettings: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack {
            Spacer()
            Button(action: openSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(hovering ? 0.85 : 0.4))
                    .frame(width: 26, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 0.85))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .help("Настройки")
        }
        .padding(.horizontal, 16)
        .frame(height: height)
        .staggeredAppear(0)
    }
}
