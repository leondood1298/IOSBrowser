import BrowserCore
import Combine
import UIKit
import WebKit

/// Every download in the app. Downloads start in WebKit, so a tab's cookies, user agent and
/// private storage apply. Normal-tab downloads that can be resumed then move to a background
/// URLSession (`SessionDownloader`), which keeps going while the app is suspended and can fetch
/// big files in several parts at once; everything else stays with WebKit. The manager asks where
/// to save, tracks progress, pauses and resumes, and moves finished files from a hidden staging
/// folder into their folder in Files. Normal downloads are listed across launches; private ones
/// are kept in memory until Erase.
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
        /// A name to use when the server's has no extension (a video saved from the media picker).
        var preferredName: String?
    }

    let preferences: Preferences
    private let file: JSONFileStore<[DownloadRecord]>
    /// Application Support/Downloads: partial files ("Incomplete") and resume data.
    let directory: URL
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
    /// The system Live Activity for running downloads.
    private let activity = DownloadActivity()
    private lazy var notifier = DownloadNotifier { [weak self] in self?.preferences.downloadNotifications ?? false }
    /// The background engine and what it's doing.
    private let sessionEngine: SessionDownloader
    private var sessionRunning: Set<UUID> = []
    private var partBytes: [UUID: [Int: Int64]] = [:]
    private var merging: Set<UUID> = []
    private(set) var defaultUserAgent: String?
    /// The system's completion handler while it runs the app for background download events.
    var backgroundEventsCompletion: (() -> Void)?
    /// Running stream (HLS) downloads, and the headers each one fetches with (see DownloadManager+Streams).
    var streamTasks: [UUID: Task<Void, Never>] = [:]
    var streamRequests: [UUID: StreamRequest] = [:]

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
        sessionEngine = SessionDownloader(directory: directory.appendingPathComponent("Parts", isDirectory: true))
        super.init()
        let saved = file.load() ?? []
        // WebKit downloads stopped with the app; background ones may still be running (see below).
        let webKit = DownloadScheduler.reconcileAfterLaunch(saved.filter { $0.sessionParts == nil }) { [directory] id in
            FileManager.default.fileExists(atPath: Self.resumeDataURL(for: id, in: directory).path)
                || FileManager.default.fileExists(atPath: Self.streamJobURL(for: id, in: directory).path)
        }
        let byID = Dictionary(uniqueKeysWithValues: webKit.map { ($0.id, $0) })
        let reconciled = saved.map { byID[$0.id] ?? $0 }
        items = reconciled.map(makeItem)
        if reconciled != saved {
            save()
        }
        sessionEngine.connect { [weak self] event in self?.handle(event) }
        Task { [weak self] in await self?.reconcileSessionDownloads() }
        activity.onExpire = { [weak self] in self?.pauseAllForBackground() }
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

    /// The page a downloaded file came from, for the file manager's "Open Source Page".
    func sourcePage(forFile url: URL) -> URL? {
        let path = url.standardizedFileURL.path
        return items.first { $0.record.state == .finished && $0.fileURL.standardizedFileURL.path == path }?.record.pageURL
    }

    // MARK: - Starting

    /// Takes over a download WebKit started for a page: a file link, or a response it can't show.
    func adopt(_ download: WKDownload, from tab: TabModel?, preferredName: String? = nil) {
        download.delegate = self
        origins[ObjectIdentifier(download)] = Origin(
            pageURL: tab?.url, isPrivate: tab?.isPrivate ?? false,
            presenter: tab.flatMap { $0.delegate?.presenter(for: $0) }, preferredName: preferredName)
    }

    /// Downloads a link from a page with that tab's web view, so its cookies apply and the page
    /// is sent as the referrer. Works for the page's own blob: links too. `preferredName` is used
    /// when the server's file name has no extension.
    func download(_ url: URL, from tab: TabModel, preferredName: String? = nil) {
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
                self?.adopt(download, from: tab, preferredName: preferredName)
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
        if item.record.stream != nil {
            pauseStream(item)
            return
        }
        if item.record.sessionParts != nil {
            pauseSession(item, reason: nil)
            return
        }
        guard let download = active[item.id], item.move(to: .paused) else { return }
        stop(download, item: item)
    }

    func resume(_ item: DownloadItem) {
        guard item.record.state == .paused else { return }
        if item.record.stream != nil {
            resumeStream(item)
            return
        }
        if item.record.sessionParts != nil {
            guard item.move(to: .running, change: { $0.failureReason = nil }) else { return }
            startSessionParts(item)
            showInLiveActivity(item)
            return
        }
        guard let data = try? Data(contentsOf: resumeDataURL(for: item.id)) else {
            retry(item)
            return
        }
        guard item.move(to: .running, change: { $0.failureReason = nil }) else { return }
        resuming.insert(item.id)
        showInLiveActivity(item)
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
        if item.record.stream != nil {
            resumeStream(item)
            return
        }
        // Retries run in WebKit, the way the page itself would fetch the file.
        if item.record.sessionParts != nil {
            removeSessionFiles(for: item.id)
            item.update { $0.sessionParts = nil }
        }
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
        showInLiveActivity(item)
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
        let usesSession = item.record.sessionParts != nil
        guard item.move(to: .cancelled) else { return }
        if item.record.stream != nil {
            // Keeps what Retry needs to read the stream again.
            discardStream(item.id, keepJob: true)
        }
        if let download {
            untrack(download)
            download.cancel { _ in }
        }
        if usesSession {
            sessionRunning.remove(item.id)
            removeSessionFiles(for: item.id)
            updateCounts()
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
        if item.record.stream != nil {
            discardStream(item.id, keepJob: false)
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
        for item in items where !item.record.state.isActive && item.record.stream != nil {
            discardStream(item.id, keepJob: false)
        }
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
        for item in items where item.record.isPrivate && item.record.stream != nil {
            discardStream(item.id, keepJob: false)
        }
        items.removeAll { $0.record.isPrivate }
        helperWebViews[true] = nil
    }

    // MARK: - Background

    /// Keeps downloads going for a while after the app leaves the screen; when that time runs
    /// out they're paused with what's needed to continue later.
    func appDidEnterBackground() {
        guard !active.isEmpty || !streamTasks.isEmpty, backgroundTask == .invalid, !activity.isRunning else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Downloads") { [weak self] in
            MainActor.assumeIsolated {
                self?.pauseAllForBackground()
            }
        }
    }

    func appWillEnterForeground() {
        endBackgroundTask()
        notifier.clearBadge()
    }

    private func pauseAllForBackground() {
        for id in Array(streamTasks.keys) {
            if let item = item(id) {
                pauseStream(item, reason: "Paused in the background")
            }
        }
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

    /// A stream stopped: the app needn't stay awake in the background when nothing else runs.
    func streamDidStop() {
        updateCounts()
        activity.update(with: items)
        if active.isEmpty && streamTasks.isEmpty && pendingBackgroundPauses == 0 {
            endBackgroundTask()
        }
    }

    /// Progress from a stream download, for the counts and the Live Activity.
    func streamProgressChanged() {
        updateCounts()
        activity.update(with: items)
    }

    /// Adds a new download at the top of the list.
    func insert(_ item: DownloadItem) {
        items.insert(item, at: 0)
        save()
        didStart.send(item)
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
        pendingBackgroundPauses = 0
    }

    // MARK: - Internals

    func makeItem(_ record: DownloadRecord) -> DownloadItem {
        let item = DownloadItem(record: record)
        item.onStateChange = { [weak self, weak item] in
            guard let self else { return }
            self.objectWillChange.send()
            self.activity.update(with: self.items)
            if let item {
                self.notifier.stateChanged(item)
            }
        }
        return item
    }

    func showInLiveActivity(_ item: DownloadItem) {
        notifier.prepare()
        // UI tests skip it: the simulator can't show it, and system banners could cover the toolbar.
        guard preferences.downloadLiveActivity, !ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return }
        activity.downloadStarted(item.id, title: "Downloading \(item.record.fileName)")
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
        if active.isEmpty && streamTasks.isEmpty && pendingBackgroundPauses == 0 {
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

    func finish(_ item: DownloadItem) {
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

    // MARK: Background engine

    /// Normal-tab GET downloads with a known size from servers that accept byte ranges.
    private func canUseSession(origin: Origin, request: URLRequest, response: URLResponse) -> Bool {
        guard preferences.backgroundDownloads, !origin.isPrivate,
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength > 0,
              (request.httpMethod ?? "GET").uppercased() == "GET",
              let scheme = request.url?.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return false }
        return (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased().contains("bytes")
    }

    private func sessionParts(for record: DownloadRecord) -> [DownloadPart] {
        DownloadPart.parts(of: record.id, ranges: record.partRanges)
    }

    /// Starts (or continues) every part that isn't finished yet.
    private func startSessionParts(_ item: DownloadItem, url: URL? = nil) {
        guard let url = url ?? item.record.sourceURL else { return }
        var request = URLRequest(url: url)
        if let agent = defaultUserAgent {
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
        }
        if let page = item.record.pageURL, ["http", "https"].contains(page.scheme?.lowercased() ?? "") {
            request.setValue(page.absoluteString, forHTTPHeaderField: "Referer")
        }
        sessionRunning.insert(item.id)
        partBytes[item.id] = [:]
        for part in sessionParts(for: item.record) {
            if sessionEngine.isFinished(part) {
                partBytes[item.id]?[part.index] = part.expectedLength ?? 0
                continue
            }
            let resumeURL = sessionEngine.resumeDataURL(part)
            if let data = try? Data(contentsOf: resumeURL) {
                try? FileManager.default.removeItem(at: resumeURL)
                sessionEngine.resume(part, resumeData: data)
            } else {
                sessionEngine.start(part, request: request)
            }
        }
        if sessionParts(for: item.record).allSatisfy(sessionEngine.isFinished) {
            mergeParts(of: item)
        }
        updateCounts()
        startProgressTimer()
    }

    /// Pauses every part, keeping resume data, so the download continues as a whole later.
    private func pauseSession(_ item: DownloadItem, reason: String?) {
        guard item.move(to: .paused, change: { $0.failureReason = reason }) else { return }
        sessionRunning.remove(item.id)
        updateCounts()
        let id = item.id
        Task {
            let saved = await sessionEngine.pause(id)
            for (part, data) in saved {
                try? FileManager.default.createDirectory(at: sessionEngine.folder(for: id), withIntermediateDirectories: true)
                try? data.write(to: sessionEngine.resumeDataURL(part), options: .atomic)
            }
            save()
        }
    }

    private func removeSessionFiles(for id: UUID) {
        let folder = sessionEngine.folder(for: id)
        Task {
            await sessionEngine.cancel(id)
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func handle(_ event: SessionDownloader.Event) {
        switch event {
        case .progress(let part, let written):
            guard let item = item(part.downloadID), item.record.state == .running else { return }
            partBytes[part.downloadID, default: [:]][part.index] = written
            let received = partBytes[part.downloadID]?.values.reduce(0, +) ?? written
            item.progress(received: received, expected: item.record.expectedBytes, at: ProcessInfo.processInfo.systemUptime)
        case .finished(let part):
            guard let item = item(part.downloadID), item.record.state == .running else { return }
            if let length = part.expectedLength {
                partBytes[part.downloadID, default: [:]][part.index] = length
            }
            if sessionParts(for: item.record).allSatisfy(sessionEngine.isFinished) {
                mergeParts(of: item)
            }
        case .failed(let part, let message, let resumeData, let status):
            guard let item = item(part.downloadID), item.record.state == .running else { return }
            if let resumeData {
                try? FileManager.default.createDirectory(
                    at: sessionEngine.folder(for: part.downloadID), withIntermediateDirectories: true)
                try? resumeData.write(to: sessionEngine.resumeDataURL(part), options: .atomic)
            }
            if let status, status >= 400 || (part.range != nil && status == 200) {
                // The server won't serve the file the way this engine asks; WebKit tries once more.
                sessionRunning.remove(item.id)
                item.move(to: .failed) { $0.failureReason = Self.reason(forStatus: status) }
                retry(item)
            } else {
                pauseSession(item, reason: message)
            }
        case .allEventsDelivered:
            backgroundEventsCompletion?()
            backgroundEventsCompletion = nil
        }
    }

    /// After a relaunch: downloads still running in the background carry on; ones that finished
    /// meanwhile are put together; the rest are paused (or failed when nothing can continue).
    private func reconcileSessionDownloads() async {
        let running = await sessionEngine.tasks()
        for item in items where item.record.sessionParts != nil && item.record.state == .running {
            let parts = sessionParts(for: item.record)
            if running[item.id] != nil {
                sessionRunning.insert(item.id)
                startProgressTimer()
            } else if parts.allSatisfy(sessionEngine.isFinished) {
                mergeParts(of: item)
            } else {
                let fileManager = FileManager.default
                let canContinue = parts.contains {
                    fileManager.fileExists(atPath: sessionEngine.resumeDataURL($0).path) || sessionEngine.isFinished($0)
                }
                item.move(to: canContinue ? .paused : .failed) {
                    $0.failureReason = canContinue ? "Paused while the app was closed" : "The download was interrupted."
                }
            }
        }
        updateCounts()
        save()
    }

    /// Joins the parts into the staging file, off the main thread, then finishes as usual.
    private func mergeParts(of item: DownloadItem) {
        guard !merging.contains(item.id) else { return }
        merging.insert(item.id)
        sessionRunning.remove(item.id)
        let parts = sessionParts(for: item.record).map(sessionEngine.partFileURL)
        let output = partialFileURL(for: item.record)
        let folder = sessionEngine.folder(for: item.id)
        Task {
            let error = await Self.concatenate(parts, into: output)
            merging.remove(item.id)
            if let error {
                item.move(to: .failed) { $0.failureReason = "The parts couldn't be joined: \(error.localizedDescription)" }
                save()
            } else {
                try? FileManager.default.removeItem(at: folder)
                finish(item)
            }
            updateCounts()
        }
    }

    nonisolated private static func concatenate(_ parts: [URL], into output: URL) async -> Error? {
        await Task.detached(priority: .utility) { () -> Error? in
            let fileManager = FileManager.default
            do {
                try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fileManager.removeItem(at: output)
                if parts.count == 1 {
                    try fileManager.moveItem(at: parts[0], to: output)
                    return nil
                }
                fileManager.createFile(atPath: output.path, contents: nil)
                let writer = try FileHandle(forWritingTo: output)
                defer { try? writer.close() }
                for part in parts {
                    let reader = try FileHandle(forReadingFrom: part)
                    defer { try? reader.close() }
                    while let chunk = try reader.read(upToCount: 4 << 20), !chunk.isEmpty {
                        try writer.write(contentsOf: chunk)
                    }
                }
                return nil
            } catch {
                return error
            }
        }.value
    }

    /// The background session sends the normal store's cookies, so downloads behind a login work.
    private func copyCookiesToSharedStorage() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        for cookie in cookies {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    /// The user agent the page used, so the server sees the same browser.
    private func rememberUserAgent(from webView: WKWebView?) async {
        if let custom = webView?.customUserAgent, !custom.isEmpty {
            defaultUserAgent = custom
            return
        }
        guard defaultUserAgent == nil else { return }
        let source = webView ?? helperWebView(isPrivate: false)
        defaultUserAgent = (try? await source.evaluateJavaScript("navigator.userAgent")) as? String
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
        activity.update(with: items)
        if active.isEmpty && sessionRunning.isEmpty {
            progressTimer?.invalidate()
            progressTimer = nil
        }
    }

    func updateCounts() {
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

    func removePartialFile(for id: UUID) {
        let folder = directory.appendingPathComponent("Incomplete", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
    }

    /// An empty place for a new transfer to write to (a resumed one keeps its partial file).
    func preparePartialFile(for record: DownloadRecord) -> URL {
        let url = partialFileURL(for: record)
        if !resuming.contains(record.id) {
            removePartialFile(for: record.id)
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    func save() {
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
        if let preferred = origin.preferredName, (name as NSString).pathExtension.isEmpty {
            name = FileNaming.sanitize(preferred)
        }
        var folder = defaultFolder(forFileNamed: name, mimeType: response.mimeType)
        if preferences.confirmDownloads, let presenter = origin.presenter {
            let choice = await DownloadConfirmation.ask(
                from: presenter, fileName: name, size: expected, mimeType: response.mimeType, folder: folder)
            guard let choice else { return nil }
            name = choice.fileName
            folder = choice.folder
        }
        if let request = download.originalRequest, let expected, let fileURL = response.url ?? request.url,
           canUseSession(origin: origin, request: request, response: response) {
            // WebKit's request stops here; the background session fetches the file instead.
            let parts = preferences.downloadParts > 1
                ? max(1, RangePlanner.ranges(totalBytes: expected, parts: preferences.downloadParts, minimumPartSize: 2 << 20).count)
                : 1
            let record = DownloadRecord(
                sourceURL: request.url ?? fileURL, pageURL: origin.pageURL, fileName: name, folder: folder,
                mimeType: response.mimeType, expectedBytes: expected, state: .running, isPrivate: false,
                sessionParts: parts)
            let item = makeItem(record)
            items.insert(item, at: 0)
            save()
            didStart.send(item)
            showInLiveActivity(item)
            await copyCookiesToSharedStorage()
            await rememberUserAgent(from: download.webView)
            startSessionParts(item, url: fileURL)
            return nil
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
        showInLiveActivity(item)
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
