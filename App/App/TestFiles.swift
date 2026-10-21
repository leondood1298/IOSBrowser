#if DEBUG
import UIKit

/// Sample files for the viewer and player UI tests (launch argument --seed-viewer-files): five
/// numbered colour images, a five-page PDF and a short tone in Documents/Viewer Test.
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
        try? toneWAV(seconds: 4).write(to: folder.appendingPathComponent("Tone.wav"))
    }

    /// A mono 16-bit 440 Hz tone.
    private static func toneWAV(seconds: Int, rate: Int = 22050) -> Data {
        var samples = Data(capacity: seconds * rate * 2)
        for index in 0..<(seconds * rate) {
            let value = Int16(8000 * sin(2 * Double.pi * 440 * Double(index) / Double(rate)))
            withUnsafeBytes(of: value.littleEndian) { samples.append(contentsOf: $0) }
        }
        var header = Data()
        func append(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + samples.count))
        header.append(contentsOf: Array("WAVEfmt ".utf8))
        append(16)
        append16(1)
        append16(1)
        append(UInt32(rate))
        append(UInt32(rate * 2))
        append16(2)
        append16(16)
        header.append(contentsOf: Array("data".utf8))
        append(UInt32(samples.count))
        return header + samples
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
