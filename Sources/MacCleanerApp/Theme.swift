import SwiftUI
import AppKit
import MacCleanerCore

public struct RGBColor: Equatable, Sendable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    public var color: Color {
        Color(red: Double(r) / 255.0, green: Double(g) / 255.0, blue: Double(b) / 255.0)
    }

    public func lightened(_ amount: Double) -> Color {
        let nr = Double(r) + (255.0 - Double(r)) * amount
        let ng = Double(g) + (255.0 - Double(g)) * amount
        let nb = Double(b) + (255.0 - Double(b)) * amount
        return Color(red: nr / 255.0, green: ng / 255.0, blue: nb / 255.0)
    }
}

public enum Theme {
    private static func dynamicNSColor(
        dark: (UInt8, UInt8, UInt8, Double),
        light: (UInt8, UInt8, UInt8, Double)
    ) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat(c.0) / 255.0,
                green: CGFloat(c.1) / 255.0,
                blue: CGFloat(c.2) / 255.0,
                alpha: CGFloat(c.3)
            )
        }
    }

    private static func dynamicColor(
        dark: (UInt8, UInt8, UInt8, Double),
        light: (UInt8, UInt8, UInt8, Double)
    ) -> Color {
        Color(nsColor: dynamicNSColor(dark: dark, light: light))
    }

    public static let nsWindowBg = dynamicNSColor(
        dark: (0x1E, 0x1E, 0x1E, 1.0),
        light: (0xF4, 0xF5, 0xF7, 1.0)
    )

    public static let windowBg = Color(nsColor: nsWindowBg)
    public static let cardBg = dynamicColor(dark: (0x28, 0x28, 0x2A, 1.0), light: (0xFF, 0xFF, 0xFF, 1.0))
    public static let cardStroke = dynamicColor(dark: (0x38, 0x38, 0x3C, 1.0), light: (0xDC, 0xDC, 0xE2, 1.0))
    public static let controlBg = dynamicColor(dark: (0x32, 0x32, 0x36, 1.0), light: (0xEF, 0xEF, 0xF4, 1.0))
    public static let controlStroke = dynamicColor(dark: (0x46, 0x46, 0x4B, 1.0), light: (0xC4, 0xC4, 0xCC, 1.0))
    public static let hoverFill = dynamicColor(dark: (0xFF, 0xFF, 0xFF, 0.07), light: (0x00, 0x00, 0x00, 0.05))
    public static let progressTrack = dynamicColor(dark: (0xFF, 0xFF, 0xFF, 0.16), light: (0x00, 0x00, 0x00, 0.10))
    public static let modalBackdrop = dynamicColor(dark: (0x00, 0x00, 0x00, 0.60), light: (0x00, 0x00, 0x00, 0.35))

    public static let accent = dynamicColor(dark: (0x7A, 0xB5, 0xC1, 1.0), light: (0x1D, 0x78, 0x88, 1.0))
    public static let accentSelectedBg = dynamicColor(dark: (0x62, 0xA8, 0xB8, 1.0), light: (0x1D, 0x78, 0x88, 1.0))
    public static let textOnAccent = dynamicColor(dark: (0x10, 0x18, 0x1B, 1.0), light: (0xFF, 0xFF, 0xFF, 1.0))

    public static let textPrimary = dynamicColor(dark: (0xF5, 0xF5, 0xF7, 1.0), light: (0x1C, 0x1C, 0x1E, 1.0))
    public static let textSecondary = dynamicColor(dark: (0xAD, 0xAD, 0xB3, 1.0), light: (0x56, 0x56, 0x5E, 1.0))
    public static let textTertiary = dynamicColor(dark: (0x7E, 0x7E, 0x86, 1.0), light: (0x78, 0x78, 0x82, 1.0))

    public static let safe = dynamicColor(dark: (0x1E, 0x9E, 0x5A, 1.0), light: (0x16, 0x80, 0x47, 1.0))
    public static let review = dynamicColor(dark: (0xC7, 0x7C, 0x00, 1.0), light: (0xB2, 0x6A, 0x00, 1.0))
    public static let locked = dynamicColor(dark: (0x7A, 0x7F, 0x87, 1.0), light: (0x68, 0x6D, 0x75, 1.0))

    public static func tierColor(_ tier: RiskTier) -> Color {
        switch tier {
        case .safe: return safe
        case .review: return review
        case .locked: return locked
        }
    }

    public static func tierBackground(_ tier: RiskTier) -> Color {
        tierColor(tier).opacity(0.16)
    }

    public static let folderPalette: [RGBColor] = [
        RGBColor(0x3B, 0x82, 0xC4),
        RGBColor(0x2E, 0x9E, 0x8F),
        RGBColor(0x8B, 0x5C, 0xC6),
        RGBColor(0xC4, 0x6A, 0x3B),
        RGBColor(0x4F, 0x9D, 0x4F),
        RGBColor(0xB5, 0x48, 0x7A),
        RGBColor(0x6B, 0x7F, 0xD7),
        RGBColor(0xB0, 0x8A, 0x2E)
    ]

    public static let fileColor = RGBColor(0x5B, 0x65, 0x73)
    public static let otherColor = RGBColor(0x45, 0x4B, 0x54)
}
