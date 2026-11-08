import Foundation

public enum Format {
    public static func size(_ bytes: Int64) -> String {
        let clamped = max(0, bytes)
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(clamped)
        var i = 0
        while v >= 1024.0 && i < units.count - 1 {
            v /= 1024.0
            i += 1
        }
        let formatted: String
        if i == 0 {
            formatted = String(format: "%.0f", v)
        } else if v >= 100.0 {
            formatted = String(format: "%.0f", v)
        } else if v >= 10.0 {
            formatted = String(format: "%.1f", v)
        } else {
            formatted = String(format: "%.2f", v)
        }
        return "\(formatted) \(units[i])"
    }

    public static func age(_ interval: TimeInterval) -> String {
        let days = interval / 86400.0
        let hours = interval / 3600.0
        if days >= 730 {
            return "\(Int(days / 365.0)) years"
        }
        if days >= 60 {
            return "\(Int(days / 30.0)) months"
        }
        if days >= 2 {
            return "\(Int(days)) days"
        }
        if hours >= 2 {
            return "\(Int(hours)) hours"
        }
        return "less than 2 hours"
    }
}
