import SwiftUI
import WatchKit
#if canImport(MotionSoundCore)
import MotionSoundCore
#endif

struct MotionDebugView: View {
    @StateObject private var soundPlayer = WatchSoundPlayer()
    @StateObject private var recorder: WatchMotionRecorder
    @StateObject private var fileSender = WatchConnectivityFileSender()
    @State private var label = "punch"
    @State private var soundFileName = ""
    @State private var kind = GestureKind.burst
    @State private var exportedText = ""
    @State private var remoteCaptureState = "idle"

    init() {
        AppDiagnostics.record("watch.debugView.init")
        let player = WatchSoundPlayer()
        _soundPlayer = StateObject(wrappedValue: player)
        _recorder = StateObject(wrappedValue: WatchMotionRecorder(soundPlayer: player))
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("MotionSound")
                        .font(.headline)
                    Text(watchStatusTitle)
                        .font(.title3.weight(.semibold))
                    Text(watchStatusSubtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }

            Section {
                HStack {
                    Text("iPhone")
                    Spacer()
                    Text(watchConnectionText)
                        .foregroundStyle(fileSender.isPhoneReachable ? .green : .secondary)
                }
                HStack {
                    Text("动作")
                    Spacer()
                    Text("\(recorder.loadedProfileCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("音效")
                    Spacer()
                    Text("\(soundPlayer.preloadedCount)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if recorder.isRecording {
                    HStack {
                        Text("采样")
                        Spacer()
                        Text("\(recorder.samples.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if recorder.isRecording || remoteCaptureState == "recording" {
                Section {
                    ProgressView()
                    Text("动作完成后，在 iPhone 上点击结束。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let event = recorder.lastRecognitionEvent, event.triggered {
                Section {
                    Text(event.profile?.name ?? "已识别动作")
                        .font(.headline)
                    Text(event.logEntry.audioPlayed ? "音效已触发" : "动作已识别")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("误触反馈") {
                        recorder.markLastTriggerAsFalse()
                    }
                }
            }

            if let message = userFacingMessage {
                Section {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .onAppear {
            AppDiagnostics.record("watch.debugView.onAppear")
            recorder.reloadSavedProfiles()
            recorder.startLiveUpdates()
            soundPlayer.configureAudioSession()
            fileSender.activate()
            fileSender.reloadReceivedSoundFiles()
            preloadReceivedSounds()
        }
        .onChange(of: fileSender.receivedSoundFiles) {
            preloadReceivedSounds()
        }
        .onChange(of: fileSender.lastReceivedProfileURL) {
            recorder.reloadSavedProfiles()
        }
        .onReceive(fileSender.$lastRecordingCommand.compactMap { $0 }) { command in
            handleRemoteRecordingCommand(command)
        }
        .onDisappear {
            AppDiagnostics.record("watch.debugView.onDisappear")
            recorder.stopLiveUpdates()
        }
    }

    private var watchStatusTitle: String {
        if recorder.isRecording || remoteCaptureState == "recording" {
            return "正在录制"
        }
        if recorder.loadedProfileCount > 0 {
            return "正在监听"
        }
        return "等待设置"
    }

    private var watchStatusSubtitle: String {
        if recorder.isRecording || remoteCaptureState == "recording" {
            return "保持动作自然，完成后在 iPhone 点击结束。"
        }
        if recorder.loadedProfileCount > 0 {
            return "抬手做动作，匹配后会立即触发音效。"
        }
        return "请在 iPhone 上创建动作、录制、配音并同步。"
    }

    private var watchConnectionText: String {
        if fileSender.isPhoneReachable {
            return "已连接"
        }
        if fileSender.activationStateDescription == "activated" {
            return "等待手机"
        }
        return "等待连接"
    }

    private var userFacingMessage: String? {
        if let feedback = recorder.lastFeedbackMessage {
            return feedback
        }
        if let transfer = fileSender.lastTransferMessage,
           !transfer.contains("队列") {
            return transfer
        }
        if let assessment = recorder.lastAssessment,
           assessment.sampleCount > 0 {
            return "已采集 \(assessment.sampleCount) 个采样点"
        }
        return nil
    }

    private func toggleLocalRecording() {
        if recorder.isRecording {
            _ = recorder.stopRecording()
            saveAndSendRemoteCSV(sampleRole: "watch")
        } else {
            label = "watch"
            kind = .burst
            recorder.startRecording()
            remoteCaptureState = "recording"
            WKInterfaceDevice.current().play(.start)
        }
    }

    private func exportCurrentRecording() {
        do {
            let data = try recorder.exportRecordingJSON(label: label, kind: kind)
            exportedText = String(data: data, encoding: .utf8) ?? ""
        } catch {
            exportedText = error.localizedDescription
        }
    }

    private func exportCurrentCSV() {
        do {
            exportedText = try recorder.exportRecordingCSV()
        } catch {
            exportedText = error.localizedDescription
        }
    }

    private func exportCurrentProfile() {
        do {
            let data = try recorder.exportQuickProfileJSON(label: label, kind: kind, soundFileName: soundFileName)
            exportedText = String(data: data, encoding: .utf8) ?? ""
        } catch {
            exportedText = error.localizedDescription
        }
    }

    private func saveCurrentProfile() {
        do {
            let url = try recorder.saveQuickProfile(label: label, kind: kind, soundFileName: soundFileName)
            exportedText = "Saved: \(url.lastPathComponent)"
        } catch {
            exportedText = error.localizedDescription
        }
    }

    private func saveCurrentCSV() {
        do {
            let url = try recorder.saveRecordingCSV(label: label)
            exportedText = "Saved CSV: \(url.lastPathComponent)"
        } catch {
            exportedText = error.localizedDescription
        }
    }

    private func addCurrentRecordingToStandardProfile() {
        do {
            let count = try recorder.addCurrentRecordingToStandardProfile(label: label, kind: kind)
            exportedText = "Added standard sample \(count)/\(recorder.standardRequiredTemplateCount)"
        } catch {
            exportedText = error.localizedDescription
        }
    }

    private func addCurrentRecordingAsStandardNegative() {
        do {
            let count = try recorder.addCurrentRecordingAsStandardNegative(label: label, kind: kind)
            exportedText = "Added negative sample \(count)"
        } catch {
            exportedText = error.localizedDescription
        }
    }

    private func exportStandardProfile() {
        do {
            let data = try recorder.exportStandardProfileJSON(label: label, kind: kind, soundFileName: soundFileName)
            exportedText = String(data: data, encoding: .utf8) ?? ""
        } catch {
            exportedText = error.localizedDescription
        }
    }

    private func saveStandardProfile() {
        do {
            let url = try recorder.saveStandardProfile(label: label, kind: kind, soundFileName: soundFileName)
            exportedText = "Saved standard: \(url.lastPathComponent)"
        } catch {
            exportedText = error.localizedDescription
        }
    }

    private func sendSavedProfile(_ url: URL) {
        if fileSender.transferFile(url, kind: .gestureProfile) {
            exportedText = "Queued profile: \(url.lastPathComponent)"
        } else {
            exportedText = fileSender.lastTransferMessage ?? "Profile transfer failed"
        }
    }

    private func sendSavedCSV(_ url: URL) {
        if fileSender.transferFile(url, kind: .recordingCSV) {
            exportedText = "Queued CSV: \(url.lastPathComponent)"
        } else {
            exportedText = fileSender.lastTransferMessage ?? "CSV transfer failed"
        }
    }

    private func preloadReceivedSounds() {
        for url in fileSender.receivedSoundFiles {
            soundPlayer.preload(fileURL: url)
        }
    }

    private func handleRemoteRecordingCommand(_ command: RecordingControlCommand) {
        if let commandLabel = command.label, !commandLabel.isEmpty {
            label = commandLabel
        }
        if let kindRawValue = command.kindRawValue,
           let commandKind = GestureKind(rawValue: kindRawValue) {
            kind = commandKind
        }

        switch command.action {
        case .startRecording:
            if !recorder.isRecording {
                recorder.startRecording()
            }
            AppDiagnostics.record("watch.remoteRecording.start", ["label": label, "kind": kind.rawValue])
            remoteCaptureState = "recording"
            WKInterfaceDevice.current().play(.start)
            exportedText = "Remote start: \(label)"
            fileSender.sendRecordingStatus(
                action: .startRecording,
                label: label,
                state: remoteCaptureState,
                samples: recorder.samples.count
            )
        case .stopRecording:
            if recorder.isRecording {
                _ = recorder.stopRecording()
            }
            AppDiagnostics.record("watch.remoteRecording.stop", ["label": label, "samples": recorder.samples.count])
            remoteCaptureState = "stopped"
            WKInterfaceDevice.current().play(.stop)
            if command.autoSendCSV {
                saveAndSendRemoteCSV(sampleRole: command.sampleRole)
            } else {
                exportedText = "Remote stop: \(label), samples \(recorder.samples.count)"
                fileSender.sendRecordingStatus(
                    action: .stopRecording,
                    label: label,
                    state: remoteCaptureState,
                    samples: recorder.samples.count
                )
            }
        }
    }

    private func saveAndSendRemoteCSV(sampleRole: String?) {
        do {
            let fileLabel = [label, normalizedSampleRole(sampleRole)]
                .compactMap { $0 }
                .joined(separator: "-")
            let url = try recorder.saveRecordingCSV(label: fileLabel)
            let queued = fileSender.transferFile(url, kind: .recordingCSV)
            if queued {
                exportedText = "Remote saved and queued CSV: \(url.lastPathComponent)"
            } else {
                exportedText = fileSender.lastTransferMessage ?? "Remote CSV transfer failed"
            }
            fileSender.sendRecordingStatus(
                action: .stopRecording,
                label: label,
                state: remoteCaptureState,
                samples: recorder.samples.count,
                csvQueued: queued,
                fileName: url.lastPathComponent,
                errorMessage: queued ? nil : exportedText
            )
        } catch {
            exportedText = error.localizedDescription
            fileSender.sendRecordingStatus(
                action: .stopRecording,
                label: label,
                state: remoteCaptureState,
                samples: recorder.samples.count,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func normalizedSampleRole(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
