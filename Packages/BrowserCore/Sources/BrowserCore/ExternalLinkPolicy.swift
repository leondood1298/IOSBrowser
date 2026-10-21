import Foundation

/// The kind of app a link would open, used to word the confirmation prompt.
public enum ExternalApp: Equatable, Sendable {
    case mail
    case phone
    case facetime
    case messages
    case appStore
    case maps
    case other(scheme: String)
}

/// What the browser does with a link the page navigates to.
public enum LinkAction: Equatable, Sendable {
    /// Load it in the web view.
    case load
    /// Hand it to iOS straight away (iOS shows its own confirmation for phone calls).
    case openDirectly
    /// Ask before leaving the browser for another app.
    case askToOpen(ExternalApp)
    /// A web link that has a native app (App Store, Maps): offer the app, otherwise load the page.
    case offerApp(ExternalApp)
    /// Never follow it.
    case block
}

/// Decides how links leave the browser, following Firefox Focus: `tel:` opens directly,
/// mail, FaceTime and unknown schemes ask first, and App Store or Maps web links offer their app.
public enum ExternalLinkPolicy {
    public static func action(for url: URL) -> LinkAction {
        guard let scheme = url.scheme?.lowercased() else { return .load }
        switch scheme {
        case "http", "https":
            switch url.host?.lowercased() {
            case "apps.apple.com", "itunes.apple.com":
                return .offerApp(.appStore)
            case "maps.apple.com":
                return .offerApp(.maps)
            default:
                return .load
            }
        case "about", "data", "blob", "javascript":
            return .load
        case "file":
            return .block
        case "tel":
            return .openDirectly
        case "mailto":
            return .askToOpen(.mail)
        case "facetime", "facetime-audio":
            return .askToOpen(.facetime)
        case "sms":
            return .askToOpen(.messages)
        case "itms-apps", "itms-appss":
            return .askToOpen(.appStore)
        case "maps":
            return .askToOpen(.maps)
        default:
            return .askToOpen(.other(scheme: scheme))
        }
    }

    /// The prompt shown before opening another app.
    public static func prompt(for app: ExternalApp) -> String {
        switch app {
        case .mail: return "Open this link in Mail?"
        case .phone: return "Call this number?"
        case .facetime: return "Start a FaceTime call?"
        case .messages: return "Open this link in Messages?"
        case .appStore: return "Open this link in the App Store?"
        case .maps: return "Open this location in Maps?"
        case .other: return "This page wants to open another app."
        }
    }
}
