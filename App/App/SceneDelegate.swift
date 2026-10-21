import Combine
import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var root: BrowserSplitViewController?
    private var cover: PrivacyCover?

    private static let groupIDKey = "normalGroupID"
    private static let activeGroupIDKey = "activeGroupID"
    private var observers: Set<AnyCancellable> = []

    /// Activity used to open a link in a new window ("url" and "private" in userInfo).
    static let openURLActivityType = "io.github.leondood1298.browser.open-url"

    /// The tab group a window shows, remembered in its scene session across launches.
    static func groupID(in session: UISceneSession) -> UUID? {
        (session.userInfo?[groupIDKey] as? String).flatMap(UUID.init(uuidString:))
    }

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let activeID = (session.userInfo?[Self.activeGroupIDKey] as? String).flatMap(UUID.init(uuidString:))
        let model = BrowserWindowModel(restoringGroupID: Self.groupID(in: session), activeGroupID: activeID)
        model.sceneSession = session
        var info = session.userInfo ?? [:]
        info[Self.groupIDKey] = model.defaultGroup.id.uuidString
        session.userInfo = info
        model.$normalGroup
            .sink { [weak session] group in
                guard let session else { return }
                var info = session.userInfo ?? [:]
                info[Self.activeGroupIDKey] = group.id.uuidString
                session.userInfo = info
            }
            .store(in: &observers)

        let root = BrowserSplitViewController(model: model)
        let window = BrowserWindow(windowScene: windowScene)
        window.browser = root.browser
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        self.root = root
        applyTheme()
        let cover = PrivacyCover(scene: windowScene, model: model)
        self.cover = cover
        cover.showIfLocked()
        AppServices.shared.preferences.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyTheme() }
            .store(in: &observers)

        for context in connectionOptions.urlContexts {
            root.browser.handleIncomingURL(context.url)
        }
        for activity in connectionOptions.userActivities where activity.activityType == Self.openURLActivityType {
            open(activity, in: model)
        }
    }

    private func open(_ activity: NSUserActivity, in model: BrowserWindowModel) {
        guard let address = activity.userInfo?["url"] as? String, let url = URL(string: address) else { return }
        let isPrivate = activity.userInfo?["private"] as? Bool ?? false
        if let blank = model.selectedTab, blank.showsStartPage, blank.isPrivate == isPrivate {
            blank.load(url)
        } else {
            model.newTab(url: url, isPrivate: isPrivate)
        }
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        for context in URLContexts {
            root?.browser.handleIncomingURL(context.url)
        }
    }

    private func applyTheme() {
        window?.overrideUserInterfaceStyle = AppServices.shared.preferences.theme.interfaceStyle
    }

    func sceneWillResignActive(_ scene: UIScene) {
        cover?.sceneWillResignActive()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        cover?.sceneDidBecomeActive()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        cover?.sceneDidEnterBackground()
        AppServices.shared.tabStore.saveNow()
    }
}
