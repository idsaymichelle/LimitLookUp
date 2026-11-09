import SwiftUI
import BackgroundTasks

@main
struct LimitLookUpApp: App {
    @Environment(\.scenePhase) private var phase
    @StateObject private var model = AppModel.shared

    init() {
        WatchSync.shared.start()
        AppModel.shared.startCloudSync()
        // SwiftUI has no modifier for the inline navigation title font; set it once for the whole app.
        if let f = UIFont(name: "AvenirNext-DemiBold", size: 17) {
            UINavigationBar.appearance().titleTextAttributes = [.font: UIFontMetrics(forTextStyle: .headline).scaledFont(for: f)]
        }
        if let f = UIFont(name: "AvenirNext-Bold", size: 34) {
            UINavigationBar.appearance().largeTitleTextAttributes = [.font: UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: f)]
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model)
                .task {
                    // On first launch the welcome flow asks for notifications after the first account, not over it.
                    if Store.defaults.bool(forKey: "onboarded") { Notifier.request() }
                    await model.refresh()
                }
        }
        .onChange(of: phase) { _, p in if p == .background { scheduleRefresh() } }
        .backgroundTask(.appRefresh("refresh")) {
            await AppModel.shared.refresh()
            scheduleRefresh()
        }
    }
}

/// iOS decides when to actually run it; usually every 15–60 minutes.
func scheduleRefresh() {
    let r = BGAppRefreshTaskRequest(identifier: "refresh")
    r.earliestBeginDate = .now.addingTimeInterval(15 * 60)
    try? BGTaskScheduler.shared.submit(r)
}
