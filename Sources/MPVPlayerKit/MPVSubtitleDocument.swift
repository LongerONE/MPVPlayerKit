import CoreFoundation
import Foundation

public enum MPVSubtitleFormat: String, Sendable {
    case subRip
    case webVTT
    case ass
    case ssa
    case unknown

    public static func infer(from url: URL, contents: String? = nil) -> Self {
        switch url.pathExtension.lowercased() {
        case "srt": return .subRip
        case "vtt": return .webVTT
        case "ass": return .ass
        case "ssa": return .ssa
        default:
            guard let contents else { return .unknown }
            let normalized = contents.lowercased()
            if normalized.contains("[script info]"), normalized.contains("[events]") {
                return normalized.contains("[v4 styles]") ? .ssa : .ass
            }
            if normalized.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("webvtt") {
                return .webVTT
            }
            return normalized.contains("-->") ? .subRip : .unknown
        }
    }
}

public struct MPVSubtitleCue: Equatable, Sendable {
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String

    public init(startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.startTime = max(0, startTime.isFinite ? startTime : 0)
        self.endTime = endTime.isFinite ? max(self.startTime, endTime) : .infinity
        self.text = text
    }
}

public enum MPVSubtitleDocumentError: Error, Equatable {
    case unreadableText
    case unsupportedFormat
    case noCues
}

public struct MPVSubtitleDocument: Equatable, Sendable {
    public let format: MPVSubtitleFormat
    public let cues: [MPVSubtitleCue]

    public init(format: MPVSubtitleFormat, cues: [MPVSubtitleCue]) {
        self.format = format
        self.cues = cues
            .filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
            .sorted {
                if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
                return $0.startTime < $1.startTime
            }
    }

    public static func load(
        from url: URL,
        headers: [String: String] = [:]
    ) async throws -> Self {
        let data: Data
        if url.isFileURL {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } else {
            var request = URLRequest(url: url)
            headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            data = try await URLSession.shared.data(for: request).0
        }
        return try decode(data, sourceURL: url)
    }

    public static func decode(_ data: Data, sourceURL: URL) throws -> Self {
        guard let text = decodeText(data) else {
            throw MPVSubtitleDocumentError.unreadableText
        }
        let format = MPVSubtitleFormat.infer(from: sourceURL, contents: text)
        let cues: [MPVSubtitleCue]
        switch format {
        case .subRip, .webVTT:
            cues = parseTimedText(text)
        case .ass, .ssa:
            cues = parseASS(text)
        case .unknown:
            throw MPVSubtitleDocumentError.unsupportedFormat
        }
        guard cues.isEmpty == false else {
            throw MPVSubtitleDocumentError.noCues
        }
        return Self(format: format, cues: cues)
    }

    public func cues(at time: TimeInterval) -> [MPVSubtitleCue] {
        guard time.isFinite, cues.isEmpty == false else { return [] }
        var lowerBound = 0
        var upperBound = cues.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if cues[middle].startTime <= time {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        guard lowerBound > 0 else { return [] }
        return cues[..<lowerBound].filter { $0.endTime >= time }
    }
}

private extension MPVSubtitleDocument {
    struct PositionedLine {
        let text: String
        let y: Double?
        let hadASSOverride: Bool
    }

    struct TimedTextGroup {
        let start: TimeInterval
        let end: TimeInterval
        var lines: [PositionedLine]
    }

    static func decodeText(_ data: Data) -> String? {
        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0632))
        )
        let decoded: String?
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            decoded = String(data: data.dropFirst(3), encoding: .utf8)
        } else if data.starts(with: [0xFF, 0xFE]) {
            decoded = String(data: data, encoding: .utf16LittleEndian)
        } else if data.starts(with: [0xFE, 0xFF]) {
            decoded = String(data: data, encoding: .utf16BigEndian)
        } else if let utf8 = String(data: data, encoding: .utf8) {
            decoded = utf8
        } else if let encoding = likelyUTF16Encoding(for: data) {
            decoded = String(data: data, encoding: encoding)
        } else {
            decoded = String(data: data, encoding: gb18030)
        }
        guard let decoded,
              decoded.isEmpty == false,
              decoded.unicodeScalars.contains(where: { $0.value == 0 }) == false else {
            return nil
        }
        return decoded.unicodeScalars.first?.value == 0xFEFF
            ? String(decoded.dropFirst())
            : decoded
    }

    static func likelyUTF16Encoding(for data: Data) -> String.Encoding? {
        let sample = Array(data.prefix(1024))
        guard sample.count >= 4 else { return nil }
        let pairs = sample.count / 2
        let evenNulls = stride(from: 0, to: pairs * 2, by: 2)
            .reduce(0) { $0 + (sample[$1] == 0 ? 1 : 0) }
        let oddNulls = stride(from: 1, to: pairs * 2, by: 2)
            .reduce(0) { $0 + (sample[$1] == 0 ? 1 : 0) }
        let minimumNulls = max(2, pairs / 5)
        if oddNulls >= minimumNulls, oddNulls > evenNulls * 2 { return .utf16LittleEndian }
        if evenNulls >= minimumNulls, evenNulls > oddNulls * 2 { return .utf16BigEndian }
        return nil
    }

    static func parseTimedText(_ source: String) -> [MPVSubtitleCue] {
        let normalized = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        var groups: [TimedTextGroup] = []
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
            guard let timelineIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timestamps = lines[timelineIndex].components(separatedBy: "-->")
            guard timestamps.count == 2,
                  let start = parseTimestamp(timestamps[0]),
                  let end = parseTimestamp(timestamps[1]) else { continue }
            let textStart = lines.index(after: timelineIndex)
            let rawText = lines[textStart...].joined(separator: "\n")
            let parsed = cleanTimedText(rawText)
            guard parsed.text.isEmpty == false else { continue }
            if var previous = groups.last,
               previous.start == start,
               previous.end == end,
               previous.lines.allSatisfy(\.hadASSOverride),
               parsed.hadASSOverride {
                previous.lines.append(parsed)
                groups[groups.count - 1] = previous
                continue
            }
            groups.append(TimedTextGroup(start: start, end: end, lines: [parsed]))
        }
        return groups.map { group in
            let text = group.lines.enumerated().sorted { left, right in
                switch (left.element.y, right.element.y) {
                case let (leftY?, rightY?) where leftY != rightY: leftY < rightY
                default: left.offset < right.offset
                }
            }.map(\.element.text).joined(separator: "\n")
            return MPVSubtitleCue(startTime: group.start, endTime: group.end, text: text)
        }
    }

    static func cleanTimedText(_ source: String) -> PositionedLine {
        let overridePattern = #"\{\\[^}]*\}"#
        let positionY = source.range(of: #"\\pos\([^)]*\)"#, options: .regularExpression)
            .flatMap { range -> Double? in
                let values = source[range].dropFirst(5).dropLast()
                    .split(separator: ",", maxSplits: 1)
                guard values.count == 2 else { return nil }
                return Double(values[1].trimmingCharacters(in: .whitespaces))
            }
        let hadASSOverride = source.range(of: overridePattern, options: .regularExpression) != nil
        let text = source
            .replacingOccurrences(of: overridePattern, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PositionedLine(text: text, y: positionY, hadASSOverride: hadASSOverride)
    }

    static func parseASS(_ source: String) -> [MPVSubtitleCue] {
        source.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasPrefix("Dialogue:") else { return nil }
            let fields = line.dropFirst("Dialogue:".count)
                .split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
            guard fields.count == 10,
                  let start = parseTimestamp(String(fields[1])),
                  let end = parseTimestamp(String(fields[2])) else { return nil }
            let text = cleanTimedText(String(fields[9])).text
            guard text.isEmpty == false else { return nil }
            return MPVSubtitleCue(startTime: start, endTime: end, text: text)
        }
    }

    static func parseTimestamp(_ source: String) -> TimeInterval? {
        let value = source
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 1)[0]
            .replacingOccurrences(of: ",", with: ".")
        let components = value.split(separator: ":")
        guard components.count == 3,
              let hours = Double(components[0]),
              let minutes = Double(components[1]),
              let seconds = Double(components[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
}
