import Foundation
import Network

/// Downloads release DMGs with progress reporting. One flight at a time.
final class UpdateDownloader: NSObject {
    static let shared = UpdateDownloader()

    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var expected: ReleaseInfo?
    private var destination: URL?
    private var progressHandler: ((Double) -> Void)?
    private var completionHandler: ((Result<Void, UpdateError>) -> Void)?

    var isDownloading: Bool { task != nil }

    /// Snapshot of whether the current path is metered (cellular / Low Data Mode).
    static func isMetered() -> Bool {
        let monitor = NWPathMonitor()
        let semaphore = DispatchSemaphore(value: 0)
        var metered = false
        monitor.pathUpdateHandler = { path in
            metered = path.isExpensive || path.isConstrained
            semaphore.signal()
            monitor.cancel()
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        // NWPath always delivers an initial update promptly; cap the wait.
        _ = semaphore.wait(timeout: .now() + 3)
        return metered
    }

    func download(_ release: ReleaseInfo,
                  to url: URL,
                  progress: @escaping (Double) -> Void,
                  completion: @escaping (Result<Void, UpdateError>) -> Void) {
        guard task == nil else {
            completion(.failure(.network))
            return
        }
        expected = release
        destination = url
        progressHandler = progress
        completionHandler = completion

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 10 * 60
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session

        let task = session.downloadTask(with: release.downloadURL)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        finish()
        if let destination { try? FileManager.default.removeItem(at: destination) }
    }

    private func finish() {
        task = nil
        session?.invalidateAndCancel()
        session = nil
        expected = nil
        destination = nil
        progressHandler = nil
        completionHandler = nil
    }
}

extension UpdateDownloader: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let fraction: Double
        if totalBytesExpectedToWrite > 0 {
            fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        } else if let expected = expected, expected.size > 0 {
            fraction = Double(totalBytesWritten) / Double(expected.size)
        } else {
            fraction = 0
        }
        let clamped = min(max(fraction, 0), 0.99)
        DispatchQueue.main.async { [weak self] in self?.progressHandler?(clamped) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // A transport error arrives here with a non-nil error on the task.
        if let error = downloadTask.error {
            fail(with: .network, error: error)
            return
        }
        guard let destination else { fail(with: .network); return }
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: location, to: destination)
        } catch {
            fail(with: .network, error: error)
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.progressHandler?(1)
            self?.completionHandler?(.success(()))
            self?.finish()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Success already completed via didFinishDownloadingTo and finish();
        // only act if an error arrived and the flight is still open.
        guard error != nil, completionHandler != nil else { return }
        fail(with: .network, error: error)
    }

    private func fail(with updateError: UpdateError, error: Error? = nil) {
        if let error { NSLog("SwitchMuxUpdater: download failed: \(error)") }
        DispatchQueue.main.async { [weak self] in
            self?.completionHandler?(.failure(updateError))
            self?.finish()
        }
    }
}
