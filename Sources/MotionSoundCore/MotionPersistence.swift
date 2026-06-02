import Foundation

public struct StoredGestureProfileArchive: Equatable, Sendable {
    public var fileURL: URL
    public var archive: GestureProfileArchive

    public init(fileURL: URL, archive: GestureProfileArchive) {
        self.fileURL = fileURL
        self.archive = archive
    }
}

public struct GestureProfileFileStore {
    public var directoryURL: URL
    public var codec: GestureProfileCodec
    public var fileManager: FileManager

    public init(
        directoryURL: URL,
        codec: GestureProfileCodec = GestureProfileCodec(),
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.codec = codec
        self.fileManager = fileManager
    }

    public static func appDocumentsStore(
        subdirectory: String = "GestureProfiles",
        fileManager: FileManager = .default
    ) throws -> GestureProfileFileStore {
        let documents = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return GestureProfileFileStore(
            directoryURL: documents.appendingPathComponent(subdirectory, isDirectory: true),
            fileManager: fileManager
        )
    }

    @discardableResult
    public func save(_ archive: GestureProfileArchive, preferredName: String? = nil) throws -> URL {
        try ensureDirectoryExists()
        let fileURL = directoryURL.appendingPathComponent(fileName(for: archive, preferredName: preferredName))
        let data = try codec.encode(archive)
        try data.write(to: fileURL, options: [.atomic])
        return fileURL
    }

    public func load(from fileURL: URL) throws -> GestureProfileArchive {
        let data = try Data(contentsOf: fileURL)
        return try codec.decode(data)
    }

    public func list() throws -> [StoredGestureProfileArchive] {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return []
        }

        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .sorted { lhs, rhs in
            modificationDate(lhs) > modificationDate(rhs)
        }

        return try urls.map { url in
            StoredGestureProfileArchive(fileURL: url, archive: try load(from: url))
        }
    }

    public func delete(_ stored: StoredGestureProfileArchive) throws {
        try fileManager.removeItem(at: stored.fileURL)
    }

    public func delete(fileURL: URL) throws {
        try fileManager.removeItem(at: fileURL)
    }

    private func ensureDirectoryExists() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func fileName(for archive: GestureProfileArchive, preferredName: String?) -> String {
        let baseName = sanitizeFileName(preferredName ?? archive.profiles.first?.name ?? "gesture-profile")
        let timestamp = fileTimestamp(archive.exportedAt)
        return "\(timestamp)-\(baseName).json"
    }

    private func sanitizeFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let compact = String(scalars)
            .split(separator: "-")
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return compact.isEmpty ? "gesture-profile" : compact
    }

    private func modificationDate(_ url: URL) -> Date {
        ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate) ?? .distantPast
    }

    private func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

public struct MotionSampleCSVCodec: Sendable {
    public init() {}

    public func encode(_ samples: [MotionSample]) -> String {
        var lines = [
            "timestamp,userAccelerationX,userAccelerationY,userAccelerationZ,rotationRateX,rotationRateY,rotationRateZ,gravityX,gravityY,gravityZ,attitudeX,attitudeY,attitudeZ,attitudeW"
        ]
        lines.reserveCapacity(samples.count + 1)

        for sample in samples {
            lines.append([
                format(sample.timestamp),
                format(sample.userAcceleration.x),
                format(sample.userAcceleration.y),
                format(sample.userAcceleration.z),
                format(sample.rotationRate.x),
                format(sample.rotationRate.y),
                format(sample.rotationRate.z),
                format(sample.gravity?.x),
                format(sample.gravity?.y),
                format(sample.gravity?.z),
                format(sample.attitude?.x),
                format(sample.attitude?.y),
                format(sample.attitude?.z),
                format(sample.attitude?.w),
            ].joined(separator: ","))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    public func encodeData(_ samples: [MotionSample]) -> Data {
        Data(encode(samples).utf8)
    }

    public func decode(_ csv: String) throws -> [MotionSample] {
        let lines = csv
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let header = lines.first else {
            throw MotionSampleCSVCodecError.emptyFile
        }

        let columns = header.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let index = Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($0.element, $0.offset) })
        let required = [
            "timestamp",
            "userAccelerationX",
            "userAccelerationY",
            "userAccelerationZ",
            "rotationRateX",
            "rotationRateY",
            "rotationRateZ",
        ]
        for column in required where index[column] == nil {
            throw MotionSampleCSVCodecError.missingColumn(column)
        }

        return try lines.dropFirst().enumerated().map { offset, line in
            let lineNumber = offset + 2
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)

            let timestamp = try requiredDouble("timestamp", fields: fields, index: index, lineNumber: lineNumber)
            let userAcceleration = MotionVector3(
                x: try requiredDouble("userAccelerationX", fields: fields, index: index, lineNumber: lineNumber),
                y: try requiredDouble("userAccelerationY", fields: fields, index: index, lineNumber: lineNumber),
                z: try requiredDouble("userAccelerationZ", fields: fields, index: index, lineNumber: lineNumber)
            )
            let rotationRate = MotionVector3(
                x: try requiredDouble("rotationRateX", fields: fields, index: index, lineNumber: lineNumber),
                y: try requiredDouble("rotationRateY", fields: fields, index: index, lineNumber: lineNumber),
                z: try requiredDouble("rotationRateZ", fields: fields, index: index, lineNumber: lineNumber)
            )

            let gravity = optionalVector(
                x: "gravityX",
                y: "gravityY",
                z: "gravityZ",
                fields: fields,
                index: index
            )
            let attitude = optionalQuaternion(
                x: "attitudeX",
                y: "attitudeY",
                z: "attitudeZ",
                w: "attitudeW",
                fields: fields,
                index: index
            )

            return MotionSample(
                timestamp: timestamp,
                userAcceleration: userAcceleration,
                rotationRate: rotationRate,
                gravity: gravity,
                attitude: attitude
            )
        }
    }

    public func decodeData(_ data: Data) throws -> [MotionSample] {
        guard let csv = String(data: data, encoding: .utf8) else {
            throw MotionSampleCSVCodecError.invalidEncoding
        }
        return try decode(csv)
    }

    private func format(_ value: Double?) -> String {
        guard let value else { return "" }
        return String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func requiredDouble(
        _ column: String,
        fields: [String],
        index: [String: Int],
        lineNumber: Int
    ) throws -> Double {
        guard let columnIndex = index[column], columnIndex < fields.count else {
            throw MotionSampleCSVCodecError.missingValue(column: column, line: lineNumber)
        }
        let rawValue = fields[columnIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(rawValue) else {
            throw MotionSampleCSVCodecError.invalidDouble(column: column, value: rawValue, line: lineNumber)
        }
        return value
    }

    private func optionalDouble(_ column: String, fields: [String], index: [String: Int]) -> Double? {
        guard let columnIndex = index[column], columnIndex < fields.count else { return nil }
        let rawValue = fields[columnIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawValue.isEmpty else { return nil }
        return Double(rawValue)
    }

    private func optionalVector(
        x: String,
        y: String,
        z: String,
        fields: [String],
        index: [String: Int]
    ) -> MotionVector3? {
        guard let xValue = optionalDouble(x, fields: fields, index: index),
              let yValue = optionalDouble(y, fields: fields, index: index),
              let zValue = optionalDouble(z, fields: fields, index: index) else {
            return nil
        }
        return MotionVector3(x: xValue, y: yValue, z: zValue)
    }

    private func optionalQuaternion(
        x: String,
        y: String,
        z: String,
        w: String,
        fields: [String],
        index: [String: Int]
    ) -> MotionQuaternion? {
        guard let xValue = optionalDouble(x, fields: fields, index: index),
              let yValue = optionalDouble(y, fields: fields, index: index),
              let zValue = optionalDouble(z, fields: fields, index: index),
              let wValue = optionalDouble(w, fields: fields, index: index) else {
            return nil
        }
        return MotionQuaternion(x: xValue, y: yValue, z: zValue, w: wValue)
    }
}

public enum MotionSampleCSVCodecError: Error, LocalizedError, Equatable, Sendable {
    case emptyFile
    case invalidEncoding
    case missingColumn(String)
    case missingValue(column: String, line: Int)
    case invalidDouble(column: String, value: String, line: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "CSV 文件为空"
        case .invalidEncoding:
            return "CSV 不是 UTF-8 编码"
        case let .missingColumn(column):
            return "CSV 缺少字段：\(column)"
        case let .missingValue(column, line):
            return "CSV 第 \(line) 行缺少字段值：\(column)"
        case let .invalidDouble(column, value, line):
            return "CSV 第 \(line) 行字段 \(column) 不是数字：\(value)"
        }
    }
}

public struct MotionRecordingFileStore {
    public var directoryURL: URL
    public var codec: MotionSampleCSVCodec
    public var fileManager: FileManager

    public init(
        directoryURL: URL,
        codec: MotionSampleCSVCodec = MotionSampleCSVCodec(),
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.codec = codec
        self.fileManager = fileManager
    }

    public static func appDocumentsStore(
        subdirectory: String = "MotionRecordings",
        fileManager: FileManager = .default
    ) throws -> MotionRecordingFileStore {
        let documents = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return MotionRecordingFileStore(
            directoryURL: documents.appendingPathComponent(subdirectory, isDirectory: true),
            fileManager: fileManager
        )
    }

    @discardableResult
    public func save(_ samples: [MotionSample], preferredName: String? = nil, exportedAt: Date = Date()) throws -> URL {
        try ensureDirectoryExists()
        let baseName = sanitizeFileName(preferredName ?? "motion-recording")
        let fileURL = directoryURL.appendingPathComponent("\(fileTimestamp(exportedAt))-\(baseName).csv")
        try codec.encodeData(samples).write(to: fileURL, options: [.atomic])
        return fileURL
    }

    public func list() throws -> [URL] {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return []
        }

        return try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "csv" }
        .sorted { lhs, rhs in
            modificationDate(lhs) > modificationDate(rhs)
        }
    }

    private func ensureDirectoryExists() throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func sanitizeFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let compact = String(scalars)
            .split(separator: "-")
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return compact.isEmpty ? "motion-recording" : compact
    }

    private func modificationDate(_ url: URL) -> Date {
        ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate) ?? .distantPast
    }

    private func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
