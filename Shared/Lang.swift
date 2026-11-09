import Foundation

/// The language chosen inside the app (nil = follow the system). Read on every lookup, so a change applies at once.
enum Lang {
    static var code: String? {
        let c = Store.defaults.string(forKey: "language") ?? ""
        return c.isEmpty ? nil : c
    }

    /// Translations for the chosen language; the system's when none is chosen.
    static var bundle: Bundle {
        let c = code
        if let hit = cache, hit.code == c { return hit.bundle }
        let b = c.flatMap { Bundle.main.path(forResource: $0, ofType: "lproj") }.flatMap(Bundle.init(path:)) ?? .main
        cache = (c, b)
        return b
    }
    /// Looked up once per language instead of for every string. Only read and written on the main thread.
    nonisolated(unsafe) private static var cache: (code: String?, bundle: Bundle)?

    static var locale: Locale { code.map(Locale.init(identifier:)) ?? .current }

    // Dates and numbers in the app's language, not the phone's (otherwise "Resets in 3 ч").
    static func time(_ d: Date) -> String { d.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)) }
    static func weekdayTime(_ d: Date) -> String { d.formatted(Date.FormatStyle().weekday(.abbreviated).hour().minute().locale(locale)) }
    static func dayMonth(_ d: Date) -> String { d.formatted(Date.FormatStyle().day().month(.abbreviated).locale(locale)) }
    static func month(_ d: Date) -> String { d.formatted(Date.FormatStyle().month(.abbreviated).locale(locale)) }
    static func relative(_ d: Date) -> String { d.formatted(Date.RelativeFormatStyle(presentation: .named).locale(locale)) }
    static func decimal(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(1)).locale(locale)) }
}

/// Localized string in the app's current language. Use instead of `String(localized:)`.
func L(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: Lang.bundle, locale: Lang.locale)
}
