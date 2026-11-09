import SwiftUI
import WebKit

/// The app's mark: the icon's three arcs.
struct GaugeMark: View {
    var size: CGFloat = 30
    var body: some View {
        // The three arcs cut straight from the app icon (Assets: Mark), so the mark always matches it.
        Image("Mark")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// "LimitLookUp" set large with the mark: the one accent on the main screen.
struct Wordmark: View {
    var size: CGFloat = 32
    var body: some View {
        HStack(spacing: size * 0.3) {
            GaugeMark(size: size * 0.85)
            Text(verbatim: "LimitLookUp")
                .font(.custom("AvenirNext-Bold", size: size))
                .kerning(-0.6)
                .foregroundStyle(Theme.wordmark)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "LimitLookUp"))
        .accessibilityAddTraits(.isHeader)
    }
}

/// Watches which site a sign-in web view shows.
final class HostWatcher {
    private var observation: NSKeyValueObservation?
    func watch(_ w: WKWebView, _ update: @escaping (String) -> Void) {
        observation = w.observe(\.url, options: [.initial, .new]) { w, _ in
            let host = w.url?.host ?? ""
            DispatchQueue.main.async { update(host) }
        }
    }
}

/// The open site's address above a sign-in page, with a warning when it is not the service's own site.
struct SiteBar: View {
    let host: String
    let expected: String
    var body: some View {
        let own = host == expected || host.hasSuffix("." + expected) || host.hasSuffix(".openai.com") || host == "openai.com"
        Label(host.isEmpty ? " " : host, systemImage: own ? "lock.fill" : "exclamationmark.triangle.fill")
            .font(Theme.font(.footnote, .demi))
            .foregroundStyle(own ? Theme.ink : Color.red)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(Theme.card)
            .accessibilityLabel(own ? Text("Site: \(host)") : Text("Not the service’s site: \(host)"))
    }
}
