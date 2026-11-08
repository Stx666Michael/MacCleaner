import Foundation

public struct RectD: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double

    public var right: Double { x + w }
    public var bottom: Double { y + h }
    public var area: Double { w * h }

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

/// Squarified treemap layout (Bruls, Huijing, van Wijk): blocks stay as close to square as possible.
public enum Treemap {
    /// Splits `bounds` into one rectangle per value, each with an area proportional to its value.
    /// Values that are zero or negative get an empty rectangle. The result is in the same order as the input.
    public static func layout(_ values: [Double], _ bounds: RectD) -> [RectD] {
        var result = Array(repeating: RectD(x: 0, y: 0, w: 0, h: 0), count: values.count)
        if values.isEmpty || bounds.w <= 0 || bounds.h <= 0 {
            return result
        }

        // Indices of positive values, largest first (the algorithm needs descending order).
        let idx = values.indices
            .filter { values[$0] > 0 }
            .sorted { values[$0] > values[$1] }
        if idx.isEmpty {
            return result
        }

        let total = idx.reduce(0.0) { $0 + values[$1] }
        let scale = bounds.w * bounds.h / total
        let areas = idx.map { values[$0] * scale }

        var rest = bounds
        var start = 0
        while start < areas.count {
            let side = min(rest.w, rest.h)
            var end = start + 1
            var sum = areas[start]
            var minVal = areas[start]
            var maxVal = areas[start]
            var worstRatio = worst(sum: sum, min: minVal, max: maxVal, side: side)

            // Keep adding blocks to the current row while that does not make the shapes worse.
            while end < areas.count {
                let a = areas[end]
                let s2 = sum + a
                let mn = min(minVal, a)
                let mx = max(maxVal, a)
                let w2 = worst(sum: s2, min: mn, max: mx, side: side)
                if w2 > worstRatio { break }
                sum = s2
                minVal = mn
                maxVal = mx
                worstRatio = w2
                end += 1
            }

            if rest.w >= rest.h {
                // Wide area: the row is a column down the left edge.
                let colW = min(sum / rest.h, rest.w)
                var y = rest.y
                for k in start..<end {
                    let h = areas[k] / colW
                    result[idx[k]] = RectD(x: rest.x, y: y, w: colW, h: h)
                    y += h
                }
                rest = RectD(x: rest.x + colW, y: rest.y, w: max(0, rest.w - colW), h: rest.h)
            } else {
                // Tall area: the row runs along the top edge.
                let rowH = min(sum / rest.w, rest.h)
                var x = rest.x
                for k in start..<end {
                    let w = areas[k] / rowH
                    result[idx[k]] = RectD(x: x, y: rest.y, w: w, h: rowH)
                    x += w
                }
                rest = RectD(x: rest.x, y: rest.y + rowH, w: rest.w, h: max(0, rest.h - rowH))
            }
            start = end
        }
        return result
    }

    /// The worst (largest) aspect ratio in a row of the given areas laid along a side of the given length.
    private static func worst(sum: Double, min: Double, max: Double, side: Double) -> Double {
        let s2 = sum * sum
        let w2 = side * side
        return Swift.max(w2 * max / s2, s2 / (w2 * min))
    }
}
