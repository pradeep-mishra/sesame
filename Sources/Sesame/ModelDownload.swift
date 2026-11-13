import Foundation
import SesameEngine

/// Gets the model files once, safely (design section 7): bytes go to `models/<name>.partial` through
/// `SesameFolder` (Range resume after a drop), and the file takes its real name only when its size and
/// SHA-256 are exact. A redirect to a host outside the allowlist ends the download. The only network code
/// in the product; the session is ephemeral (no URL cache, no cookies).
final class ModelDownload: @unchecked Sendable {
    /// Seconds to wait after the 1st, 2nd, 3rd and 4th failure in a row.
    static let retryDelays: [TimeInterval] = [2, 5, 15, 30]
    /// Seconds without a byte before a request fails.
    static let noBytesTimeout: TimeInterval = 60

    /// The hosts seen in the connection log of the one real download (t6).
    private static let allowedHosts: Set<String> = ["huggingface.co", "us.aws.cdn.hf.co"]
    private static let realHost = "https://huggingface.co"

    /// The test kit's local server (SESAME_MODEL_HOST, a base URL), when the setting is present.
    private static var hostOverride: URL? {
        guard let text = ProcessInfo.processInfo.environment["SESAME_MODEL_HOST"] else { return nil }
        return URL(string: text)
    }

    /// True for the exact hosts above (over https, default port), and for the host and port the kit's
    /// setting names.
    static func isAllowedRedirect(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(), url.user == nil else { return false }
        if url.scheme == "https", url.port == nil || url.port == 443, allowedHosts.contains(host) {
            return true
        }
        guard let override = hostOverride, let overrideHost = override.host else { return false }
        return host == overrideHost.lowercased() && url.port == override.port
    }

    private let files: [ModelFile]

    init(files: [ModelFile] = ModelFiles.all) {
        self.files = files
    }

    /// Downloads every file that is not already whole. True when every file is whole under its real name,
    /// false when it stopped (a refused redirect, retries used up, a failed check twice, or a cancel).
    func start() async -> Bool {
        do { try SesameFolder.createModels() } catch { return false }
        for file in files where !(await fetch(file)) {
            return false
        }
        return true
    }

    // MARK: one file

    private func fetch(_ file: ModelFile) async -> Bool {
        let partialName = file.name + ".partial"
        let partialURL = SesameFolder.modelsURL.appendingPathComponent(partialName)
        if ModelFiles.isPresent(file, at: SesameFolder.modelsURL.appendingPathComponent(file.name)) {
            return true
        }
        var failures = 0
        var badChecks = 0
        while !Task.isCancelled {
            var offset = (try? SesameFolder.size(of: partialName, in: .models)) ?? 0
            if offset > file.size {
                try? SesameFolder.delete(partialName, in: .models)
                offset = 0
            }
            var attempt = Attempt(outcome: .finished, gotBytes: false)
            if offset < file.size {
                attempt = await transfer(file, partialName: partialName, offset: offset)
            }
            switch attempt.outcome {
            case .refused:
                return false
            case .finished:
                let whole = ((try? SesameFolder.size(of: partialName, in: .models)) ?? -1) == file.size
                    && ((try? ModelFiles.sha256(of: partialURL)) == file.sha256)
                if whole {
                    do { try SesameFolder.rename(partialName, to: file.name, in: .models) } catch { return false }
                    return true
                }
                try? SesameFolder.delete(partialName, in: .models)
                badChecks += 1
                if badChecks >= 2 { return false }
            case .failed:
                if attempt.gotBytes { failures = 0 }
                guard failures < Self.retryDelays.count else { return false }
                do { try await Task.sleep(nanoseconds: UInt64(Self.retryDelays[failures] * 1_000_000_000)) } catch { return false }
                failures += 1
            }
        }
        return false
    }

    // MARK: one request

    private struct Attempt {
        enum Outcome { case finished, failed, refused }
        var outcome: Outcome
        var gotBytes: Bool
    }

    private func requestURL(for file: ModelFile) -> URL? {
        let base = Self.hostOverride?.absoluteString ?? Self.realHost
        return URL(string: base + ModelFiles.resolvePath(of: file))
    }

    private func transfer(_ file: ModelFile, partialName: String, offset: Int) async -> Attempt {
        guard let url = requestURL(for: file) else { return Attempt(outcome: .failed, gotBytes: false) }
        let delegate = Transfer(partialName: partialName, offset: offset)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.noBytesTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        var request = URLRequest(url: url, timeoutInterval: Self.noBytesTimeout)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let range = delegate.rangeValue { request.setValue(range, forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: request)
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if delegate.begin(continuation) { task.resume() }
            }
        } onCancel: {
            delegate.cancel(task)
        }
        session.invalidateAndCancel()
        return delegate.attempt
    }

    /// The delegate of one request. Callbacks run one at a time on the session's queue; `lock` covers
    /// the continuation and the cancel flag, which the calling task also touches.
    private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let partialName: String
        private var offset: Int
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var cancelled = false
        private var refused = false
        private var badStatus = false
        private var gotBytes = false

        init(partialName: String, offset: Int) {
            self.partialName = partialName
            self.offset = offset
        }

        var rangeValue: String? { offset > 0 ? "bytes=\(offset)-" : nil }

        var attempt: Attempt {
            lock.lock()
            defer { lock.unlock() }
            let outcome: Attempt.Outcome = refused ? .refused : (badStatus ? .failed : .finished)
            return Attempt(outcome: outcome, gotBytes: gotBytes)
        }

        /// Keeps the continuation; false when the task was cancelled before it started (then it is resumed here).
        func begin(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
            lock.lock()
            if cancelled {
                badStatus = true
                lock.unlock()
                continuation.resume()
                return false
            }
            self.continuation = continuation
            lock.unlock()
            return true
        }

        func cancel(_ task: URLSessionTask) {
            lock.lock()
            cancelled = true
            lock.unlock()
            task.cancel()
        }

        private func complete() {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume()
        }

        private func fail() {
            lock.lock()
            badStatus = true
            lock.unlock()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            guard let target = request.url, ModelDownload.isAllowedRedirect(target) else {
                lock.lock()
                refused = true
                lock.unlock()
                completionHandler(nil)
                return
            }
            var next = request
            if let range = rangeValue { next.setValue(range, forHTTPHeaderField: "Range") }
            completionHandler(next)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else {
                fail()
                return completionHandler(.cancel)
            }
            switch http.statusCode {
            case 200:
                if offset > 0 {   // the server ignored the Range: start the file over
                    try? SesameFolder.delete(partialName, in: .models)
                    offset = 0
                }
                completionHandler(.allow)
            case 206 where http.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes \(offset)-") == true:
                completionHandler(.allow)
            default:
                if http.statusCode == 416 || http.statusCode == 206 {   // the kept bytes do not fit the file
                    try? SesameFolder.delete(partialName, in: .models)
                }
                fail()
                completionHandler(.cancel)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            do {
                try SesameFolder.append(data, to: partialName, in: .models)
                lock.lock()
                gotBytes = true
                lock.unlock()
            } catch {
                fail()
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if error != nil { fail() }
            complete()
        }
    }
}
