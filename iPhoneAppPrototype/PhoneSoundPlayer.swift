import AVFoundation
import Foundation
#if canImport(MotionSoundCore)
import MotionSoundCore
#endif

@MainActor
final class PhoneSoundPlayer: ObservableObject {
    @Published private(set) var lastError: String?
    @Published private(set) var lastPlayedFileName: String?
    @Published private(set) var lastPlaySucceeded = false

    private var players: [String: AVAudioPlayer] = [:]
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    @discardableResult
    func play(fileName: String, volume: Float = 1) -> Bool {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "音频文件名为空"
            AppDiagnostics.record("phone.audio.play.emptyFileName")
            return false
        }

        configureAudioSession()

        if players[trimmed] == nil {
            preload(fileName: trimmed)
        }

        guard let player = players[trimmed] else {
            lastPlayedFileName = trimmed
            lastPlaySucceeded = false
            AppDiagnostics.record("phone.audio.play.missing", ["file": trimmed])
            return false
        }

        player.volume = max(0, min(1, volume))
        player.currentTime = 0
        let played = player.play()
        lastPlayedFileName = trimmed
        lastPlaySucceeded = played
        lastError = played ? nil : "iPhone 音频播放失败：\(trimmed)"
        AppDiagnostics.record(
            "phone.audio.play",
            [
                "file": trimmed,
                "played": played,
                "isPlaying": player.isPlaying,
                "volume": player.volume,
                "duration": player.duration,
            ]
        )
        return played
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            AppDiagnostics.record("phone.audioSession.ready", ["outputVolume": session.outputVolume])
        } catch {
            lastError = error.localizedDescription
            AppDiagnostics.record(error: error, event: "phone.audioSession.error")
        }
    }

    private func preload(fileName: String) {
        guard let url = resolveAudioURL(fileName: fileName) else {
            lastError = "iPhone 找不到音频：\(fileName)"
            AppDiagnostics.record("phone.audio.preload.missing", ["file": fileName])
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            players[fileName] = player
            lastError = nil
            AppDiagnostics.record("phone.audio.preload", ["file": url.lastPathComponent, "key": fileName])
        } catch {
            lastError = error.localizedDescription
            AppDiagnostics.record(error: error, event: "phone.audio.preload.error", ["file": url.lastPathComponent])
        }
    }

    private func resolveAudioURL(fileName: String) -> URL? {
        if let documentsURL = documentsAudioURL(fileName: fileName) {
            return documentsURL
        }

        let fileURL = URL(fileURLWithPath: fileName)
        guard !fileURL.pathExtension.isEmpty else {
            return Bundle.main.url(forResource: fileName, withExtension: "wav")
        }
        return Bundle.main.url(
            forResource: fileURL.deletingPathExtension().lastPathComponent,
            withExtension: fileURL.pathExtension
        )
    }

    private func documentsAudioURL(fileName: String) -> URL? {
        guard let documents = try? fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else {
            return nil
        }
        let url = documents.appendingPathComponent(fileName)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }
}
