import XCTest
@testable import BrowserCore

final class DownloadsTests: XCTestCase {
    private func record(_ state: DownloadState, created: TimeInterval = 0) -> DownloadRecord {
        DownloadRecord(
            sourceURL: URL(string: "https://example.com/file.zip"), pageURL: nil, fileName: "file.zip",
            folder: "Downloads", state: state, created: Date(timeIntervalSince1970: created))
    }

    func testStateMoves() {
        XCTAssertTrue(DownloadState.running.canMove(to: .paused))
        XCTAssertTrue(DownloadState.paused.canMove(to: .queued))
        XCTAssertTrue(DownloadState.paused.canMove(to: .running))
        XCTAssertTrue(DownloadState.failed.canMove(to: .queued))
        XCTAssertFalse(DownloadState.finished.canMove(to: .running))
        XCTAssertFalse(DownloadState.cancelled.canMove(to: .finished))
        XCTAssertFalse(DownloadState.paused.canMove(to: .finished))
        XCTAssertTrue(DownloadState.paused.isActive)
        XCTAssertFalse(DownloadState.failed.isActive)
    }

    func testSchedulerStartsOldestQueuedWithinLimit() {
        let running = record(.running, created: 1)
        let newer = record(.queued, created: 30)
        let older = record(.queued, created: 20)
        let oldest = record(.queued, created: 10)
        let paused = record(.paused, created: 5)
        let picked = DownloadScheduler.downloadsToStart(in: [running, newer, older, oldest, paused], limit: 3)
        XCTAssertEqual(picked, [oldest.id, older.id])
        XCTAssertEqual(DownloadScheduler.downloadsToStart(in: [running, newer], limit: 1), [])
    }

    func testReconcileAfterLaunch() {
        let resumable = record(.running)
        let lost = record(.running)
        let queued = record(.queued)
        let done = record(.finished)
        let result = DownloadScheduler.reconcileAfterLaunch([resumable, lost, queued, done]) { $0 == resumable.id }
        XCTAssertEqual(result.map(\.state), [.paused, .failed, .queued, .finished])
        XCTAssertNotNil(result[1].failureReason)
    }

    func testRecordProgressAndRetry() {
        var item = record(.running)
        XCTAssertNil(item.fractionCompleted)
        item.expectedBytes = 200
        item.receivedBytes = 50
        XCTAssertEqual(item.fractionCompleted, 0.25)
        XCTAssertTrue(item.canRetry)
        item.sourceURL = URL(string: "blob:https://example.com/123")
        XCTAssertFalse(item.canRetry)
    }

    func testRecordRoundTripsThroughJSON() throws {
        var item = record(.paused)
        item.expectedBytes = 1000
        item.linkExpired = true
        let decoded = try JSONDecoder().decode(DownloadRecord.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded, item)

        item.stream = StreamProgress(segmentCount: 40, completedSegments: 10, quality: "720p")
        XCTAssertEqual(try JSONDecoder().decode(DownloadRecord.self, from: JSONEncoder().encode(item)), item)
    }

    func testStreamProgress() throws {
        var item = record(.running)
        item.stream = StreamProgress(segmentCount: 40, completedSegments: 10)
        XCTAssertEqual(item.fractionCompleted, 0.25)
        // Records saved before streams existed still load.
        let old = try JSONEncoder().encode(record(.finished))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
        object.removeValue(forKey: "stream")
        let decoded = try JSONDecoder().decode(DownloadRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.stream)
    }

    func testTransferRate() {
        var rate = TransferRate(window: 5)
        rate.record(totalBytes: 0, at: 0)
        XCTAssertNil(rate.bytesPerSecond)
        rate.record(totalBytes: 1000, at: 1)
        rate.record(totalBytes: 2000, at: 2)
        XCTAssertEqual(rate.bytesPerSecond ?? 0, 1000, accuracy: 0.001)
        XCTAssertEqual(rate.secondsRemaining(expectedBytes: 5000) ?? 0, 3, accuracy: 0.001)
        // Old readings drop out of the window.
        rate.record(totalBytes: 2000, at: 10)
        rate.record(totalBytes: 12000, at: 15)
        XCTAssertEqual(rate.bytesPerSecond ?? 0, 2000, accuracy: 0.001)
        XCTAssertNil(rate.secondsRemaining(expectedBytes: nil))
    }

    func testTimeLeft() {
        XCTAssertEqual(DownloadFormatting.timeLeft(0.3), "1 s left")
        XCTAssertEqual(DownloadFormatting.timeLeft(42), "42 s left")
        XCTAssertEqual(DownloadFormatting.timeLeft(61), "2 min left")
        XCTAssertEqual(DownloadFormatting.timeLeft(3600), "1 h left")
        XCTAssertEqual(DownloadFormatting.timeLeft(3900), "1 h 5 min left")
    }

    func testProgressText() {
        let received = DownloadFormatting.bytes(1_000_000)
        let expected = DownloadFormatting.bytes(4_000_000)
        XCTAssertEqual(DownloadFormatting.progress(received: 1_000_000, expected: 4_000_000), "\(received) of \(expected)")
        XCTAssertEqual(DownloadFormatting.progress(received: 1_000_000, expected: nil), received)
    }

    func testFileCategory() {
        XCTAssertEqual(FileCategory.of(fileName: "clip.MKV"), .video)
        XCTAssertEqual(FileCategory.of(fileName: "song.flac"), .audio)
        XCTAssertEqual(FileCategory.of(fileName: "photo.HEIC"), .image)
        XCTAssertEqual(FileCategory.of(fileName: "report.pdf"), .document)
        XCTAssertEqual(FileCategory.of(fileName: "backup.7z"), .archive)
        XCTAssertEqual(FileCategory.of(fileName: "download", mimeType: "video/mp4"), .video)
        XCTAssertEqual(FileCategory.of(fileName: "file.bin", mimeType: "application/x-rar-compressed"), .archive)
        XCTAssertEqual(FileCategory.of(fileName: "file.bin"), .other)
        XCTAssertEqual(FileCategory.video.folderName, "Videos")
        XCTAssertEqual(FileCategory.other.folderName, "Downloads")
    }

    func testDataURL() throws {
        let base64 = try XCTUnwrap(DataURL(string: "data:image/png;base64,iVBORw0KGgo="))
        XCTAssertEqual(base64.mimeType, "image/png")
        XCTAssertEqual(base64.data, Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        XCTAssertEqual(base64.suggestedFileName, "download.png")

        let text = try XCTUnwrap(DataURL(string: "data:,Hello%2C%20World"))
        XCTAssertEqual(text.mimeType, "text/plain")
        XCTAssertEqual(String(decoding: text.data, as: UTF8.self), "Hello, World")
        XCTAssertEqual(text.suggestedFileName, "download.txt")

        let unpadded = try XCTUnwrap(DataURL(string: "data:text/plain;charset=utf-8;base64,SGk"))
        XCTAssertEqual(String(decoding: unpadded.data, as: UTF8.self), "Hi")
        XCTAssertNil(DataURL(string: "https://example.com"))
        XCTAssertNil(DataURL(string: "data:text/plain;base64,***"))
    }

    func testDownloadPartDescriptions() throws {
        let id = UUID()
        let part = DownloadPart(downloadID: id, index: 2, count: 4, range: 100...199)
        XCTAssertEqual(DownloadPart(taskDescription: part.taskDescription), part)
        XCTAssertEqual(part.expectedLength, 100)

        let whole = DownloadPart(downloadID: id, index: 0, count: 1, range: nil)
        XCTAssertTrue(whole.taskDescription.hasSuffix("|0|1|-|-"))
        XCTAssertEqual(DownloadPart(taskDescription: whole.taskDescription), whole)
        XCTAssertNil(whole.expectedLength)

        XCTAssertNil(DownloadPart(taskDescription: "not a part"))
        XCTAssertNil(DownloadPart(taskDescription: "\(id.uuidString)|4|4|0|9"))
        XCTAssertNil(DownloadPart(taskDescription: "\(id.uuidString)|0|2|9|0"))
    }

    func testPartsOfADownload() {
        let id = UUID()
        XCTAssertEqual(DownloadPart.parts(of: id, ranges: []), [DownloadPart(downloadID: id, index: 0, count: 1, range: nil)])
        let parts = DownloadPart.parts(of: id, ranges: [0...9, 10...19])
        XCTAssertEqual(parts.map(\.index), [0, 1])
        XCTAssertEqual(parts.map(\.count), [2, 2])
        XCTAssertEqual(parts.last?.range, 10...19)

        // The ranges of a saved record come out the same as when it started.
        let started = RangePlanner.ranges(totalBytes: 9_000_000, parts: 4, minimumPartSize: 2_000_000)
        var saved = record(.running)
        saved.expectedBytes = 9_000_000
        saved.sessionParts = started.count
        XCTAssertEqual(saved.partRanges, started)
        saved.sessionParts = 1
        XCTAssertEqual(saved.partRanges, [])
    }

    func testRangePlanner() {
        let ranges = RangePlanner.ranges(totalBytes: 10_000_000, parts: 4, minimumPartSize: 1_000_000)
        XCTAssertEqual(ranges.count, 4)
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, 9_999_999)
        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(previous.upperBound + 1, next.lowerBound)
        }
        XCTAssertEqual(RangePlanner.ranges(totalBytes: 500_000, parts: 8, minimumPartSize: 1_000_000), [0...499_999])
        XCTAssertEqual(RangePlanner.ranges(totalBytes: 3_000_000, parts: 8, minimumPartSize: 1_000_000).count, 3)
        XCTAssertEqual(RangePlanner.ranges(totalBytes: 0, parts: 4), [])
        XCTAssertEqual(RangePlanner.header(for: 0...1023), "bytes=0-1023")
    }
}
