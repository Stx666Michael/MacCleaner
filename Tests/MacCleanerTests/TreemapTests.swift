import XCTest
@testable import MacCleanerCore

final class TreemapTests: XCTestCase {
    private static let bounds = RectD(x: 10, y: 20, w: 800, h: 500)

    private func assertValid(_ values: [Double], _ rects: [RectD], _ bounds: RectD) {
        let eps = 1e-6
        let total = values.filter { $0 > 0 }.reduce(0, +)
        for i in 0..<values.count {
            let r = rects[i]
            if values[i] <= 0 {
                XCTAssertEqual(r.area, 0, accuracy: eps)
                continue
            }
            XCTAssertTrue(r.x >= bounds.x - eps && r.y >= bounds.y - eps, "rect \(i) starts outside")
            XCTAssertTrue(r.right <= bounds.right + eps && r.bottom <= bounds.bottom + eps, "rect \(i) ends outside")
            XCTAssertEqual(values[i] / total * bounds.area, r.area, accuracy: 1e-3)
        }
        let sumArea = rects.reduce(0.0) { $0 + $1.area }
        XCTAssertEqual(bounds.area, sumArea, accuracy: 1e-3)
        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count {
                let w = min(rects[i].right, rects[j].right) - max(rects[i].x, rects[j].x)
                let h = min(rects[i].bottom, rects[j].bottom) - max(rects[i].y, rects[j].y)
                XCTAssertFalse(w > 1e-6 && h > 1e-6, "rects \(i) and \(j) overlap")
            }
        }
    }

    func testSingleValueFillsEverything() {
        let r = Treemap.layout([5], Self.bounds)
        XCTAssertEqual(Self.bounds, r[0])
    }

    func testAreasAreProportionalInsideBoundsAndDoNotOverlap() {
        let v = [60.0, 25.0, 10.0, 3.0, 1.5, 0.5]
        assertValid(v, Treemap.layout(v, Self.bounds), Self.bounds)
    }

    func testWorksForRandomInputsAndUnsortedOrder() {
        var state: UInt64 = 42
        func nextDouble() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        for _ in 0..<50 {
            let count = Int(nextDouble() * 59) + 1
            let v = (0..<count).map { _ in pow(nextDouble(), 3) * 1000.0 + 0.01 }
            let b = RectD(x: 0, y: 0, w: 100 + floor(nextDouble() * 900), h: 100 + floor(nextDouble() * 600))
            assertValid(v, Treemap.layout(v, b), b)
        }
    }

    func testZeroAndNegativeValuesGetEmptyRectanglesAndRestStillFillArea() {
        let v = [10.0, 0.0, 30.0, -5.0, 20.0]
        let r = Treemap.layout(v, Self.bounds)
        XCTAssertEqual(r[1].area, 0)
        XCTAssertEqual(r[3].area, 0)
        assertValid(v, r, Self.bounds)
    }

    func testEmptyInputOrEmptyBoundsGivesNoArea() {
        XCTAssertTrue(Treemap.layout([], Self.bounds).isEmpty)
        for r in Treemap.layout([1, 2], RectD(x: 0, y: 0, w: 0, h: 100)) {
            XCTAssertEqual(r.area, 0)
        }
        for r in Treemap.layout([0, 0], Self.bounds) {
            XCTAssertEqual(r.area, 0)
        }
    }

    func testBlocksStayReasonablySquare() {
        let v = (1...30).map { 1000.0 / Double($0) }
        let rects = Treemap.layout(v, RectD(x: 0, y: 0, w: 800, h: 500))
        for r in rects.prefix(10) {
            let aspect = max(r.w / r.h, r.h / r.w)
            XCTAssertTrue(aspect >= 1.0 && aspect <= 5.0, "Expected aspect ratio in 1...5, got \(aspect)")
        }
    }
}
