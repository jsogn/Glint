import Foundation

struct ResumableFileDownloader: Sendable {
    let session: URLSession

    func download(
        from url: URL,
        to partURL: URL,
        expectedBytes: Int64,
        progress: @escaping @Sendable (Int64, Int64, Int64?) -> Void
    ) async throws -> HTTPURLResponse {
        try FileManager.default.createDirectory(
            at: partURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var partialBytes = fileSize(at: partURL)
        if expectedBytes > 0, partialBytes > expectedBytes {
            try? FileManager.default.removeItem(at: partURL)
            partialBytes = 0
        }
        if partialBytes > 0 {
            progress(partialBytes, expectedBytes, nil)
        }

        do {
            return try await transfer(
                from: url,
                to: partURL,
                expectedBytes: expectedBytes,
                offset: partialBytes,
                progress: progress
            )
        } catch ResumableDownloadFailure.rangeRestartRequired {
            try? FileManager.default.removeItem(at: partURL)
            return try await transfer(
                from: url,
                to: partURL,
                expectedBytes: expectedBytes,
                offset: 0,
                progress: progress
            )
        }
    }

    private func transfer(
        from url: URL,
        to partURL: URL,
        expectedBytes: Int64,
        offset: Int64,
        progress: @escaping @Sendable (Int64, Int64, Int64?) -> Void
    ) async throws -> HTTPURLResponse {
        var request = URLRequest(url: url)
        if offset > 0 {
            request.setValue(
                "bytes=\(offset)-",
                forHTTPHeaderField: "Range"
            )
        }

        let taskBox = ResumableDownloadTaskBox()
        return try await withTaskCancellationHandler {
            defer { taskBox.invalidate() }
            return try await withCheckedThrowingContinuation { continuation in
                let delegate = ResumableDownloadDelegate(
                    partURL: partURL,
                    expectedBytes: expectedBytes,
                    offset: offset,
                    continuation: continuation,
                    progress: progress
                )
                let downloadSession = URLSession(
                    configuration: session.configuration,
                    delegate: delegate,
                    delegateQueue: nil
                )
                let task = downloadSession.dataTask(with: request)
                taskBox.install(session: downloadSession)
                taskBox.install(task: task)
                task.resume()
            }
        } onCancel: {
            taskBox.cancel()
        }
    }

    private func fileSize(at url: URL) -> Int64 {
        guard
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: url.path
            ),
            let size = attributes[.size] as? NSNumber
        else {
            return 0
        }
        return size.int64Value
    }
}

private enum ResumableDownloadFailure: Error {
    case rangeRestartRequired
}

private final class ResumableDownloadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var isCancelled = false

    func install(task: URLSessionDataTask) {
        lock.lock()
        self.task = task
        let shouldCancel = isCancelled
        lock.unlock()
        if shouldCancel {
            task.cancel()
        }
    }

    func install(session: URLSession) {
        lock.lock()
        self.session = session
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func invalidate() {
        lock.lock()
        let session = session
        self.session = nil
        lock.unlock()
        session?.finishTasksAndInvalidate()
    }
}

private final class ResumableDownloadDelegate:
    NSObject,
    URLSessionDataDelegate,
    @unchecked Sendable
{
    private struct ContentRange {
        let start: Int64
        let total: Int64?
    }

    private let partURL: URL
    private let expectedBytes: Int64
    private let initialOffset: Int64
    private let continuation: CheckedContinuation<HTTPURLResponse, Error>
    private let onProgress: @Sendable (Int64, Int64, Int64?) -> Void
    private let lock = NSLock()
    private let speedMeter: ResumableDownloadSpeedMeter
    private var fileHandle: FileHandle?
    private var response: HTTPURLResponse?
    private var currentBytes: Int64
    private var completed = false

    init(
        partURL: URL,
        expectedBytes: Int64,
        offset: Int64,
        continuation: CheckedContinuation<HTTPURLResponse, Error>,
        progress: @escaping @Sendable (Int64, Int64, Int64?) -> Void
    ) {
        self.partURL = partURL
        self.expectedBytes = expectedBytes
        self.initialOffset = offset
        self.continuation = continuation
        self.onProgress = progress
        self.speedMeter = ResumableDownloadSpeedMeter(
            startingBytes: offset
        )
        self.currentBytes = offset
    }

    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (
            URLSession.ResponseDisposition
        ) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            finish(.failure(URLError(.badServerResponse)))
            completionHandler(.cancel)
            return
        }

        do {
            let startingBytes = try prepareFile(
                for: http,
                expectedBytes: expectedBytes,
                initialOffset: initialOffset
            )
            lock.lock()
            self.response = http
            currentBytes = startingBytes
            lock.unlock()
            completionHandler(.allow)
        } catch {
            finish(.failure(error))
            completionHandler(.cancel)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        guard !completed, let fileHandle else {
            lock.unlock()
            return
        }
        do {
            try fileHandle.write(contentsOf: data)
            currentBytes += Int64(data.count)
            let bytes = currentBytes
            lock.unlock()
            onProgress(
                bytes,
                expectedBytes,
                speedMeter.update(totalBytes: bytes)
            )
        } catch {
            lock.unlock()
            finish(.failure(error))
            dataTask.cancel()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let response = response
        try? fileHandle?.close()
        fileHandle = nil
        lock.unlock()

        if let error {
            if (error as? URLError)?.code == .cancelled {
                finish(.failure(CancellationError()))
            } else {
                finish(.failure(error))
            }
            return
        }
        guard let response else {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        finish(.success(response))
    }

    private func prepareFile(
        for response: HTTPURLResponse,
        expectedBytes: Int64,
        initialOffset: Int64
    ) throws -> Int64 {
        switch response.statusCode {
        case 206:
            guard initialOffset > 0,
                let contentRange = Self.contentRange(
                    response.value(forHTTPHeaderField: "Content-Range")
                ),
                contentRange.start == initialOffset,
                expectedBytes <= 0
                    || contentRange.total == nil
                    || contentRange.total == expectedBytes
            else {
                throw ResumableDownloadFailure.rangeRestartRequired
            }
            guard fileSize(at: partURL) == initialOffset else {
                throw ResumableDownloadFailure.rangeRestartRequired
            }
            let handle = try FileHandle(forWritingTo: partURL)
            try handle.seekToEnd()
            lock.lock()
            fileHandle = handle
            lock.unlock()
            return initialOffset
        case 200:
            if !FileManager.default.fileExists(atPath: partURL.path) {
                FileManager.default.createFile(
                    atPath: partURL.path,
                    contents: nil
                )
            }
            let handle = try FileHandle(forWritingTo: partURL)
            try handle.truncate(atOffset: 0)
            try handle.seekToEnd()
            lock.lock()
            fileHandle = handle
            lock.unlock()
            return 0
        case 416:
            throw ResumableDownloadFailure.rangeRestartRequired
        default:
            throw URLError(.badServerResponse)
        }
    }

    private func fileSize(at url: URL) -> Int64 {
        guard
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: url.path
            ),
            let size = attributes[.size] as? NSNumber
        else {
            return 0
        }
        return size.int64Value
    }

    private func finish(_ result: Result<HTTPURLResponse, Error>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        continuation.resume(with: result)
    }

    private static func contentRange(_ value: String?) -> ContentRange? {
        guard let value else { return nil }
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0] == "bytes" else {
            return nil
        }
        let ranges = parts[1].split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard ranges.count == 2 else { return nil }
        let bounds = ranges[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
            let start = Int64(bounds[0])
        else {
            return nil
        }
        let total: Int64?
        if ranges[1] == "*" {
            total = nil
        } else if let value = Int64(ranges[1]) {
            total = value
        } else {
            return nil
        }
        return ContentRange(start: start, total: total)
    }
}

private final class ResumableDownloadSpeedMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTimestamp = DispatchTime.now().uptimeNanoseconds
    private var lastBytes: Int64
    private var smoothedBytesPerSecond: Double = 0

    init(startingBytes: Int64) {
        self.lastBytes = startingBytes
    }

    func update(totalBytes: Int64) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed =
            now > lastTimestamp
            ? Double(now - lastTimestamp) / 1_000_000_000
            : 0
        guard elapsed >= 0.2 else {
            return smoothedBytesPerSecond > 0
                ? Int64(smoothedBytesPerSecond)
                : nil
        }
        let deltaBytes = max(0, totalBytes - lastBytes)
        let instantaneous = Double(deltaBytes) / elapsed
        smoothedBytesPerSecond =
            smoothedBytesPerSecond == 0
            ? instantaneous
            : smoothedBytesPerSecond * 0.75 + instantaneous * 0.25
        lastTimestamp = now
        lastBytes = totalBytes
        guard smoothedBytesPerSecond > 0 else { return nil }
        return Int64(smoothedBytesPerSecond)
    }
}
