import Combine
import LocalAuthentication
import SwiftUI
import UIKit

/// Face ID (or passcode) protection, like Firefox Focus's "Use Face ID to unlock app": either the
/// whole app or only private tabs. The app locks again whenever it goes to the background.
final class AppLock {
    static let shared = AppLock()

    private var appUnlocked = false
    private var privateUnlocked = false
    private var authenticating = false

    var mode: AppLockMode { AppServices.shared.preferences.appLock }

    /// Whether a window showing (private, or not) tabs needs unlocking right now.
    func needsUnlock(showingPrivate: Bool) -> Bool {
        switch mode {
        case .off: return false
        case .wholeApp: return !appUnlocked
        case .privateTabs: return showingPrivate && !privateUnlocked
        }
    }

    func lock() {
        appUnlocked = false
        privateUnlocked = false
    }

    /// Asks for Face ID or the passcode. Returns true once unlocked.
    func unlock() async -> Bool {
        if authenticating {
            return false
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode is set on the device, so there is nothing to lock with.
            markUnlocked()
            return true
        }
        authenticating = true
        defer { authenticating = false }
        let reason = mode == .privateTabs ? "Unlock your private tabs" : "Unlock the browser"
        let success = (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
        if success {
            markUnlocked()
        }
        return success
    }

    private func markUnlocked() {
        appUnlocked = true
        privateUnlocked = true
    }
}

/// Covers a window with a blurred screen in the app switcher, and with a lock screen when the app
/// lock applies. Lives in its own window above the browser, as in Firefox Focus.
final class PrivacyCover {
    private weak var scene: UIWindowScene?
    private let model: BrowserWindowModel
    private var window: UIWindow?
    private var observers: Set<AnyCancellable> = []

    init(scene: UIWindowScene, model: BrowserWindowModel) {
        self.scene = scene
        self.model = model
        model.$isPrivate
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &observers)
    }

    /// Private windows are always covered in the app switcher; others when the app lock is on.
    private var coversInAppSwitcher: Bool {
        model.isPrivate || AppServices.shared.preferences.appLock != .off
    }

    func sceneWillResignActive() {
        if coversInAppSwitcher {
            show(locked: false)
        }
    }

    func sceneDidEnterBackground() {
        AppLock.shared.lock()
        if coversInAppSwitcher {
            show(locked: AppLock.shared.needsUnlock(showingPrivate: model.isPrivate))
        }
    }

    func sceneDidBecomeActive() {
        refresh()
    }

    /// Covers the window right away if it's locked; the Face ID prompt waits until it's active.
    func showIfLocked() {
        if AppLock.shared.needsUnlock(showingPrivate: model.isPrivate) {
            show(locked: true)
        }
    }

    /// Shows the lock screen if this window needs unlocking, otherwise removes the cover.
    func refresh() {
        if AppLock.shared.needsUnlock(showingPrivate: model.isPrivate) {
            show(locked: true)
            promptForUnlock()
        } else {
            hide()
        }
    }

    private func promptForUnlock() {
        Task {
            if await AppLock.shared.unlock() {
                hide()
            }
        }
    }

    private func show(locked: Bool) {
        guard let scene else { return }
        let view = PrivacyCoverView(locked: locked) { [weak self] in self?.promptForUnlock() }
        if let window {
            (window.rootViewController as? UIHostingController<PrivacyCoverView>)?.rootView = view
            window.isHidden = false
            return
        }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        self.window = window
    }

    private func hide() {
        window?.isHidden = true
        window = nil
    }
}

struct PrivacyCoverView: View {
    let locked: Bool
    var onUnlock: () -> Void

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: locked ? "lock.fill" : "hand.raised.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(.secondary)
                if locked {
                    Text("Browser Is Locked").font(.title2.weight(.semibold))
                    Button(action: onUnlock) {
                        Label("Unlock", systemImage: "faceid")
                            .padding(.horizontal, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("unlockButton")
                }
            }
        }
    }
}
