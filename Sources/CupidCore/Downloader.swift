import Foundation

/// Synchronous HTTPS download to a file, with progress. Follows redirects (HTTPS only).
public final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public typealias Progress = @Sendable (_ received: Int64, _ expected: Int64?) -> Void

    private let destination: URL
    private let progress: Progress?
    private let done = DispatchSemaphore(value: 0)
    private var error: Error?
    private var finalURL: URL?

    private init(destination: URL, progress: Progress?) {
        self.destination = destination
        self.progress = progress
    }

    /// Downloads `url` to `destination` (via `destination.part`). Returns the final URL after redirects.
    @discardableResult
    public static func download(_ url: URL, to destination: URL, progress: Progress? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let delegate = Downloader(destination: destination, progress: progress)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        session.downloadTask(with: url).resume()
        delegate.done.wait()
        if let error = delegate.error { throw error }
        return delegate.finalURL ?? url
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress?(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let fm = FileManager.default
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw CupidError(.download, "HTTP \(http.statusCode) for \(downloadTask.originalRequest?.url?.absoluteString ?? "?")")
            }
            let part = destination.appendingPathExtension("part")
            try? fm.removeItem(at: part)
            try fm.moveItem(at: location, to: part)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: part, to: destination)
            finalURL = downloadTask.response?.url
        } catch {
            self.error = error
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, self.error == nil { self.error = CupidError(.download, "Download failed: \(error.localizedDescription)") }
        done.signal()
    }
}
