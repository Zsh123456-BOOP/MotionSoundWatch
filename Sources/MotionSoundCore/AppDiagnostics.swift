import Foundation
import OSLog

enum AppDiagnostics {
    static let subsystem = "com.zhongsuhua.MotionSound"

    private static let logger = Logger(subsystem: subsystem, category: "diagnostics")
    private static let stateLock = NSLock()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedRunID: String?
    nonisolated(unsafe) private static var cachedBuildCommit: String?
    nonisolated(unsafe) private static var didConfigureFromEnvironment = false
    private static let runDefaultsKey = "MotionSoundDiagnostics.activeRunID"

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
        try runDirectory().appendingPathComponent(platform, isDirectory: true)
    }

    static func logFileURL() throws -> URL {
        try logDirectory().appendingPathComponent("app.log")
    }

    static func diagnosticsRootURL(fileManager: FileManager = .default) throws -> URL {
        let support = try applicationSupportURL(fileManager: fileManager)
        let root = support
            .appendingPathComponent("MotionSoundWatch", isDirectory: true)
            .appendingPathComponent("MotionSoundDiagnostics", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try? MotionSecureFileWriter.applyProtection(to: root, fileManager: fileManager)
        return root
    }

    static func runsRootURL(fileManager: FileManager = .default) throws -> URL {
        try diagnosticsRootURL(fileManager: fileManager)
            .appendingPathComponent("runs", isDirectory: true)
    }

    static func runDirectory(fileManager: FileManager = .default) throws -> URL {
        try runsRootURL(fileManager: fileManager)
            .appendingPathComponent(currentRunID(), isDirectory: true)
    }

    static func currentRunID() -> String {
        configureFromEnvironmentIfNeeded()
        stateLock.lock()
        defer { stateLock.unlock() }

        if let cachedRunID {
            return cachedRunID
        }

        let stored = UserDefaults.standard.string(forKey: runDefaultsKey)
        let runID = sanitizeIdentifier(stored?.isEmpty == false ? stored! : generateRunID())
        cachedRunID = runID
        UserDefaults.standard.set(runID, forKey: runDefaultsKey)
        writeManifestQuietly(runID: runID)
        return runID
    }

    static func currentBuildCommit() -> String {
        configureFromEnvironmentIfNeeded()
        stateLock.lock()
        defer { stateLock.unlock() }

        if let cachedBuildCommit {
            return cachedBuildCommit
        }

        let bundleValue = Bundle.main.object(forInfoDictionaryKey: "MotionSoundBuildCommit") as? String
        let environmentValue = ProcessInfo.processInfo.environment["MOTIONSOUND_BUILD_COMMIT"]
        let commit = sanitizeIdentifier(environmentValue ?? bundleValue ?? "unknown")
        cachedBuildCommit = commit
        return commit
    }

    static func configureRun(
        id requestedID: String,
        buildCommit requestedBuildCommit: String? = nil,
        clearExisting: Bool = false,
        reason: String
    ) {
        let runID = sanitizeIdentifier(requestedID)
        let buildCommit = requestedBuildCommit.map(sanitizeIdentifier)

        stateLock.lock()
        cachedRunID = runID
        if let buildCommit, !buildCommit.isEmpty {
            cachedBuildCommit = buildCommit
        }
        didConfigureFromEnvironment = true
        UserDefaults.standard.set(runID, forKey: runDefaultsKey)
        stateLock.unlock()

        if clearExisting {
            clearDiagnosticsQuietly()
        }
        writeManifestQuietly(runID: runID)
        record(
            "diagnostics.run.configured",
            [
                "reason": reason,
                "clearExisting": clearExisting,
            ]
        )
    }

    static func startNewRun(reason: String, clearExisting: Bool = false) -> String {
        let runID = generateRunID()
        configureRun(id: runID, clearExisting: clearExisting, reason: reason)
        return runID
    }

    static func clearDiagnostics(reason: String) {
        clearDiagnosticsQuietly()
        writeManifestQuietly(runID: currentRunID())
        record("diagnostics.cleared", ["reason": reason])
    }

    static func watchEventsDirectory(fileManager: FileManager = .default) throws -> URL {
        try runDirectory(fileManager: fileManager)
            .appendingPathComponent("iOS", isDirectory: true)
            .appendingPathComponent("watch-events", isDirectory: true)
    }

    static func relativeLogPathDescription() -> String {
        "Application Support/MotionSoundWatch/MotionSoundDiagnostics/runs/\(currentRunID())/\(platform)/app.log"
    }

    private static func makeLine(event: String, fields: [String: CustomStringConvertible]) -> String {
        let timestampFormatter = ISO8601DateFormatter()
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var parts = [
            timestampFormatter.string(from: Date()),
            platform,
            event,
            "testRunId=\(sanitize(currentRunID()))",
            "buildCommit=\(sanitize(currentBuildCommit()))",
            "deviceRole=\(sanitize(platform))",
            "eventType=appLog",
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
                try MotionSecureFileWriter.write(data, to: fileURL)
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

    private static func configureFromEnvironmentIfNeeded() {
        stateLock.lock()
        guard !didConfigureFromEnvironment else {
            stateLock.unlock()
            return
        }
        didConfigureFromEnvironment = true

        let environment = ProcessInfo.processInfo.environment
        let requestedRunID = environment["MOTIONSOUND_TEST_RUN_ID"]
        let requestedBuildCommit = environment["MOTIONSOUND_BUILD_COMMIT"]
        let shouldReset = ["1", "true", "yes"].contains(
            (environment["MOTIONSOUND_RESET_DIAGNOSTICS"] ?? "").lowercased()
        )
        let runID = sanitizeIdentifier(
            requestedRunID?.isEmpty == false
                ? requestedRunID!
                : (UserDefaults.standard.string(forKey: runDefaultsKey) ?? generateRunID())
        )
        cachedRunID = runID
        cachedBuildCommit = sanitizeIdentifier(requestedBuildCommit ?? "unknown")
        UserDefaults.standard.set(runID, forKey: runDefaultsKey)
        stateLock.unlock()

        if shouldReset {
            clearDiagnosticsQuietly()
        }
        writeManifestQuietly(runID: runID)
    }

    private static func writeManifestQuietly(runID: String) {
        do {
            let directory = try runDirectory(fileManager: .default)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let manifest: [String: Any] = [
                "schemaVersion": 1,
                "testRunId": runID,
                "buildCommit": currentBuildCommit(),
                "deviceRole": platform,
                "createdAt": ISO8601DateFormatter().string(from: Date()),
            ]
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try MotionSecureFileWriter.write(data, to: directory.appendingPathComponent("manifest-\(platform).json"))
        } catch {
            logger.error("Failed to write diagnostics manifest: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func clearDiagnosticsQuietly(fileManager: FileManager = .default) {
        do {
            let documents = try documentsURL(fileManager: fileManager)
            let support = try applicationSupportURL(fileManager: fileManager)
            let paths = [
                documents.appendingPathComponent("MotionSoundDiagnostics", isDirectory: true),
                documents.appendingPathComponent("MotionSoundLogs", isDirectory: true),
                documents.appendingPathComponent("MotionSoundTriggerLogs", isDirectory: true),
                support
                    .appendingPathComponent("MotionSoundWatch", isDirectory: true)
                    .appendingPathComponent("MotionSoundDiagnostics", isDirectory: true),
            ]
            for url in paths where fileManager.fileExists(atPath: url.path) {
                try? fileManager.removeItem(at: url)
            }
        } catch {
            logger.error("Failed to clear diagnostics: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func documentsURL(fileManager: FileManager) throws -> URL {
        try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    private static func applicationSupportURL(fileManager: FileManager) throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    private static func generateRunID() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))"
    }

    private static func sanitizeIdentifier(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let compact = String(scalars)
            .split(separator: "-")
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return compact.isEmpty ? generateRunID() : compact
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
