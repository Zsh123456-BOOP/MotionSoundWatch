import Foundation
import OSLog

enum AppDiagnostics {
    static let subsystem = "com.zhongsuhua.MotionSound"

    private static let logger = Logger(subsystem: subsystem, category: "diagnostics")
    private static let lock = NSLock()

    static func record(_ event: String, _ fields: [String: CustomStringConvertible] = [:]) {
        let line = makeLine(event: event, fields: fields)
        logger.notice("\(line, privacy: .public)")
        append(line)
    }

    static func record(error: Error, event: String, _ fields: [String: CustomStringConvertible] = [:]) {
        var enriched = fields
        enriched["error"] = error.localizedDescription
        record(event, enriched)
    }

    static func logDirectory() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return documents.appendingPathComponent("MotionSoundLogs", isDirectory: true)
    }

    static func logFileURL() throws -> URL {
        try logDirectory().appendingPathComponent("app.log")
    }

    private static func makeLine(event: String, fields: [String: CustomStringConvertible]) -> String {
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var parts = [
            timestampFormatter.string(from: Date()),
            platform,
            event,
        ]
        for key in fields.keys.sorted() {
            if let value = fields[key] {
                parts.append("\(key)=\(sanitize(value.description))")
            }
        }
        return parts.joined(separator: " ")
    }

    private static func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }

        do {
            let directory = try logDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = try logFileURL()
            let data = Data((line + "\n").utf8)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: fileURL, options: .atomic)
            }
        } catch {
            logger.error("Failed to append diagnostics log: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static var platform: String {
        #if os(watchOS)
        "watchOS"
        #elseif os(iOS)
        "iOS"
        #else
        "unknownOS"
        #endif
    }
}
