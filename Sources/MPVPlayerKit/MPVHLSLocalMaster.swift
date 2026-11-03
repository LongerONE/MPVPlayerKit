import Foundation
import Network

/// 只在本机提供一次播放会话的精简 master，避免允许远程清单读取本地文件。
final class MPVHLSLocalMaster: @unchecked Sendable {
    private final class Startup: @unchecked Sendable {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var ready = false
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.mpvplayerkit.hls-master")
    private let data: Data
    private let path: String

    var url: URL {
        URL(string: "http://127.0.0.1:\(listener.port!.rawValue)\(path)")!
    }

    init?(playlist: String) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        self.listener = listener
        data = Data(playlist.utf8)
        path = "/\(UUID().uuidString)/master.m3u8"
        let startup = Startup()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                startup.lock.lock()
                startup.ready = true
                startup.lock.unlock()
                startup.semaphore.signal()
            case .failed, .cancelled:
                startup.semaphore.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.receive(connection, accumulated: Data())
        }
        listener.start(queue: queue)
        guard startup.semaphore.wait(timeout: .now() + 3) == .success else {
            listener.cancel()
            return nil
        }
        startup.lock.lock()
        let ready = startup.ready
        startup.lock.unlock()
        guard ready, listener.port != nil else { listener.cancel(); return nil }
    }

    func stop() { listener.cancel() }

    deinit { listener.cancel() }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, complete, error in
            guard let self, error == nil else { connection.cancel(); return }
            var request = accumulated
            if let chunk { request.append(chunk) }
            guard request.count <= 8192 else { connection.cancel(); return }
            guard let text = String(data: request, encoding: .utf8), text.contains("\r\n") else {
                if complete { connection.cancel() } else { self.receive(connection, accumulated: request) }
                return
            }
            let valid = text.hasPrefix("GET \(self.path) ")
            let body = valid ? self.data : Data()
            let status = valid ? "200 OK" : "404 Not Found"
            var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(body)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
