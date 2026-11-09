import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Warm, quiet palette: cream paper / soft graphite, ink in warm greys, muted sage / ochre / rose for state.
enum Theme {
    static let bg = dynamic(0xEDEBE4, 0x1E1C1A) // dark: same graphite as the app icon
    static let ink = dynamic(0x1E1D1B, 0xE8E6DE)
    static let sub = dynamic(0x6B6962, 0x8F8C83)
    static let line = dynamic(0xD9D6CC, 0x35322F)
    static let card = dynamic(0xE3E0D7, 0x2A2826)
    static let track = dynamic(0xD6D3C9, 0x3A3734)
    static let ok = dynamic(0x4A7656, 0x7FA588)
    static let warn = dynamic(0x9C7A2A, 0xCDAE62)
    static let amber = dynamic(0xA8613A, 0xCF8C5E)
    static let over = dynamic(0x9A463D, 0xC46F64)

    // Brighter than the brand references (Claude #D97757, Codex icon #7A9DFF→#3941FF) so they read clearly on dark cards.
    /// The app's main colour: buttons, switches, charts, the logo.
    static let accent = Color(red: 0xE6 / 255, green: 0x73 / 255, blue: 0x3C / 255)
    static let accentDeep = Color(red: 0xC6 / 255, green: 0x5A / 255, blue: 0x28 / 255)
    // Service header bands: muted takes on Claude orange and Codex blue, calm next to the dark cards.
    static let claudeLight = Color(red: 0xD9 / 255, green: 0x8A / 255, blue: 0x63 / 255)
    static let claude = Color(red: 0xC2 / 255, green: 0x6D / 255, blue: 0x4A / 255)
    static let codexLight = Color(red: 0x70 / 255, green: 0x96 / 255, blue: 0xD8 / 255)
    static let codexDeep = Color(red: 0x4E / 255, green: 0x6F / 255, blue: 0xBF / 255)

    // App icon arcs, inner to outer.
    static let stepInner = Color(red: 0xFD / 255, green: 0x8B / 255, blue: 0x49 / 255)
    static let stepMiddle = Color(red: 0xCC / 255, green: 0x48 / 255, blue: 0x0B / 255)
    static let stepOuter = Color(red: 0xDB / 255, green: 0x33 / 255, blue: 0x1A / 255)

    /// The logo text takes the gauge's colors, left to right.
    static let wordmark = LinearGradient(colors: [accent, accentDeep], startPoint: .leading, endPoint: .trailing)

    /// Avenir Next: built into iOS, has Cyrillic and tabular digits, softer than the system font.
    /// Sizes follow the matching text style, so Dynamic Type still works.
    enum Weight: String { case regular = "Regular", medium = "Medium", demi = "DemiBold" }

    /// The Mac menu bar panel is a small utility window: everything a bit smaller, same proportions.
    #if os(macOS)
    static let k: CGFloat = 0.85
    #else
    static let k: CGFloat = 1
    #endif

    static func font(_ style: Font.TextStyle, _ weight: Weight = .regular) -> Font {
        let size: CGFloat = switch style {
        case .title2: 26; case .title3: 20; case .headline: 17; case .body: 17; case .callout: 16
        case .subheadline: 15; case .footnote: 13; case .caption: 12; case .caption2: 11; default: 17
        }
        return .custom("AvenirNext-\(weight.rawValue)", size: size * k, relativeTo: style)
    }

    /// The one-line status at the top.
    static let headline = font(.title3, .medium)

    /// Percentages use fixed-width digits so numbers do not jump between refreshes.
    static func number(_ style: Font.TextStyle, _ weight: Weight = .demi) -> Font {
        font(style, weight).monospacedDigit()
    }

    #if os(watchOS)
    // The watch is always dark. Debug builds can draw it light (-light) for the website's light-theme screenshots.
    static var watchLight: Bool {
        #if DEBUG
        CommandLine.arguments.contains("-light")
        #else
        false
        #endif
    }
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        let c = watchLight ? light : dark
        return Color(red: Double(c >> 16 & 0xFF) / 255, green: Double(c >> 8 & 0xFF) / 255, blue: Double(c & 0xFF) / 255)
    }
    #elseif canImport(UIKit)
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? rgb(dark) : rgb(light) })
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    #elseif canImport(AppKit)
    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light) })
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    #endif
}

/// Spent share on a track tinted with the same color, so the bar reads as one object.
struct PaceBar: View {
    let limit: Limit
    var height: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(limit.color.opacity(0.18))
                Capsule().fill(limit.color)
                    .frame(width: max(height, geo.size.width * min(limit.percent, 100) / 100))
            }
            .animation(reduceMotion ? nil : .snappy, value: limit.percent)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
