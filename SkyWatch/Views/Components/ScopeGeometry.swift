import CoreGraphics
import Foundation

/// Maps bearing and distance onto the scope.
///
/// Distance is scaled **linearly** to the selected radius. A log or square-root scale would fit more
/// targets on screen, but it would also lie about how far away they are, and this is an instrument.
struct ScopeGeometry: Equatable {
    let center: CGPoint
    /// Radius of the outermost ring, in points.
    let radius: CGFloat
    /// What the outermost ring means, in nautical miles.
    let rangeNM: Double
    /// Degrees to rotate the whole scope by. Zero is north-up; in heading-up mode this is the
    /// device heading, so "ahead of you" is at the top.
    let rotation: Double

    init(size: CGSize, rangeNM: Double, rotation: Double = 0, inset: CGFloat = 2) {
        let side = min(size.width, size.height)
        center = CGPoint(x: size.width / 2, y: size.height / 2)
        radius = max(side / 2 - inset, 1)
        self.rangeNM = max(rangeNM, 0.1)
        self.rotation = rotation
    }

    /// Ring radii at ⅓, ⅔ and full range.
    var ringFractions: [Double] { [1.0 / 3.0, 2.0 / 3.0, 1.0] }

    func ringRadius(_ fraction: Double) -> CGFloat { radius * fraction }

    /// Glyphs scale with the scope so a 49 mm Ultra doesn't draw the same tiny triangles as a
    /// 40 mm SE — and the invisible tap areas keep pace with what's on screen.
    var glyphScale: CGFloat { radius / 96 }

    func point(bearingDegrees: Double, distanceNM: Double) -> CGPoint {
        let relative = Geodesy.normalized0to360(bearingDegrees - rotation).radians
        // Clamped rather than dropped: a target just outside the ring sits on the edge, which is
        // more honest than making it vanish between refreshes.
        let scaled = radius * CGFloat(min(max(distanceNM / rangeNM, 0), 1))
        return CGPoint(
            x: center.x + scaled * CGFloat(sin(relative)),
            y: center.y - scaled * CGFloat(cos(relative))
        )
    }

    /// True when the target is inside the selected range rather than pinned to the edge.
    func isInRange(distanceNM: Double) -> Bool { distanceNM <= rangeNM }

    /// Screen rotation for a glyph pointing along a compass track.
    func glyphRotation(trackDegrees: Double) -> Double {
        Geodesy.normalized0to360(trackDegrees - rotation)
    }
}
