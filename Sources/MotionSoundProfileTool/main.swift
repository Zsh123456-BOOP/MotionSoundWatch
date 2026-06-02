import Foundation
import MotionSoundCore

@main
enum MotionSoundProfileTool {
    static func main() throws {
        do {
            let options = try ProfileToolOptions(arguments: Array(CommandLine.arguments.dropFirst()))
            let result = try ProfileGenerator().generate(options: options)
            print(result.summary)
        } catch ProfileToolError.helpRequested {
            print(ProfileToolOptions.usage)
        } catch {
            fputs("error: \(error.localizedDescription)\n\n\(ProfileToolOptions.usage)\n", stderr)
            Foundation.exit(1)
        }
    }
}

private struct ProfileToolOptions {
    var datasetRoot: URL
    var gesture: String
    var kind: GestureKind
    var outputURL: URL
    var soundFileName: String?
    var cooldownSeconds: Double
    var strictness: Double

    init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--help" || argument == "-h" {
                throw ProfileToolError.helpRequested
            }
            guard argument.hasPrefix("--") else {
                throw ProfileToolError.invalidArgument(argument)
            }
            let key = String(argument.dropFirst(2))
            guard index + 1 < arguments.count else {
                throw ProfileToolError.missingValue(argument)
            }
            values[key] = arguments[index + 1]
            index += 2
        }

        guard let gesture = values["gesture"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !gesture.isEmpty else {
            throw ProfileToolError.missingOption("--gesture")
        }
        guard let kindValue = values["kind"],
              let kind = GestureKind(rawValue: kindValue) else {
            throw ProfileToolError.invalidKind(values["kind"])
        }

        let fileManager = FileManager.default
        let datasetPath = values["dataset"] ?? "data/raw"
        let datasetRoot = URL(fileURLWithPath: datasetPath, relativeTo: URL(fileURLWithPath: fileManager.currentDirectoryPath))
            .standardizedFileURL
        let outputPath = values["output"] ?? "data/reports/\(gesture)-profile.json"
        let outputURL = URL(fileURLWithPath: outputPath, relativeTo: URL(fileURLWithPath: fileManager.currentDirectoryPath))
            .standardizedFileURL

        self.datasetRoot = datasetRoot
        self.gesture = gesture
        self.kind = kind
        self.outputURL = outputURL
        self.soundFileName = values["sound"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.cooldownSeconds = Double(values["cooldown"] ?? "0.8") ?? 0.8
        self.strictness = Double(values["strictness"] ?? "0.5") ?? 0.5
    }

    static let usage = """
    Usage:
      swift run motion-sound-profile --gesture <name> --kind <burst|sequence|posture|combo> [options]

    Options:
      --dataset <path>     Dataset root containing <gesture>/*.csv. Default: data/raw
      --output <path>      Output GestureProfileArchive JSON. Default: data/reports/<gesture>-profile.json
      --sound <file>       Optional sound file name already synced to Watch.
      --cooldown <seconds> Recognition cooldown. Default: 0.8
      --strictness <0-1>   Profile strictness metadata. Default: 0.5

    Filename roles:
      positive: contains positive or pos
      negative: contains negative or neg
      debug/unknown files are ignored for profile generation
    """
}

private struct ProfileGenerator {
    private let fileManager = FileManager.default
    private let csvCodec = MotionSampleCSVCodec()
    private let templateBuilder = MotionTemplateBuilder()
    private let profileBuilder = GestureProfileBuilder()
    private let profileCodec = GestureProfileCodec()

    func generate(options: ProfileToolOptions) throws -> ProfileGenerationResult {
        let gestureDirectory = options.datasetRoot.appendingPathComponent(options.gesture, isDirectory: true)
        let files = try discoverCSVFiles(in: gestureDirectory)
        guard !files.isEmpty else {
            throw ProfileToolError.noCSVFiles(gestureDirectory.path)
        }

        var positiveTemplates: [MotionTemplate] = []
        var negativeTemplates: [MotionTemplate] = []
        var ignoredFiles: [URL] = []

        for file in files {
            let role = SampleRole(fileURL: file)
            let data = try Data(contentsOf: file)
            let samples = try csvCodec.decodeData(data)
            guard !samples.isEmpty else {
                ignoredFiles.append(file)
                continue
            }

            switch role {
            case .positive:
                positiveTemplates.append(templateBuilder.makeTemplate(
                    label: options.gesture,
                    kind: options.kind,
                    samples: samples
                ))
            case .negative:
                negativeTemplates.append(templateBuilder.makeTemplate(
                    label: "\(options.gesture)-negative",
                    kind: options.kind,
                    samples: samples
                ))
            case .debug, .unknown:
                ignoredFiles.append(file)
            }
        }

        guard !positiveTemplates.isEmpty else {
            throw ProfileToolError.noPositiveSamples(gestureDirectory.path)
        }

        let sound = options.soundFileName.map {
            SoundAsset(fileName: $0, duration: 0, localWatchPath: $0)
        }
        let profile = profileBuilder.makeProfile(
            name: options.gesture,
            kind: options.kind,
            templates: positiveTemplates,
            negativeTemplates: negativeTemplates,
            sound: sound,
            cooldownSeconds: options.cooldownSeconds,
            strictness: options.strictness
        )
        let archive = GestureProfileArchive(profiles: [profile])

        try fileManager.createDirectory(
            at: options.outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try profileCodec.encode(archive).write(to: options.outputURL, options: [.atomic])

        return ProfileGenerationResult(
            outputURL: options.outputURL,
            profile: profile,
            positives: positiveTemplates.count,
            negatives: negativeTemplates.count,
            ignoredFiles: ignoredFiles.count
        )
    }

    private func discoverCSVFiles(in directory: URL) throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else {
            throw ProfileToolError.noCSVFiles(directory.path)
        }
        return try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "csv" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

private struct ProfileGenerationResult {
    var outputURL: URL
    var profile: GestureProfile
    var positives: Int
    var negatives: Int
    var ignoredFiles: Int

    var summary: String {
        """
        profile: \(profile.name)
        kind: \(profile.kind.rawValue)
        positives: \(positives)
        negatives: \(negatives)
        ignored: \(ignoredFiles)
        acceptanceThreshold: \(format(profile.acceptanceThreshold))
        marginThreshold: \(format(profile.marginThreshold))
        qualityScore: \(format(profile.quality.score))
        output: \(outputURL.path)
        """
    }

    private func format(_ value: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

private enum SampleRole {
    case positive
    case negative
    case debug
    case unknown

    init(fileURL: URL) {
        let parts = fileURL.deletingPathExtension().lastPathComponent
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map(String.init)
        if parts.contains("positive") || parts.contains("pos") {
            self = .positive
        } else if parts.contains("negative") || parts.contains("neg") {
            self = .negative
        } else if parts.contains("debug") {
            self = .debug
        } else {
            self = .unknown
        }
    }
}

private enum ProfileToolError: LocalizedError {
    case helpRequested
    case invalidArgument(String)
    case missingValue(String)
    case missingOption(String)
    case invalidKind(String?)
    case noCSVFiles(String)
    case noPositiveSamples(String)

    var errorDescription: String? {
        switch self {
        case .helpRequested:
            return nil
        case let .invalidArgument(argument):
            return "未知参数：\(argument)"
        case let .missingValue(argument):
            return "参数缺少值：\(argument)"
        case let .missingOption(option):
            return "缺少必需参数：\(option)"
        case let .invalidKind(kind):
            return "动作类型无效：\(kind ?? "nil")"
        case let .noCSVFiles(path):
            return "没有找到 CSV 文件：\(path)"
        case let .noPositiveSamples(path):
            return "没有找到 positive/pos 正样本 CSV：\(path)"
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
