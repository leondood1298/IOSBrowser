import PDFKit
import UIKit

/// The PDF viewer: one page at a time, and the next or previous page appears instantly (no page
/// curl or slide). Tap the left or right edge, use the ‹ › buttons, swipe in any direction, or
/// the arrow keys, space and Page Up/Down. Go to a page by number, browse thumbnails or the
/// table of contents, search, or switch to continuous scrolling. The last page read is remembered.
final class PDFViewerController: UIViewController, UIGestureRecognizerDelegate {
    private let url: URL
    private let pdfView = PDFView()
    private let pageButton = UIButton(type: .system)
    private let thumbnails = PDFThumbnailView()
    private let preferences: Preferences
    private var continuous = false
    private var pageObserver: NSObjectProtocol?

    init(url: URL, preferences: Preferences) {
        self.url = url
        self.preferences = preferences
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = url.deletingPathExtension().lastPathComponent

        pdfView.document = PDFDocument(url: url)
        pdfView.autoScales = true
        pdfView.isFindInteractionEnabled = true
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.accessibilityIdentifier = "pdfView"
        applyMode()
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pdfView)

        thumbnails.pdfView = pdfView
        thumbnails.layoutMode = .horizontal
        thumbnails.thumbnailSize = CGSize(width: 44, height: 60)
        thumbnails.backgroundColor = .secondarySystemBackground
        thumbnails.isHidden = true
        thumbnails.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(thumbnails)

        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: thumbnails.topAnchor),
            thumbnails.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            thumbnails.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            thumbnails.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            thumbnails.heightAnchor.constraint(equalToConstant: 76),
        ])

        configureToolbar()
        configureGestures()
        restorePage()
        pageObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: pdfView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pageChanged() }
        }
        updatePageLabel()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    // MARK: Toolbar

    private func configureToolbar() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        navigationItem.leftBarButtonItem?.accessibilityIdentifier = "pdfDoneButton"

        pageButton.titleLabel?.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        pageButton.accessibilityIdentifier = "pdfPageButton"
        pageButton.addAction(UIAction { [weak self] _ in self?.askForPage() }, for: .touchUpInside)

        let previous = UIBarButtonItem(image: UIImage(systemName: "chevron.left"), primaryAction: UIAction { [weak self] _ in
            self?.previousPage()
        })
        previous.accessibilityIdentifier = "pdfPrevious"
        let next = UIBarButtonItem(image: UIImage(systemName: "chevron.right"), primaryAction: UIAction { [weak self] _ in
            self?.nextPage()
        })
        next.accessibilityIdentifier = "pdfNext"
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.menuElements() ?? [])
            },
        ]))
        let search = UIBarButtonItem(image: UIImage(systemName: "magnifyingglass"), primaryAction: UIAction { [weak self] _ in
            (self?.pdfView.findInteraction as UIFindInteraction?)?.presentFindNavigator(showingReplace: false)
        })
        navigationItem.rightBarButtonItems = [more, search, next, UIBarButtonItem(customView: pageButton), previous]
    }

    private func menuElements() -> [UIMenuElement] {
        var elements: [UIMenuElement] = [
            UIAction(title: thumbnails.isHidden ? "Show Thumbnails" : "Hide Thumbnails",
                     image: UIImage(systemName: "square.grid.3x1.below.line.grid.1x2")) { [weak self] _ in
                guard let self else { return }
                self.thumbnails.isHidden.toggle()
            },
            UIAction(title: continuous ? "One Page at a Time" : "Continuous Scrolling",
                     image: UIImage(systemName: continuous ? "doc" : "doc.text")) { [weak self] _ in
                guard let self else { return }
                self.continuous.toggle()
                self.applyMode()
            },
            UIAction(title: "Go to Page…", image: UIImage(systemName: "number")) { [weak self] _ in
                self?.askForPage()
            },
        ]
        if let outline = pdfView.document?.outlineRoot, outline.numberOfChildren > 0 {
            elements.append(UIAction(title: "Contents", image: UIImage(systemName: "list.bullet")) { [weak self] _ in
                self?.showOutline(outline)
            })
        }
        elements.append(UIAction(title: "Share…", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
            guard let self else { return }
            let controller = UIActivityViewController(activityItems: [self.url], applicationActivities: nil)
            controller.popoverPresentationController?.sourceItem = self.navigationItem.rightBarButtonItems?.first
            self.present(controller, animated: true)
        })
        return elements
    }

    private func applyMode() {
        let page = pdfView.currentPage
        if continuous {
            pdfView.displayMode = .singlePageContinuous
            pdfView.displayDirection = .vertical
        } else {
            pdfView.displayMode = .singlePage
            pdfView.displayDirection = .horizontal
            // No page view controller: pages swap instantly instead of sliding.
            pdfView.usePageViewController(false, withViewOptions: nil)
        }
        pdfView.autoScales = true
        if let page {
            pdfView.go(to: page)
        }
    }

    // MARK: Paging

    private func configureGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.delegate = self
        pdfView.addGestureRecognizer(tap)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right, .up, .down] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            swipe.direction = direction
            swipe.delegate = self
            pdfView.addGestureRecognizer(swipe)
        }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // In continuous mode and when zoomed in, swipes scroll the page instead.
        guard gestureRecognizer is UISwipeGestureRecognizer else { return true }
        return !continuous && !isZoomedIn
    }

    private var isZoomedIn: Bool {
        pdfView.scaleFactor > pdfView.scaleFactorForSizeToFit * 1.02
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard !continuous else { return }
        let x = recognizer.location(in: pdfView).x
        let edge = pdfView.bounds.width * 0.18
        if x < edge {
            previousPage()
        } else if x > pdfView.bounds.width - edge {
            nextPage()
        }
    }

    @objc private func swiped(_ recognizer: UISwipeGestureRecognizer) {
        switch recognizer.direction {
        case .left, .up: nextPage()
        default: previousPage()
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        let next = [UIKeyCommand.inputRightArrow, UIKeyCommand.inputDownArrow, " ", UIKeyCommand.inputPageDown]
        let previous = [UIKeyCommand.inputLeftArrow, UIKeyCommand.inputUpArrow, UIKeyCommand.inputPageUp]
        var commands = next.map { UIKeyCommand(title: "Next Page", action: #selector(nextPage), input: $0) }
        commands += previous.map { UIKeyCommand(title: "Previous Page", action: #selector(previousPage), input: $0) }
        commands.append(UIKeyCommand(title: "Close", action: #selector(close), input: UIKeyCommand.inputEscape))
        commands.append(UIKeyCommand(title: "Close", action: #selector(close), input: "w", modifierFlags: .command))
        for command in commands where !continuous || command.action == #selector(close) {
            command.wantsPriorityOverSystemBehavior = true
        }
        // In continuous mode the arrows scroll.
        return continuous ? commands.filter { $0.action == #selector(close) } : commands
    }

    @objc private func nextPage() {
        if pdfView.canGoToNextPage {
            pdfView.goToNextPage(nil)
        }
    }

    @objc private func previousPage() {
        if pdfView.canGoToPreviousPage {
            pdfView.goToPreviousPage(nil)
        }
    }

    @objc private func close() {
        dismiss(animated: true)
    }

    private func askForPage() {
        guard let document = pdfView.document else { return }
        let alert = UIAlertController(title: "Go to Page", message: "1–\(document.pageCount)", preferredStyle: .alert)
        alert.addTextField { field in
            field.keyboardType = .numberPad
            field.placeholder = "Page"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Go", style: .default) { [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text, let number = Int(text),
                  let page = document.page(at: min(max(number, 1), document.pageCount) - 1)
            else { return }
            self?.pdfView.go(to: page)
        })
        present(alert, animated: true)
    }

    private func showOutline(_ root: PDFOutline) {
        let list = OutlineViewController(root: root) { [weak self] destination in
            self?.dismiss(animated: true)
            self?.pdfView.go(to: destination)
        }
        let navigation = UINavigationController(rootViewController: list)
        navigation.modalPresentationStyle = .popover
        navigation.popoverPresentationController?.sourceItem = navigationItem.rightBarButtonItems?.first
        navigation.preferredContentSize = CGSize(width: 380, height: 520)
        present(navigation, animated: true)
    }

    // MARK: Remembering the page

    private var pageKey: String {
        AppServices.shared.files.relativePath(of: url)
    }

    private func restorePage() {
        guard let saved = preferences.pdfPages[pageKey], let document = pdfView.document,
              let page = document.page(at: min(max(saved, 0), document.pageCount - 1))
        else { return }
        pdfView.go(to: page)
    }

    private func pageChanged() {
        updatePageLabel()
        if let document = pdfView.document, let page = pdfView.currentPage {
            preferences.setPDFPage(document.index(for: page), for: pageKey)
        }
    }

    private func updatePageLabel() {
        guard let document = pdfView.document, let page = pdfView.currentPage else {
            pageButton.setTitle("", for: .normal)
            return
        }
        pageButton.setTitle("\(document.index(for: page) + 1) / \(document.pageCount)", for: .normal)
        pageButton.sizeToFit()
    }
}

/// A PDF's table of contents.
final class OutlineViewController: UITableViewController {
    private struct Row {
        let title: String
        let level: Int
        let destination: PDFDestination?
    }

    private var rows: [Row] = []
    private let onSelect: (PDFDestination) -> Void

    init(root: PDFOutline, onSelect: @escaping (PDFDestination) -> Void) {
        self.onSelect = onSelect
        super.init(style: .plain)
        title = "Contents"
        collect(root, level: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func collect(_ outline: PDFOutline, level: Int) {
        for index in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: index) else { continue }
            rows.append(Row(title: child.label ?? "Untitled", level: level, destination: child.destination))
            collect(child, level: level + 1)
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row") ?? UITableViewCell(style: .default, reuseIdentifier: "row")
        let row = rows[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = row.title
        content.directionalLayoutMargins.leading = CGFloat(16 + row.level * 18)
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if let destination = rows[indexPath.row].destination {
            onSelect(destination)
        }
    }
}
