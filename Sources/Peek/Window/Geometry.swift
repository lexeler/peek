import AppKit

/// Shape metrics for one screen's island (real notch or virtual "Dynamic Island").
struct IslandGeometry: Equatable {
    var hasNotch: Bool
    /// Hardware notch size, or the virtual pill size on screens without a notch.
    var notch: CGSize
    /// Gap between the top of the screen and the island (0 when attached to a notch).
    var topInset: CGFloat

    static let expandedBodyWidth: CGFloat = 600
    /// Open-state window: the 624 pt panel + 8 pt margins, and the tallest content (8-line translation).
    static let windowSize = CGSize(width: 640, height: 400)
    static let earWidth: CGFloat = 20

    var collapsedFlare: CGFloat { hasNotch ? 6 : 0 }
    var expandedFlare: CGFloat { hasNotch ? 12 : 0 }
    var collapsedTopRadius: CGFloat { hasNotch ? 0 : notch.height / 2 }
    var collapsedBottomRadius: CGFloat { hasNotch ? 10 : notch.height / 2 }
    var expandedTopRadius: CGFloat { hasNotch ? 0 : 26 }
    var expandedBottomRadius: CGFloat { 28 }
    var expandedTotalWidth: CGFloat { Self.expandedBodyWidth + 2 * expandedFlare }
    /// Height of the black band at the top of the open panel that blends into the notch.
    var bandHeight: CGFloat { notch.height }
    /// Band + modules row + translator row + paddings (see ExpandedContent).
    var expandedMinimumHeight: CGFloat { bandHeight + 8 + 112 + 10 + 28 + 14 }

    static let peekGrowth = CGSize(width: 14, height: 4)

    /// Outline of the closed island (slightly larger while the pointer rests on it).
    func collapsedShape(peeking: Bool) -> IslandShape {
        IslandShape(flare: collapsedFlare, topRadius: collapsedTopRadius,
                    bottomRadius: collapsedBottomRadius + (peeking ? 2 : 0))
    }

    /// The "ear" indicator extends the black shape to the right of a real notch.
    func collapsedSize(ear: Bool, peeking: Bool) -> CGSize {
        CGSize(width: notch.width + 2 * collapsedFlare + (ear ? Self.earWidth : 0) + (peeking ? Self.peekGrowth.width : 0),
               height: notch.height + (peeking ? Self.peekGrowth.height : 0))
    }

    func collapsedOffset(ear: Bool) -> CGFloat { ear ? Self.earWidth / 2 : 0 }
}

/// Where an island lives on a particular display.
struct ScreenSlot: Equatable {
    let displayID: CGDirectDisplayID
    let geometry: IslandGeometry
    /// Global x of the island's centre.
    let anchorX: CGFloat
    /// Global y of the screen's top edge.
    let screenTop: CGFloat

    /// Frame while open (and animating). Not rounded: half-point origins are pixel-exact on Retina,
    /// and rounding would shift the island half a point off the hardware notch.
    var windowFrame: CGRect {
        let size = IslandGeometry.windowSize
        return CGRect(x: anchorX - size.width / 2, y: screenTop - size.height,
                      width: size.width, height: size.height)
    }

    /// Frame while closed: just the island, its hover growth and the widest indicator. A big
    /// transparent window would still receive every mouse move over the tab bars beneath it.
    var collapsedWindowFrame: CGRect {
        let width = 2 * ((geometry.notch.width + 96) / 2).rounded(.up) // even → stays pixel-centred
        let height = (geometry.topInset + geometry.notch.height + 24).rounded(.up)
        return CGRect(x: anchorX - width / 2, y: screenTop - height, width: width, height: height)
    }

    static func current(settings: Settings) -> [ScreenSlot] {
        NSScreen.screens.compactMap { slot(for: $0, settings: settings) }
    }

    private static func slot(for screen: NSScreen, settings: Settings) -> ScreenSlot? {
        guard let displayID = screen.displayID else { return nil }
        let frame = screen.frame

        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = frame.width - left.width - right.width
            let height = screen.safeAreaInsets.top
            guard width > 60, height > 10 else { return nil }
            return ScreenSlot(
                displayID: displayID,
                geometry: IslandGeometry(hasNotch: true, notch: CGSize(width: width, height: height), topInset: 0),
                anchorX: frame.minX + left.width + width / 2,
                screenTop: frame.maxY)
        }

        guard settings.islandEnabled else { return nil }
        let measured = frame.maxY - screen.visibleFrame.maxY
        let menuBar = measured > 12 ? measured : 24 // auto-hidden menu bar reports 0
        let pill = CGSize(width: 124, height: min(max(menuBar - 6, 20), 26))
        let maxOffset = max(frame.width / 2 - IslandGeometry.windowSize.width / 2, 0)
        let offset = min(max(settings.islandOffset, -maxOffset), maxOffset)
        return ScreenSlot(
            displayID: displayID,
            geometry: IslandGeometry(hasNotch: false, notch: pill, topInset: max(((menuBar - pill.height) / 2).rounded(), 3)),
            anchorX: frame.midX + offset,
            screenTop: frame.maxY)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
