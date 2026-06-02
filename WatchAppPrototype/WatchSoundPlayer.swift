import AVFoundation
import Combine
import Foundation
import WatchKit
#if canImport(MotionSoundCore)
import MotionSoundCore
#endif

@MainActor
final class WatchSoundPlayer: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var lastError: String?
    @Published private(set) var preloadedCount = 0
    @Published private(set) var lastPlayedAssetName: String?
    @Published private(set) var lastPlaySucceeded = false
    @Published private(set) var lastAudiblePlaySucceeded = false
    @Published private(set) var lastSystemSoundFallbackSucceeded = false
    @Published private(set) var lastOutputVolume: Float = 0

    private var players: [String: AVAudioPlayer] = [:]
    private var watchKitPlayers: [String: WKAudioFilePlayer] = [:]

    func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            try session.setActive(true)
            lastOutputVolume = session.outputVolume
            isReady = true
            lastError = nil
            AppDiagnostics.record(
                "watch.audioSession.ready",
                [
                    "outputVolume": session.outputVolume,
                    "secondaryAudioSilenced": session.secondaryAudioShouldBeSilencedHint,
                    "category": session.category.rawValue,
                    "routeSharingPolicy": session.routeSharingPolicy.rawValue,
                    "outputs": routeDescription(session),
                ]
            )
        } catch {
            isReady = false
            lastError = error.localizedDescription
            AppDiagnostics.record(error: error, event: "watch.audioSession.error")
        }
    }

    func preload(assetName: String, fileExtension: String = "wav") {
        guard players[assetName] == nil else { return }
        guard let url = Bundle.main.url(forResource: assetName, withExtension: fileExtension) else {
            lastError = "找不到音频资源：\(assetName).\(fileExtension)"
            AppDiagnostics.record("watch.audio.preload.missingBundleAsset", ["asset": "\(assetName).\(fileExtension)"])
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            players[assetName] = player
            preloadedCount = players.count
            lastError = nil
            AppDiagnostics.record("watch.audio.preload.bundleAsset", ["asset": "\(assetName).\(fileExtension)"])
        } catch {
            lastError = error.localizedDescription
            AppDiagnostics.record(error: error, event: "watch.audio.preload.bundleAsset.error", ["asset": "\(assetName).\(fileExtension)"])
        }
    }

    func preload(sound: SoundAsset?) {
        guard let sound else { return }

        if let path = sound.localWatchPath {
            let explicitURL = URL(fileURLWithPath: path)
            if explicitURL.isFileURL, FileManager.default.fileExists(atPath: explicitURL.path) {
                preload(fileURL: explicitURL, key: sound.fileName)
                return
            }
        }

        let fileURL = URL(fileURLWithPath: sound.fileName)
        if fileURL.pathExtension.isEmpty {
            preload(assetName: sound.fileName)
        } else if let bundleURL = Bundle.main.url(
            forResource: fileURL.deletingPathExtension().lastPathComponent,
            withExtension: fileURL.pathExtension
        ) {
            preload(fileURL: bundleURL, key: sound.fileName)
        } else if let documentsURL = Self.documentsSoundURL(fileName: sound.fileName) {
            preload(fileURL: documentsURL, key: sound.fileName)
        } else {
            lastError = "找不到音频资源：\(sound.fileName)"
        }
    }

    func preload(sounds: [SoundAsset?]) {
        sounds.forEach { preload(sound: $0) }
    }

    @discardableResult
    func play(assetName: String) -> Bool {
        configureAudioSession()
        guard let player = players[assetName] else {
            lastError = "音频尚未预加载：\(assetName)"
            AppDiagnostics.record("watch.audio.play.missing", ["asset": assetName])
            return false
        }

        player.currentTime = 0
        let played = player.play()
        lastPlayedAssetName = assetName
        lastPlaySucceeded = played
        lastOutputVolume = AVAudioSession.sharedInstance().outputVolume
        lastSystemSoundFallbackSucceeded = false
        if played, lastOutputVolume <= 0.01 {
            lastSystemSoundFallbackSucceeded = playWatchKitFallback(assetName: assetName)
        }
        lastAudiblePlaySucceeded = (played && lastOutputVolume > 0.01) || lastSystemSoundFallbackSucceeded
        if !played {
            lastError = "音频播放失败：\(assetName)"
        } else {
            lastError = nil
        }
        AppDiagnostics.record(
            "watch.audio.play",
            [
                "asset": assetName,
                "played": played,
                "volume": player.volume,
                "duration": player.duration,
                "outputVolume": AVAudioSession.sharedInstance().outputVolume,
                "isPlaying": player.isPlaying,
                "audible": lastAudiblePlaySucceeded,
                "systemSoundFallback": lastSystemSoundFallbackSucceeded,
                "outputs": routeDescription(AVAudioSession.sharedInstance()),
            ]
        )
        return played
    }

    @discardableResult
    func play(sound: SoundAsset?) -> Bool {
        guard let sound else {
            lastError = "Profile 未绑定音频"
            return false
        }

        if players[sound.fileName] == nil {
            preload(sound: sound)
        }

        players[sound.fileName]?.volume = sound.volume

        return play(assetName: sound.fileName)
    }

    func preload(fileURL: URL) {
        preload(fileURL: fileURL, key: fileURL.lastPathComponent)
    }

    static func soundsDirectory() throws -> URL {
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return documents.appendingPathComponent("MotionSoundSounds", isDirectory: true)
    }

    static func documentsSoundURL(fileName: String) -> URL? {
        guard let directory = try? soundsDirectory() else { return nil }
        let url = directory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func preload(fileURL: URL, key: String) {
        guard players[key] == nil else { return }

        do {
            let player = try AVAudioPlayer(contentsOf: fileURL)
            player.volume = 1
            player.prepareToPlay()
            players[key] = player
            preloadedCount = players.count
            lastError = nil
            AppDiagnostics.record("watch.audio.preload.file", ["file": fileURL.lastPathComponent, "key": key])
        } catch {
            lastError = error.localizedDescription
            AppDiagnostics.record(error: error, event: "watch.audio.preload.file.error", ["file": fileURL.lastPathComponent, "key": key])
        }
    }

    private func playWatchKitFallback(assetName: String) -> Bool {
        guard let player = players[assetName] else {
            AppDiagnostics.record("watch.audio.watchKitFallback.missingPlayer", ["asset": assetName])
            return false
        }
        guard let url = player.url else {
            AppDiagnostics.record("watch.audio.watchKitFallback.missingURL", ["asset": assetName])
            return false
        }

        let watchKitPlayer: WKAudioFilePlayer
        if let existing = watchKitPlayers[assetName] {
            watchKitPlayer = existing
        } else {
            let asset = WKAudioFileAsset(url: url)
            let item = WKAudioFilePlayerItem(asset: asset)
            watchKitPlayer = WKAudioFilePlayer(playerItem: item)
            watchKitPlayers[assetName] = watchKitPlayer
        }

        watchKitPlayer.currentItem?.setCurrentTime(0)
        watchKitPlayer.play()
        AppDiagnostics.record(
            "watch.audio.watchKitFallback.play",
            [
                "asset": assetName,
                "status": watchKitPlayer.status.rawValue,
                "rate": watchKitPlayer.rate,
                "itemStatus": watchKitPlayer.currentItem?.status.rawValue ?? -1,
                "error": watchKitPlayer.error?.localizedDescription ?? "",
            ]
        )
        return true
    }

    private func routeDescription(_ session: AVAudioSession) -> String {
        let outputs = session.currentRoute.outputs
        guard !outputs.isEmpty else { return "none" }
        return outputs
            .map { output in
                "\(output.portType.rawValue):\(output.portName)"
            }
            .joined(separator: "|")
    }
}
