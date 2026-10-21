#if DEBUG
import UIKit

/// Sample images and a PDF for the viewer UI tests (launch argument --seed-viewer-files): five
/// numbered colour images and a five-page PDF in Documents/Viewer Test.
enum TestFiles {
    static func writeViewerSamples() {
        let folder = AppFolders.documentsDirectory.appendingPathComponent("Viewer Test", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let colors: [UIColor] = [.systemRed, .systemOrange, .systemGreen, .systemBlue, .systemPurple]
        let size = CGSize(width: 1200, height: 800)
        for (index, color) in colors.enumerated() {
            let image = UIGraphicsImageRenderer(size: size).image { context in
                color.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                draw("\(index + 1)", in: CGRect(origin: .zero, size: size), size: 360, color: .white)
            }
            try? image.pngData()?.write(to: folder.appendingPathComponent("Image \(index + 1).png"))
        }
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = UIGraphicsPDFRenderer(bounds: page).pdfData { context in
            for number in 1...5 {
                context.beginPage()
                draw("Page \(number)", in: page, size: 72, color: .black)
            }
        }
        try? pdf.write(to: folder.appendingPathComponent("Sample.pdf"))
    }

    private static func draw(_ text: String, in rect: CGRect, size: CGFloat, color: UIColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: color,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let bounds = string.size()
        string.draw(at: CGPoint(x: rect.midX - bounds.width / 2, y: rect.midY - bounds.height / 2))
    }
}
#endif
