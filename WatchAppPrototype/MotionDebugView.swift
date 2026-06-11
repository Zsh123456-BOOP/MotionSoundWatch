import SwiftUI
import WatchKit
#if canImport(MotionSoundCore)
import MotionSoundCore
#endif

struct MotionDebugView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var soundPlayer = WatchSoundPlayer()
    @StateObject private var recorder: WatchMotionRecorder
    @StateObject private var fileSender = WatchConnectivityFileSender()
    @StateObject private var runtimeSession = WatchRuntimeSessionController()
    @State private var label = "punch"
    @State private var soundFileName = ""
    @State private var kind = GestureKind.burst
    @State private var exportedText = ""
    @State private var remoteCaptureState = "idle"
    @State private var remoteRecordingTimeoutTask: Task<Void, Never>?
    @State private var runtimeStartTask: Task<Void, Never>?

    private let remoteRecordingLimitSeconds: UInt64 = 20

    init() {
        AppDiagnostics.record("watch.debugView.init")
        let player = WatchSoundPlayer()
        _soundPlayer = StateObject(wrappedValue: player)
        _recorder = StateObject(wrappedValue: WatchMotionRecorder(soundPlayer: player))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                PajiWatchStatusCard(
                    title: watchStatusTitle,
                    subtitle: watchStatusSubtitle,
                    glyph: watchStatusGlyph,
                    style: watchStatusStyle,
                    isActive: watchStatusIsActive,
                    triggerCount: recorder.triggerCount
                )

                if recorder.triggerCount > 0 {
                    WatchStatusPanel {
                        HStack {
                            Label(PajiStrings.t("watch.panel.triggerStats"), systemImage: "waveform")
                            Spacer()
                            Text("\(recorder.triggerCount)")
                                .font(.title3.weight(.semibold))
                                .monospacedDigit()
                        }
                        .foregroundStyle(.white)

                        if let profileName = recorder.lastTriggeredProfileName {
                            HStack(alignment: .top) {
                                Text(PajiStrings.t("watch.panel.lastTrigger"))
                                    .foregroundStyle(PajiTheme.textMuted)
                                Spacer()
                                Text(profileName)
                                    .multilineTextAlignment(.trailing)
                            }
                            .font(.footnote)
                        }

                        HStack(spacing: 8) {
                            if let event = recorder.lastRecognitionEvent,
                               event.triggered,
                               event.profile?.sound != nil {
                                Button {
                                    _ = soundPlayer.play(sound: event.profile?.sound)
                                } label: {
                                    Label(PajiStrings.t("watch.action.testSound"), systemImage: "play.fill")
                                }
                            }
                            Button {
                                recorder.markLastTriggerAsFalse()
                            } label: {
                                Label(PajiStrings.t("watch.action.falseFeedback"), systemImage: "hand.raised.fill")
                            }
                        }
                        .font(.caption.weight(.semibold))
                    }
                } else if recorder.loadedProfileCount > 0 {
                    WatchStatusPanel {
                        Label(PajiStrings.t("watch.panel.noTriggers"), systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.white)
                        Text(PajiStrings.t("watch.panel.noTriggers.detail"))
                            .font(.footnote)
                            .foregroundStyle(PajiTheme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if recorder.isRecording || remoteCaptureState == "recording" {
                    WatchStatusPanel {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(PajiStrings.t("watch.panel.recordingHint"))
                                .font(.footnote)
                                .foregroundStyle(PajiTheme.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let message = userFacingMessage {
                    WatchStatusPanel {
                        Label(PajiStrings.t("watch.panel.message"), systemImage: "info.circle")
                            .foregroundStyle(.white)
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(PajiTheme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .background(PajiTheme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            AppDiagnostics.record("watch.debugView.onAppear")
            recorder.startLiveUpdates()
            soundPlayer.configureAudioSession()
            fileSender.activate()
            syncProfileLibraryState(reason: "viewAppear")
            recorder.recognitionEventSink = { event in
                _ = fileSender.sendRecognitionEvent(event)
            }
            fileSender.reloadReceivedSoundFiles()
            preloadReceivedSounds()
            syncRuntimeSession(reason: "viewAppear")
        }
        .onChange(of: scenePhase) { _, newPhase in
            AppDiagnostics.record("watch.scenePhase", ["phase": describe(newPhase)])
            syncRuntimeSession(reason: "scenePhase.\(describe(newPhase))")
        }
        .onReceive(NotificationCenter.default.publisher(for: .watchApplicationDidBecomeActive)) { _ in
            scheduleRuntimeStart(reason: "applicationDidBecomeActive", requireActiveScene: false)
        }
        .onChange(of: fileSender.receivedSoundFiles) {
            preloadReceivedSounds()
        }
        .onChange(of: fileSender.runtimePrepareRequestCount) {
            syncRuntimeSession(reason: "phonePrepareRuntime")
        }
        .onChange(of: fileSender.lastReceivedProfileURL) {
            syncProfileLibraryState(reason: "profileReceived")
            syncRuntimeSession(reason: "profileReceived")
        }
        .onChange(of: fileSender.profileLibraryChangeCount) {
            syncProfileLibraryState(reason: "profileLibraryChanged")
            syncRuntimeSession(reason: "profileLibraryChanged")
        }
        .onChange(of: fileSender.profileLibraryStateChangeCount) {
            syncProfileLibraryState(reason: "profileLibraryStateChanged")
            syncRuntimeSession(reason: "profileLibraryStateChanged")
        }
        .onReceive(fileSender.$lastRecordingCommand.compactMap { $0 }) { command in
            handleRemoteRecordingCommand(command)
        }
        .onDisappear {
            AppDiagnostics.record("watch.debugView.onDisappear")
            runtimeStartTask?.cancel()
            runtimeStartTask = nil
            recorder.recognitionEventSink = nil
            recorder.stopLiveUpdates()
            runtimeSession.stop(reason: "viewDisappear")
        }
    }

    private var watchStatusTitle: String {
        if recorder.isRecording || remoteCaptureState == "recording" {
            return PajiStrings.t("watch.status.recording")
        }
        if !recorder.isProfileLibraryReady {
            return PajiStrings.t("watch.status.waitSync")
        }
        if recorder.loadedProfileCount > 0 {
            return PajiStrings.t("watch.status.listening")
        }
        return PajiStrings.t("watch.status.waitSetup")
    }

    private var watchStatusSubtitle: String {
        if recorder.isRecording || remoteCaptureState == "recording" {
            return PajiStrings.t("watch.subtitle.recording")
        }
        if !recorder.isProfileLibraryReady {
            return PajiStrings.t("watch.subtitle.waitSync")
        }
        if recorder.loadedProfileCount > 0 {
            return PajiStrings.t("watch.subtitle.listening")
        }
        return PajiStrings.t("watch.subtitle.waitSetup")
    }

    private var watchStatusGlyph: PajiGlyph {
        if recorder.isRecording || remoteCaptureState == "recording" {
            return .recordGesture
        }
        if !recorder.isProfileLibraryReady {
            return .sync
        }
        if recorder.loadedProfileCount > 0 {
            return .listening
        }
        return .playBurst
    }

    private var watchStatusStyle: PajiStatusPill.Style {
        if recorder.isRecording || remoteCaptureState == "recording" {
            return .warning
        }
        if !recorder.isProfileLibraryReady {
            return .warning
        }
        if recorder.loadedProfileCount > 0 {
            return .stable
        }
        return .blocked
    }

    private var watchStatusIsActive: Bool {
        recorder.loadedProfileCount > 0 || recorder.isRecording || remoteCaptureState == "recording"
    }

    private var triggerAudioStatusText: String {
        if recorder.lastTriggerAudioPlayed {
            return "已请求播放"
        }
        if let error = soundPlayer.lastError, !error.isEmpty {
            return "无声"
        }
        return "未播放"
    }

    private var outputVolumeText: String {
        "\(Int((soundPlayer.lastOutputVolume * 100).rounded()))%"
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
        return nil
    }

    private func syncProfileLibraryState(reason: String) {
        recorder.updateProfileLibraryState(
            isReady: fileSender.isProfileLibraryReady,
            version: fileSender.profileLibraryVersion,
            expectedProfileCount: fileSender.profileLibraryProfileCount,
            reason: reason
        )
        if fileSender.isProfileLibraryReady {
            recorder.reloadSavedProfiles()
        }
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
            if recorder.isRecording {
                AppDiagnostics.record("watch.remoteRecording.restart", ["label": label])
            }
            recorder.startRecording()
            syncRuntimeSession(reason: "remoteRecording")
            scheduleRemoteRecordingTimeout(sampleRole: command.sampleRole)
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
            remoteRecordingTimeoutTask?.cancel()
            remoteRecordingTimeoutTask = nil
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

    private func scheduleRemoteRecordingTimeout(sampleRole: String?) {
        remoteRecordingTimeoutTask?.cancel()
        remoteRecordingTimeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: remoteRecordingLimitSeconds * 1_000_000_000)
            guard !Task.isCancelled, recorder.isRecording else { return }
            _ = recorder.stopRecording()
            remoteCaptureState = "stopped"
            WKInterfaceDevice.current().play(.stop)
            AppDiagnostics.record(
                "watch.remoteRecording.autoStop",
                [
                    "label": label,
                    "samples": recorder.samples.count,
                    "limitSeconds": remoteRecordingLimitSeconds,
                ]
            )
            saveAndSendRemoteCSV(sampleRole: sampleRole)
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

    private func syncRuntimeSession(reason: String) {
        switch scenePhase {
        case .active:
            scheduleRuntimeStart(reason: reason, requireActiveScene: true)
        case .background:
            runtimeStartTask?.cancel()
            runtimeStartTask = nil
            if shouldKeepRuntimeSessionActive {
                AppDiagnostics.record(
                    "watch.runtime.keepAlive.background",
                    [
                        "reason": reason,
                        "profiles": recorder.loadedProfileCount,
                        "recording": recorder.isRecording || remoteCaptureState == "recording",
                    ]
                )
            } else {
                runtimeSession.stop(reason: "scenePhase.background")
            }
        case .inactive:
            AppDiagnostics.record("watch.runtime.start.deferred", ["phase": "inactive", "reason": reason])
            break
        @unknown default:
            break
        }
    }

    private var shouldKeepRuntimeSessionActive: Bool {
        recorder.loadedProfileCount > 0 || recorder.isRecording || remoteCaptureState == "recording"
    }

    private func scheduleRuntimeStart(reason: String, requireActiveScene: Bool) {
        runtimeStartTask?.cancel()
        runtimeStartTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            if requireActiveScene, scenePhase != .active {
                AppDiagnostics.record(
                    "watch.runtime.start.cancelled",
                    ["phase": describe(scenePhase), "reason": reason]
                )
                return
            }
            runtimeSession.start(reason: reason)
        }
    }

    private func describe(_ phase: ScenePhase) -> String {
        switch phase {
        case .active:
            return "active"
        case .inactive:
            return "inactive"
        case .background:
            return "background"
        @unknown default:
            return "unknown"
        }
    }
}

private struct WatchStatusPanel<Content: View>: View {
    private var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(PajiTheme.panel.opacity(0.76))
        .clipShape(RoundedRectangle(cornerRadius: PajiTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PajiTheme.cardRadius, style: .continuous)
                .stroke(PajiTheme.border, lineWidth: 1)
        )
    }
}
