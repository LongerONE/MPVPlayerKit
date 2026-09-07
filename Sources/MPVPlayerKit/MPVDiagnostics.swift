import Foundation
import OSLog

public enum MPVDiagnosticSource: String, Sendable {
    case automatic, localFile, remote, localHTTP, vaultDecryption

    static func resolve(_ source: Self, url: URL?) -> Self {
        guard source == .automatic else { return source }
        guard let url else { return .automatic }
        if url.isFileURL { return .localFile }
        if ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? "") {
            return .localHTTP
        }
        return .remote
    }
}

public enum MPVDiagnosticHost: String, Sendable {
    case unspecified, temby, luwu
}

public struct MPVDiagnosticConfiguration: Sendable {
    public var isEnabled: Bool
    public var source: MPVDiagnosticSource
    public var host: MPVDiagnosticHost

    /// 启用后每 5 秒采样；也可通过启动参数 -MPVPlayerKit.DiagnosticsEnabled YES 开启 Release 诊断。
    public init(
        isEnabled: Bool = MPVDiagnostics.isEnabledByDefault,
        source: MPVDiagnosticSource = .automatic,
        host: MPVDiagnosticHost = .unspecified
    ) {
        self.isEnabled = isEnabled
        self.source = source
        self.host = host
    }
}

public enum MPVDiagnostics {
    public static var isEnabledByDefault: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "MPVPlayerKit.DiagnosticsEnabled") != nil {
            return defaults.bool(forKey: "MPVPlayerKit.DiagnosticsEnabled")
        }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// 文件位于 Caches/MPVPlayerKit/Diagnostics。返回的文件可能仍在追加或被容量淘汰。
    public static func logFiles(sessionID: UUID? = nil) async throws -> [URL] {
        try await MPVDiagnosticStore.shared.files(sessionID: sessionID)
    }
}

struct MPVDiagnosticRecord: Codable, Sendable {
    let schemaVersion: Int
    let sessionID: UUID
    let sequence: Int
    let timestamp: Date
    let uptimeSeconds: Double
    let elapsedSeconds: Double
    let event: String
    let fields: [String: String]
}

/// 只保护计数和有界投递；编码、控制台输出和磁盘 I/O 均在 utility 消费任务中执行。
final class MPVDiagnosticChannel: @unchecked Sendable {
    let sessionID = UUID()
    private let started = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    private let continuation: AsyncStream<MPVDiagnosticRecord>.Continuation
    private var sequence = 0
    private var dropped = 0
    private var snapshots = 0
    private var finished = false

    init(store: MPVDiagnosticStore = .shared) {
        let stream = AsyncStream<MPVDiagnosticRecord>.makeStream(bufferingPolicy: .bufferingNewest(128))
        continuation = stream.continuation
        Task.detached(priority: .utility) {
            for await record in stream.stream {
                await store.append(record)
            }
        }
    }

    func record(_ event: String, fields: [String: String] = [:], finish: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        sequence += 1
        if event == "周期快照" { snapshots += 1 }
        var values = fields
        values["此前日志队列丢弃累计"] = String(dropped)
        if finish {
            values["事件累计"] = String(sequence)
            values["周期快照累计"] = String(snapshots)
        }
        let uptime = ProcessInfo.processInfo.systemUptime
        let record = MPVDiagnosticRecord(
            schemaVersion: 1, sessionID: sessionID, sequence: sequence,
            timestamp: Date(), uptimeSeconds: uptime, elapsedSeconds: uptime - started,
            event: event, fields: values
        )
        if case .dropped = continuation.yield(record) { dropped += 1 }
        if finish {
            finished = true
            continuation.finish()
        }
    }

    deinit { continuation.finish() }
}

/// 全 App 共用容量预算；每段 2 MiB，总量 20 MiB，超限按最早修改时间淘汰。
actor MPVDiagnosticStore {
    static let shared = MPVDiagnosticStore()
    private let directory: URL
    private let segmentLimit: Int
    private let totalLimit: Int
    private let consoleEnabled: Bool
    private let logger = Logger(subsystem: "MPVPlayerKit", category: "功耗诊断")
    private var failed = false

    init(
        directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MPVPlayerKit/Diagnostics", isDirectory: true),
        segmentLimit: Int = 2 * 1_024 * 1_024,
        totalLimit: Int = 20 * 1_024 * 1_024,
        consoleEnabled: Bool = true
    ) {
        self.directory = directory
        self.segmentLimit = segmentLimit
        self.totalLimit = totalLimit
        self.consoleEnabled = consoleEnabled
    }

    func files(sessionID: UUID? = nil) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ).filter {
            $0.pathExtension == "jsonl" && (sessionID == nil || $0.lastPathComponent.hasPrefix(sessionID!.uuidString))
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func append(_ record: MPVDiagnosticRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            var data = try encoder.encode(record)
            data.append(0x0A)
            if consoleEnabled, let line = String(data: data, encoding: .utf8) {
                logger.info("\(line, privacy: .public)")
            }
            guard !failed else { return }
            // 单条过大时不允许突破文件上限；正常快照远小于此限制。
            guard data.count <= segmentLimit, data.count <= totalLimit else { return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var segments = try files(sessionID: record.sessionID)
            var destination = segments.last
            if let last = destination, try size(of: last) + data.count > segmentLimit {
                destination = nil
            }
            if destination == nil {
                let index = (segments.last.flatMap {
                    Int($0.deletingPathExtension().lastPathComponent.split(separator: "_").last ?? "")
                } ?? -1) + 1
                destination = directory.appendingPathComponent(
                    "\(record.sessionID.uuidString)_\(String(format: "%06d", index)).jsonl"
                )
            }
            guard let destination else { return }
            segments = try files()
            let oldest = try segments.map { url in
                (url, try size(of: url), try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast)
            }.sorted { $0.2 < $1.2 }
            var total = oldest.reduce(0) { $0 + $1.1 }
            for (url, bytes, _) in oldest where total + data.count > totalLimit {
                try FileManager.default.removeItem(at: url)
                total -= bytes
            }
            if !FileManager.default.fileExists(atPath: destination.path) {
                guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // 不输出可能包含文件路径的错误正文；磁盘错误只报告一次，避免重试风暴。
            if !failed {
                logger.error("诊断文件写入失败，错误码=\((error as NSError).code)，本进程后续仅输出控制台")
                failed = true
            }
        }
    }

    private func size(of url: URL) throws -> Int {
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }
}
