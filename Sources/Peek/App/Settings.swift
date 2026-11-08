import SwiftUI

enum IndicatorStyle: String, CaseIterable, Identifiable {
    case rim, edge, led, line, glow, none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rim: "Кайма"
        case .edge: "Подсветка"
        case .led: "Огонёк"
        case .line: "Линия"
        case .glow: "Свечение"
        case .none: "Ничего"
        }
    }

    /// Drawn under the black island (it shows only around it) rather than on top.
    var drawsBelowIsland: Bool { self == .rim || self == .glow }
    /// Extends the black shape to the right of the notch to host a dot.
    var usesEar: Bool { self == .led }
}

enum GlassStyle: String, CaseIterable, Identifiable {
    case regular, clear

    var id: String { rawValue }
    var title: String { self == .regular ? "Стекло" : "Прозрачное" }

    var glass: Glass { self == .regular ? .regular : .clear }
}

/// How the open panel meets the camera notch.
enum TopStyle: String, CaseIterable, Identifiable {
    case melt, glass, band

    var id: String { rawValue }

    var title: String {
        switch self {
        case .melt: "Плавно"
        case .glass: "Стекло"
        case .band: "Полоса"
        }
    }
}

extension Notification.Name {
    /// Posted when a setting that affects window placement changes.
    static let peekLayoutChanged = Notification.Name("PeekLayoutChanged")
}

/// User preferences, persisted in the app's defaults domain. No other files are written.
@Observable
final class Settings {
    private enum Key {
        static let indicator = "indicatorStyle"
        static let glass = "glassStyle"
        static let hoverDelay = "hoverDelay"
        static let islandEnabled = "islandEnabled"
        static let islandOffset = "islandOffset"
        static let vpnServiceID = "vpnServiceID"
        static let topStyle = "topStyle"
        static let transparency = "glassTransparency"
        static let indicatorVersion = "indicatorVersion"
    }

    @ObservationIgnored private let defaults = UserDefaults.standard

    var indicator: IndicatorStyle {
        didSet { defaults.set(indicator.rawValue, forKey: Key.indicator) }
    }

    var glass: GlassStyle {
        didSet { defaults.set(glass.rawValue, forKey: Key.glass) }
    }

    /// Seconds the pointer must rest on the notch before the panel opens.
    var hoverDelay: Double {
        didSet { defaults.set(hoverDelay, forKey: Key.hoverDelay) }
    }

    /// Virtual "Dynamic Island" on displays without a camera notch.
    var islandEnabled: Bool {
        didSet {
            defaults.set(islandEnabled, forKey: Key.islandEnabled)
            NotificationCenter.default.post(name: .peekLayoutChanged, object: nil)
        }
    }

    /// Horizontal offset of the virtual island from the screen centre, in points.
    var islandOffset: Double {
        didSet {
            defaults.set(islandOffset, forKey: Key.islandOffset)
            NotificationCenter.default.post(name: .peekLayoutChanged, object: nil)
        }
    }

    var vpnServiceID: String? {
        didSet { defaults.set(vpnServiceID, forKey: Key.vpnServiceID) }
    }

    var topStyle: TopStyle {
        didSet { defaults.set(topStyle.rawValue, forKey: Key.topStyle) }
    }

    /// 0 = dense (veiled) glass … 1 = fully clear glass.
    var transparency: Double {
        didSet { defaults.set(transparency, forKey: Key.transparency) }
    }

    init() {
        // v2 replaced the whole indicator set: start everyone on the new default once.
        if defaults.integer(forKey: Key.indicatorVersion) < 2 {
            defaults.set(IndicatorStyle.rim.rawValue, forKey: Key.indicator)
            defaults.set(2, forKey: Key.indicatorVersion)
        }
        indicator = IndicatorStyle(rawValue: defaults.string(forKey: Key.indicator) ?? "") ?? .rim
        glass = GlassStyle(rawValue: defaults.string(forKey: Key.glass) ?? "") ?? .regular
        hoverDelay = defaults.object(forKey: Key.hoverDelay) as? Double ?? 0.15
        islandEnabled = defaults.object(forKey: Key.islandEnabled) as? Bool ?? true
        islandOffset = defaults.object(forKey: Key.islandOffset) as? Double ?? 0
        vpnServiceID = defaults.string(forKey: Key.vpnServiceID)
        topStyle = TopStyle(rawValue: defaults.string(forKey: Key.topStyle) ?? "") ?? .melt
        transparency = defaults.object(forKey: Key.transparency) as? Double ?? 0.6
    }
}
