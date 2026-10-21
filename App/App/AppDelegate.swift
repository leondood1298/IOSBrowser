import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // UI tests launch with --reset-state so saved tabs from earlier runs don't leak in.
        if ProcessInfo.processInfo.arguments.contains("--reset-state") {
            AppFolders.eraseSavedState()
        }
        AppFolders.ensureDefaultFolders()
        Diagnostics.shared.start()
        _ = AppServices.shared
        ContentBlocker.shared.start()
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    /// Closed windows take their untitled tab group with them.
    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        let store = AppServices.shared.tabStore
        for session in sceneSessions {
            guard let id = SceneDelegate.groupID(in: session), let group = store.group(withID: id), group.title == nil
            else { continue }
            store.remove(group)
        }
    }

    /// The system ran the app for the background download session; it's finished when the session
    /// has delivered its events.
    func application(
        _ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == SessionDownloader.sessionIdentifier else {
            completionHandler()
            return
        }
        AppServices.shared.downloads.backgroundEventsCompletion = completionHandler
    }

    func applicationWillTerminate(_ application: UIApplication) {
        AppServices.shared.tabStore.saveNow()
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        MainMenu.build(with: builder)
    }
}
