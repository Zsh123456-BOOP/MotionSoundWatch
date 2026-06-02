import Charts
import SwiftUI
import UniformTypeIdentifiers

struct PhoneDebugView: View {
    @StateObject private var receiver = PhoneConnectivityReceiver()
    @State private var currentStep = SetupStep.create
    @State private var activeFileImport: FileImportTarget?
    @State private var recordingLabel = "punch"
    @State private var recordingKind = "burst"
    @State private var sampleRole = "positive"
    @State private var selectedCaptureURL: URL?
    @State private var previewSamples: [MotionSample] = []
    @State private var previewMessage: String?
    @State private var trimStartFraction = 0.05
    @State private var trimEndFraction = 0.95
    @State private var playbackFraction = 0.0
    @State private var selectedAudioFileName = ""
    @State private var volume = 1.0
    @State private var soundStartFraction = 0.0
    @State private var triggerTiming = "atEnd"
    @State private var cooldownSeconds = 0.8
    @State private var countdownRemaining: Int?
    @State private var countdownTimer: Timer?
    @State private var pendingRecordingAction: RecordingControlAction?
    @State private var captureCountBeforeStop: Int?

    private var receivedCaptureSummaries: [ReceivedCaptureSummary] {
        ReceivedCaptureSummary.makeSummaries(from: receiver.receivedFiles)
    }

    private var captureFiles: [ReceivedSyncedFile] {
        let csvFiles = receiver.receivedFiles
            .filter { $0.fileURL.pathExtension.lowercased() == "csv" }
        let matching = csvFiles.filter { file in
            let parsed = PhoneConnectivityReceiver.parseCaptureFileName(
                file.fileURL.deletingPathExtension().lastPathComponent
            )
            return parsed.gesture == normalizedGestureName && parsed.role == sampleRole
        }
        return matching.isEmpty ? csvFiles : matching
    }

    private var selectedCaptureFile: ReceivedSyncedFile? {
        if let selectedCaptureURL,
           let match = captureFiles.first(where: { $0.fileURL == selectedCaptureURL }) {
            return match
        }
        return captureFiles.first
    }

    private var normalizedGestureName: String {
        let trimmed = recordingLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "untitled" : trimmed
    }

    private var isRecording: Bool {
        receiver.lastRecordingStatus?.state == "recording"
    }

    private var canStartRecording: Bool {
        receiver.isWatchReachable
            && countdownRemaining == nil
            && pendingRecordingAction == nil
            && !normalizedGestureName.isEmpty
    }

    private var trimmedSamples: [MotionSample] {
        guard previewSamples.count > 1,
              let first = previewSamples.first,
              let last = previewSamples.last else {
            return previewSamples
        }

        let duration = max(last.timestamp - first.timestamp, .leastNonzeroMagnitude)
        let startFraction = min(trimStartFraction, trimEndFraction)
        let endFraction = max(trimStartFraction, trimEndFraction)
        let start = first.timestamp + duration * startFraction
        let end = first.timestamp + duration * endFraction
        let filtered = previewSamples.filter { $0.timestamp >= start && $0.timestamp <= end }
        return filtered.count >= 2 ? filtered : previewSamples
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ProductHeader(
                        title: connectionTitle,
                        subtitle: connectionSubtitle,
                        detail: receiver.lastMessage
                    )
                    StepProgressView(currentStep: currentStep)
                    activeStepView
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("MotionSound")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        receiver.activate()
                        receiver.reloadReceivedFiles()
                        loadPreferredCapture()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                }
            }
            .onAppear {
                AppDiagnostics.record("phone.productView.onAppear")
                receiver.activate()
                loadPreferredCapture()
            }
            .onChange(of: receiver.receivedFiles) {
                handleReceivedFilesChanged()
            }
            .onChange(of: receiver.lastRecordingStatus) {
                handleRecordingStatus(receiver.lastRecordingStatus)
            }
            .onChange(of: selectedCaptureURL) {
                loadSelectedCapture()
            }
            .onDisappear {
                countdownTimer?.invalidate()
                countdownTimer = nil
            }
            .fileImporter(
                isPresented: Binding(
                    get: { activeFileImport != nil },
                    set: { isPresented in
                        if !isPresented {
                            activeFileImport = nil
                        }
                    }
                ),
                allowedContentTypes: activeFileImport?.allowedContentTypes ?? [.data],
                allowsMultipleSelection: false
            ) { result in
                guard let target = activeFileImport else { return }
                activeFileImport = nil
                switch result {
                case let .success(urls):
                    guard let url = urls.first else { return }
                    handleImportedFile(url, target: target)
                case let .failure(error):
                    receiver.setLastMessage(error.localizedDescription)
                    AppDiagnostics.record(error: error, event: target.errorEvent)
                }
            }
        }
    }

    @ViewBuilder
    private var activeStepView: some View {
        switch currentStep {
        case .create:
            createStep
        case .record:
            recordStep
        case .trim:
            trimStep
        case .sound:
            soundStep
        case .sync:
            syncStep
        }
    }

    private var createStep: some View {
        ProductSection("创建动作") {
            VStack(alignment: .leading, spacing: 14) {
                TextField("动作名称", text: $recordingLabel)
                    .textFieldStyle(.roundedBorder)

                VStack(alignment: .leading, spacing: 8) {
                    Text("动作类型")
                        .font(.subheadline.weight(.semibold))
                    Picker("动作类型", selection: $recordingKind) {
                        Text("短促").tag("burst")
                        Text("连续").tag("sequence")
                        Text("姿态").tag("posture")
                    }
                    .pickerStyle(.segmented)
                }

                ActionKindHint(kind: recordingKind)

                PrimaryActionButton(title: "下一步：录制动作", systemImage: "arrow.right") {
                    currentStep = .record
                    AppDiagnostics.record("phone.wizard.step", ["step": currentStep.rawValue])
                }
                .disabled(normalizedGestureName.isEmpty)
            }
        }
    }

    private var recordStep: some View {
        ProductSection("录制动作") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(normalizedGestureName)
                            .font(.title3.weight(.semibold))
                        Text(recordingKindText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    RecordingStateBadge(isRecording: isRecording, countdown: countdownRemaining)
                }

                Text("在 iPhone 点击开始后，会倒数 3 秒并让 Watch 震动。动作完成后，只需要在 iPhone 点击结束。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("样本", selection: $sampleRole) {
                    Text("正样本").tag("positive")
                    Text("负样本").tag("negative")
                }
                .pickerStyle(.segmented)

                if let countdownRemaining {
                    CountdownView(value: countdownRemaining)
                    Button {
                        cancelCountdown()
                    } label: {
                        Label("取消倒计时", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                } else if let pendingRecordingAction {
                    PrimaryActionButton(
                        title: pendingRecordingTitle(pendingRecordingAction),
                        systemImage: "hourglass",
                        tint: .gray
                    ) {}
                    .disabled(true)
                    if pendingRecordingAction == .stopRecording {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在等待 Watch 保存并同步样本，完成后自动进入裁剪。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if isRecording {
                    PrimaryActionButton(title: "结束录制", systemImage: "stop.fill", tint: .red) {
                        stopRecording()
                    }
                } else {
                    PrimaryActionButton(title: "开始录制", systemImage: "record.circle") {
                        beginCountdownAndRecording()
                    }
                    .disabled(!canStartRecording)
                }

                if !receiver.isWatchReachable {
                    Text("请保持 Watch App 打开，并确认 iPhone 与 Watch 已连接。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                if let status = receiver.lastRecordingStatus {
                    Text(recordingStatusText(status))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                StepNavigationBar(
                    backTitle: "返回",
                    nextTitle: captureFiles.isEmpty ? "等待样本" : "下一步：裁剪",
                    canGoNext: !captureFiles.isEmpty
                ) {
                    currentStep = .create
                } next: {
                    currentStep = .trim
                    loadPreferredCapture()
                }
            }
        }
    }

    private var trimStep: some View {
        ProductSection("裁剪动作片段") {
            VStack(alignment: .leading, spacing: 14) {
                if previewSamples.isEmpty {
                    EmptyStateView(
                        title: "还没有可裁剪的样本",
                        subtitle: "先录一次动作，Watch 会把样本同步到 iPhone。"
                    )
                    PrimaryActionButton(title: "返回录制", systemImage: "record.circle") {
                        currentStep = .record
                    }
                } else {
                    CapturePicker(
                        files: captureFiles,
                        selectedURL: $selectedCaptureURL
                    )

                    MotionSignalTimeline(
                        samples: previewSamples,
                        trimStartFraction: trimStartFraction,
                        trimEndFraction: trimEndFraction,
                        playbackFraction: playbackFraction
                    )
                    .frame(height: 260)
                    .padding(.vertical, 4)

                    TrimControls(
                        startFraction: $trimStartFraction,
                        endFraction: $trimEndFraction,
                        playbackFraction: $playbackFraction,
                        duration: captureDuration
                    )

                    CaptureStats(samples: trimmedSamples)

                    HStack(spacing: 10) {
                        Button {
                            playbackFraction = 0
                            withAnimation(.easeInOut(duration: 1.2)) {
                                playbackFraction = 1
                            }
                        } label: {
                            Label("播放片段", systemImage: "play.fill")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            currentStep = .record
                        } label: {
                            Label("重新录制", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                    }

                    if let previewMessage {
                        Text(previewMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    StepNavigationBar(
                        backTitle: "返回录制",
                        nextTitle: "下一步：配置声音",
                        canGoNext: !trimmedSamples.isEmpty
                    ) {
                        currentStep = .record
                    } next: {
                        currentStep = .sound
                    }
                }
            }
        }
    }

    private var soundStep: some View {
        ProductSection("配置声音") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: selectedAudioFileName.isEmpty ? "music.note" : "waveform")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedAudioFileName.isEmpty ? "还未选择音效" : selectedAudioFileName)
                            .font(.headline)
                            .lineLimit(2)
                        Text("后续接入 DSWaveformImage 后，这里显示音频波形和播放进度。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    activeFileImport = .audio
                } label: {
                    Label("选择音频文件", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)

                VStack(alignment: .leading, spacing: 10) {
                    SliderValueRow(title: "音量", value: "\(Int(volume * 100))%")
                    Slider(value: $volume, in: 0.2...1)
                    SliderValueRow(title: "声音起点", value: "\(Int(soundStartFraction * 100))%")
                    Slider(value: $soundStartFraction, in: 0...1)
                }

                Picker("触发时机", selection: $triggerTiming) {
                    Text("动作结束").tag("atEnd")
                    Text("峰值附近").tag("atPeak")
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 8) {
                    SliderValueRow(title: "冷却时间", value: String(format: "%.1fs", cooldownSeconds))
                    Slider(value: $cooldownSeconds, in: 0.3...2.0, step: 0.1)
                }

                StepNavigationBar(
                    backTitle: "返回裁剪",
                    nextTitle: "下一步：保存同步",
                    canGoNext: true
                ) {
                    currentStep = .trim
                } next: {
                    currentStep = .sync
                }
            }
        }
    }

    private var syncStep: some View {
        ProductSection("保存并同步") {
            VStack(alignment: .leading, spacing: 14) {
                SummaryRow(label: "动作", value: normalizedGestureName)
                SummaryRow(label: "类型", value: recordingKindText)
                SummaryRow(label: "片段", value: "\(trimmedSamples.count) 个采样点")
                SummaryRow(label: "音效", value: selectedAudioFileName.isEmpty ? "未绑定" : selectedAudioFileName)
                SummaryRow(label: "触发", value: triggerTiming == "atPeak" ? "峰值附近" : "动作结束")

                Text("保存后会生成动作 Profile，并把 Profile 与已选择的音频发送到 Watch。Watch 端会本地识别和播放。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                PrimaryActionButton(title: "保存并同步到 Watch", systemImage: "applewatch") {
                    syncProfile()
                }
                .disabled(trimmedSamples.isEmpty)

                Button {
                    activeFileImport = .profile
                } label: {
                    Label("导入已有 Profile", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)

                StepNavigationBar(
                    backTitle: "返回配音",
                    nextTitle: "继续录新动作",
                    canGoNext: true
                ) {
                    currentStep = .sound
                } next: {
                    resetForNextGesture()
                }
            }
        }
    }

    private var connectionTitle: String {
        if receiver.isWatchReachable {
            return "Apple Watch 已连接"
        }
        if receiver.isWatchAppInstalled {
            return "Apple Watch 已配对"
        }
        if receiver.activationStateDescription == "activated" {
            return "未识别 Watch App"
        }
        return "等待 Apple Watch"
    }

    private var connectionSubtitle: String {
        if receiver.isWatchReachable {
            return "可以从 iPhone 发起录制。"
        }
        if receiver.isWatchAppInstalled {
            return "请保持 Watch 上的 MotionSound 打开。"
        }
        if receiver.activationStateDescription == "activated" {
            return "iPhone 已启用 WatchConnectivity，但还没把手表端识别为本 App 的 companion。"
        }
        return "请先安装并打开 Watch App。"
    }

    private var recordingKindText: String {
        switch recordingKind {
        case "burst":
            return "短促动作"
        case "sequence":
            return "连续动作"
        case "posture":
            return "姿态动作"
        default:
            return "自定义动作"
        }
    }

    private var captureDuration: Double {
        guard let first = previewSamples.first, let last = previewSamples.last else { return 0 }
        return max(0, last.timestamp - first.timestamp)
    }

    private func beginCountdownAndRecording() {
        guard receiver.isWatchReachable else {
            receiver.setLastMessage("请先打开 Watch App，确认手表可连接。")
            return
        }

        countdownTimer?.invalidate()

        let label = normalizedGestureName
        let kind = recordingKind
        let role = sampleRole
        countdownRemaining = 3
        AppDiagnostics.record("phone.recording.countdown.started", ["label": label, "kind": kind])

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            Task { @MainActor in
                advanceCountdown(label: label, kind: kind, role: role)
            }
        }
    }

    @MainActor
    private func advanceCountdown(label: String, kind: String, role: String) {
        guard let current = countdownRemaining else {
            countdownTimer?.invalidate()
            countdownTimer = nil
            return
        }

        if current > 1 {
            countdownRemaining = current - 1
            return
        }

        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownRemaining = nil

        let didSend = receiver.sendRecordingCommand(
            action: .startRecording,
            label: label,
            kind: kind,
            sampleRole: role,
            autoSendCSV: false
        )
        if didSend {
            pendingRecordingAction = .startRecording
        }
        AppDiagnostics.record("phone.recording.startAfterCountdown", ["label": label, "kind": kind])
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownRemaining = nil
        AppDiagnostics.record("phone.recording.countdown.cancelled")
    }

    private func stopRecording() {
        guard pendingRecordingAction == nil else {
            AppDiagnostics.record(
                "phone.recording.commandIgnored",
                ["reason": "pendingCommand", "action": pendingRecordingAction?.rawValue ?? ""]
            )
            return
        }

        cancelCountdown()
        let didSend = receiver.sendRecordingCommand(
            action: .stopRecording,
            label: normalizedGestureName,
            kind: recordingKind,
            sampleRole: sampleRole,
            autoSendCSV: true
        )
        if didSend {
            pendingRecordingAction = .stopRecording
            captureCountBeforeStop = captureFiles.count
        }
        AppDiagnostics.record("phone.recording.stopRequested", ["label": normalizedGestureName, "kind": recordingKind])
    }

    private func handleRecordingStatus(_ status: RecordingStatusEvent?) {
        guard let status else { return }
        if status.errorMessage?.isEmpty == false {
            pendingRecordingAction = nil
            return
        }

        if status.state == "stopped", status.csvQueued, captureCountBeforeStop != nil {
            return
        }

        if status.actionRawValue == pendingRecordingAction?.rawValue {
            pendingRecordingAction = nil
        }

        if status.state == "stopped" {
            pendingRecordingAction = nil
            cancelCountdown()
        }
    }

    private func handleReceivedFilesChanged() {
        guard let captureCountBeforeStop else {
            loadPreferredCapture()
            return
        }

        guard captureFiles.count > captureCountBeforeStop else {
            loadPreferredCapture()
            return
        }

        self.captureCountBeforeStop = nil
        pendingRecordingAction = nil
        selectedCaptureURL = captureFiles.first?.fileURL
        currentStep = .trim
        loadPreferredCapture()
        AppDiagnostics.record(
            "phone.recording.captureReady",
            [
                "label": normalizedGestureName,
                "captures": captureFiles.count,
            ]
        )
    }

    private func pendingRecordingTitle(_ action: RecordingControlAction) -> String {
        switch action {
        case .startRecording:
            return "等待 Watch 开始"
        case .stopRecording:
            return "等待 Watch 结束"
        }
    }

    private func syncProfile() {
        let didSend = receiver.generateAndSendProfile(
            gesture: normalizedGestureName,
            kind: recordingKind,
            soundFileName: selectedAudioFileName,
            primarySamplesOverride: trimmedSamples
        )
        if didSend {
            receiver.setLastMessage("已生成动作并加入 Watch 同步队列。")
        }
        AppDiagnostics.record(
            "phone.profile.syncRequested",
            [
                "label": normalizedGestureName,
                "kind": recordingKind,
                "samples": trimmedSamples.count,
                "sound": selectedAudioFileName,
            ]
        )
    }

    private func handleImportedFile(_ url: URL, target: FileImportTarget) {
        switch target {
        case .audio:
            selectedAudioFileName = url.lastPathComponent
            _ = receiver.sendAudioFile(url)
            AppDiagnostics.record("phone.audio.imported", ["file": url.lastPathComponent])
        case .profile:
            _ = receiver.sendProfileFile(url)
            AppDiagnostics.record("phone.profile.imported", ["file": url.lastPathComponent])
        }
    }

    private func resetForNextGesture() {
        recordingLabel = ""
        sampleRole = "positive"
        selectedCaptureURL = nil
        previewSamples = []
        previewMessage = nil
        trimStartFraction = 0.05
        trimEndFraction = 0.95
        playbackFraction = 0
        selectedAudioFileName = ""
        currentStep = .create
        AppDiagnostics.record("phone.wizard.reset")
    }

    private func loadPreferredCapture() {
        guard let file = selectedCaptureFile else {
            previewSamples = []
            previewMessage = nil
            selectedCaptureURL = nil
            return
        }
        selectedCaptureURL = file.fileURL
        loadCapture(file)
    }

    private func loadSelectedCapture() {
        guard let selectedCaptureURL,
              let file = captureFiles.first(where: { $0.fileURL == selectedCaptureURL }) else {
            return
        }
        loadCapture(file)
    }

    private func loadCapture(_ file: ReceivedSyncedFile) {
        do {
            let samples = try MotionSampleCSVCodec().decodeData(Data(contentsOf: file.fileURL))
            previewSamples = samples
            trimStartFraction = min(trimStartFraction, 0.95)
            trimEndFraction = max(trimEndFraction, 0.05)
            playbackFraction = 0
            previewMessage = "已载入 \(samples.count) 个采样点，时长 \(formatDuration(samples))。"
            AppDiagnostics.record("phone.capture.preview.loaded", ["file": file.fileURL.lastPathComponent, "samples": samples.count])
        } catch {
            previewSamples = []
            previewMessage = error.localizedDescription
            AppDiagnostics.record(error: error, event: "phone.capture.preview.error", ["file": file.fileURL.lastPathComponent])
        }
    }

    private func recordingStatusText(_ status: RecordingStatusEvent) -> String {
        if let error = status.errorMessage, !error.isEmpty {
            return "Watch 执行失败：\(error)"
        }
        if status.state == "recording" {
            return "Watch 正在录制 \(status.label.isEmpty ? normalizedGestureName : status.label)"
        }
        if status.csvQueued {
            return "已收到 \(status.samples) 个采样点，正在同步样本。"
        }
        return "已采集 \(status.samples) 个采样点。"
    }

    private func formatDuration(_ samples: [MotionSample]) -> String {
        guard let first = samples.first, let last = samples.last else { return "0.0s" }
        return String(format: "%.1fs", max(0, last.timestamp - first.timestamp))
    }
}

private enum SetupStep: String, CaseIterable, Identifiable {
    case create
    case record
    case trim
    case sound
    case sync

    var id: String { rawValue }

    var title: String {
        switch self {
        case .create:
            return "动作"
        case .record:
            return "录制"
        case .trim:
            return "裁剪"
        case .sound:
            return "声音"
        case .sync:
            return "同步"
        }
    }

    var systemImage: String {
        switch self {
        case .create:
            return "sparkle"
        case .record:
            return "record.circle"
        case .trim:
            return "timeline.selection"
        case .sound:
            return "waveform"
        case .sync:
            return "applewatch"
        }
    }
}

private enum FileImportTarget {
    case audio
    case profile

    var allowedContentTypes: [UTType] {
        switch self {
        case .audio:
            return Self.audioTypes
        case .profile:
            return [.json]
        }
    }

    var errorEvent: String {
        switch self {
        case .audio:
            return "phone.audio.import.error"
        case .profile:
            return "phone.profile.import.error"
        }
    }

    private static var audioTypes: [UTType] {
        let extensions = ["mp3", "m4a", "wav", "caf", "aiff", "aif", "aac"]
        let explicit = extensions.compactMap { UTType(filenameExtension: $0) }
        return [.audio] + explicit
    }
}

private struct ProductHeader: View {
    var title: String
    var subtitle: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "applewatch")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
            }

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct StepProgressView: View {
    var currentStep: SetupStep

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SetupStep.allCases) { step in
                VStack(spacing: 6) {
                    Image(systemName: step.systemImage)
                        .font(.caption.weight(.semibold))
                        .frame(width: 30, height: 30)
                        .background(background(for: step))
                        .foregroundStyle(foreground(for: step))
                        .clipShape(Circle())
                    Text(step.title)
                        .font(.caption2)
                        .foregroundStyle(step.rawValue == currentStep.rawValue ? .primary : .secondary)
                }
                if step != SetupStep.allCases.last {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(height: 1)
                }
            }
        }
        .padding(.horizontal, 6)
    }

    private func background(for step: SetupStep) -> Color {
        step.rawValue == currentStep.rawValue ? .accentColor : Color(.tertiarySystemFill)
    }

    private func foreground(for step: SetupStep) -> Color {
        step.rawValue == currentStep.rawValue ? .white : .secondary
    }
}

private struct ProductSection<Content: View>: View {
    private var title: String
    private var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct PrimaryActionButton: View {
    var title: String
    var systemImage: String
    var tint: Color = .accentColor
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(tint)
    }
}

private struct StepNavigationBar: View {
    var backTitle: String
    var nextTitle: String
    var canGoNext: Bool
    var back: () -> Void
    var next: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(backTitle, action: back)
                .buttonStyle(.bordered)
            Button(nextTitle, action: next)
                .buttonStyle(.borderedProminent)
                .disabled(!canGoNext)
        }
    }
}

private struct ActionKindHint: View {
    var kind: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var title: String {
        switch kind {
        case "burst":
            return "适合挥拳、甩腕、下劈"
        case "sequence":
            return "适合转腕、完整挥舞、变身动作"
        case "posture":
            return "适合举手保持、手腕朝上"
        default:
            return "适合自定义动作"
        }
    }

    private var detail: String {
        switch kind {
        case "burst":
            return "系统会更关注峰值和短窗口，目标是低延迟触发。"
        case "sequence":
            return "系统会等动作完成后匹配整段节奏，更适合长动作。"
        case "posture":
            return "系统会关注姿态是否稳定保持，第一版先作为配置入口。"
        default:
            return "先采集个人模板，再按动作形态选择识别方式。"
        }
    }

    private var systemImage: String {
        switch kind {
        case "burst":
            return "bolt.fill"
        case "sequence":
            return "point.3.connected.trianglepath.dotted"
        case "posture":
            return "figure.stand"
        default:
            return "sparkle"
        }
    }
}

private struct RecordingStateBadge: View {
    var isRecording: Bool
    var countdown: Int?

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var text: String {
        if let countdown {
            return "\(countdown)"
        }
        return isRecording ? "录制中" : "待开始"
    }

    private var color: Color {
        countdown == nil && !isRecording ? .secondary : .red
    }
}

private struct CountdownView: View {
    var value: Int

    var body: some View {
        VStack(spacing: 6) {
            Text("\(value)")
                .font(.system(size: 72, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("准备做动作")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

private struct EmptyStateView: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct CapturePicker: View {
    var files: [ReceivedSyncedFile]
    @Binding var selectedURL: URL?

    var body: some View {
        if files.count > 1 {
            Picker("样本", selection: $selectedURL) {
                ForEach(files) { file in
                    Text(file.fileURL.lastPathComponent)
                        .tag(Optional(file.fileURL))
                }
            }
            .pickerStyle(.menu)
        } else if let file = files.first {
            SummaryRow(label: "样本", value: file.fileURL.lastPathComponent)
        }
    }
}

private struct MotionSignalTimeline: View {
    var samples: [MotionSample]
    var trimStartFraction: Double
    var trimEndFraction: Double
    var playbackFraction: Double

    private var points: [SignalPoint] {
        guard let first = samples.first else { return [] }
        let stride = max(samples.count / 500, 1)
        let reduced = samples.enumerated().compactMap { offset, sample -> (Int, MotionSample)? in
            offset % stride == 0 ? (offset, sample) : nil
        }
        let maxAcceleration = max(
            reduced.flatMap { item in
                [
                    abs(item.1.userAcceleration.x),
                    abs(item.1.userAcceleration.y),
                    abs(item.1.userAcceleration.z),
                ]
            }.max() ?? 1,
            0.01
        )
        let maxEnergy = max(
            reduced.map { $0.1.userAcceleration.magnitude + 0.25 * $0.1.rotationRate.magnitude }.max() ?? 1,
            0.01
        )

        return reduced.flatMap { offset, sample in
            let time = sample.timestamp - first.timestamp
            let energy = sample.userAcceleration.magnitude + 0.25 * sample.rotationRate.magnitude
            return [
                SignalPoint(id: "\(offset)-energy", time: time, value: energy / maxEnergy, series: "强度"),
                SignalPoint(id: "\(offset)-x", time: time, value: sample.userAcceleration.x / maxAcceleration, series: "X"),
                SignalPoint(id: "\(offset)-y", time: time, value: sample.userAcceleration.y / maxAcceleration, series: "Y"),
                SignalPoint(id: "\(offset)-z", time: time, value: sample.userAcceleration.z / maxAcceleration, series: "Z"),
            ]
        }
    }

    private var duration: Double {
        guard let last = points.last else { return 0 }
        return max(last.time, .leastNonzeroMagnitude)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SignalLegend(color: .accentColor, label: "强度")
                SignalLegend(color: .red, label: "X")
                SignalLegend(color: .green, label: "Y")
                SignalLegend(color: .blue, label: "Z")
            }
            .font(.caption)

            Chart {
                ForEach(points) { point in
                    LineMark(
                        x: .value("时间", point.time),
                        y: .value("归一化", point.value),
                        series: .value("信号", point.series)
                    )
                    .lineStyle(StrokeStyle(lineWidth: point.series == "强度" ? 2.4 : 1.1))
                    .foregroundStyle(by: .value("信号", point.series))
                    .opacity(point.series == "强度" ? 1 : 0.62)
                }

                RectangleMark(
                    xStart: .value("开始", duration * min(trimStartFraction, trimEndFraction)),
                    xEnd: .value("结束", duration * max(trimStartFraction, trimEndFraction)),
                    yStart: .value("下限", -1.05),
                    yEnd: .value("上限", 1.05)
                )
                .foregroundStyle(Color.orange.opacity(0.12))

                RuleMark(x: .value("开始", duration * trimStartFraction))
                    .foregroundStyle(Color.orange)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                RuleMark(x: .value("结束", duration * trimEndFraction))
                    .foregroundStyle(Color.orange)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                RuleMark(x: .value("播放", duration * playbackFraction))
                    .foregroundStyle(Color.red)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
            .chartForegroundStyleScale([
                "强度": Color.accentColor,
                "X": Color.red,
                "Y": Color.green,
                "Z": Color.blue,
            ])
            .chartLegend(.hidden)
            .chartYScale(domain: -1.05...1.05)
            .chartXAxisLabel("时间")
            .chartYAxis(.hidden)
        }
    }
}

private struct SignalLegend: View {
    var color: Color
    var label: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SignalPoint: Identifiable {
    var id: String
    var time: Double
    var value: Double
    var series: String
}

private struct TrimControls: View {
    @Binding var startFraction: Double
    @Binding var endFraction: Double
    @Binding var playbackFraction: Double
    var duration: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SliderValueRow(title: "开始", value: timeText(startFraction))
            Slider(value: $startFraction, in: 0...max(0, endFraction - 0.02))

            SliderValueRow(title: "结束", value: timeText(endFraction))
            Slider(value: $endFraction, in: min(1, startFraction + 0.02)...1)

            SliderValueRow(title: "播放位置", value: timeText(playbackFraction))
            Slider(value: $playbackFraction, in: startFraction...endFraction)
        }
    }

    private func timeText(_ fraction: Double) -> String {
        String(format: "%.2fs", duration * fraction)
    }
}

private struct CaptureStats: View {
    var samples: [MotionSample]

    var body: some View {
        HStack {
            SummaryMetric(title: "采样点", value: "\(samples.count)")
            SummaryMetric(title: "时长", value: durationText)
            SummaryMetric(title: "峰值", value: peakText)
        }
    }

    private var durationText: String {
        guard let first = samples.first, let last = samples.last else { return "0.0s" }
        return String(format: "%.1fs", max(0, last.timestamp - first.timestamp))
    }

    private var peakText: String {
        let peak = samples.map(\.userAcceleration.magnitude).max() ?? 0
        return String(format: "%.2f", peak)
    }
}

private struct SummaryMetric: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.headline)
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct SliderValueRow: View {
    var title: String
    var value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.subheadline)
    }
}

private struct SummaryRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

private struct ReceivedCaptureSummary: Identifiable, Equatable {
    var id: String { gesture }
    var gesture: String
    var positiveCount: Int
    var negativeCount: Int
    var debugCount: Int
    var unknownCount: Int

    var isReadyForFirstProfile: Bool {
        positiveCount >= 5 && negativeCount >= 3
    }

    var statusText: String {
        if positiveCount >= 10 && negativeCount >= 3 {
            return "样本充足，可以生成较稳定的动作。"
        }
        if isReadyForFirstProfile {
            return "可以先生成动作，之后继续补充正样本。"
        }
        if positiveCount < 5 {
            return "还需至少 \(5 - positiveCount) 个正样本"
        }
        return "还需至少 \(3 - negativeCount) 个负样本"
    }

    static func makeSummaries(from files: [ReceivedSyncedFile]) -> [ReceivedCaptureSummary] {
        var summaries: [String: ReceivedCaptureSummary] = [:]

        for file in files where file.fileURL.pathExtension.lowercased() == "csv" {
            let parsed = PhoneConnectivityReceiver.parseCaptureFileName(file.fileURL.deletingPathExtension().lastPathComponent)
            var summary = summaries[parsed.gesture] ?? ReceivedCaptureSummary(
                gesture: parsed.gesture,
                positiveCount: 0,
                negativeCount: 0,
                debugCount: 0,
                unknownCount: 0
            )
            switch parsed.role {
            case "positive":
                summary.positiveCount += 1
            case "negative":
                summary.negativeCount += 1
            case "debug":
                summary.debugCount += 1
            default:
                summary.unknownCount += 1
            }
            summaries[parsed.gesture] = summary
        }

        return summaries.values.sorted { lhs, rhs in
            if lhs.isReadyForFirstProfile != rhs.isReadyForFirstProfile {
                return lhs.isReadyForFirstProfile && !rhs.isReadyForFirstProfile
            }
            return lhs.gesture < rhs.gesture
        }
    }
}
