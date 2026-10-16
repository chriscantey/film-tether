import Foundation
import CoreGraphics

/// Where the camera's 5x punch-in can land, and the `eoszoomposition` value
/// that puts it there.
///
/// The body does not land the zoom on an arbitrary point. It snaps the center
/// of the magnified region to a fixed set of positions on each axis, about 14
/// pixels of the 1056x704 Fit frame apart, and the two axes are independent:
/// the landed x never depends on the y written, and the reverse. One lattice
/// position on each axis is never landed at all, and beyond the outermost
/// positions the body clamps. So the box is snapped to a position the camera
/// can reach, and the value sent is one measured to land exactly there. The
/// box then shows where the punch-in goes, rather than a point near it.
///
/// The tables below are measured on an EOS 7D by locating each 5x frame inside
/// the Fit frame, with positions written in steps of 10. Each position value is
/// the middle of the range that lands on its cell, which is 50 to 60 units wide
/// for every interior cell. Located centers repeat to within 0.3 Fit pixels and
/// do not depend on the direction of approach.
public struct PunchInGrid: Sendable, Equatable {
    /// One landing position on one axis: the center of the magnified region as
    /// a fraction of the Fit frame, and the value that lands there.
    public struct Cell: Sendable, Equatable {
        public let center: Double
        public let position: Int
        public init(center: Double, position: Int) {
            self.center = center
            self.position = position
        }
    }

    /// Reachable cells, sorted by center.
    public let x: [Cell]
    public let y: [Cell]
    /// The magnified region's size as a fraction of the Fit frame.
    public let boxFraction: CGSize

    public init(x: [Cell], y: [Cell], boxFraction: CGSize) {
        self.x = x.sorted { $0.center < $1.center }
        self.y = y.sorted { $0.center < $1.center }
        self.boxFraction = boxFraction
    }

    /// The reachable center nearest to `point` (normalized, top-down): where
    /// the punch-in will land if aimed at `point`.
    public func snapped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: Self.nearest(point.x, in: x).center,
                y: Self.nearest(point.y, in: y).center)
    }

    /// The `eoszoomposition` value that lands the punch-in on the reachable
    /// center nearest to `point`.
    public func position(for point: CGPoint) -> (x: Int, y: Int) {
        (Self.nearest(point.x, in: x).position, Self.nearest(point.y, in: y).position)
    }

    static func nearest(_ v: CGFloat, in cells: [Cell]) -> Cell {
        let t = Double(v)
        var best = cells[0]
        for c in cells.dropFirst() where abs(c.center - t) < abs(best.center - t) {
            best = c
        }
        return best
    }

    /// The EOS 7D's landing positions.
    public static let eos7D = PunchInGrid(
        x: [
            .init(center: 0.1437, position: 150),
            .init(center: 0.1569, position: 340),
            .init(center: 0.1701, position: 410),
            .init(center: 0.1833, position: 480),
            .init(center: 0.1965, position: 545),
            .init(center: 0.2097, position: 610),
            .init(center: 0.2228, position: 680),
            .init(center: 0.2360, position: 750),
            .init(center: 0.2491, position: 820),
            .init(center: 0.2624, position: 885),
            .init(center: 0.2756, position: 950),
            .init(center: 0.2888, position: 1020),
            .init(center: 0.3019, position: 1090),
            .init(center: 0.3151, position: 1160),
            .init(center: 0.3282, position: 1225),
            .init(center: 0.3414, position: 1290),
            .init(center: 0.3546, position: 1360),
            .init(center: 0.3679, position: 1430),
            .init(center: 0.3810, position: 1500),
            .init(center: 0.3942, position: 1565),
            .init(center: 0.4074, position: 1630),
            .init(center: 0.4205, position: 1700),
            .init(center: 0.4337, position: 1770),
            .init(center: 0.4469, position: 1840),
            .init(center: 0.4601, position: 1905),
            .init(center: 0.4733, position: 1970),
            .init(center: 0.4864, position: 2040),
            .init(center: 0.5128, position: 2110),
            .init(center: 0.5260, position: 2180),
            .init(center: 0.5392, position: 2250),
            .init(center: 0.5524, position: 2315),
            .init(center: 0.5656, position: 2380),
            .init(center: 0.5788, position: 2450),
            .init(center: 0.5918, position: 2520),
            .init(center: 0.6050, position: 2590),
            .init(center: 0.6182, position: 2655),
            .init(center: 0.6314, position: 2720),
            .init(center: 0.6446, position: 2790),
            .init(center: 0.6578, position: 2860),
            .init(center: 0.6710, position: 2930),
            .init(center: 0.6841, position: 2995),
            .init(center: 0.6973, position: 3060),
            .init(center: 0.7105, position: 3130),
            .init(center: 0.7238, position: 3200),
            .init(center: 0.7369, position: 3270),
            .init(center: 0.7501, position: 3335),
            .init(center: 0.7632, position: 3400),
            .init(center: 0.7765, position: 3470),
            .init(center: 0.7896, position: 3540),
            .init(center: 0.8028, position: 3610),
            .init(center: 0.8160, position: 3675),
            .init(center: 0.8291, position: 3740),
            .init(center: 0.8423, position: 3810),
            .init(center: 0.8555, position: 3975),
        ],
        y: [
            .init(center: 0.2224, position: 235),
            .init(center: 0.2426, position: 510),
            .init(center: 0.2632, position: 580),
            .init(center: 0.2837, position: 650),
            .init(center: 0.3040, position: 720),
            .init(center: 0.3244, position: 790),
            .init(center: 0.3448, position: 860),
            .init(center: 0.3653, position: 930),
            .init(center: 0.3856, position: 1000),
            .init(center: 0.4060, position: 1070),
            .init(center: 0.4265, position: 1140),
            .init(center: 0.4469, position: 1210),
            .init(center: 0.4672, position: 1280),
            .init(center: 0.4876, position: 1350),
            .init(center: 0.5282, position: 1420),
            .init(center: 0.5488, position: 1490),
            .init(center: 0.5693, position: 1560),
            .init(center: 0.5896, position: 1630),
            .init(center: 0.6100, position: 1700),
            .init(center: 0.6304, position: 1770),
            .init(center: 0.6509, position: 1840),
            .init(center: 0.6712, position: 1910),
            .init(center: 0.6917, position: 1980),
            .init(center: 0.7121, position: 2050),
            .init(center: 0.7324, position: 2120),
            .init(center: 0.7528, position: 2190),
            .init(center: 0.7733, position: 2260),
            .init(center: 0.7934, position: 2600),
        ],
        boxFraction: CGSize(width: 0.200, height: 0.200)
    )
}
