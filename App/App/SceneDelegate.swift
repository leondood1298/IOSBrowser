import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var root: BrowserSplitViewController?

    private static let groupIDKey = "normalGroupID"

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
        let model = BrowserWindowModel(restoringGroupID: Self.groupID(in: session))
        var info = session.userInfo ?? [:]
        info[Self.groupIDKey] = model.normalGroup.id.uuidString
        session.userInfo = info

        let root = BrowserSplitViewController(model: model)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        self.root = root

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

    func sceneDidEnterBackground(_ scene: UIScene) {
        AppServices.shared.tabStore.saveNow()
    }
}
