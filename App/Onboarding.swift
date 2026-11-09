import SwiftUI
import AuthenticationServices
import UserNotifications

/// Contact details from Sign in with Apple. Kept on this device only; there is no server to send them to.
enum Profile {
    private static let d = UserDefaults.standard
    static var name: String? { d.string(forKey: "profile.name") }
    static var email: String? { d.string(forKey: "profile.email") }
    static var isSignedIn: Bool { d.string(forKey: "profile.user") != nil }

    /// Apple sends name and email only on the very first sign-in, so keep what we already have when they are missing.
    static func save(_ c: ASAuthorizationAppleIDCredential) {
        d.set(c.user, forKey: "profile.user")
        if let n = c.fullName, let s = Optional(PersonNameComponentsFormatter().string(from: n)), !s.isEmpty { d.set(s, forKey: "profile.name") }
        if let e = c.email { d.set(e, forKey: "profile.email") }
    }

    static func signOut() {
        for k in ["profile.user", "profile.name", "profile.email"] { d.removeObject(forKey: k) }
    }
}

/// Notification permission, read and requested in one place. The app needs alerts to do its job.
enum NotificationAccess {
    static func status() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
    static func request() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }
    #if os(iOS)
    /// Opens this app's notification page in Settings (the user taps a button; never opened automatically).
    @MainActor static func openSettings() {
        // The app's own Settings page (Notifications is one row on it), reliable on every iOS version.
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
    #endif
}

/// Shared frame for every onboarding step: art on top, title and text, one main action at the bottom.
struct OnboardingPage<Art: View, Actions: View>: View {
    let step: Int?
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    @ViewBuilder var art: Art
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 0) {
            if let step {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in
                        Capsule().fill(i == step ? Theme.accent : Theme.track)
                            .frame(width: i == step ? 22 : 7, height: 7)
                    }
                }
                .padding(.top, 12)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L("Step \(step + 1) of 3"))
            }
            Spacer(minLength: 16)
            art
            Spacer(minLength: 16)
            // Type scale: 30/34 bold title, 17/25 body, 16 pt between them, 32 pt before the actions.
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.custom("AvenirNext-Bold", size: 30, relativeTo: .largeTitle)).kerning(-0.3)
                    .lineSpacing(-2)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(text)
                    .font(Theme.font(.body)).foregroundStyle(Theme.sub)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 340, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 12) { actions }
                .padding(.top, 32)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 24)
    }
}

/// Main call to action: full width, app colour.
struct PrimaryButton: View {
    let title: LocalizedStringKey
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(Theme.font(.headline, .demi))
                .frame(maxWidth: .infinity, minHeight: 54)
                .foregroundStyle(.white)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

/// First launch: Sign in with Apple, connect a service, allow notifications. No way around any step.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    let finish: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var phase
    enum Step { case welcome, connect, notify, denied }
    @State private var step: Step = .welcome
    @State private var appleFailed = false
    @State private var login: Account?
    @State private var loginFailed = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            Group {
                switch step {
                case .welcome: welcome
                case .connect: connect
                case .notify: notify
                case .denied: NotificationsBlockedView()
                }
            }
            .transition(.opacity)
        }
        .animation(.easeOut(duration: 0.25), value: step)
        .task {
            #if DEBUG
            // Sign in with Apple needs a paid developer team, so simulator runs can start one step later.
            if CommandLine.arguments.contains("-skipAppleSignIn") { step = .connect }
            if Profile.isSignedIn { step = model.accounts.isEmpty ? .connect : .notify }
            // Preview any step: -onboardingStep welcome|connect|notify|denied
            if let i = CommandLine.arguments.firstIndex(of: "-onboardingStep"), i + 1 < CommandLine.arguments.count {
                step = ["welcome": .welcome, "connect": .connect, "notify": .notify, "denied": .denied][CommandLine.arguments[i + 1]] ?? step
            }
            #else
            if Profile.isSignedIn { step = model.accounts.isEmpty ? .connect : .notify }
            #endif
        }
        .onChange(of: phase) { _, p in
            // Back from Settings: continue as soon as notifications are on.
            if p == .active, step == .denied { Task { if await NotificationAccess.status() == .authorized { finish() } } }
        }
        .sheet(item: $login, onDismiss: checkLogin) { a in
            NavigationStack {
                LoginPage(service: a.service, store: a.store)
                    .navigationTitle(a.service.title).navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Done") { login = nil } }
            }
        }
    }

    // MARK: Steps

    private var welcome: some View {
        OnboardingPage(step: 0, title: "Your AI limits at a glance",
                       text: "See how much of your Claude Code and Codex limits is left and when they reset. Sign in with Apple to start; your name and email stay on this device.") {
            DrawnMark()
        } actions: {
            SignInWithAppleButton(.signIn) { $0.requestedScopes = [.fullName, .email] } onCompletion: { r in
                if case .success(let auth) = r, let c = auth.credential as? ASAuthorizationAppleIDCredential {
                    Profile.save(c); appleFailed = false; step = model.accounts.isEmpty ? .connect : .notify
                } else { appleFailed = true }
            }
            .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
            .frame(height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            if appleFailed {
                Text("Couldn’t sign in with Apple. Check your internet connection and try again.")
                    .font(Theme.font(.footnote)).foregroundStyle(Theme.warn)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var connect: some View {
        OnboardingPage(step: 1, title: "Connect your first account",
                       text: "Choose a service and sign in on its official page. LimitLookUp only reads your usage limits.") {
            GaugeMark(size: 120)
        } actions: {
            ForEach(Service.available) { s in ServiceTile(service: s) { login = model.addAccount(s) } }
            if loginFailed {
                Text("Sign-in wasn’t finished. Choose the service again to sign in.")
                    .font(Theme.font(.footnote)).foregroundStyle(Theme.warn)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var notify: some View {
        OnboardingPage(step: 2, title: "Turn on notifications",
                       text: "LimitLookUp warns you before a limit runs out and tells you when it resets. iOS will now ask for permission: tap “Allow”.") {
            NotificationPreview()
        } actions: {
            PrimaryButton(title: "Continue") {
                Task {
                    if await NotificationAccess.request() { finish() } else { step = .denied }
                }
            }
        }
    }

    /// After the login sheet closes: keep the account only if it actually signed in.
    private func checkLogin() {
        guard let a = model.accounts.last else { return }
        Task {
            await model.refreshAfterLogin()
            let u = model.usage.first { $0.accountID == a.id }
            if let u, u.error == nil, !u.limits.isEmpty {
                loginFailed = false
                step = .notify
            } else if u?.temporary == true {
                // Network trouble, not a failed sign-in: keep the session and let the user try again.
                loginFailed = true
            } else {
                await model.logout(a)
                loginFailed = true
            }
        }
    }
}

/// The logo appearing once, the welcome screen's single moment of motion.
struct DrawnMark: View {
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GaugeMark(size: 150)
            .scaleEffect(shown || reduceMotion ? 1 : 0.85)
            .opacity(shown || reduceMotion ? 1 : 0)
            .animation(reduceMotion ? nil : .spring(duration: 0.7, bounce: 0.25), value: shown)
            .onAppear { shown = true }
    }
}

/// A realistic example of the alert the user is about to allow.
struct NotificationPreview: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            GaugeMark(size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(verbatim: "LimitLookUp").font(Theme.font(.footnote, .demi)).foregroundStyle(Theme.sub)
                    Spacer()
                    Text("now").font(Theme.font(.footnote)).foregroundStyle(Theme.sub)
                }
                Text(L("\(Service.claude.title): limit almost used up")).font(Theme.font(.subheadline, .demi)).foregroundStyle(Theme.ink)
                Text(L("“\(Limit(name: "5 hours", percent: 0, resetsAt: nil).title)”: \(Int(85))% used. Resets at \(Lang.time(.now.addingTimeInterval(5400)))."))
                    .font(Theme.font(.subheadline)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Shown when notifications are off: the app cannot do its job, so it stops here and explains how to turn them on.
struct NotificationsBlockedView: View {
    var body: some View {
        OnboardingPage(step: nil, title: "Notifications are off",
                       text: "LimitLookUp needs notifications to warn you about limits and resets. iOS won’t ask again, so turn them on in Settings:") {
            Image(systemName: "bell.slash.fill")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 130, height: 130)
                .background(Theme.card, in: Circle())
                .accessibilityHidden(true)
        } actions: {
            VStack(alignment: .leading, spacing: 14) {
                step(1, "Tap “Open Settings”.")
                step(2, "Open “Apps”.")
                step(3, "Open “LimitLookUp”.")
                step(4, "Tap “Notifications”.")
                step(5, "Turn on “Allow Notifications”.")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            PrimaryButton(title: "Open Settings") {
                Task {
                    // iOS adds "Notifications" to the app's Settings page only after the app has asked once.
                    if await NotificationAccess.status() == .notDetermined, await NotificationAccess.request() { return }
                    NotificationAccess.openSettings()
                }
            }
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: "\(n)")
                .font(Theme.number(.subheadline)).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Theme.accent, in: Circle())
            Text(text).font(Theme.font(.body)).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A large, tappable choice of service in its brand colour (no company logos).
struct ServiceTile: View {
    let service: Service
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: service.title).font(.custom("AvenirNext-Bold", size: 21, relativeTo: .title3))
                    Text(verbatim: service == .claude ? "claude.ai" : "chatgpt.com").font(Theme.font(.footnote)).opacity(0.85)
                }
                Spacer()
                Image(systemName: "arrow.right").font(.system(size: 17, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20).padding(.vertical, 20)
            .background(Brand.fill(service), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L("Sign in to \(service.title)"))
    }
}
