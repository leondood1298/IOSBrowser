import UIKit

/// Alerts that suspend until the user answers. If the presenter can't show an alert right now
/// (it isn't on screen or is already showing something), each returns its "cancel" answer at once.
enum Prompts {
    static func notice(from presenter: UIViewController, title: String?, message: String?) async {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        _ = await present(alert, from: presenter, actions: [("OK", .default)], fallback: 0)
    }

    static func confirm(
        from presenter: UIViewController, title: String?, message: String?,
        confirm: String, cancel: String = "Cancel"
    ) async -> Bool {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        let choice = await present(alert, from: presenter, actions: [(cancel, .cancel), (confirm, .default)], fallback: 0)
        return choice == 1
    }

    static func textInput(
        from presenter: UIViewController, title: String?, message: String?, defaultText: String?
    ) async -> String? {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = defaultText
        }
        let choice = await present(alert, from: presenter, actions: [("Cancel", .cancel), ("OK", .default)], fallback: 0)
        return choice == 1 ? (alert.textFields?.first?.text ?? "") : nil
    }

    static func httpLogin(
        from presenter: UIViewController, host: String, realm: String?, failedBefore: Bool
    ) async -> URLCredential? {
        var message = "\(host) requires a user name and password."
        if let realm, !realm.isEmpty {
            message += " (\(realm))"
        }
        if failedBefore {
            message = "That didn't work. " + message
        }
        let alert = UIAlertController(title: "Sign In", message: message, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "User name"
            field.textContentType = .username
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addTextField { field in
            field.placeholder = "Password"
            field.textContentType = .password
            field.isSecureTextEntry = true
        }
        let choice = await present(alert, from: presenter, actions: [("Cancel", .cancel), ("Sign In", .default)], fallback: 0)
        guard choice == 1 else { return nil }
        let user = alert.textFields?[0].text ?? ""
        let password = alert.textFields?[1].text ?? ""
        return URLCredential(user: user, password: password, persistence: .forSession)
    }

    /// Adds the actions, presents the alert and returns the index of the tapped action.
    private static func present(
        _ alert: UIAlertController, from presenter: UIViewController,
        actions: [(String, UIAlertAction.Style)], fallback: Int
    ) async -> Int {
        let host = topmostPresenter(from: presenter)
        guard host.viewIfLoaded?.window != nil, !(host is UIAlertController) else { return fallback }
        return await withCheckedContinuation { continuation in
            for (index, action) in actions.enumerated() {
                alert.addAction(UIAlertAction(title: action.0, style: action.1) { _ in
                    continuation.resume(returning: index)
                })
            }
            if let lastDefault = actions.lastIndex(where: { $0.1 == .default }) {
                alert.preferredAction = alert.actions[lastDefault]
            }
            host.present(alert, animated: true)
        }
    }

    private static func topmostPresenter(from controller: UIViewController) -> UIViewController {
        var current = controller
        while let presented = current.presentedViewController, !presented.isBeingDismissed {
            current = presented
        }
        return current
    }
}
