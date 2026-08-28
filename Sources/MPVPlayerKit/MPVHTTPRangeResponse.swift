import Foundation

struct MPVHTTPRangeResponseResult: @unchecked Sendable {
    let data: Data
    let response: HTTPURLResponse?
    let error: Error?
    let bodyLimitExceeded: Bool
}

final class MPVHTTPRangeResponseCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)

    private let maximumBodyBytes: Int
    private let lock = NSLock()
    private var body = Data()
    private var response: HTTPURLResponse?
    private var error: Error?
    private var bodyLimitExceeded = false
    private var didFinish = false

    init(maximumBodyBytes: Int) {
        self.maximumBodyBytes = max(1, maximumBodyBytes)
        super.init()
    }

    func result() -> MPVHTTPRangeResponseResult {
        lock.lock()
        defer { lock.unlock() }
        return MPVHTTPRangeResponseResult(
            data: body,
            response: response,
            error: error,
            bodyLimitExceeded: bodyLimitExceeded
        )
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        self.response = response as? HTTPURLResponse
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var shouldCancel = false
        lock.lock()
        if bodyLimitExceeded == false {
            let remaining = maximumBodyBytes - body.count
            if data.count <= remaining {
                body.append(data)
            } else {
                if remaining > 0 {
                    body.append(data.prefix(remaining))
                }
                bodyLimitExceeded = true
                shouldCancel = true
            }
        }
        lock.unlock()

        if shouldCancel {
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        guard didFinish == false else {
            lock.unlock()
            return
        }
        didFinish = true
        self.error = error
        lock.unlock()
        semaphore.signal()
    }
}
