import BrowserCore
import UIKit
import UniformTypeIdentifiers

/// "Browser" in the share sheet: open the shared link (or search for the shared text) in a new
/// tab or private tab, or download the linked file. It hands the request to the app through
/// the app's own links (AppLink).
final class ShareViewController: UIViewController {
    private var sharedURL: URL?
    private var sharedText: String?
    private let card = UIStackView()
    private let preview = UILabel()
    private let buttons = UIStackView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        configureCard()
        Task {
            await loadSharedItem()
            showChoices()
        }
    }

    // MARK: Input

    private func loadSharedItem() async {
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, !url.isFileURL {
                sharedURL = url
                return
            }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Shared text that is just an address counts as a link.
                if let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    sharedURL = url
                } else if !trimmed.isEmpty {
                    sharedText = trimmed
                }
                return
            }
        }
    }

    // MARK: Choices

    private func configureCard() {
        card.axis = .vertical
        card.spacing = 14
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 22, leading: 22, bottom: 22, trailing: 22)
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 22
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false

        let title = UILabel()
        title.text = "Browser"
        title.font = .preferredFont(forTextStyle: .headline)
        preview.font = .preferredFont(forTextStyle: .subheadline)
        preview.textColor = .secondaryLabel
        preview.numberOfLines = 3
        preview.lineBreakMode = .byTruncatingMiddle
        preview.text = "Reading what you shared…"
        buttons.axis = .vertical
        buttons.spacing = 10
        for subview in [title, preview, buttons] {
            card.addArrangedSubview(subview)
        }
        view.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 380),
        ])
    }

    private func showChoices() {
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let url = sharedURL {
            preview.text = url.absoluteString
            addButton("Open in Browser", systemImage: "safari", prominent: true) { [weak self] in
                self?.finish(with: .open(url, isPrivate: false))
            }
            addButton("Open in Private Tab", systemImage: "hand.raised") { [weak self] in
                self?.finish(with: .open(url, isPrivate: true))
            }
            if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                addButton("Download with Browser", systemImage: "arrow.down.circle") { [weak self] in
                    self?.finish(with: .download(url))
                }
            }
        } else if let text = sharedText {
            preview.text = text
            addButton("Search in Browser", systemImage: "magnifyingglass", prominent: true) { [weak self] in
                self?.finish(with: .openText(text, isPrivate: false))
            }
            addButton("Search in Private Tab", systemImage: "hand.raised") { [weak self] in
                self?.finish(with: .openText(text, isPrivate: true))
            }
        } else {
            preview.text = "There's no link or text to open."
        }
        addButton("Cancel", systemImage: nil) { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
    }

    private func addButton(_ title: String, systemImage: String?, prominent: Bool = false, action: @escaping () -> Void) {
        var configuration: UIButton.Configuration = prominent ? .borderedProminent() : .bordered()
        configuration.title = title
        if let systemImage {
            configuration.image = UIImage(systemName: systemImage)
            configuration.imagePadding = 8
        }
        configuration.cornerStyle = .large
        configuration.buttonSize = .large
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        buttons.addArrangedSubview(button)
    }

    // MARK: Handing over

    private func finish(with link: AppLink) {
        if let url = link.url {
            openApp(url)
        }
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    /// Share extensions can't open apps through their API; the application object at the end of
    /// the responder chain can (the approach Firefox Focus's extension takes, with the current
    /// open-URL method).
    private func openApp(_ url: URL) {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector) {
                typealias OpenURL = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
                let open = unsafeBitCast(current.method(for: selector), to: OpenURL.self)
                open(current, selector, url as NSURL, NSDictionary(), nil)
                return
            }
            responder = current.next
        }
    }
}
