import SwiftUI
import WebKit
import ServiceManagement

/// Menu bar version. A status item opens a small panel that grows to the right of the icon.
/// Same fetching, data and settings as the iPhone app; logins on the Mac are its own.
@main
struct LimitLookUpMac: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Settings { EmptyView() } // no windows of its own; everything lives in the status item panel
    }
}

/// A borderless panel that can take keyboard focus (for the rename field) without activating the app's windows.
final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var shared: AppDelegate!
    private var item: NSStatusItem!
    private var panel: MenuPanel!
    private var clickMonitor: Any?
    private var loginWindows: [UUID: NSWindow] = [:]
    /// Wide and tall enough for two full accounts (e.g. Claude Code with four limits and Codex) plus the add buttons.
    static let panelSize = NSSize(width: 320, height: 500)

    func applicationDidFinishLaunching(_ n: Notification) {
        Self.shared = self
        let model = AppModel.shared

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            if let m = NSImage(named: "Mark")?.copy() as? NSImage { m.size = NSSize(width: 16, height: 16); b.image = m }
            b.imagePosition = .imageOnly
            b.setAccessibilityLabel("LimitLookUp")
            b.target = self
            b.action = #selector(clicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        panel = MenuPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: PopoverRoot().environmentObject(model))

        Notifier.request()
        model.startCloudSync()
        Task { @MainActor in
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }

        #if DEBUG
        // -snapshot <path>: open the panel and save it as PNG (no screen-recording permission needed).
        if let i = CommandLine.arguments.firstIndex(of: "-snapshot"), i + 1 < CommandLine.arguments.count {
            show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let v = self?.panel.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            }
        }
        #endif
    }

    /// Left click opens the panel; right click (or Control-click) shows a small menu with Quit,
    /// because a menu bar app has no Dock icon or window to quit from.
    @objc private func clicked() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            hide()
            let m = NSMenu()
            m.addItem(withTitle: L("Open LimitLookUp"), action: #selector(openPanel), keyEquivalent: "").target = self
            m.addItem(.separator())
            m.addItem(withTitle: L("Quit LimitLookUp"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            item.menu = m
            item.button?.performClick(nil) // shows the menu under the icon
            item.menu = nil                // so the next left click opens the panel again
        } else {
            panel.isVisible && !closing ? hide() : show()
        }
    }

    @objc private func openPanel() { show() }

    /// Left edge lines up with the icon, so the panel opens to the right; kept inside the screen.
    private func show() {
        guard let b = item.button, let w = b.window else { return }
        let icon = w.convertToScreen(b.convert(b.bounds, to: nil))
        let screen = (w.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var size = Self.panelSize
        // Fit small screens; ignore the measurement while the status item is not on screen yet.
        let room = icon.minY - screen.minY - 14
        if room > 320 { size.height = min(size.height, room) }
        var x = icon.minX
        if x + size.width > screen.maxX - 8 { x = screen.maxX - 8 - size.width }
        let final = NSRect(x: x, y: icon.minY - size.height - 6, width: size.width, height: size.height)
        // Fade in while sliding down a few points, about as quick as a system menu.
        closing = false
        panel.setFrame(final.offsetBy(dx: 0, dy: 6), display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.14
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(final, display: true)
        }
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    private var closing = false

    /// Fades out quickly, then leaves the screen. A click during the fade is treated as already closed.
    private func hide() {
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        guard panel.isVisible, !closing else { return }
        closing = true
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.1
            c.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.closing else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.closing = false
            }
        })
    }

    /// Sign-in page for one account in its own window. New accounts are dropped again if closed without signing in.
    func openLogin(_ a: Account, isNew: Bool) {
        hide()
        if let w = loginWindows[a.id] { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 720),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = a.service.title
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: LoginPane(account: a) { [weak w] in w?.close() }
            .environment(\.locale, Lang.locale))
        w.center()
        loginWindows[a.id] = w
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            if let token { NotificationCenter.default.removeObserver(token) }
            Task { @MainActor in
                self?.loginWindows[a.id] = nil
                await Self.finishLogin(a, isNew: isNew)
            }
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func finishLogin(_ a: Account, isNew: Bool) async {
        let model = AppModel.shared
        await model.refreshAfterLogin()
        guard isNew else { return }
        let u = model.usage.first { $0.accountID == a.id }
        if u == nil || (u?.limits.isEmpty == true && u?.temporary != true) { await model.logout(a) }
    }
}

/// Applies theme and language for the whole panel, like the iPhone root view.
struct PopoverRoot: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("theme", store: Store.defaults) private var theme = "system"
    @AppStorage("language", store: Store.defaults) private var language = ""

    var body: some View {
        MenuView()
            .environment(\.locale, Lang.locale)
            .id(language)
            .preferredColorScheme(theme == "light" ? .light : theme == "dark" ? .dark : nil)
    }
}

/// Small, quiet panel: icon tabs in the header, one-line limit rows, no big cards.
struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @State private var renaming: Account?
    @State private var newLabel = ""
    @State private var removing: Account?
    @State private var tab = {
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "-tab"), i + 1 < CommandLine.arguments.count { return Int(CommandLine.arguments[i + 1]) ?? 0 }
        #endif
        return 0
    }()

    private var isDemo: Bool { Demo.on }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                GaugeMark(size: 16)
                Text(verbatim: "LimitLookUp").font(.custom("AvenirNext-Bold", size: 13.5)).foregroundStyle(Theme.wordmark)
                Spacer()
                tabButton(0, "gauge.with.dots.needle.33percent", "Limits")
                tabButton(1, "chart.bar", "Stats")
                tabButton(2, "gearshape", "Settings")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider().overlay(Theme.line)

            ScrollView {
                VStack(spacing: 8) {
                    switch tab {
                    case 0: limits
                    case 1:
                        OverviewCard(samples: model.statsHistory, threshold: Notifier.threshold)
                        HistoryCard(samples: model.statsHistory, usage: model.usage.filter { $0.error == nil }, threshold: Notifier.threshold)
                        ActivityCard(samples: model.statsHistory)
                    default: MacSettings()
                    }
                }
                .padding(8)
            }

            if tab == 0 { footer }
        }
        .frame(width: AppDelegate.panelSize.width)
        .frame(maxHeight: .infinity)
        .background(Theme.bg)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line, lineWidth: 1))
        .font(Theme.font(.subheadline))
        .tint(Theme.accent)
        .alert("Account name", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("For example, Work", text: $newLabel)
            Button("Save") { if let a = renaming { model.rename(a, to: newLabel) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only you see this name. It helps tell accounts of the same service apart.")
        }
        .alert(removing.map { L("Remove “\($0.title)”?") } ?? "",
               isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove account", role: .destructive) { if let a = removing { Task { await model.logout(a) } } }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The sign-in will be deleted from this device. The account itself stays with the service.")
        }
    }

    private func tabButton(_ i: Int, _ icon: String, _ help: LocalizedStringKey) -> some View {
        Button { tab = i } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 20)
                .foregroundStyle(tab == i ? Theme.accent : Theme.sub)
                .background(tab == i ? Theme.card : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder private var limits: some View {
        if isDemo {
            ForEach(model.usage, id: \.service) { u in
                AccountBlock(service: Service.allCases.first { u.service.hasPrefix($0.title) } ?? .claude, label: nil, usage: u, account: nil,
                             onLogin: {}, onRename: {}, onRemove: {}, dense: true)
            }
        } else if model.accounts.isEmpty {
            VStack(spacing: 10) {
                GaugeMark(size: 40).padding(.top, 18)
                Text("No accounts yet").font(Theme.font(.subheadline, .demi)).foregroundStyle(Theme.ink)
                Text("Add an account to see how much of your limits is left and when they reset.")
                    .font(Theme.font(.caption)).foregroundStyle(Theme.sub)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }
        } else {
            ForEach(model.accounts) { a in
                AccountBlock(service: a.service, label: a.label.flatMap { Int($0) == nil ? $0 : nil },
                             usage: model.usage.first { $0.accountID == a.id }, account: a,
                             onLogin: { AppDelegate.shared.openLogin(a, isNew: false) },
                             onRename: { newLabel = a.label ?? ""; renaming = a },
                             onRemove: { removing = a }, dense: true)
            }
        }
        ForEach(Array(model.remote.enumerated()), id: \.offset) { _, r in
            VStack(alignment: .leading, spacing: 4) {
                Label(L("From \(r.device)"), systemImage: "icloud")
                    .font(Theme.font(.caption2, .medium)).foregroundStyle(Theme.sub)
                AccountBlock(service: Service.allCases.first { r.usage.service.hasPrefix($0.title) } ?? .claude,
                             label: nil, usage: r.usage, account: nil, onLogin: {}, onRename: {}, onRemove: {}, dense: true)
            }
        }
    }

    /// Add buttons in the services' colours, then refresh.
    private var footer: some View {
        HStack(spacing: 6) {
            ForEach(Service.available) { s in
                Button { AppDelegate.shared.openLogin(model.addAccount(s), isNew: true) } label: {
                    Label { Text(verbatim: s.title) } icon: { Image(systemName: "plus") }
                        .font(Theme.font(.caption, .demi))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9).frame(height: 22)
                        .background(Brand.fill(s), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Sign in to \(s.title)"))
            }
            Spacer()
            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .rotationEffect(.degrees(model.loading ? 360 : 0))
                    .animation(model.loading ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: model.loading)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.sub)
            .disabled(model.loading)
            .help("Refresh")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .overlay(alignment: .top) { Divider().overlay(Theme.line) }
    }
}

/// Settings that make sense on a Mac; same storage keys as the iPhone app.
struct MacSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("theme", store: Store.defaults) private var theme = "system"
    @AppStorage("language", store: Store.defaults) private var language = ""
    @AppStorage("compact", store: Store.defaults) private var compact = false
    @AppStorage("showRemaining", store: Store.defaults) private var showRemaining = false
    @AppStorage("showIdentity", store: Store.defaults) private var showIdentity = true
    @AppStorage("threshold", store: Store.defaults) private var threshold = 80.0
    @AppStorage("notifyThreshold", store: Store.defaults) private var notifyThreshold = true
    @AppStorage("notifyReset", store: Store.defaults) private var notifyReset = true
    @AppStorage("notifyEarly", store: Store.defaults) private var notifyEarly = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 10) {
            group("Appearance") {
                row("Theme") {
                    Picker("", selection: $theme) {
                        Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                    }
                }
                row("Language") {
                    Picker("", selection: $language) {
                        Text("System").tag("")
                        ForEach(appLanguages, id: \.code) { Text(verbatim: $0.name).tag($0.code) }
                    }
                }
                row("Layout") {
                    Picker("", selection: $compact) { Text("Detailed").tag(false); Text("Compact").tag(true) }
                }
                row("Show remaining") { Toggle("", isOn: $showRemaining) }
                row("Show account name and email") { Toggle("", isOn: $showIdentity) }
            }
            group("Notifications", note: "An early reset is when a service restores a limit before the announced time.") {
                row("Limit almost used up") { Toggle("", isOn: $notifyThreshold) }
                if notifyThreshold {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notify at \(Int(threshold))% used").foregroundStyle(Theme.sub)
                        Slider(value: $threshold, in: 50...100, step: 5)
                    }
                }
                row("Limit reset") { Toggle("", isOn: $notifyReset) }
                row("Limit reset early") { Toggle("", isOn: $notifyEarly) }
            }
            group("General") {
                row("Launch at login") { Toggle("", isOn: $launchAtLogin) }
                    .onChange(of: launchAtLogin) { _, on in
                        try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                Divider().overlay(Theme.line)
                action("Clear history", role: .destructive) { confirmClear = true }
                action("Quit LimitLookUp") { NSApplication.shared.terminate(nil) }
            }
            group("About") {
                link("Privacy Policy", Site.privacy)
                link("Terms of Use", Site.terms)
                link("Help and support", Site.support)
                Divider().overlay(Theme.line)
                HStack {
                    Text("Version")
                    Spacer()
                    Text(verbatim: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0").foregroundStyle(Theme.sub)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .alert("Clear history?", isPresented: $confirmClear) {
            Button("Clear history", role: .destructive) { model.history = []; History.save([]) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Charts and activity will start from scratch. Limits and accounts are not affected.")
        }
    }

    /// A full-width text button, left-aligned like a settings row.
    private func action(_ title: LocalizedStringKey, role: ButtonRole? = nil, _ run: @escaping () -> Void) -> some View {
        Button(role: role, action: run) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Theme.over : Theme.accent)
    }

    /// A link row with an arrow that shows it opens the website.
    private func link(_ title: LocalizedStringKey, _ url: URL) -> some View {
        Link(destination: url) {
            HStack {
                Text(title).foregroundStyle(Theme.ink)
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.sub)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func group<C: View>(_ title: LocalizedStringKey, note: LocalizedStringKey? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Theme.font(.caption, .demi)).foregroundStyle(Theme.sub).padding(.leading, 4)
            VStack(alignment: .leading, spacing: 11) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if let note {
                Text(note).font(Theme.font(.caption2)).foregroundStyle(Theme.sub)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
        }
    }

    private func row<C: View>(_ title: LocalizedStringKey, @ViewBuilder _ control: () -> C) -> some View {
        HStack(spacing: 10) {
            // Long titles wrap instead of pushing the control off the edge.
            Text(title).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            control().labelsHidden().fixedSize()
        }
    }
}

/// Languages the app ships (same list as the iPhone app). Names in their own language.
let appLanguages: [(code: String, name: String)] = [
    ("en", "English"), ("ru", "Русский"), ("zh-Hant", "繁體中文"), ("zh-Hans", "简体中文"), ("es", "Español"),
    ("ko", "한국어"), ("ar", "العربية"), ("de", "Deutsch"), ("it", "Italiano"), ("fr", "Français"), ("ja", "日本語"),
]

/// Sign-in page with the email hint, shown in its own window.
struct LoginPane: View {
    let account: Account
    let done: () -> Void
    @State private var host = ""
    var body: some View {
        VStack(spacing: 0) {
            SiteBar(host: host, expected: account.service.host)
            HStack {
                Label("Sign in with email. Google doesn’t allow its sign-in inside apps.", systemImage: "envelope")
                    .font(Theme.font(.footnote, .medium))
                Spacer()
                Button("Done", action: done)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.accent.opacity(0.18))
            MacWebView(url: account.service.loginURL, store: account.store, host: $host)
        }
    }
}

/// Login page in the account's own data store, so sessions stay inside WebKit and apart from each other.
struct MacWebView: NSViewRepresentable {
    let url: URL
    let store: WKWebsiteDataStore
    @Binding var host: String
    func makeCoordinator() -> HostWatcher { HostWatcher() }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        let w = WKWebView(frame: .zero, configuration: config)
        context.coordinator.watch(w) { host = $0 }
        w.load(URLRequest(url: url))
        return w
    }
    func updateNSView(_ w: WKWebView, context: Context) {}
}
