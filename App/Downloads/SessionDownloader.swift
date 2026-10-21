import BrowserCore
import Foundation

/// The background download engine: a background URLSession that keeps downloading while the app
/// is suspended, fetching big files in several parts at once (like Aloha's multi-thread
/// downloads). Each task's description names its download and part (`DownloadPart`), so tasks
/// still match up after the app is relaunched. URLSession calls back on its own queue; events
/// go to the main actor in order.
nonisolated final class SessionDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Event: Sendable {
        /// Bytes one part has written so far.
        case progress(DownloadPart, written: Int64)
        /// A part's file is in place.
        case finished(DownloadPart)
        /// A part stopped: an error (with resume data when it can continue) or a wrong response.
        case failed(DownloadPart, message: String, resumeData: Data?, status: Int?)
        /// Everything queued while the app was in the background has been delivered.
        case allEventsDelivered
    }

    static let sessionIdentifier = "io.github.leondood1298.browser.downloads"

    /// Finished parts and resume data, one folder per download.
    let directory: URL
    private var handler: (@MainActor (Event) -> Void)?
    /// Last progress report per task, to send at most a few a second (delegate queue only).
    private var lastReport: [Int: TimeInterval] = [:]
    /// Tasks cancelled on purpose (pause or cancel): their "cancelled" error isn't a failure.
    private let stopped = Locked<Set<Int>>([])

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "SessionDownloader"
        return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }()

    init(directory: URL) {
        self.directory = directory
        super.init()
    }

    /// Starts receiving events, including ones the system kept while the app wasn't running.
    @MainActor
    func connect(_ handler: @escaping @MainActor (Event) -> Void) {
        self.handler = handler
        _ = session
    }

    func partFileURL(_ part: DownloadPart) -> URL {
        folder(for: part.downloadID).appendingPathComponent("part-\(part.index)")
    }

    func resumeDataURL(_ part: DownloadPart) -> URL {
        folder(for: part.downloadID).appendingPathComponent("part-\(part.index).resume")
    }

    func folder(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Whether a part's file is complete.
    func isFinished(_ part: DownloadPart) -> Bool {
        let url = partFileURL(part)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) else { return false }
        return part.expectedLength.map { size == $0 } ?? true
    }

    func start(_ part: DownloadPart, request: URLRequest) {
        var request = request
        if let range = part.range {
            request.setValue(RangePlanner.header(for: range), forHTTPHeaderField: "Range")
        }
        let task = session.downloadTask(with: request)
        task.taskDescription = part.taskDescription
        task.resume()
    }

    func resume(_ part: DownloadPart, resumeData: Data) {
        let task = session.downloadTask(withResumeData: resumeData)
        task.taskDescription = part.taskDescription
        task.resume()
    }

    /// The running tasks, by download.
    func tasks() async -> [UUID: [URLSessionTask]] {
        let tasks = await session.allTasks
        var result: [UUID: [URLSessionTask]] = [:]
        for task in tasks where task.state == .running || task.state == .suspended {
            if let part = DownloadPart(taskDescription: task.taskDescription ?? "") {
                result[part.downloadID, default: []].append(task)
            }
        }
        return result
    }

    /// Stops a download's tasks, keeping resume data for each part that can continue later.
    func pause(_ id: UUID) async -> [DownloadPart: Data] {
        var saved: [DownloadPart: Data] = [:]
        for task in await tasks()[id] ?? [] {
            guard let download = task as? URLSessionDownloadTask,
                  let part = DownloadPart(taskDescription: task.taskDescription ?? "")
            else { continue }
            stopped.mutate { $0.insert(task.taskIdentifier) }
            if let data = await download.cancelByProducingResumeData() {
                saved[part] = data
            }
        }
        return saved
    }

    /// Stops a download's tasks for good.
    func cancel(_ id: UUID) async {
        for task in await tasks()[id] ?? [] {
            stopped.mutate { $0.insert(task.taskIdentifier) }
            task.cancel()
        }
    }

    private func send(_ event: Event) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.handler?(event)
            }
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let part = DownloadPart(taskDescription: downloadTask.taskDescription ?? "") else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - (lastReport[downloadTask.taskIdentifier] ?? 0) >= 0.25 else { return }
        lastReport[downloadTask.taskIdentifier] = now
        send(.progress(part, written: totalBytesWritten))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let part = DownloadPart(taskDescription: downloadTask.taskDescription ?? "") else { return }
        lastReport[downloadTask.taskIdentifier] = nil
        let response = downloadTask.response as? HTTPURLResponse
        let status = response?.statusCode ?? 0
        // A part asked for a byte range; anything but 206 means the server sent something else.
        let expected = part.range == nil ? 200..<300 : 206..<207
        guard expected.contains(status) else {
            send(.failed(part, message: "The server answered \(status).", resumeData: nil, status: status))
            return
        }
        let destination = partFileURL(part)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            try? FileManager.default.removeItem(at: resumeDataURL(part))
            send(.finished(part))
        } catch {
            send(.failed(part, message: error.localizedDescription, resumeData: nil, status: nil))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lastReport[task.taskIdentifier] = nil
        let wasStopped = stopped.mutate { $0.remove(task.taskIdentifier) != nil }
        guard let error, !wasStopped, let part = DownloadPart(taskDescription: task.taskDescription ?? "") else { return }
        let nsError = error as NSError
        let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let status = (task.response as? HTTPURLResponse)?.statusCode
        send(.failed(part, message: nsError.localizedDescription, resumeData: resumeData, status: status))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        send(.allEventsDelivered)
    }
}

/// A value guarded by a lock, for state shared between the main actor and URLSession's queue.
nonisolated final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    func mutate<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
