import SwiftUI

/// The island outline.
///
/// Attached mode (`flare > 0`, notch screens): the top edge is flush with the screen and flares
/// outward with concave curves like the hardware notch; the bottom corners are rounded.
/// Floating mode (`flare == 0`, virtual island): a rounded rectangle / capsule.
struct IslandShape: Shape {
    var flare: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(flare, AnimatablePair(topRadius, bottomRadius)) }
        set {
            flare = newValue.first
            topRadius = newValue.second.first
            bottomRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let f = max(0, min(flare, rect.width / 4, rect.height / 2))
        let left = rect.minX + f
        let right = rect.maxX - f
        let bodyWidth = right - left
        let tr = f > 0 ? 0 : max(0, min(topRadius, bodyWidth / 2, rect.height / 2))
        let br = max(0, min(bottomRadius, bodyWidth / 2, rect.height - max(f, tr)))
        let top = rect.minY
        let bottom = rect.maxY

        var path = Path()
        if f > 0 {
            path.move(to: CGPoint(x: rect.minX, y: top))
            path.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: left, y: top + f), radius: f)
        } else {
            path.move(to: CGPoint(x: left, y: top + tr))
        }
        path.addLine(to: CGPoint(x: left, y: bottom - br))
        path.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: left + br, y: bottom), radius: br)
        path.addLine(to: CGPoint(x: right - br, y: bottom))
        path.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: right, y: bottom - br), radius: br)
        if f > 0 {
            path.addLine(to: CGPoint(x: right, y: top + f))
            path.addArc(tangent1End: CGPoint(x: right, y: top), tangent2End: CGPoint(x: rect.maxX, y: top), radius: f)
        } else {
            path.addLine(to: CGPoint(x: right, y: top + tr))
            path.addArc(tangent1End: CGPoint(x: right, y: top), tangent2End: CGPoint(x: right - tr, y: top), radius: tr)
            path.addLine(to: CGPoint(x: left + tr, y: top))
            path.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: left, y: top + tr), radius: tr)
        }
        path.closeSubpath()
        return path
    }
}
