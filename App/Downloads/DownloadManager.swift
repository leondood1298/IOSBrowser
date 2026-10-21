import BrowserCore
import Combine
import UIKit
import WebKit

/// Every download in the app. Downloads run through WebKit, so a tab's cookies, user agent and
/// private storage apply. The manager asks where to save, tracks progress, pauses and resumes,
/// and moves finished files from a hidden staging folder into their folder in Files.
/// Normal downloads are listed across launches; private ones are kept in memory until Erase.
final class DownloadManager: NSObject, ObservableObject {
    @Published private(set) var items: [DownloadItem] = []
    /// Overall progress of the running downloads (0…1), or nil when nothing with a known size runs.
    @Published private(set) var overallProgress: Double?
    @Published private(set) var runningCount = 0
    /// A download got its row and started (windows show a short message).
    let didStart = PassthroughSubject<DownloadItem, Never>()
    /// A download finished and its file is in place.
    let didFinish = PassthroughSubject<DownloadItem, Never>()

    /// What we know about a download before it has a row: where it came from and who to ask.
    private struct Origin {
        var pageURL: URL?
        var isPrivate: Bool
        weak var presenter: UIViewController?
    }

    private let preferences: Preferences
    private let file: JSONFileStore<[DownloadRecord]>
    /// Application Support/Downloads: partial files ("Incomplete") and resume data.
    private let directory: URL
    private var active: [UUID: WKDownload] = [:]
    private var itemIDs: [ObjectIdentifier: UUID] = [:]
    private var origins: [ObjectIdentifier: Origin] = [:]
    /// Downloads continuing from resume data: their partial file must be kept.
    private var resuming: Set<UUID> = []
    private var helperWebViews: [Bool: WKWebView] = [:]
    private var progressTimer: Timer?
    private var saveTask: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var pendingBackgroundPauses = 0
    private var lifecycleObservers: [NSObjectProtocol] = []

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
    }

    init(
        preferences: Preferences,
        file: JSONFileStore<[DownloadRecord]> = LibraryFiles.store("downloads.json"),
        directory: URL = DownloadManager.defaultDirectory
    ) {
        self.preferences = preferences
        self.file = file
        self.directory = directory
        super.init()
        let saved = file.load() ?? []
        let reconciled = DownloadScheduler.reconcileAfterLaunch(saved) { [directory] id in
            FileManager.default.fileExists(atPath: Self.resumeDataURL(for: id, in: directory).path)
        }
        items = reconciled.map(makeItem)
        if reconciled != saved {
            save()
        }
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appDidEnterBackground() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appWillEnterForeground() }
            },
        ]
    }

    func item(_ id: UUID) -> DownloadItem? {
        items.first { $0.id == id }
    }

    // MARK: - Starting

    /// Takes over a download WebKit started for a page: a file link, or a response it can't show.
    func adopt(_ download: WKDownload, from tab: TabModel?) {
        download.delegate = self
        origins[ObjectIdentifier(download)] = Origin(
            pageURL: tab?.url, isPrivate: tab?.isPrivate ?? false,
            presenter: tab.flatMap { $0.delegate?.presenter(for: $0) })
    }

    /// Downloads a link from a page with that tab's web view, so its cookies apply and the page
    /// is sent as the referrer. Works for the page's own blob: links too.
    func download(_ url: URL, from tab: TabModel) {
        if url.scheme?.lowercased() == "data" {
            saveDataURL(url, pageURL: tab.url, isPrivate: tab.isPrivate)
            return
        }
        guard let webView = tab.webView else {
            download(url, isPrivate: tab.isPrivate, pageURL: tab.url, presenter: tab.delegate?.presenter(for: tab))
            return
        }
        var request = URLRequest(url: url)
        if let page = tab.url, ["http", "https"].contains(page.scheme?.lowercased() ?? "") {
            request.setValue(page.absoluteString, forHTTPHeaderField: "Referer")
        }
        webView.startDownload(using: request) { [weak self, weak tab] download in
            MainActor.assumeIsolated {
                self?.adopt(download, from: tab)
            }
        }
    }

    /// Downloads an address entered in "Download from URL".
    func download(_ url: URL, isPrivate: Bool, pageURL: URL? = nil, presenter: UIViewController?) {
        if url.scheme?.lowercased() == "data" {
            saveDataURL(url, pageURL: pageURL, isPrivate: isPrivate)
            return
        }
        helperWebView(isPrivate: isPrivate).startDownload(using: URLRequest(url: url)) { [weak self, weak presenter] download in
            MainActor.assumeIsolated {
                guard let self else { return }
                download.delegate = self
                self.origins[ObjectIdentifier(download)] = Origin(pageURL: pageURL, isPrivate: isPrivate, presenter: presenter)
            }
        }
    }

    /// Lists a file the browser saved itself, such as an image saved from a page.
    func addSavedFile(_ fileURL: URL, folder: String, sourceURL: URL?, pageURL: URL?, isPrivate: Bool) {
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        let record = DownloadRecord(
            sourceURL: sourceURL, pageURL: pageURL, fileName: fileURL.lastPathComponent, folder: folder,
            expectedBytes: size, receivedBytes: size ?? 0, state: .finished, isPrivate: isPrivate, finished: Date())
        items.insert(makeItem(record), at: 0)
        save()
    }

    /// The folder new downloads go to: the chosen one, or one by file type.
    func defaultFolder(forFileNamed name: String, mimeType: String?) -> String {
        preferences.sortDownloadsByType
            ? FileCategory.of(fileName: name, mimeType: mimeType).folderName
            : preferences.downloadFolder
    }

    // MARK: - Controlling

    func pause(_ item: DownloadItem) {
        guard let download = active[item.id], item.move(to: .paused) else { return }
        stop(download, item: item)
    }

    func resume(_ item: DownloadItem) {
        guard item.record.state == .paused else { return }
        guard let data = try? Data(contentsOf: resumeDataURL(for: item.id)) else {
            retry(item)
            return
        }
        guard item.move(to: .running, change: { $0.failureReason = nil }) else { return }
        resuming.insert(item.id)
        helperWebView(isPrivate: item.record.isPrivate).resumeDownload(fromResumeData: data) { [weak self] download in
            MainActor.assumeIsolated {
                guard let self else { return }
                download.delegate = self
                self.track(download, as: item.id)
            }
        }
    }

    /// Starts a failed or cancelled download again from its address.
    func retry(_ item: DownloadItem) {
        guard item.record.canRetry, let url = item.record.sourceURL else { return }
        removeResumeData(for: item.id)
        removePartialFile(for: item.id)
        let moved = item.move(to: .queued) { record in
            record.failureReason = nil
            record.linkExpired = false
            record.receivedBytes = 0
        }
        guard moved else { return }
        if url.scheme?.lowercased() == "data" {
            remove(item)
            saveDataURL(url, pageURL: item.record.pageURL, isPrivate: item.record.isPrivate)
            return
        }
        item.move(to: .running)
        helperWebView(isPrivate: item.record.isPrivate).startDownload(using: URLRequest(url: url)) { [weak self] download in
            MainActor.assumeIsolated {
                guard let self else { return }
                download.delegate = self
                self.track(download, as: item.id)
            }
        }
        save()
    }

    func cancel(_ item: DownloadItem) {
        let download = active[item.id]
        guard item.move(to: .cancelled) else { return }
        if let download {
            untrack(download)
            download.cancel { _ in }
        }
        resuming.remove(item.id)
        removeResumeData(for: item.id)
        removePartialFile(for: item.id)
        save()
    }

    /// Takes a download off the list (stopping it if it runs). The file stays.
    func remove(_ item: DownloadItem) {
        if item.record.state.isActive {
            cancel(item)
        }
        items.removeAll { $0.id == item.id }
        save()
    }

    /// Deletes the downloaded file and takes it off the list.
    func deleteFile(_ item: DownloadItem) {
        if item.record.state == .finished {
            try? FileManager.default.removeItem(at: item.fileURL)
        }
        remove(item)
    }

    func rename(_ item: DownloadItem, to newName: String) throws {
        let name = FileNaming.sanitize(newName)
        guard name != item.record.fileName else { return }
        if item.record.state == .finished {
            let destination = FileNaming.uniqueURL(in: item.fileURL.deletingLastPathComponent(), for: name)
            try FileManager.default.moveItem(at: item.fileURL, to: destination)
            item.update { $0.fileName = destination.lastPathComponent }
        } else {
            item.update { $0.fileName = name }
        }
        save()
    }

    /// Clears finished, failed and cancelled downloads from the list (files stay).
    func clearInactive() {
        items.removeAll { !$0.record.state.isActive }
        save()
    }

    /// Clear Browsing Data: forgets the list of downloads (files stay).
    func clearList(since date: Date? = nil) {
        items.removeAll { item in
            !item.record.state.isActive && item.record.created >= (date ?? .distantPast)
        }
        save()
    }

    /// Erase: stops private downloads and forgets them (finished files stay in their folder).
    func erasePrivateDownloads() {
        for item in items where item.record.isPrivate && item.record.state.isActive {
            cancel(item)
        }
        items.removeAll { $0.record.isPrivate }
        helperWebViews[true] = nil
    }

    // MARK: - Background

    /// Keeps downloads going for a while after the app leaves the screen; when that time runs
    /// out they're paused with what's needed to continue later.
    func appDidEnterBackground() {
        guard !active.isEmpty, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Downloads") { [weak self] in
            MainActor.assumeIsolated {
                self?.pauseAllForBackground()
            }
        }
    }

    func appWillEnterForeground() {
        endBackgroundTask()
    }

    private func pauseAllForBackground() {
        var toStop: [(DownloadItem, WKDownload)] = []
        for (id, download) in active {
            if let item = item(id), item.move(to: .paused, change: { $0.failureReason = "Paused in the background" }) {
                toStop.append((item, download))
            }
        }
        guard !toStop.isEmpty else {
            endBackgroundTask()
            return
        }
        pendingBackgroundPauses = toStop.count
        for (item, download) in toStop {
            stop(download, item: item)
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
        pendingBackgroundPauses = 0
    }

    // MARK: - Internals

    private func makeItem(_ record: DownloadRecord) -> DownloadItem {
        let item = DownloadItem(record: record)
        item.onStateChange = { [weak self] in self?.objectWillChange.send() }
        return item
    }

    private func track(_ download: WKDownload, as id: UUID) {
        active[id] = download
        itemIDs[ObjectIdentifier(download)] = id
        updateCounts()
        startProgressTimer()
    }

    @discardableResult
    private func untrack(_ download: WKDownload) -> DownloadItem? {
        guard let id = itemIDs.removeValue(forKey: ObjectIdentifier(download)) else { return nil }
        active[id] = nil
        updateCounts()
        if active.isEmpty && pendingBackgroundPauses == 0 {
            endBackgroundTask()
        }
        return item(id)
    }

    /// Cancels the transfer, keeping resume data when the server allows continuing later.
    private func stop(_ download: WKDownload, item: DownloadItem) {
        download.cancel { [weak self] resumeData in
            MainActor.assumeIsolated {
                self?.didStop(download, item: item, resumeData: resumeData)
            }
        }
    }

    private func didStop(_ download: WKDownload, item: DownloadItem, resumeData: Data?) {
        untrack(download)
        if let resumeData {
            writeResumeData(resumeData, for: item.id)
        } else {
            item.move(to: .failed) {
                $0.failureReason = "This server can't continue the download later, so it stopped. Retry starts it again."
            }
            removePartialFile(for: item.id)
        }
        resuming.remove(item.id)
        save()
        if pendingBackgroundPauses > 0 {
            pendingBackgroundPauses -= 1
            if pendingBackgroundPauses == 0 {
                endBackgroundTask()
            }
        }
    }

    private func finish(_ item: DownloadItem) {
        let fileManager = FileManager.default
        let partial = partialFileURL(for: item.record)
        resuming.remove(item.id)
        let size = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        if let expected = item.record.expectedBytes, let size, size < expected {
            removePartialFile(for: item.id)
            item.move(to: .failed) { record in
                record.failureReason = "The file is incomplete. The link may have expired."
                record.linkExpired = true
            }
            save()
            return
        }
        let folder = AppFolders.documentsDirectory.appendingPathComponent(item.record.folder, isDirectory: true)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = FileNaming.uniqueURL(in: folder, for: item.record.fileName)
            try fileManager.moveItem(at: partial, to: destination)
            removePartialFile(for: item.id)
            item.move(to: .finished) { record in
                record.fileName = destination.lastPathComponent
                record.finished = Date()
                if let size {
                    record.receivedBytes = size
                    record.expectedBytes = size
                }
            }
            didFinish.send(item)
        } catch {
            item.move(to: .failed) { $0.failureReason = "The file couldn't be saved: \(error.localizedDescription)" }
        }
        removeResumeData(for: item.id)
        save()
    }

    private func saveDataURL(_ url: URL, pageURL: URL?, isPrivate: Bool) {
        guard let contents = DataURL(url) else { return }
        let folderName = defaultFolder(forFileNamed: contents.suggestedFileName, mimeType: contents.mimeType)
        let folder = AppFolders.documentsDirectory.appendingPathComponent(folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = FileNaming.uniqueURL(in: folder, for: contents.suggestedFileName)
            try contents.data.write(to: destination)
            addSavedFile(destination, folder: folderName, sourceURL: url, pageURL: pageURL, isPrivate: isPrivate)
            if let item = items.first {
                didFinish.send(item)
            }
        } catch {
            Log.event("Saving a data: link failed: \(error.localizedDescription)", category: "downloads")
        }
    }

    /// A web view that isn't on screen, for starting and resuming downloads with the right
    /// website data (normal, or the current private session).
    private func helperWebView(isPrivate: Bool) -> WKWebView {
        let store = isPrivate ? AppServices.shared.privateSession.dataStore : WKWebsiteDataStore.default()
        if let webView = helperWebViews[isPrivate], webView.configuration.websiteDataStore === store {
            return webView
        }
        let webView = WKWebView(frame: .zero, configuration: WebViewFactory.makeConfiguration(isPrivate: isPrivate))
        helperWebViews[isPrivate] = webView
        return webView
    }

    // MARK: Progress

    private func startProgressTimer() {
        guard progressTimer == nil else { return }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateProgress()
            }
        }
    }

    private func updateProgress() {
        let now = ProcessInfo.processInfo.systemUptime
        for (id, download) in active {
            guard let item = item(id), item.record.state == .running else { continue }
            let progress = download.progress
            let expected = progress.totalUnitCount > 0 ? progress.totalUnitCount : nil
            item.progress(received: max(0, progress.completedUnitCount), expected: expected, at: now)
        }
        updateCounts()
        if active.isEmpty {
            progressTimer?.invalidate()
            progressTimer = nil
        }
    }

    private func updateCounts() {
        let running = items.filter { $0.record.state == .running }
        if runningCount != running.count {
            runningCount = running.count
        }
        let sized = running.filter { ($0.record.expectedBytes ?? 0) > 0 }
        let total = sized.reduce(Int64(0)) { $0 + ($1.record.expectedBytes ?? 0) }
        let received = sized.reduce(Int64(0)) { $0 + min($1.record.receivedBytes, $1.record.expectedBytes ?? 0) }
        let progress: Double? = total > 0 ? Double(received) / Double(total) : nil
        if overallProgress != progress {
            overallProgress = progress
        }
    }

    // MARK: Files

    private static func resumeDataURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("ResumeData", isDirectory: true).appendingPathComponent("\(id.uuidString).data")
    }

    private func resumeDataURL(for id: UUID) -> URL {
        Self.resumeDataURL(for: id, in: directory)
    }

    private func writeResumeData(_ data: Data, for id: UUID) {
        let url = resumeDataURL(for: id)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func removeResumeData(for id: UUID) {
        try? FileManager.default.removeItem(at: resumeDataURL(for: id))
    }

    /// Where a download is written until it finishes; hidden from the Files app.
    private func partialFileURL(for record: DownloadRecord) -> URL {
        directory.appendingPathComponent("Incomplete", isDirectory: true)
            .appendingPathComponent(record.id.uuidString, isDirectory: true)
            .appendingPathComponent(record.fileName.isEmpty ? "download" : record.fileName)
    }

    private func removePartialFile(for id: UUID) {
        let folder = directory.appendingPathComponent("Incomplete", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
    }

    /// An empty place for a new transfer to write to (a resumed one keeps its partial file).
    private func preparePartialFile(for record: DownloadRecord) -> URL {
        let url = partialFileURL(for: record)
        if !resuming.contains(record.id) {
            removePartialFile(for: record.id)
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    private func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            let records = self.items.map(\.record).filter { !$0.isPrivate }
            LibraryFiles.write(records, to: self.file)
        }
    }

    private static func reason(for error: NSError) -> String {
        if error.domain == NSURLErrorDomain {
            switch error.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "The connection was lost."
            case NSURLErrorTimedOut:
                return "The server stopped responding."
            case NSURLErrorCannotCreateFile, NSURLErrorCannotWriteToFile:
                return "The file couldn't be written. Is the iPad full?"
            default:
                break
            }
        }
        return error.localizedDescription
    }

    private static func reason(forStatus status: Int) -> String {
        switch status {
        case 401, 403: return "The server refused the download (\(status)). The link may have expired."
        case 404, 410: return "The file isn't there any more (\(status))."
        default: return "The server returned an error (\(status))."
        }
    }
}

// MARK: - WKDownloadDelegate

extension DownloadManager: WKDownloadDelegate {
    func download(
        _ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String
    ) async -> URL? {
        let key = ObjectIdentifier(download)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200

        // Retried and resumed downloads already have a row.
        if let id = itemIDs[key], let item = item(id) {
            guard status < 400 else {
                untrack(download)
                item.move(to: .failed) { record in
                    record.failureReason = Self.reason(forStatus: status)
                    record.linkExpired = [401, 403, 404, 410].contains(status)
                }
                save()
                return nil
            }
            if response.expectedContentLength > 0, !resuming.contains(id) {
                item.update { $0.expectedBytes = response.expectedContentLength }
            }
            return preparePartialFile(for: item.record)
        }

        guard let origin = origins.removeValue(forKey: key) else { return nil }
        let expected = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        var name = FileNaming.sanitize(suggestedFilename)
        var folder = defaultFolder(forFileNamed: name, mimeType: response.mimeType)
        if preferences.confirmDownloads, let presenter = origin.presenter {
            let choice = await DownloadConfirmation.ask(
                from: presenter, fileName: name, size: expected, mimeType: response.mimeType, folder: folder)
            guard let choice else { return nil }
            name = choice.fileName
            folder = choice.folder
        }
        var record = DownloadRecord(
            sourceURL: download.originalRequest?.url ?? response.url, pageURL: origin.pageURL, fileName: name,
            folder: folder, mimeType: response.mimeType, expectedBytes: expected, state: .running,
            isPrivate: origin.isPrivate)
        if status >= 400 {
            record.state = .failed
            record.failureReason = Self.reason(forStatus: status)
            record.linkExpired = [401, 403, 404, 410].contains(status)
            items.insert(makeItem(record), at: 0)
            save()
            return nil
        }
        let item = makeItem(record)
        items.insert(item, at: 0)
        track(download, as: item.id)
        save()
        didStart.send(item)
        return preparePartialFile(for: record)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let item = untrack(download) else { return }
        finish(item)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = untrack(download) else {
            origins[ObjectIdentifier(download)] = nil
            return
        }
        resuming.remove(item.id)
        // Paused or cancelled here: the state already says so.
        guard item.record.state == .running else { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            item.move(to: .cancelled)
            removePartialFile(for: item.id)
        } else if let resumeData {
            writeResumeData(resumeData, for: item.id)
            item.move(to: .paused) { $0.failureReason = Self.reason(for: nsError) }
        } else {
            removePartialFile(for: item.id)
            item.move(to: .failed) { $0.failureReason = Self.reason(for: nsError) }
        }
        save()
    }
}
