import BrowserCore
import SwiftUI
import UniformTypeIdentifiers

/// Where the user chose to save a download.
struct DownloadChoice {
    var fileName: String
    var folder: String
}

/// The sheet shown before a download starts: name, size, type and folder.
enum DownloadConfirmation {
    /// Shows the sheet and waits for the choice; nil when the user cancels.
    static func ask(
        from presenter: UIViewController, fileName: String, size: Int64?, mimeType: String?, folder: String
    ) async -> DownloadChoice? {
        await withCheckedContinuation { continuation in
            var answered = false
            var host: UIViewController?
            let answer: (DownloadChoice?) -> Void = { choice in
                guard !answered else { return }
                answered = true
                host?.dismiss(animated: true)
                continuation.resume(returning: choice)
            }
            let folders = AppFolders.defaultFolderNames.contains(folder)
                ? AppFolders.defaultFolderNames
                : AppFolders.defaultFolderNames + [folder]
            let view = DownloadConfirmView(
                fileName: fileName, size: size, mimeType: mimeType, folder: folder, folders: folders,
                onDownload: { answer($0) }, onCancel: { answer(nil) })
            let controller = UIHostingController(rootView: view)
            controller.modalPresentationStyle = .formSheet
            controller.preferredContentSize = CGSize(width: 480, height: 440)
            // Swiping the sheet away would leave the download waiting forever.
            controller.isModalInPresentation = true
            host = controller
            var top = presenter
            while let presented = top.presentedViewController, !presented.isBeingDismissed {
                top = presented
            }
            top.present(controller, animated: true)
        }
    }
}

struct DownloadConfirmView: View {
    let size: Int64?
    let mimeType: String?
    let folders: [String]
    let onDownload: (DownloadChoice) -> Void
    let onCancel: () -> Void
    @State private var fileName: String
    @State private var folder: String

    init(
        fileName: String, size: Int64?, mimeType: String?, folder: String, folders: [String],
        onDownload: @escaping (DownloadChoice) -> Void, onCancel: @escaping () -> Void
    ) {
        self.size = size
        self.mimeType = mimeType
        self.folders = folders
        self.onDownload = onDownload
        self.onCancel = onCancel
        _fileName = State(initialValue: fileName)
        _folder = State(initialValue: folder)
    }

    private var trimmedName: String {
        fileName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var kind: String {
        let ext = (fileName as NSString).pathExtension
        let type = mimeType.flatMap { UTType(mimeType: $0) } ?? UTType(filenameExtension: ext)
        return type?.localizedDescription ?? "File"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: FileCategory.of(fileName: fileName, mimeType: mimeType).symbolName)
                            .font(.system(size: 34))
                            .foregroundStyle(.tint)
                            .frame(width: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(kind)
                            Text(size.map(DownloadFormatting.bytes) ?? "Size unknown")
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                    }
                    .padding(.vertical, 4)
                }
                Section("Name") {
                    TextField("File name", text: $fileName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("downloadFileName")
                }
                Section("Save To") {
                    Picker("Folder", selection: $folder) {
                        ForEach(folders, id: \.self) { name in
                            Label(name, systemImage: "folder").tag(name)
                        }
                    }
                }
            }
            .navigationTitle("Download File")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .accessibilityIdentifier("cancelDownloadButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download") {
                        onDownload(DownloadChoice(fileName: FileNaming.sanitize(trimmedName), folder: folder))
                    }
                    .disabled(trimmedName.isEmpty)
                    .accessibilityIdentifier("confirmDownloadButton")
                }
            }
        }
    }
}
