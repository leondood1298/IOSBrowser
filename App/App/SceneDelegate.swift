import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private var root: BrowserSplitViewController?

    private static let groupIDKey = "normalGroupID"

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
