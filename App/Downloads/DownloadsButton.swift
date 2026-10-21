import QuickLook
import UIKit

/// The toolbar's Downloads button: an arrow in a ring that fills while downloads run.
final class DownloadsRingView: UIControl {
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let icon = UIImageView(image: UIImage(systemName: "arrow.down"))

    /// 0…1 while downloads run, nil when idle (the ring is hidden).
    var progress: Double? {
        didSet { updateRing() }
    }

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        icon.contentMode = .center
        icon.isUserInteractionEnabled = false
        addSubview(icon)
        for shape in [track, ring] {
            shape.fillColor = UIColor.clear.cgColor
            shape.lineWidth = 2.5
            shape.lineCap = .round
            layer.addSublayer(shape)
        }
        ring.strokeEnd = 0
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Downloads"
        accessibilityIdentifier = "downloadsButton"
        updateColors()
        updateRing()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: DownloadsRingView, _: UITraitCollection) in
            view.updateColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: 32, height: 32)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        icon.frame = bounds
        let inset = bounds.insetBy(dx: 3, dy: 3)
        let path = UIBezierPath(
            arcCenter: CGPoint(x: inset.midX, y: inset.midY), radius: inset.width / 2,
            startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true)
        track.path = path.cgPath
        ring.path = path.cgPath
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateColors()
    }

    private func updateColors() {
        icon.tintColor = .label
        track.strokeColor = UIColor.tertiaryLabel.resolvedColor(with: traitCollection).cgColor
        ring.strokeColor = tintColor.resolvedColor(with: traitCollection).cgColor
    }

    private func updateRing() {
        let running = progress != nil
        track.isHidden = !running
        ring.isHidden = !running
        ring.strokeEnd = CGFloat(min(max(progress ?? 0, 0), 1))
        accessibilityValue = progress.map { "\(Int(($0 * 100).rounded())) percent" }
    }

    /// A short bounce when a download finishes.
    func bounce() {
        UIView.animate(withDuration: 0.15, animations: {
            self.transform = CGAffineTransform(scaleX: 1.25, y: 1.25)
        }, completion: { _ in
            UIView.animate(withDuration: 0.2) { self.transform = .identity }
        })
    }
}

/// Shows one file with Quick Look (until the dedicated viewers arrive).
final class FilePreviewController: QLPreviewController, QLPreviewControllerDataSource {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        super.init(nibName: nil, bundle: nil)
        dataSource = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        1
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        fileURL as NSURL
    }
}

enum DownloadedFiles {
    /// Opens the Files app at the folder holding `fileURL`.
    static func showInFiles(_ fileURL: URL) {
        var components = URLComponents()
        components.scheme = "shareddocuments"
        components.path = fileURL.deletingLastPathComponent().path
        if let url = components.url {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
}
