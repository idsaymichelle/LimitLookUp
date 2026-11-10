import SwiftUI
import WebKit
import WidgetKit

/// Three tabs: limits, history, settings (settings sits bottom-right, as the last tab).
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("theme", store: Store.defaults) private var theme = "system"
    /// "" follows the system. Changing it re-renders everything in the new language right away.
    @AppStorage("language", store: Store.defaults) private var language = ""
    @AppStorage("onboarded", store: Store.defaults) private var onboarded = false
    /// Kept outside the re-created view tree, so switching language keeps you on the Settings tab.
    @State private var tab: Int = {
        #if DEBUG // screenshots: -tab N
        if let i = CommandLine.arguments.firstIndex(of: "-tab"), i + 1 < CommandLine.arguments.count { return Int(CommandLine.arguments[i + 1]) ?? 0 }
        #endif
        return 0
    }()
    @State private var notificationsOff = false
    @Environment(\.scenePhase) private var phase

    /// Notifications are required; if they get switched off later, the guide screen comes back until they are on.
    private func checkNotifications() async {
        notificationsOff = await NotificationAccess.status() == .denied
    }

    var body: some View {
        tabs
            .fullScreenCover(isPresented: Binding(get: { !onboarded && !Demo.on }, set: { _ in })) {
                OnboardingView { onboarded = true }
                    .environmentObject(model)
                    .environment(\.locale, Lang.locale)
                    .preferredColorScheme(scheme)
            }
            .fullScreenCover(isPresented: Binding(get: { onboarded && notificationsOff && !Demo.on }, set: { _ in })) {
                ZStack { Theme.bg.ignoresSafeArea(); NotificationsBlockedView() }
                    .environment(\.locale, Lang.locale)
                    .preferredColorScheme(scheme)
            }
            .task { await checkNotifications() }
            .onChange(of: phase) { _, p in if p == .active { Task { await checkNotifications() } } }
            .environment(\.locale, Lang.locale)
            .id(language)
            .preferredColorScheme(scheme)
    }

    private var scheme: ColorScheme? { theme == "light" ? .light : theme == "dark" ? .dark : nil }

    private var tabs: some View {
        TabView(selection: $tab) {
            LimitsView()
                .tabItem { Label("Limits", systemImage: "gauge.with.dots.needle.33percent") }.tag(0)
            InsightsView()
                .tabItem { Label("Stats", systemImage: "chart.bar.xaxis") }.tag(1)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }.tag(2)
        }
        .tint(Theme.ink)
    }
}

struct LimitsView: View {
    @EnvironmentObject var model: AppModel
    @State private var login: Account?
    @State private var renaming: Account?
    @State private var newLabel = ""
    @State private var removing: Account?
    /// The account just added from the menu; dropped again if its sign-in is closed without finishing.
    @State private var added: UUID?

    private func dropUnfinished() {
        guard let id = added, let a = model.accounts.first(where: { $0.id == id }) else { return }
        added = nil
        Task {
            await model.refreshAfterLogin()
            let u = model.usage.first { $0.accountID == id }
            if u == nil || (u?.limits.isEmpty == true && u?.temporary != true) { await model.logout(a) }
        }
    }

    private var isDemo: Bool { Demo.on }

    /// One row per account; in demo mode, one per sample entry.
    private var rows: [(id: String, service: Service, label: String?, usage: ServiceUsage?, account: Account?)] {
        if isDemo {
            return model.usage.map { u in (u.service, Service.allCases.first { u.service.hasPrefix($0.title) } ?? .claude, nil, u, nil) }
        }
        return model.accounts.map { a in
            (a.id.uuidString, a.service, a.label.flatMap { Int($0) == nil ? $0 : nil },
             model.usage.first { $0.accountID == a.id } ?? model.usage.first { $0.accountID == nil && $0.service == a.title }, a)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    HStack {
                        Wordmark()
                        Spacer()
                        if !rows.isEmpty { RefreshButton() }
                    }
                    .padding(.top, 4).padding(.bottom, 6)

                    if rows.isEmpty { emptyState }
                    ForEach(rows, id: \.id) { r in
                        AccountBlock(service: r.service, label: r.label, usage: r.usage, account: r.account,
                                     onLogin: { login = r.account },
                                     onRename: { newLabel = r.account?.label ?? ""; renaming = r.account },
                                     onRemove: { removing = r.account })
                    }
                    if !rows.isEmpty { addMenu(prominent: false).padding(.top, 2) }
                    ForEach(Array(model.remote.enumerated()), id: \.offset) { _, r in
                        VStack(alignment: .leading, spacing: 6) {
                            Label(L("From \(r.device)"), systemImage: "icloud")
                                .font(Theme.font(.caption, .medium)).foregroundStyle(Theme.sub)
                            AccountBlock(service: Service.allCases.first { r.usage.service.hasPrefix($0.title) } ?? .claude,
                                         label: nil, usage: r.usage, account: nil,
                                         onLogin: {}, onRename: {}, onRemove: {})
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .font(Theme.font(.body))
            .background(Theme.bg.ignoresSafeArea())
            .refreshable { await model.refresh() }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $login, onDismiss: dropUnfinished) { a in
                NavigationStack {
                    LoginPage(service: a.service, store: a.store)
                        .navigationTitle(a.title).navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("Done") { login = nil; Task { await model.refresh() } } }
                }
            }
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
    }

    /// Nothing added yet: one clear invitation instead of empty cards.
    private var emptyState: some View {
        VStack(spacing: 16) {
            GaugeMark(size: 64).padding(.top, 8)
            Text("No accounts yet").font(Theme.font(.title3, .demi)).foregroundStyle(Theme.ink)
            Text("Add an account to see how much of your limits is left and when they reset.")
                .font(Theme.font(.subheadline)).foregroundStyle(Theme.sub)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            addMenu(prominent: true).padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.top, 24)
    }

    /// The service choice lives inside the button's menu.
    private func addMenu(prominent: Bool) -> some View {
        Menu {
            ForEach(Service.available) { s in Button(s.title) { let a = model.addAccount(s); added = a.id; login = a } }
        } label: {
            Label("Add account", systemImage: "plus")
                .font(Theme.font(.headline, .demi))
                .frame(maxWidth: .infinity, minHeight: prominent ? 54 : 48)
                .foregroundStyle(prominent ? Theme.bg : Theme.ink)
                .background(prominent ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.card),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

struct InsightsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("threshold", store: Store.defaults) private var threshold = 80.0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    PageTitle("Stats")
                    OverviewCard(samples: model.statsHistory, threshold: threshold)
                    HistoryCard(samples: model.statsHistory, usage: model.usage.filter { $0.error == nil }, threshold: threshold)
                    ActivityCard(samples: model.statsHistory)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(Theme.bg.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

/// Languages the app ships. Names are written in their own language so anyone can find theirs.
let appLanguages: [(code: String, name: String)] = [
    ("en", "English"), ("ru", "Русский"), ("zh-Hant", "繁體中文"), ("zh-Hans", "简体中文"), ("es", "Español"),
    ("ko", "한국어"), ("ar", "العربية"), ("de", "Deutsch"), ("it", "Italiano"), ("fr", "Français"), ("ja", "日本語"),
]

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("theme", store: Store.defaults) private var theme = "system"
    @AppStorage("threshold", store: Store.defaults) private var threshold = 80.0
    @AppStorage("showRemaining", store: Store.defaults) private var showRemaining = false
    @AppStorage("compact", store: Store.defaults) private var compact = false
    @AppStorage("notifyThreshold", store: Store.defaults) private var notifyThreshold = true
    @AppStorage("notifyReset", store: Store.defaults) private var notifyReset = true
    @AppStorage("notifyEarly", store: Store.defaults) private var notifyEarly = true
    @AppStorage("language", store: Store.defaults) private var language = ""
    @AppStorage("showIdentity", store: Store.defaults) private var showIdentity = true
    @AppStorage("onboarded", store: Store.defaults) private var onboarded = false
    @Environment(\.colorScheme) private var colorScheme
    @State private var confirmClear = false
    @State private var confirmDeleteAll = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    PageTitle("Settings")
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 0))
                }
                Section {
                    Button("Delete all data", role: .destructive) { confirmDeleteAll = true }
                }

                Section {
                    Picker("Theme", selection: $theme) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    Picker("Language", selection: $language) {
                        Text("System").tag("")
                        ForEach(appLanguages, id: \.code) { Text(verbatim: $0.name).tag($0.code) }
                    }
                    .onChange(of: language) { _, code in setLanguage(code) }
                    Picker("Layout", selection: $compact) {
                        Text("Detailed").tag(false)
                        Text("Compact").tag(true)
                    }
                    if compact { CompactPreview() }
                    Toggle("Show remaining", isOn: $showRemaining)
                    Toggle("Show account name and email", isOn: $showIdentity)
                } header: { Text("Appearance") }

                Section {
                    Toggle("Limit almost used up", isOn: $notifyThreshold)
                    if notifyThreshold {
                        VStack(alignment: .leading) {
                            Text("Notify at \(Int(threshold))% used")
                            Slider(value: $threshold, in: 50...100, step: 5)
                        }
                    }
                    Toggle("Limit reset", isOn: $notifyReset)
                    Toggle("Limit reset early", isOn: $notifyEarly)
                } header: { Text("Notifications") } footer: {
                    Text("An early reset is when a service restores a limit before the announced time.")
                }

                Section {
                    Button("Clear history", role: .destructive) { confirmClear = true }
                } header: { Text("Data") }

                Section {
                    Text("LimitLookUp has no server of its own. Limits are requested only from the sites of the services you add and are stored on this device.")
                        .font(Theme.font(.footnote)).foregroundStyle(Theme.sub)
                    Link("Privacy Policy", destination: Site.privacy)
                    Link("Terms of Use", destination: Site.terms)
                    Link("Help and support", destination: Site.support)
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                } header: { Text("About") }
            }
            .font(Theme.font(.body))
            .tint(Theme.accent)
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .contentMargins(.top, 8, for: .scrollContent)
            .toolbar(.hidden, for: .navigationBar)
            .alert("Delete all data?", isPresented: $confirmDeleteAll) {
                Button("Delete all data", role: .destructive) {
                    Task { await model.deleteAll(); onboarded = false }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your profile, all accounts and their sign-ins, history and settings will be removed from this device and from iCloud. This can't be undone.")
            }
            .alert("Clear history?", isPresented: $confirmClear) {
                Button("Clear history", role: .destructive) { model.history = []; History.save([]) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Charts and activity will start from scratch. Limits and accounts are not affected.")
            }
        }
    }

    /// The app switches at once (see `Lang`). Also tell iOS, so system parts such as dialogs follow on next launch.
    private func setLanguage(_ code: String) {
        if code.isEmpty { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([code], forKey: "AppleLanguages") }
        Task { await model.refresh() } // re-create messages that were stored in the old language
        WidgetCenter.shared.reloadAllTimelines()
    }
}

/// Login page. Uses the account's own data store, so its session stays inside WebKit and apart from other accounts.
struct WebView: UIViewRepresentable {
    let url: URL
    let store: WKWebsiteDataStore
    /// The site actually open, shown above the page: a link inside it can lead anywhere, so the user sees where they type.
    @Binding var host: String
    func makeCoordinator() -> HostWatcher { HostWatcher() }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        let w = WKWebView(frame: .zero, configuration: config)
        context.coordinator.watch(w) { host = $0 }
        w.load(URLRequest(url: url))
        return w
    }
    func updateUIView(_ w: WKWebView, context: Context) {}
}

/// Arrow spins while refreshing; a light tap when new numbers arrive. Still when Reduce Motion is on.
struct RefreshButton: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { Task { await model.refresh() } } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 16, weight: .semibold))
                .rotationEffect(.degrees(model.loading && !reduceMotion ? 360 : 0))
                .animation(model.loading && !reduceMotion
                           ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .easeOut(duration: 0.3),
                           value: model.loading)
                .frame(width: 42, height: 42)
                .background(Theme.card, in: Circle())
        }
        .foregroundStyle(Theme.ink)
        .disabled(model.loading)
        .sensoryFeedback(.success, trigger: model.refreshCount)
        .accessibilityLabel("Refresh")
    }
}

/// Section title that scrolls away with the page (no pinned bar), matching the logo on the Limits tab.
struct PageTitle: View {
    let key: LocalizedStringKey
    init(_ key: LocalizedStringKey) { self.key = key }
    var body: some View {
        Text(key)
            .font(.custom("AvenirNext-Bold", size: 32, relativeTo: .largeTitle))
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Service sign-in page with a note on top: Google blocks its sign-in inside apps' web views, so suggest email.
struct LoginPage: View {
    let service: Service
    let store: WKWebsiteDataStore
    @State private var host = ""
    var body: some View {
        VStack(spacing: 0) {
            SiteBar(host: host, expected: service.host)
            Label("Sign in with email. Google doesn’t allow its sign-in inside apps.", systemImage: "envelope")
                .font(Theme.font(.footnote, .medium))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Theme.accent.opacity(0.18))
            WebView(url: service.loginURL, store: store, host: $host)
        }
    }
}
