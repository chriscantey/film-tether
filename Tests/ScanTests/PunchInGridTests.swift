import XCTest
import CoreGraphics
@testable import Scan

final class PunchInGridTests: XCTestCase {
    let grid = PunchInGrid.eos7D

    func testTablesAreSortedAndPositionsRiseWithCenters() {
        for cells in [grid.x, grid.y] {
            for (a, b) in zip(cells, cells.dropFirst()) {
                XCTAssertLessThan(a.center, b.center)
                XCTAssertLessThan(a.position, b.position)
            }
        }
    }

    /// Adjacent landings sit one lattice step apart (about 0.0132 of the width,
    /// 0.0204 of the height), or two where the body never lands on a cell.
    func testNeighborsAreOneOrTwoLatticeStepsApart() {
        for (cells, pitch) in [(grid.x, 0.01318), (grid.y, 0.02040)] {
            for (a, b) in zip(cells, cells.dropFirst()) {
                let steps = (b.center - a.center) / pitch
                let nearest = steps.rounded()
                XCTAssertTrue(nearest == 1 || nearest == 2, "gap of \(steps) steps at \(a.center)")
                XCTAssertEqual(steps, nearest, accuracy: 0.1)
            }
        }
    }

    func testSnappedPointIsALandingAndPositionIsItsValue() {
        let p = CGPoint(x: 0.3, y: 0.6)
        let s = grid.snapped(p)
        let pos = grid.position(for: p)
        let cx = grid.x.first { $0.center == Double(s.x) }
        let cy = grid.y.first { $0.center == Double(s.y) }
        XCTAssertEqual(cx?.position, pos.x)
        XCTAssertEqual(cy?.position, pos.y)
    }

    func testTheAxesAreIndependent() {
        let a = grid.position(for: CGPoint(x: 0.42, y: 0.25))
        let b = grid.position(for: CGPoint(x: 0.42, y: 0.75))
        let c = grid.position(for: CGPoint(x: 0.66, y: 0.25))
        XCTAssertEqual(a.x, b.x)
        XCTAssertEqual(a.y, c.y)
        XCTAssertNotEqual(a.y, b.y)
        XCTAssertNotEqual(a.x, c.x)
    }

    func testPointsPastTheReachableRegionGoToTheOutermostLanding() {
        let lo = grid.snapped(CGPoint(x: 0, y: 0))
        let hi = grid.snapped(CGPoint(x: 1, y: 1))
        XCTAssertEqual(Double(lo.x), grid.x.first!.center)
        XCTAssertEqual(Double(lo.y), grid.y.first!.center)
        XCTAssertEqual(Double(hi.x), grid.x.last!.center)
        XCTAssertEqual(Double(hi.y), grid.y.last!.center)
    }

    /// Inside the reachable region the box never moves further than half the
    /// widest gap between landings: about 0.0132 of the width at the one
    /// missing column, 0.0204 of the height at the one missing row.
    func testSnappingMovesThePointNoMoreThanHalfTheWidestGap() {
        for (cells, axisIsX) in [(grid.x, true), (grid.y, false)] {
            let widest = zip(cells, cells.dropFirst()).map { $1.center - $0.center }.max()!
            var v = cells.first!.center
            while v <= cells.last!.center {
                let p = axisIsX ? CGPoint(x: v, y: 0.5) : CGPoint(x: 0.5, y: v)
                let s = grid.snapped(p)
                let moved = abs(Double(axisIsX ? s.x : s.y) - v)
                XCTAssertLessThanOrEqual(moved, widest / 2 + 1e-9)
                v += 0.001
            }
        }
    }

    func testTheBoxIsAFifthOfTheFrame() {
        XCTAssertEqual(grid.boxFraction.width, 0.2, accuracy: 0.001)
        XCTAssertEqual(grid.boxFraction.height, 0.2, accuracy: 0.001)
    }
}
