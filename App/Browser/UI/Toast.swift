import UIKit

/// A short message that fades in at the bottom of a view and disappears on its own,
/// like Firefox Focus's "Browsing history cleared".
enum Toast {
    static func show(_ text: String, systemImage: String? = nil, in view: UIView) {
        // It goes on the window, above sheets and popovers, and outside the suggestions panel's
        // part of the screen: that panel is accessibility-modal, which hides the views beside it.
        let host = view.window ?? view
        host.subviews.filter { $0.accessibilityIdentifier == "toast" }.forEach { $0.removeFromSuperview() }

        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .white
        label.numberOfLines = 2
        let stack = UIStackView(arrangedSubviews: [label])
        if let systemImage {
            let icon = UIImageView(image: UIImage(systemName: systemImage))
            icon.tintColor = .white
            stack.insertArrangedSubview(icon, at: 0)
        }
        stack.spacing = 8
        stack.alignment = .center
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18)

        let container = UIView()
        container.backgroundColor = UIColor.black.withAlphaComponent(0.82)
        container.layer.cornerRadius = 14
        container.layer.cornerCurve = .continuous
        container.accessibilityIdentifier = "toast"
        container.isAccessibilityElement = true
        container.accessibilityLabel = text
        container.alpha = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        host.addSubview(container)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            container.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40),
        ])
        UIAccessibility.post(notification: .announcement, argument: text)

        UIView.animate(withDuration: 0.2) {
            container.alpha = 1
        }
        // A timer rather than a delayed animation: an animation waiting to start keeps the app
        // "busy", and UI tests (which wait for quiet) would only look after the toast is gone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak container] in
            UIView.animate(withDuration: 0.3) {
                container?.alpha = 0
            } completion: { _ in
                container?.removeFromSuperview()
            }
        }
    }
}
