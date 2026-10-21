import Photos
import UniformTypeIdentifiers

/// Saves images and videos from the file manager to the photo library (add-only access).
enum PhotoLibrary {
    static func save(_ urls: [URL]) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw ImageActions.Failure.photosAccessDenied }
        let items = urls.map { url -> (URL, PHAssetResourceType) in
            let type = UTType(filenameExtension: url.pathExtension)
            let isVideo = type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true
            return (url, isVideo ? .video : .photo)
        }
        try await PHPhotoLibrary.shared().performChanges {
            for (url, kind) in items {
                PHAssetCreationRequest.forAsset().addResource(with: kind, fileURL: url, options: nil)
            }
        }
    }
}
