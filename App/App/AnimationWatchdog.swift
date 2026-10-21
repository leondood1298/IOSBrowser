#if DEBUG
import UIKit

/// UI tests wait for the app to be idle before every step, and an animation that never ends
/// makes each step wait a minute. In UI test runs this logs any animation still running ten
/// seconds later, with the view it belongs to and the first responder at the time.
enum AnimationWatchdog {
    private static var timer: Timer?
    private static var previous: Set<String> = []
    private static var reported: Set<String> = []

    static func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { scan() }
        }
    }

    private static func scan() {
        var found: Set<String> = []
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                collect(window.layer, into: &found)
            }
        }
        let lasting = found.intersection(previous).subtracting(reported)
        previous = found
        guard !lasting.isEmpty else { return }
        reported.formUnion(lasting)
        let responder = UIResponder.current.map { String(describing: type(of: $0)) } ?? "none"
        Log.event("Still animating: \(lasting.sorted().prefix(6).joined(separator: "; ")) (first responder: \(responder))")
    }

    private static func collect(_ layer: CALayer, into found: inout Set<String>) {
        for key in layer.animationKeys() ?? [] {
            let owner = layer.delegate.map { String(describing: type(of: $0)) } ?? String(describing: type(of: layer))
            var detail = "\(owner).\(key)"
            if let animation = layer.animation(forKey: key) {
                detail += " (\(type(of: animation)), \(animation.duration) s, repeats \(animation.repeatCount))"
            }
            found.insert(detail)
        }
        for sublayer in layer.sublayers ?? [] {
            collect(sublayer, into: &found)
        }
    }
}
#endif
