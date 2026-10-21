import UIKit

extension UIResponder {
    private static weak var found: UIResponder?

    /// The window's first responder, found by sending an action to "the first responder".
    static var current: UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(captureFirstResponder(_:)), to: nil, from: nil, for: nil)
        return found
    }

    @objc private func captureFirstResponder(_ sender: Any?) {
        UIResponder.found = self
    }
}
