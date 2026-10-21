import BrowserCore
import UIKit

/// The address bar. While not editing it shows just the host (with a lock for secure pages)
/// and a reload/stop button; while editing it shows the full address, selected.
final class AddressField: UITextField {
    var onSubmit: ((String) -> Void)?
    var onReloadOrStop: (() -> Void)?

    private let lockView = UIImageView(image: UIImage(systemName: "lock.fill"))
    private let reloadButton = UIButton(type: .system)
    private var currentURL: URL?
    private var isSecurePage = false
    private var isLoadingPage = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configure() {
        borderStyle = .none
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = 11
        layer.cornerCurve = .continuous
        font = .preferredFont(forTextStyle: .body)
        adjustsFontForContentSizeCategory = true
        placeholder = "Search or enter address"
        keyboardType = .webSearch
        returnKeyType = .go
        autocapitalizationType = .none
        autocorrectionType = .no
        spellCheckingType = .no
        smartDashesType = .no
        smartQuotesType = .no
        clearButtonMode = .whileEditing
        textContentType = .URL
        accessibilityIdentifier = "urlField"
        delegate = self

        lockView.tintColor = .secondaryLabel
        lockView.contentMode = .center
        lockView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
        lockView.frame = CGRect(x: 0, y: 0, width: 30, height: 30)
        leftView = lockView
        leftViewMode = .unlessEditing

        reloadButton.frame = CGRect(x: 0, y: 0, width: 36, height: 30)
        reloadButton.tintColor = .label
        reloadButton.accessibilityIdentifier = "reloadButton"
        reloadButton.addAction(UIAction { [weak self] _ in self?.onReloadOrStop?() }, for: .touchUpInside)
        rightView = reloadButton
        rightViewMode = .unlessEditing

        heightAnchor.constraint(equalToConstant: 38).isActive = true
        let preferredWidth = widthAnchor.constraint(equalToConstant: 680)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            preferredWidth,
            widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        refresh()
    }

    func update(url: URL?, isSecure: Bool, isLoading: Bool) {
        currentURL = url
        isSecurePage = isSecure
        isLoadingPage = isLoading
        refresh()
    }

    /// Puts the cursor in the field with the full address selected.
    func beginEditingAddress() {
        becomeFirstResponder()
    }

    private func refresh() {
        let showingPage = URLDisplay.host(for: currentURL) != nil
        reloadButton.setImage(UIImage(systemName: isLoadingPage ? "xmark" : "arrow.clockwise"), for: .normal)
        reloadButton.accessibilityLabel = isLoadingPage ? "Stop" : "Reload"
        reloadButton.isHidden = !showingPage
        lockView.isHidden = !(showingPage && isSecurePage)
        guard !isEditing else { return }
        text = URLDisplay.host(for: currentURL)
        textAlignment = .center
    }
}

extension AddressField: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        textAlignment = .natural
        text = URLDisplay.editableText(for: currentURL)
        DispatchQueue.main.async { [weak self] in
            self?.selectAll(nil)
        }
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        let input = text ?? ""
        resignFirstResponder()
        if !input.trimmingCharacters(in: .whitespaces).isEmpty {
            onSubmit?(input)
        }
        return true
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        refresh()
    }
}
