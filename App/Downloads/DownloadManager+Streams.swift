import BrowserCore
import Foundation
import WebKit

/// Saved HLS streams. Their segments download into Application Support/Downloads/Streams/<id>
/// next to the playlists (`job.json`), then are joined into one MP4 that moves into its folder in
/// Files like any other download. Pausing keeps the segments; Resume and Retry fetch only the rest.
extension DownloadManager {
    static func streamFolder(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("Streams", isDirectory: true).appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func streamJobURL(for id: UUID, in directory: URL) -> URL {
        streamFolder(for: id, in: directory).appendingPathComponent("job.json")
    }

    private func streamFolder(for id: UUID) -> URL {
        Self.streamFolder(for: id, in: directory)
    }

    private func saveJob(_ job: StreamJob, for id: UUID) throws {
        try FileManager.default.createDirectory(at: streamFolder(for: id), withIntermediateDirectories: true)
        try JSONEncoder().encode(job).write(to: Self.streamJobURL(for: id, in: directory), options: .atomic)
    }

    /// Starts saving a stream chosen on a page, as `fileName` in `folder`.
    func startStream(
        _ job: StreamJob, fileName: String, folder: String, sourceURL: URL, from tab: TabModel?, request: StreamRequest
    ) {
        let record = DownloadRecord(
            sourceURL: sourceURL, pageURL: tab?.url, fileName: FileNaming.sanitize(fileName), folder: folder,
            mimeType: "video/mp4", state: .running, isPrivate: tab?.isPrivate ?? false,
            stream: StreamProgress(segmentCount: job.segmentCount, quality: job.quality))
        let item = makeItem(record)
        insert(item)
        do {
            try saveJob(job, for: item.id)
        } catch {
            item.move(to: .failed) { $0.failureReason = "The download couldn't be prepared: \(error.localizedDescription)" }
            save()
            return
        }
        streamRequests[item.id] = request
        showInLiveActivity(item)
        runStream(item, job: job, request: request)
    }

    func pauseStream(_ item: DownloadItem, reason: String? = nil) {
        let moved = item.move(to: .paused) { record in
            record.failureReason = reason
            record.stream?.isProcessing = false
        }
        guard moved else { return }
        stopStreamTask(item.id)
        save()
    }

    /// Continues a paused or failed stream from the segments it has, or reads a cancelled one
    /// again (in the quality chosen before).
    func resumeStream(_ item: DownloadItem) {
        let state = item.record.state
        guard state == .paused || state == .failed || state == .cancelled else { return }
        if state != .paused {
            item.move(to: .queued)
        }
        let moved = item.move(to: .running) { record in
            record.failureReason = nil
            record.linkExpired = false
        }
        guard moved else { return }
        showInLiveActivity(item)
        save()
        Task {
            let request: StreamRequest
            if let saved = streamRequests[item.id] {
                request = saved
            } else {
                // After a relaunch: the normal website data's cookies.
                let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
                request = StreamRequest(
                    cookies: item.record.isPrivate ? [] : cookies, userAgent: defaultUserAgent, referer: item.record.pageURL)
                streamRequests[item.id] = request
            }
            let job: StreamJob
            if let data = try? Data(contentsOf: Self.streamJobURL(for: item.id, in: directory)),
               let saved = try? JSONDecoder().decode(StreamJob.self, from: data) {
                job = saved
            } else {
                guard let source = item.record.sourceURL else { return failStream(item, StreamError.notAPlaylist) }
                let quality = item.record.stream?.quality
                do {
                    let fresh = try await StreamJob.make(for: source, request: request) { variants in
                        variants.first { $0.qualityLabel == quality } ?? variants.first
                    }
                    guard let fresh else { return }
                    try saveJob(fresh, for: item.id)
                    job = fresh
                } catch {
                    return failStream(item, error)
                }
            }
            guard item.record.state == .running else { return }
            runStream(item, job: job, request: request)
        }
    }

    /// Stops a stream's transfer and deletes its segments; with `keepJob` the playlists stay for Retry.
    func discardStream(_ id: UUID, keepJob: Bool) {
        stopStreamTask(id)
        let folder = streamFolder(for: id)
        if keepJob {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.lastPathComponent != "job.json" {
                try? FileManager.default.removeItem(at: file)
            }
        } else {
            streamRequests[id] = nil
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func runStream(_ item: DownloadItem, job: StreamJob, request: StreamRequest) {
        let download: StreamDownload
        do {
            download = try StreamDownload(folder: streamFolder(for: item.id), job: job, request: request)
        } catch {
            return failStream(item, error)
        }
        let output = preparePartialFile(for: item.record)
        streamTasks.removeValue(forKey: item.id)?.cancel()
        streamTasks[item.id] = Task { [weak self, weak item] in
            do {
                try await download.run(to: output) { progress in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, let item else { return }
                            self.streamProgress(item, progress)
                        }
                    }
                }
                guard let self, let item, item.record.state == .running else { return }
                self.stopStreamTask(item.id)
                self.finish(item)
                if item.record.state == .finished {
                    self.discardStream(item.id, keepJob: false)
                }
            } catch is CancellationError {
                // Paused or cancelled: the item's state already says so.
            } catch {
                guard let self, let item, item.record.state == .running else { return }
                self.failStream(item, error)
            }
        }
        updateCounts()
    }

    private func streamProgress(_ item: DownloadItem, _ progress: StreamDownload.Progress) {
        guard item.record.state == .running else { return }
        item.progress(received: progress.bytes, expected: nil, at: ProcessInfo.processInfo.systemUptime)
        item.update { record in
            record.stream?.segmentCount = progress.total
            record.stream?.completedSegments = progress.completed
            record.stream?.isProcessing = progress.isProcessing
        }
        streamProgressChanged()
    }

    private func failStream(_ item: DownloadItem, _ error: Error) {
        stopStreamTask(item.id)
        let streamError = error as? StreamError
        item.move(to: .failed) { record in
            record.failureReason = error.localizedDescription
            record.linkExpired = streamError?.linkExpired ?? false
            record.stream?.isProcessing = false
        }
        save()
    }

    private func stopStreamTask(_ id: UUID) {
        streamTasks.removeValue(forKey: id)?.cancel()
        streamDidStop()
    }
}

extension MediaRequestContext {
    func streamRequest(referer: URL?) -> StreamRequest {
        StreamRequest(cookies: cookies, userAgent: userAgent, referer: referer)
    }
}
