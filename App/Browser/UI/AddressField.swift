import BrowserCore
import UIKit

/// The address bar. While not editing it shows just the host (with a lock for secure pages),
/// the "aA" page settings button and a reload/stop button; while editing it shows the full
/// address, selected.
final class AddressField: UITextField {
    var onSubmit: ((String) -> Void)?
    var onReloadOrStop: (() -> Void)?
    var onPageSettings: ((UIView) -> Void)?
    var onShield: ((UIView) -> Void)?
    /// Called with the text whenever editing starts or the text changes.
    var onTextChange: ((String) -> Void)?
    var onEditingEnded: (() -> Void)?
    var onPasteAndGo: ((String) -> Void)?
    /// Text to edit instead of the URL (the search terms on a results page).
    var editingTextProvider: ((URL?) -> String?)?
    /// The rest of a site's address for what's been typed (inline autocomplete).
    var completionProvider: ((String) -> String?)?
    private var lastEditWasInsertionAtEnd = false

    /// Space between the text and the field's rounded ends.
    private static let textInset: CGFloat = 12
    private let leadingButtons = UIView(frame: CGRect(x: 0, y: 0, width: 76, height: 38))
    private let shieldButton = UIButton(type: .system)
    private let pageSettingsButton = UIButton(type: .system)
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
        addAction(UIAction { [weak self] _ in self?.textDidChange() }, for: .editingChanged)

        pageSettingsButton.setImage(UIImage(systemName: "textformat.size"), for: .normal)
        pageSettingsButton.tintColor = .label
        pageSettingsButton.accessibilityLabel = "Page Settings"
        pageSettingsButton.accessibilityIdentifier = "pageSettingsButton"
        pageSettingsButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onPageSettings?(self.pageSettingsButton)
        }, for: .touchUpInside)
        shieldButton.setImage(UIImage(systemName: "shield.lefthalf.filled"), for: .normal)
        shieldButton.tintColor = .label
        shieldButton.accessibilityLabel = "Tracking Protection"
        shieldButton.accessibilityIdentifier = "shieldButton"
        shieldButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onShield?(self.shieldButton)
        }, for: .touchUpInside)
        // Plain frames, no Auto Layout: with a stack view here the empty field showed neither
        // the placeholder nor the cursor.
        shieldButton.frame = CGRect(x: 0, y: 0, width: 38, height: 38)
        pageSettingsButton.frame = CGRect(x: 38, y: 0, width: 38, height: 38)
        leadingButtons.addSubview(shieldButton)
        leadingButtons.addSubview(pageSettingsButton)
        leftView = leadingButtons

        reloadButton.frame = CGRect(x: 0, y: 0, width: 38, height: 38)
        reloadButton.tintColor = .label
        reloadButton.accessibilityIdentifier = "reloadButton"
        reloadButton.addAction(UIAction { [weak self] _ in self?.onReloadOrStop?() }, for: .touchUpInside)
        rightView = reloadButton

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

    /// Reports the typed text and, after typing at the end, completes a known site inline with
    /// the added part selected, so typing on replaces it and Delete removes it.
    private func textDidChange() {
        let typed = text ?? ""
        onTextChange?(typed)
        guard lastEditWasInsertionAtEnd, markedTextRange == nil else { return }
        lastEditWasInsertionAtEnd = false
        guard let suffix = completionProvider?(typed), !suffix.isEmpty else { return }
        text = typed + suffix
        if let start = position(from: beginningOfDocument, offset: typed.count),
           let end = position(from: start, offset: suffix.count) {
            selectedTextRange = textRange(from: start, to: end)
        }
    }

    /// Called when the window switches tabs. If the field is being edited, its text is replaced
    /// with the new tab's address so it never shows the previous tab's URL.
    func showTab(url: URL?) {
        currentURL = url
        if isEditing {
            text = URLDisplay.editableText(for: url)
            selectAll(nil)
            onTextChange?(text ?? "")
        }
        refresh()
    }

    /// Shows the tracking protection state: on, off for this page, or an insecure connection.
    func updateShield(protected: Bool, secure: Bool) {
        let symbol = !secure ? "exclamationmark.shield" : (protected ? "shield.lefthalf.filled" : "shield.slash")
        shieldButton.setImage(UIImage(systemName: symbol), for: .normal)
        shieldButton.tintColor = secure ? .label : .systemOrange
        shieldButton.accessibilityValue = !secure ? "Connection not secure" : (protected ? "On" : "Off")
    }

    /// Puts the cursor in the field with the full address selected.
    func beginEditingAddress() {
        becomeFirstResponder()
    }

    private func refresh() {
        let showingPage = URLDisplay.host(for: currentURL) != nil
        reloadButton.setImage(UIImage(systemName: isLoadingPage ? "xmark" : "arrow.clockwise"), for: .normal)
        reloadButton.accessibilityLabel = isLoadingPage ? "Stop" : "Reload"
        // The page buttons only make sense with a page; the New Tab page gets the full width.
        leftViewMode = showingPage ? .unlessEditing : .never
        rightViewMode = showingPage ? .unlessEditing : .never
        setNeedsLayout()
        guard !isEditing else { return }
        text = URLDisplay.host(for: currentURL)
        textAlignment = .center
    }

    // MARK: - Text layout

    /// While not editing, the host is centered on the whole field, so the text area is inset
    /// equally on both sides by the wider of the two side views.
    override func textRect(forBounds bounds: CGRect) -> CGRect {
        var inset = Self.textInset
        if leftViewMode != .never, let leftView {
            inset = max(inset, leftView.frame.width + 2)
        }
        if rightViewMode != .never, let rightView {
            inset = max(inset, rightView.frame.width + 2)
        }
        return bounds.insetBy(dx: min(inset, bounds.width / 2), dy: 0)
    }

    /// While editing, the text starts near the left end and stops before the clear button.
    override func editingRect(forBounds bounds: CGRect) -> CGRect {
        let clearButton = clearButtonRect(forBounds: bounds)
        let maxX = clearButton.width > 0 ? clearButton.minX - 4 : bounds.maxX - Self.textInset
        let minX = bounds.minX + Self.textInset
        return CGRect(x: minX, y: bounds.minY, width: max(0, maxX - minX), height: bounds.height)
    }

    override func placeholderRect(forBounds bounds: CGRect) -> CGRect {
        isEditing ? editingRect(forBounds: bounds) : textRect(forBounds: bounds)
    }
}

extension AddressField: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        textAlignment = .natural
        text = editingTextProvider?(currentURL) ?? URLDisplay.editableText(for: currentURL)
        onTextChange?(text ?? "")
        DispatchQueue.main.async { [weak self] in
            self?.selectAll(nil)
        }
    }

    func textField(
        _ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String
    ) -> Bool {
        let length = (text ?? "").utf16.count
        lastEditWasInsertionAtEnd = !string.isEmpty && range.location + range.length == length
        return true
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
        onEditingEnded?()
    }

    /// Adds "Paste and Go" to the field's edit menu when the clipboard has text or a link.
    func textField(
        _ textField: UITextField, editMenuForCharactersIn range: NSRange, suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard UIPasteboard.general.hasStrings || UIPasteboard.general.hasURLs else { return nil }
        let pasteAndGo = UIAction(title: "Paste and Go", image: UIImage(systemName: "arrow.right.circle")) { [weak self] _ in
            let pasted = UIPasteboard.general.url?.absoluteString ?? UIPasteboard.general.string ?? ""
            guard let self, !pasted.isEmpty else { return }
            self.resignFirstResponder()
            self.onPasteAndGo?(pasted)
        }
        return UIMenu(children: suggestedActions + [pasteAndGo])
    }
}
