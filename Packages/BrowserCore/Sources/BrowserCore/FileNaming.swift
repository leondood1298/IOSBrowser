import Foundation

/// Safe, unique file names for downloads and saved pages.
public enum FileNaming {
    /// Removes path separators and characters the Files app rejects, trims dots and spaces,
    /// and limits the length (keeping the extension).
    public static func sanitize(_ name: String, fallback: String = "download") -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\0").union(.controlCharacters).union(.newlines)
        var cleaned = name.components(separatedBy: forbidden).joined(separator: "-")
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if cleaned.isEmpty {
            cleaned = fallback
        }
        if cleaned.count > 180 {
            let ext = (cleaned as NSString).pathExtension
            let stem = (cleaned as NSString).deletingPathExtension
            let keep = 180 - (ext.isEmpty ? 0 : ext.count + 1)
            cleaned = String(stem.prefix(max(keep, 1))) + (ext.isEmpty ? "" : ".\(ext)")
        }
        return cleaned
    }

    /// `name`, or "name (2).ext", "name (3).ext"… — the first that `exists` reports free.
    public static func unique(_ name: String, exists: (String) -> Bool) -> String {
        guard exists(name) else { return name }
        let ext = (name as NSString).pathExtension
        var stem = (name as NSString).deletingPathExtension
        var start = 2
        // Continue an existing "(n)" suffix instead of stacking another one.
        if let range = stem.range(of: #" \((\d+)\)$"#, options: .regularExpression) {
            let digits = stem[range].filter(\.isNumber)
            start = (Int(digits) ?? 1) + 1
            stem.removeSubrange(range)
        }
        for number in start... {
            let candidate = "\(stem) (\(number))" + (ext.isEmpty ? "" : ".\(ext)")
            if !exists(candidate) {
                return candidate
            }
        }
        return name
    }

    /// A free URL in `directory` for `name`.
    public static func uniqueURL(in directory: URL, for name: String, fileManager: FileManager = .default) -> URL {
        let free = unique(sanitize(name)) { candidate in
            fileManager.fileExists(atPath: directory.appendingPathComponent(candidate).path)
        }
        return directory.appendingPathComponent(free)
    }

    /// A file name for a page saved offline, from its title or host.
    public static func pageFileName(title: String?, url: URL?, extension ext: String) -> String {
        let base = URLDisplay.tabTitle(pageTitle: title, url: url)
        return sanitize(base, fallback: "Page") + ".\(ext)"
    }
}
