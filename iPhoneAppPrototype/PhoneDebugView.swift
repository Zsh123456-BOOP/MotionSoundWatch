import AVFoundation
import Charts
import SceneKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PhoneDebugView: View {
    @StateObject private var receiver = PhoneConnectivityReceiver()
    @State private var currentStep = SetupStep.library
    @State private var activeFileImport: FileImportTarget?
    @State private var recordingLabel = "punch"
    @State private var sampleRole = "sample"
    @State private var selectedCaptureURL: URL?
    @State private var previewSamples: [MotionSample] = []
    @State private var acceptedRecordings: [AcceptedGestureRecording] = []
    @State private var previewMessage: String?
    @State private var trimStartFraction = 0.05
    @State private var trimEndFraction = 0.95
    @State private var playbackFraction = 0.0
    @State private var selectedAudioFileName = ""
    @State private var selectedAudioSequenceFileNames: [String] = []
    @State private var volume = 1.0
    @State private var soundStartFraction = 0.0
    @State private var triggerTiming = "atEnd"
    @State private var cooldownSeconds = 1.2
    @State private var localAudioFiles: [URL] = []
    @State private var countdownRemaining: Int?
    @State private var countdownTimer: Timer?
    @State private var pendingRecordingAction: RecordingControlAction?
    @State private var captureCountBeforeStop: Int?
    @State private var savedProfiles: [PhoneGestureAsset] = []
    @State private var trimPlaybackTask: Task<Void, Never>?
    @State private var isPreviewPlaying = false
    @State private var editingAsset: PhoneGestureAsset?
    @State private var isAppendingRecording = false
    @State private var showingDiagnostics = false
    @State private var testingAsset: PhoneGestureAsset?
    @State private var testStartedAt: Date?
    @State private var testBaselineWatchEventCount = 0

    private var captureFiles: [ReceivedSyncedFile] {
        let csvFiles = receiver.receivedFiles
            .filter { $0.fileURL.pathExtension.lowercased() == "csv" }
        let matching = csvFiles.filter { file in
            let parsed = PhoneConnectivityReceiver.parseCaptureFileName(
                file.fileURL.deletingPathExtension().lastPathComponent
            )
            return parsed.gesture == normalizedGestureName
                && (parsed.role == sampleRole || parsed.role == "positive" || parsed.role == "watch")
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
        return trimmed
    }

    private var nameConflict: PhoneGestureAsset? {
        let name = normalizedGestureName
        guard !name.isEmpty else { return nil }
        return savedProfiles.first { asset in
            asset.profile.name.caseInsensitiveCompare(name) == .orderedSame
                && asset.profile.id != editingAsset?.profile.id
        }
    }

    private var isRecording: Bool {
        receiver.lastRecordingStatus?.state == "recording"
    }

    private var canStartRecording: Bool {
        countdownRemaining == nil
            && pendingRecordingAction == nil
            && !normalizedGestureName.isEmpty
            && nameConflict == nil
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
                    if currentStep == .library {
                        PajiActionWorkbench(
                            connectionTitle: connectionTitle,
                            connectionSubtitle: connectionSubtitle,
                            statusStyle: connectionStatusStyle,
                            actionCount: savedProfiles.count,
                            audioCount: localAudioFiles.count,
                            eventCount: receiver.receivedWatchEventCount
                        ) {
                            resetForNewGesture()
                            currentStep = .create
                        } refreshAction: {
                            refreshProductState(reason: "homeRefresh")
                        }
                    } else {
                        ProductHeader(
                            title: connectionTitle,
                            subtitle: connectionSubtitle,
                            detail: nil,
                            statusStyle: connectionStatusStyle
                        )
                    }
                    if currentStep != .library && currentStep != .test {
                        StepProgressView(currentStep: currentStep)
                    }
                    activeStepView
                }
                .padding(16)
            }
            .background(PajiTheme.background.ignoresSafeArea())
            .scrollContentBackground(.hidden)
            .preferredColorScheme(.dark)
            .navigationTitle(PajiStrings.t("brand.name"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingDiagnostics = true
                        AppDiagnostics.record("phone.diagnostics.opened")
                    } label: {
                        Label(PajiStrings.t("action.diagnostics"), systemImage: "stethoscope")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        refreshProductState(reason: "toolbarRefresh")
                    } label: {
                        Label(PajiStrings.t("action.refresh"), systemImage: "arrow.clockwise")
                    }
                }
            }
            .onAppear {
                AppDiagnostics.record("phone.productView.onAppear")
                UIApplication.shared.isIdleTimerDisabled = true
                receiver.activate()
                receiver.sendDiagnosticsConfiguration(reason: "phoneViewAppear")
                receiver.requestWatchRuntime(reason: "phoneViewAppear")
                reloadLocalAudioFiles()
                reloadSavedProfiles()
                syncWatchLibrarySnapshot(reason: "viewAppear")
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
                stopTrimPlayback()
                UIApplication.shared.isIdleTimerDisabled = false
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
            .sheet(isPresented: $showingDiagnostics) {
                PhoneDiagnosticsView(
                    receiver: receiver,
                    currentStep: currentStep,
                    savedProfiles: savedProfiles,
                    localAudioFiles: localAudioFiles,
                    captureFiles: captureFiles,
                    previewSamples: previewSamples
                )
            }
        }
    }

    @ViewBuilder
    private var activeStepView: some View {
        switch currentStep {
        case .library:
            libraryStep
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
        case .test:
            testStep
        }
    }

    private var libraryStep: some View {
        ProductSection(PajiStrings.t("library.title")) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(savedProfiles.isEmpty ? PajiStrings.t("library.ready.empty") : String(format: PajiStrings.t("library.ready.count"), savedProfiles.count))
                            .font(.title3.weight(.semibold))
                        Text(savedProfiles.isEmpty ? PajiStrings.t("library.helper.empty") : PajiStrings.t("library.helper.ready"))
                            .font(.subheadline)
                            .foregroundStyle(PajiTheme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }

                if savedProfiles.isEmpty {
                    EmptyStateView(
                        title: PajiStrings.t("library.empty.title"),
                        subtitle: PajiStrings.t("library.empty.subtitle"),
                        glyph: .recordGesture,
                        artworkName: "PajiEmptyLibraryArt"
                    )
                }

                if !savedProfiles.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(savedProfiles) { asset in
                            GestureAssetRow(asset: asset) {
                                openAssetForSound(asset)
                            } record: {
                                prepareToRecord(asset)
                            } test: {
                                startTest(asset)
                            } resync: {
                                resyncAsset(asset)
                            } delete: {
                                deleteAsset(asset)
                            }
                        }
                    }
                }

            }
        }
    }

    private var createStep: some View {
        ProductSection("创建动作") {
            VStack(alignment: .leading, spacing: 14) {
                PajiStepRail(currentIndex: 0, steps: wizardStepTitles)

                TextField("动作名称", text: $recordingLabel)
                    .textFieldStyle(.roundedBorder)

                if let nameConflict {
                    Text("动作名已存在：\(nameConflict.profile.name)，请重新命名。")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Text("先给动作取一个短名字。接下来会录满 5 次同一个动作，系统只保存你确认过的片段。")
                    .font(.subheadline)
                    .foregroundStyle(PajiTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                PrimaryActionButton(title: "下一步：录制动作", systemImage: "arrow.right") {
                    currentStep = .record
                    AppDiagnostics.record("phone.wizard.step", ["step": currentStep.rawValue])
                }
                .disabled(normalizedGestureName.isEmpty || nameConflict != nil)
            }
        }
    }

    private var recordStep: some View {
        ProductSection("录制动作") {
            VStack(alignment: .leading, spacing: 14) {
                PajiStepRail(currentIndex: 1, steps: wizardStepTitles)

                HStack(alignment: .center, spacing: 12) {
                    PajiStatusOrb(
                        style: isRecording || countdownRemaining != nil ? .stable : (currentSampleCollectionPlan.acceptedCount > 0 ? .stable : .warning),
                        glyph: .recordGesture,
                        active: isRecording || countdownRemaining != nil
                    )
                        .frame(width: 66, height: 66)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(normalizedGestureName)
                            .font(.title3.weight(.semibold))
                        Text(recordingSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(PajiTheme.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    RecordingStateBadge(isRecording: isRecording, countdown: countdownRemaining)
                }

                Text("每次只做一个完整动作。倒数结束后 Watch 会开始采样；动作完成后，在 iPhone 点结束并确认片段。")
                    .font(.subheadline)
                    .foregroundStyle(PajiTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                SampleCollectionStatusView(plan: currentSampleCollectionPlan)

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
                            Text("正在等待 Watch 保存并同步这次录制，完成后自动进入裁剪。")
                                .font(.footnote)
                                .foregroundStyle(PajiTheme.textMuted)
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
                    Text("Watch 不在前台时，录制命令会先排队。请打开手表上的啪叽 Act，避免错过这次采样。")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                if let status = receiver.lastRecordingStatus {
                    Text(recordingStatusText(status))
                        .font(.footnote)
                        .foregroundStyle(PajiTheme.textMuted)
                }

                StepNavigationBar(
                    backTitle: "返回",
                    nextTitle: captureFiles.isEmpty ? "等待录制" : "下一步：裁剪",
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
                        title: "还没有可裁剪的录制",
                        subtitle: "先录一次动作，Watch 会把这次录制同步到 iPhone。",
                        glyph: .recordGesture
                    )
                    PrimaryActionButton(title: "返回录制", systemImage: "record.circle") {
                        currentStep = .record
                    }
                } else {
                    CapturePicker(
                        files: captureFiles,
                        selectedURL: $selectedCaptureURL
                    )

                    MotionTrajectorySceneView(
                        samples: previewSamples,
                        trimStartFraction: trimStartFraction,
                        trimEndFraction: trimEndFraction,
                        playbackFraction: playbackFraction
                    )
                    .frame(height: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

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

                    SampleCollectionStatusView(plan: sampleCollectionPlan(including: trimmedSamples))

                    HStack(spacing: 10) {
                        Button {
                            toggleTrimPlayback()
                        } label: {
                            Label(isPreviewPlaying ? "暂停播放" : "播放片段", systemImage: isPreviewPlaying ? "pause.fill" : "play.fill")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            stopTrimPlayback()
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
                        nextTitle: trimNextTitle,
                        canGoNext: !trimmedSamples.isEmpty
                    ) {
                        stopTrimPlayback()
                        currentStep = .record
                    } next: {
                        stopTrimPlayback()
                        acceptTrimmedSampleAndContinueOrConfigureSound()
                    }
                }
            }
        }
    }

    private var soundStep: some View {
        ProductSection(editingAsset == nil ? "配置声音" : "编辑动作") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("动作名称", text: $recordingLabel)
                        .textFieldStyle(.roundedBorder)

                    if let nameConflict {
                        Text("动作名已存在：\(nameConflict.profile.name)，请重新命名。")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Text(soundStepSummaryText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 12) {
                    PajiGlyphView(.waveform, size: 44)
                        .padding(6)
                        .background(PajiTheme.panel.opacity(0.86))
                        .clipShape(RoundedRectangle(cornerRadius: PajiTheme.cardRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: PajiTheme.cardRadius, style: .continuous)
                                .stroke(PajiTheme.cyan.opacity(selectedAudioFileName.isEmpty ? 0.14 : 0.28), lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedAudioSummaryText)
                            .font(.headline)
                            .lineLimit(2)
                        Text("先试听，再加入触发顺序；连续触发时会按顺序播放。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    activeFileImport = .audio
                } label: {
                    Label("从文件选择音频", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)

                if !localAudioFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("本机音效")
                            .font(.subheadline.weight(.semibold))
                        ForEach(localAudioFiles, id: \.path) { url in
                            HStack(spacing: 10) {
                                Image(systemName: audioSelectionIcon(for: url))
                                    .foregroundStyle(isAudioSelected(url) ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.lastPathComponent)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Text(localAudioFileDetail(url))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    previewAudio(url)
                                } label: {
                                    Image(systemName: "play.fill")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button {
                                    toggleSoundSequence(url)
                                } label: {
                                    Image(systemName: isAudioSelected(url) ? "minus.circle" : "plus.circle")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(10)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                if !selectedAudioSequenceFileNames.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("连续触发顺序")
                            .font(.subheadline.weight(.semibold))
                        ForEach(Array(selectedAudioSequenceFileNames.enumerated()), id: \.offset) { index, name in
                            HStack(spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.caption.weight(.semibold))
                                    .frame(width: 24, height: 24)
                                    .background(Color.accentColor.opacity(0.12))
                                    .clipShape(Circle())
                                Text(name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    removeSequenceSound(at: index)
                                } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(12)
                    .background(Color(.tertiarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                VStack(alignment: .leading, spacing: 10) {
                    SliderValueRow(title: "音量", value: "\(Int(volume * 100))%")
                    Slider(value: $volume, in: 0.2...1)
                    SliderValueRow(title: "声音起点", value: "\(Int(soundStartFraction * 100))%")
                    Slider(value: $soundStartFraction, in: 0...1)
                }

                Picker("触发时机", selection: $triggerTiming) {
                    Text("动作结束").tag("atEnd")
                    Text("动作最明显时").tag("atPeak")
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 8) {
                    SliderValueRow(title: "冷却时间", value: String(format: "%.1fs", cooldownSeconds))
                    Slider(value: $cooldownSeconds, in: 0.3...2.0, step: 0.1)
                }

                StepNavigationBar(
                    backTitle: "返回裁剪",
                    nextTitle: soundStepSaveTitle,
                    canGoNext: canSaveProfile
                ) {
                    currentStep = .trim
                } next: {
                    syncProfile()
                }
            }
        }
    }

    private var syncStep: some View {
        ProductSection("保存并同步") {
            VStack(alignment: .leading, spacing: 14) {
                SummaryRow(label: "动作", value: normalizedGestureName)
                SummaryRow(label: "录制", value: "\(syncBaseTemplates.count) 次")
                SummaryRow(label: "音效", value: selectedAudioFileName.isEmpty ? "未绑定" : selectedAudioFileName)
                SummaryRow(label: "播放", value: triggerTiming == "atPeak" ? "动作最明显时" : "动作完成后")

                Text("保存后会把动作和已选择的音频发送到 Watch。Watch 端会本地识别和播放。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                PrimaryActionButton(title: soundStepSaveTitle, systemImage: "applewatch") {
                    syncProfile()
                }
                .disabled(trimmedSamples.isEmpty)

                Button {
                    activeFileImport = .profile
                } label: {
                    Label("导入动作配置", systemImage: "square.and.arrow.down")
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

    private var testStep: some View {
        ProductSection("测试动作") {
            VStack(alignment: .leading, spacing: 14) {
                if let testingAsset {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(testingAsset.profile.name)
                            .font(.title3.weight(.semibold))
                        Text("连续做 5 次这个动作。这里会统计 Watch 实际触发了几次，以及有没有播到别的动作。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    TestModeSummaryView(summary: currentTestSummary)

                    if currentTestEvents.isEmpty {
                        EmptyStateView(
                            title: "等待 Watch 事件",
                            subtitle: "保持 Watch App 打开并开始做动作。若没有任何事件，说明动作没有被切出或 Watch 没在监听。",
                            glyph: .watch
                        )
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("最近结果")
                                .font(.subheadline.weight(.semibold))
                            ForEach(currentTestEvents.prefix(8)) { event in
                                TestEventRow(event: event, targetProfileID: testingAsset.profile.id)
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            receiver.requestWatchRuntime(reason: "testModeRefresh")
                            receiver.sendDiagnosticsConfiguration(reason: "testModeRefresh")
                            syncWatchLibrarySnapshot(reason: "testModeRefresh")
                        } label: {
                            Label("刷新监听", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            finishTestMode()
                        } label: {
                            Label("结束测试", systemImage: "checkmark")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    EmptyStateView(title: "未选择动作", subtitle: "返回动作列表选择一个动作开始测试。", glyph: .test)
                    PrimaryActionButton(title: "返回动作列表", systemImage: "list.bullet") {
                        finishTestMode()
                    }
                }
            }
        }
    }

    private var connectionTitle: String {
        if receiver.isWatchReachable {
            return PajiStrings.t("status.watch.connected")
        }
        if receiver.isWatchAppInstalled {
            return PajiStrings.t("status.watch.paired")
        }
        if receiver.activationStateDescription == "activated" {
            return PajiStrings.t("status.watch.notInstalled")
        }
        return PajiStrings.t("status.watch.waiting")
    }

    private var connectionSubtitle: String {
        if receiver.isWatchReachable {
            return PajiStrings.t("status.watch.connected.subtitle")
        }
        if receiver.isWatchAppInstalled {
            return PajiStrings.t("status.watch.paired.subtitle")
        }
        if receiver.activationStateDescription == "activated" {
            return PajiStrings.t("status.watch.notInstalled.subtitle")
        }
        return PajiStrings.t("status.watch.waiting.subtitle")
    }

    private var connectionStatusStyle: PajiStatusPill.Style {
        if receiver.isWatchReachable || receiver.isWatchAppInstalled {
            return .synced
        }
        if receiver.activationStateDescription == "activated" {
            return .blocked
        }
        return .warning
    }

    private var automaticKindText: String {
        "自适应动作"
    }

    private var currentSampleCollectionPlan: GestureSampleCollectionPlan {
        sampleCollectionPlan(including: nil)
    }

    private var currentTestEvents: [WatchRecognitionEventSummary] {
        guard let testStartedAt else { return [] }
        return receiver.recentWatchEvents
            .filter { $0.receivedAt >= testStartedAt || $0.createdAt >= testStartedAt }
            .sorted { $0.receivedAt > $1.receivedAt }
    }

    private var currentTestSummary: GestureTestSummary {
        guard let testingAsset else {
            return GestureTestSummary()
        }
        return GestureTestSummary(events: currentTestEvents, targetProfile: testingAsset.profile)
    }

    private var wizardStepTitles: [String] {
        SetupStep.wizardSteps.map(\.title)
    }

    private var recordingSubtitle: String {
        let plan = currentSampleCollectionPlan
        if editingAsset != nil, isAppendingRecording {
            return "补录第 \(plan.acceptedCount + 1) 次，目标 \(plan.requiredCount) 次"
        }
        return "第 \(plan.acceptedCount + 1) 次，目标 \(plan.requiredCount) 次"
    }

    private var soundStepSummaryText: String {
        let plan = currentSampleCollectionPlan
        guard let editingAsset else {
            return "已确认 \(plan.acceptedCount) 次录制，系统会生成\(automaticKindText)模型。"
        }
        if isAppendingRecording {
            return "保存后会保留原有录制，并使用当前共 \(plan.acceptedCount) 次录制重新生成模型。"
        }
        return "当前动作已有 \(editingAsset.templateCount) 次录制；保存会同步名称、声音和触发设置。"
    }

    private var soundStepSaveTitle: String {
        if editingAsset == nil {
            return "保存并同步"
        }
        return isAppendingRecording ? "追加录制并同步" : "保存修改"
    }

    private var trimNextTitle: String {
        let plan = sampleCollectionPlan(including: trimmedSamples)
        if plan.needsMoreSamples {
            return "保存本次，继续录第 \(plan.acceptedCount + 1) 次"
        }
        return "下一步：配置声音"
    }

    private var canSaveProfile: Bool {
        !normalizedGestureName.isEmpty
            && nameConflict == nil
            && !syncBaseTemplates.isEmpty
            && currentSampleCollectionPlan.isReady
    }

    private func refreshProductState(reason: String) {
        receiver.activate()
        receiver.sendDiagnosticsConfiguration(reason: reason)
        receiver.reloadReceivedFiles()
        reloadLocalAudioFiles()
        reloadSavedProfiles()
        syncWatchLibrarySnapshot(reason: reason)
        loadPreferredCapture()
    }

    private var captureDuration: Double {
        guard let first = previewSamples.first, let last = previewSamples.last else { return 0 }
        return max(0, last.timestamp - first.timestamp)
    }

    private func beginCountdownAndRecording() {
        countdownTimer?.invalidate()

        let label = normalizedGestureName
        let kind = "burst"
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
            kind: "burst",
            sampleRole: sampleRole,
            autoSendCSV: true
        )
        if didSend {
            pendingRecordingAction = .stopRecording
            captureCountBeforeStop = captureFiles.count
        }
        AppDiagnostics.record("phone.recording.stopRequested", ["label": normalizedGestureName, "kind": "auto"])
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

        if let statusFileName = receiver.lastRecordingStatus?.fileName,
           let explicitFile = receiver.receivedFiles.first(where: { $0.fileURL.lastPathComponent == statusFileName }) {
            self.captureCountBeforeStop = nil
            pendingRecordingAction = nil
            selectedCaptureURL = explicitFile.fileURL
            currentStep = .trim
            loadCapture(explicitFile)
            AppDiagnostics.record(
                "phone.recording.captureReadyByStatusFile",
                [
                    "label": normalizedGestureName,
                    "file": statusFileName,
                ]
            )
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
        guard !normalizedGestureName.isEmpty else {
            receiver.setLastMessage("请先填写动作名称。")
            AppDiagnostics.record("phone.profile.nameMissing")
            return
        }
        if let nameConflict {
            receiver.setLastMessage("动作名已存在：\(nameConflict.profile.name)，请重新命名。")
            AppDiagnostics.record(
                "phone.profile.nameConflict",
                [
                    "name": normalizedGestureName,
                    "conflictID": nameConflict.profile.id.uuidString,
                ]
            )
            return
        }
        let collectionPlan = currentSampleCollectionPlan
        guard collectionPlan.isReady else {
            receiver.setLastMessage(collectionPlan.message)
            currentStep = .record
            AppDiagnostics.record(
                "phone.profile.sampleCollection.incomplete",
                [
                    "label": normalizedGestureName,
                    "accepted": collectionPlan.acceptedCount,
                    "required": collectionPlan.requiredCount,
                    "highDeviation": collectionPlan.hasHighDeviation,
                ]
            )
            return
        }

        let result = receiver.generateAndSendProfile(
            gesture: normalizedGestureName,
            kind: editingAsset?.profile.kind.rawValue ?? "burst",
            soundFileName: selectedAudioFileName,
            soundSequenceFileNames: selectedSoundNames,
            primarySamplesOverride: syncPrimarySamplesOverride,
            baseTemplates: syncBaseTemplates,
            cooldownSeconds: cooldownSeconds,
            triggerTimingRawValue: triggerTiming,
            volume: volume,
            replacingProfileID: editingAsset?.profile.id,
            replacingName: editingAsset?.profile.name
        )
        if let result {
            let wasAppendingRecording = isAppendingRecording
            for name in selectedSoundNames {
                if let audioURL = localAudioFiles.first(where: { $0.lastPathComponent == name }) {
                    _ = receiver.sendAudioFile(audioURL)
                }
            }
            reloadSavedProfiles()
            let didQueueLibraryReplace = receiver.sendProfileLibrarySnapshot(reason: "profileSaved")
            currentStep = .library
            editingAsset = nil
            isAppendingRecording = false
            acceptedRecordings = []
            receiver.setLastMessage(
                didQueueLibraryReplace || result.didQueueTransfer
                    ? profileSavedMessage(result, wasAppendingRecording: wasAppendingRecording)
                    : "已保存动作，但同步队列未建立。"
            )
        }
        AppDiagnostics.record(
            "phone.profile.syncRequested",
                [
                    "label": normalizedGestureName,
                    "kind": automaticKindText,
                    "recordings": syncBaseTemplates.count,
                    "sound": selectedAudioFileName,
                    "saved": result != nil,
            ]
        )
    }

    private var syncPrimarySamplesOverride: [MotionSample]? {
        return nil
    }

    private var syncBaseTemplates: [MotionTemplate] {
        var templates: [MotionTemplate] = []
        if let editingAsset {
            templates.append(contentsOf: editingAsset.profile.templates)
        }
        if editingAsset == nil || isAppendingRecording {
            templates.append(contentsOf: acceptedRecordingTemplates())
        }
        return templates
    }

    private func sampleCollectionPlan(including samples: [MotionSample]?) -> GestureSampleCollectionPlan {
        GestureSampleCollectionPolicy().plan(
            templates: collectionTemplates(including: samples),
            existingProfiles: comparableExistingProfiles
        )
    }

    private var comparableExistingProfiles: [GestureProfile] {
        savedProfiles
            .map(\.profile)
            .filter { profile in
                if let editingAsset {
                    return profile.id != editingAsset.profile.id
                }
                return true
            }
    }

    private func collectionTemplates(including samples: [MotionSample]?) -> [MotionTemplate] {
        var templates: [MotionTemplate] = []
        if let editingAsset {
            templates.append(contentsOf: editingAsset.profile.templates)
        }
        templates.append(contentsOf: acceptedRecordingTemplates())

        guard let samples, !samples.isEmpty else {
            return templates
        }

        let current = makeRecordingTemplate(samples: samples)
        guard let selectedCaptureURL else {
            templates.append(current)
            return templates
        }

        if let acceptedIndex = acceptedRecordings.firstIndex(where: { $0.sourceURL == selectedCaptureURL }) {
            let baseCount = editingAsset?.profile.templates.count ?? 0
            let templateIndex = baseCount + acceptedIndex
            if templates.indices.contains(templateIndex) {
                templates[templateIndex] = current
            } else {
                templates.append(current)
            }
        } else {
            templates.append(current)
        }
        return templates
    }

    private func acceptedRecordingTemplates() -> [MotionTemplate] {
        acceptedRecordings.map { makeRecordingTemplate(samples: $0.samples) }
    }

    private func makeRecordingTemplate(samples: [MotionSample]) -> MotionTemplate {
        MotionTemplateBuilder().makeTemplate(
            label: normalizedGestureName.isEmpty ? "gesture" : normalizedGestureName,
            kind: editingAsset?.profile.kind ?? .burst,
            samples: samples
        )
    }

    private func acceptTrimmedSampleAndContinueOrConfigureSound() {
        guard !trimmedSamples.isEmpty else { return }
        acceptCurrentTrimmedRecording()
        let plan = currentSampleCollectionPlan
        receiver.setLastMessage(plan.message)
        AppDiagnostics.record(
            "phone.recording.sampleAccepted",
            [
                "label": normalizedGestureName,
                "accepted": plan.acceptedCount,
                "required": plan.requiredCount,
                "highDeviation": plan.hasHighDeviation,
                "ready": plan.isReady,
            ]
        )

        if plan.needsMoreSamples {
            prepareNextRecordingPass()
        } else {
            currentStep = .sound
        }
    }

    private func acceptCurrentTrimmedRecording() {
        let recording = AcceptedGestureRecording(
            sourceURL: selectedCaptureURL,
            samples: trimmedSamples
        )
        if let selectedCaptureURL,
           let index = acceptedRecordings.firstIndex(where: { $0.sourceURL == selectedCaptureURL }) {
            acceptedRecordings[index] = recording
        } else {
            acceptedRecordings.append(recording)
        }
    }

    private func prepareNextRecordingPass() {
        selectedCaptureURL = nil
        previewSamples = []
        previewMessage = nil
        trimStartFraction = 0.05
        trimEndFraction = 0.95
        playbackFraction = 0
        currentStep = .record
    }

    private func profileSavedMessage(_ result: ProfileSyncResult, wasAppendingRecording: Bool) -> String {
        let templateCount = result.archive.profiles.first?.templates.count ?? 0
        if wasAppendingRecording {
            return "已追加第 \(templateCount) 次录制，并同步到 Watch。"
        }
        return "已保存动作，并以 iPhone 动作列表替换 Watch 动作库。"
    }

    private func reloadSavedProfiles() {
        do {
            let store = try GestureProfileFileStore.appDocumentsStore()
            let assets = try store.list().flatMap { stored in
                stored.archive.profiles.map { profile in
                    PhoneGestureAsset(fileURL: stored.fileURL, profile: profile)
                }
            }
            var seen: Set<String> = []
            savedProfiles = assets.filter { asset in
                guard !asset.isLegacyUntitled else { return false }
                let key = asset.deduplicationKey
                guard !seen.contains(key) else { return false }
                seen.insert(key)
                return true
            }
            AppDiagnostics.record("phone.profile.list.reload", ["count": savedProfiles.count])
        } catch {
            savedProfiles = []
            receiver.setLastMessage(error.localizedDescription)
            AppDiagnostics.record(error: error, event: "phone.profile.list.reload.error")
        }
    }

    private func syncWatchLibrarySnapshot(reason: String) {
        let queued = syncWatchLibrarySnapshotReturningQueue(reason: reason)
        AppDiagnostics.record(
            "phone.profile.librarySnapshot.requested",
            [
                "reason": reason,
                "queued": queued,
            ]
        )
    }

    @discardableResult
    private func syncWatchLibrarySnapshotReturningQueue(reason: String) -> Bool {
        receiver.sendProfileLibrarySnapshot(reason: reason)
    }

    private func resetForNewGesture() {
        recordingLabel = ""
        sampleRole = "sample"
        selectedCaptureURL = nil
        previewSamples = []
        acceptedRecordings = []
        previewMessage = nil
        trimStartFraction = 0.05
        trimEndFraction = 0.95
        playbackFraction = 0
        selectedAudioFileName = ""
        selectedAudioSequenceFileNames = []
        soundStartFraction = 0
        triggerTiming = TriggerTiming.atEnd.rawValue
        cooldownSeconds = 1.2
        editingAsset = nil
        isAppendingRecording = false
        stopTrimPlayback()
        AppDiagnostics.record("phone.wizard.newGesture")
    }

    private func openAssetForSound(_ asset: PhoneGestureAsset) {
        editingAsset = asset
        isAppendingRecording = false
        applyAsset(asset)
        acceptedRecordings = []
        previewSamples = asset.profile.templates.first?.samples ?? []
        trimStartFraction = 0
        trimEndFraction = 1
        playbackFraction = 0
        previewMessage = "已载入动作：\(asset.profile.name)"
        currentStep = .sound
        AppDiagnostics.record("phone.profile.openSound", ["profile": asset.profile.name])
    }

    private func prepareToRecord(_ asset: PhoneGestureAsset) {
        editingAsset = asset
        isAppendingRecording = true
        applyAsset(asset)
        sampleRole = "sample"
        selectedCaptureURL = nil
        previewSamples = []
        acceptedRecordings = []
        previewMessage = nil
        currentStep = .record
        AppDiagnostics.record("phone.profile.prepareRecord", ["profile": asset.profile.name])
    }

    private func resyncAsset(_ asset: PhoneGestureAsset) {
        let profileQueued = syncWatchLibrarySnapshotReturningQueue(reason: "resync.\(asset.profile.id.uuidString)")
        if let audioName = asset.profile.sound?.fileName,
           let audioURL = localAudioFiles.first(where: { $0.lastPathComponent == audioName }) {
            _ = receiver.sendAudioFile(audioURL)
        }
        receiver.setLastMessage(profileQueued ? "已重新同步完整动作库" : "重新同步失败")
        AppDiagnostics.record(
            "phone.profile.resync",
            [
                "profile": asset.profile.name,
                "queued": profileQueued,
            ]
        )
    }

    private func startTest(_ asset: PhoneGestureAsset) {
        testingAsset = asset
        testStartedAt = Date()
        testBaselineWatchEventCount = receiver.receivedWatchEventCount
        currentStep = .test
        _ = syncWatchLibrarySnapshotReturningQueue(reason: "testModeStart")
        if let audioName = asset.profile.sound?.fileName,
           let audioURL = localAudioFiles.first(where: { $0.lastPathComponent == audioName }) {
            _ = receiver.sendAudioFile(audioURL)
        }
        receiver.requestWatchRuntime(reason: "testModeStart")
        receiver.sendDiagnosticsConfiguration(reason: "testModeStart")
        AppDiagnostics.record(
            "phone.testMode.start",
            [
                "profile": asset.profile.name,
                "profileID": asset.profile.id.uuidString,
                "baselineWatchEvents": testBaselineWatchEventCount,
            ]
        )
    }

    private func finishTestMode() {
        if let testingAsset {
            let summary = currentTestSummary
            AppDiagnostics.record(
                "phone.testMode.finish",
                [
                    "profile": testingAsset.profile.name,
                    "correct": summary.correctTriggerCount,
                    "wrong": summary.wrongTriggerCount,
                    "targetRejected": summary.targetRejectedCount,
                    "events": summary.totalEventCount,
                ]
            )
        }
        testingAsset = nil
        testStartedAt = nil
        currentStep = .library
        reloadSavedProfiles()
    }

    private func deleteAsset(_ asset: PhoneGestureAsset) {
        do {
            let store = try GestureProfileFileStore.appDocumentsStore()
            let matching = try store.list().filter { stored in
                stored.archive.profiles.contains {
                    $0.id == asset.profile.id
                        || $0.name.caseInsensitiveCompare(asset.profile.name) == .orderedSame
                }
            }
            for stored in matching {
                try store.delete(fileURL: stored.fileURL)
            }
            _ = receiver.sendDeleteProfileCommand(
                profileID: asset.profile.id,
                name: asset.profile.name,
                kind: asset.profile.kind
            )
            reloadSavedProfiles()
            syncWatchLibrarySnapshot(reason: "delete")
            if editingAsset?.id == asset.id {
                editingAsset = nil
            }
            receiver.setLastMessage("已删除：\(asset.profile.name)")
            AppDiagnostics.record(
                "phone.profile.delete",
                [
                    "profile": asset.profile.name,
                    "files": matching.count,
                ]
            )
        } catch {
            receiver.setLastMessage(error.localizedDescription)
            AppDiagnostics.record(error: error, event: "phone.profile.delete.error", ["profile": asset.profile.name])
        }
    }

    private func applyAsset(_ asset: PhoneGestureAsset) {
        recordingLabel = asset.profile.name
        selectedAudioFileName = asset.profile.sound?.fileName ?? ""
        selectedAudioSequenceFileNames = asset.profile.soundSequence?.map(\.fileName) ?? []
        volume = Double(asset.profile.sound?.volume ?? 1)
        triggerTiming = asset.profile.triggerTiming.rawValue
        cooldownSeconds = asset.profile.cooldownSeconds
        stopTrimPlayback()
    }

    private func toggleTrimPlayback() {
        isPreviewPlaying ? stopTrimPlayback() : startTrimPlayback()
    }

    private func startTrimPlayback() {
        stopTrimPlayback()
        guard !previewSamples.isEmpty else { return }

        let start = min(trimStartFraction, trimEndFraction)
        let end = max(trimStartFraction, trimEndFraction)
        playbackFraction = start
        isPreviewPlaying = true

        let duration = max(0.45, captureDuration * max(0.05, end - start))
        let startedAt = Date()
        trimPlaybackTask = Task { @MainActor in
            while !Task.isCancelled {
                let progress = min(1, Date().timeIntervalSince(startedAt) / duration)
                playbackFraction = start + (end - start) * progress
                if progress >= 1 {
                    break
                }
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
            guard !Task.isCancelled else { return }
            playbackFraction = end
            trimPlaybackTask = nil
            isPreviewPlaying = false
        }
        AppDiagnostics.record("phone.trim.playback.start", ["duration": duration])
    }

    private func stopTrimPlayback() {
        trimPlaybackTask?.cancel()
        trimPlaybackTask = nil
        isPreviewPlaying = false
    }

    private func handleImportedFile(_ url: URL, target: FileImportTarget) {
        switch target {
        case .audio:
            guard FileImportTarget.isSupportedAudio(url) else {
                receiver.setLastMessage("暂不支持该音频格式：\(url.pathExtension)")
                AppDiagnostics.record("phone.audio.import.unsupported", ["file": url.lastPathComponent])
                return
            }
            do {
                let importResult = try copyImportedAudioToDocuments(url)
                let savedURL = importResult.fileURL
                reloadLocalAudioFiles()
                selectLocalAudio(savedURL)
                receiver.setLastMessage("已导入音效：\(savedURL.lastPathComponent)")
                AppDiagnostics.record(
                    "phone.audio.imported",
                    [
                        "file": savedURL.lastPathComponent,
                        "duration": String(format: "%.3f", importResult.duration),
                        "size": importResult.fileSize,
                    ]
                )
            } catch {
                receiver.setLastMessage(error.localizedDescription)
                AppDiagnostics.record(error: error, event: "phone.audio.import.error", ["file": url.lastPathComponent])
            }
        case .profile:
            importProfile(url)
        }
    }

    private func importProfile(_ url: URL) {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let archive = try GestureProfileCodec().decode(Data(contentsOf: url))
            let store = try GestureProfileFileStore.appDocumentsStore()
            let savedURL = try store.save(archive, preferredName: archive.profiles.first?.name ?? url.deletingPathExtension().lastPathComponent)
            reloadSavedProfiles()
            syncWatchLibrarySnapshot(reason: "importProfile")
            currentStep = .library
            receiver.setLastMessage("已导入动作：\(archive.profiles.first?.name ?? savedURL.lastPathComponent)")
            AppDiagnostics.record("phone.profile.imported", ["file": savedURL.lastPathComponent])
        } catch {
            receiver.setLastMessage(error.localizedDescription)
            AppDiagnostics.record(error: error, event: "phone.profile.import.error", ["file": url.lastPathComponent])
        }
    }

    private func copyImportedAudioToDocuments(_ url: URL) throws -> AudioImportResult {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let metadata = try validateAudioFile(url)
        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let destination = availableAudioDestinationURL(
            directory: documents,
            fileName: url.lastPathComponent
        )
        try FileManager.default.copyItem(at: url, to: destination)
        return AudioImportResult(
            fileURL: destination,
            duration: metadata.duration,
            fileSize: metadata.fileSize
        )
    }

    private func validateAudioFile(_ url: URL) throws -> AudioImportMetadata {
        let player = try AVAudioPlayer(contentsOf: url)
        let duration = player.duration
        guard duration.isFinite, duration > 0 else {
            throw AudioImportError.invalidDuration
        }

        let fileSize = ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0
        if duration > 30 {
            AppDiagnostics.record(
                "phone.audio.import.longFile",
                [
                    "file": url.lastPathComponent,
                    "duration": String(format: "%.3f", duration),
                    "size": fileSize,
                ]
            )
        }

        return AudioImportMetadata(duration: duration, fileSize: fileSize)
    }

    private func availableAudioDestinationURL(directory: URL, fileName: String) -> URL {
        let destination = directory.appendingPathComponent(sanitizeImportedFileName(fileName))
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return destination
        }

        let base = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        let timestamp = Int(Date().timeIntervalSince1970)
        return directory.appendingPathComponent("\(base)-\(timestamp).\(ext)")
    }

    private func sanitizeImportedFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let compact = String(scalars)
            .split(separator: "-")
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return compact.isEmpty ? "sound.wav" : compact
    }

    private func selectLocalAudio(_ url: URL) {
        selectedAudioFileName = url.lastPathComponent
        receiver.setLastMessage("已选择音效：\(url.lastPathComponent)")
        AppDiagnostics.record("phone.audio.localSelected", ["file": url.lastPathComponent])
    }

    private var selectedSoundNames: [String] {
        if !selectedAudioSequenceFileNames.isEmpty {
            return selectedAudioSequenceFileNames
        }
        return selectedAudioFileName.isEmpty ? [] : [selectedAudioFileName]
    }

    private var selectedAudioSummaryText: String {
        if selectedAudioSequenceFileNames.count > 1 {
            return "\(selectedAudioSequenceFileNames.count) 段音效"
        }
        return selectedSoundNames.first ?? "还未选择音效"
    }

    private func previewAudio(_ url: URL) {
        _ = receiver.previewAudioFile(url, volume: Float(volume))
    }

    private func toggleSoundSequence(_ url: URL) {
        let name = url.lastPathComponent
        if let index = selectedAudioSequenceFileNames.firstIndex(of: name) {
            selectedAudioSequenceFileNames.remove(at: index)
            if selectedAudioFileName == name {
                selectedAudioFileName = selectedAudioSequenceFileNames.first ?? ""
            }
        } else {
            selectedAudioSequenceFileNames.append(name)
            selectedAudioFileName = selectedAudioSequenceFileNames.first ?? name
        }
        if selectedAudioSequenceFileNames.count == 1 {
            selectedAudioFileName = selectedAudioSequenceFileNames[0]
        }
        receiver.setLastMessage("已更新音效顺序：\(selectedAudioSequenceFileNames.count) 段")
        AppDiagnostics.record(
            "phone.audio.sequenceUpdated",
            [
                "count": selectedAudioSequenceFileNames.count,
                "file": name,
            ]
        )
    }

    private func removeSequenceSound(at index: Int) {
        guard selectedAudioSequenceFileNames.indices.contains(index) else { return }
        selectedAudioSequenceFileNames.remove(at: index)
        selectedAudioFileName = selectedAudioSequenceFileNames.first ?? ""
    }

    private func isAudioSelected(_ url: URL) -> Bool {
        selectedSoundNames.contains(url.lastPathComponent)
    }

    private func audioSelectionIcon(for url: URL) -> String {
        isAudioSelected(url) ? "checkmark.circle.fill" : "waveform"
    }

    private func reloadLocalAudioFiles() {
        do {
            let documents = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let urls = try FileManager.default.contentsOfDirectory(
                at: documents,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            )
            localAudioFiles = urls
                .filter { FileImportTarget.isSupportedAudio($0) }
                .sorted { lhs, rhs in
                    modificationDate(lhs) > modificationDate(rhs)
                }
            AppDiagnostics.record("phone.audio.localReload", ["count": localAudioFiles.count])
        } catch {
            localAudioFiles = []
            AppDiagnostics.record(error: error, event: "phone.audio.localReload.error")
        }
    }

    private func localAudioFileDetail(_ url: URL) -> String {
        let size = ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0
        if size <= 0 {
            return url.pathExtension.uppercased()
        }
        let kb = max(1, size / 1024)
        return "\(url.pathExtension.uppercased()) · \(kb) KB"
    }

    private func modificationDate(_ url: URL) -> Date {
        ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate) ?? .distantPast
    }

    private func resetForNextGesture() {
        recordingLabel = ""
        sampleRole = "sample"
        selectedCaptureURL = nil
        previewSamples = []
        acceptedRecordings = []
        previewMessage = nil
        trimStartFraction = 0.05
        trimEndFraction = 0.95
        playbackFraction = 0
        selectedAudioFileName = ""
        selectedAudioSequenceFileNames = []
        editingAsset = nil
        isAppendingRecording = false
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
            previewMessage = "已载入动作片段，时长 \(formatDuration(samples))。"
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
            return "Watch 已结束，正在同步这次录制。"
        }
        return "Watch 已结束，正在保存这次录制。"
    }

    private func formatDuration(_ samples: [MotionSample]) -> String {
        guard let first = samples.first, let last = samples.last else { return "0.0s" }
        return String(format: "%.1fs", max(0, last.timestamp - first.timestamp))
    }
}

private enum SetupStep: String, CaseIterable, Identifiable {
    case library
    case create
    case record
    case trim
    case sound
    case sync
    case test

    var id: String { rawValue }

    static var wizardSteps: [SetupStep] {
        [.create, .record, .trim, .sound]
    }

    var title: String {
        switch self {
        case .library:
            return "动作"
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
        case .test:
            return "测试"
        }
    }

    var systemImage: String {
        switch self {
        case .library:
            return "list.bullet"
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
        case .test:
            return "target"
        }
    }
}

private enum FileImportTarget {
    case audio
    case profile

    var allowedContentTypes: [UTType] {
        switch self {
        case .audio:
            return [.audio] + Self.supportedAudioExtensions.compactMap {
                UTType(filenameExtension: $0)
            }
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

    static func isSupportedAudio(_ url: URL) -> Bool {
        supportedAudioExtensions.contains(url.pathExtension.lowercased())
    }

    private static let supportedAudioExtensions = ["mp3", "m4a", "wav", "caf", "aiff", "aif", "aac"]
}

private struct AudioImportResult {
    var fileURL: URL
    var duration: Double
    var fileSize: Int
}

private struct AudioImportMetadata {
    var duration: Double
    var fileSize: Int
}

private enum AudioImportError: LocalizedError {
    case invalidDuration

    var errorDescription: String? {
        switch self {
        case .invalidDuration:
            return "这个音频文件无法读取有效时长，请换一个 MP3、WAV、M4A 或 AAC 文件。"
        }
    }
}

private struct PhoneDiagnosticsView: View {
    @ObservedObject var receiver: PhoneConnectivityReceiver
    var currentStep: SetupStep
    var savedProfiles: [PhoneGestureAsset]
    var localAudioFiles: [URL]
    var captureFiles: [ReceivedSyncedFile]
    var previewSamples: [MotionSample]

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("连接") {
                    DiagnosticsRow(label: "状态", value: receiver.activationStateDescription)
                    DiagnosticsRow(label: "Watch App", value: receiver.isWatchAppInstalled ? "已安装" : "未确认")
                    DiagnosticsRow(label: "即时连接", value: receiver.isWatchReachable ? "是" : "否")
                    if let message = receiver.lastMessage, !message.isEmpty {
                        DiagnosticsText(label: "最近消息", value: message)
                    }
                }

                Section("动作与音频") {
                    DiagnosticsRow(label: "当前步骤", value: currentStep.title)
                    DiagnosticsRow(label: "已保存动作", value: "\(savedProfiles.count)")
                    DiagnosticsRow(label: "最近同步动作库", value: receiver.lastQueuedProfileLibraryVersion ?? "未同步")
                    DiagnosticsRow(label: "同步动作数", value: "\(receiver.lastQueuedProfileLibraryCount)")
                    DiagnosticsRow(label: "本机音效", value: "\(localAudioFiles.count)")
                    DiagnosticsRow(label: "录制样本", value: "\(captureFiles.count)")
                    DiagnosticsRow(label: "预览采样点", value: "\(previewSamples.count)")
                    DiagnosticsRow(label: "Watch 事件", value: "\(receiver.receivedWatchEventCount)")
                    if let fileName = receiver.lastWatchEventFileName {
                        DiagnosticsText(label: "最近 Watch 事件", value: fileName)
                    }
                }

                if let status = receiver.lastRecordingStatus {
                    Section("最近录制") {
                        DiagnosticsRow(label: "动作", value: status.label.isEmpty ? "未命名" : status.label)
                        DiagnosticsRow(label: "状态", value: status.state)
                        DiagnosticsRow(label: "采样点", value: "\(status.samples)")
                        DiagnosticsRow(label: "CSV", value: status.csvQueued ? "已排队" : "未排队")
                        if let fileName = status.fileName, !fileName.isEmpty {
                            DiagnosticsText(label: "文件", value: fileName)
                        }
                        if let error = status.errorMessage, !error.isEmpty {
                            DiagnosticsText(label: "错误", value: error)
                        }
                    }
                }

                Section("日志") {
                    DiagnosticsText(label: "当前 runId", value: AppDiagnostics.currentRunID())
                    DiagnosticsText(label: "iPhone 日志位置", value: AppDiagnostics.relativeLogPathDescription())
                    DiagnosticsText(
                        label: "Watch 事件",
                        value: "Application Support/MotionSoundWatch/MotionSoundDiagnostics/runs/\(AppDiagnostics.currentRunID())/iOS/watch-events"
                    )
                }
            }
            .navigationTitle("诊断")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct DiagnosticsRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

private struct DiagnosticsText: View {
    var label: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.subheadline)
            Text(value)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct ProductHeader: View {
    var title: String
    var subtitle: String
    var detail: String? = nil
    var statusStyle: PajiStatusPill.Style = .synced

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    PajiLogoLockup(compact: true)
                    PajiStatusPill(style: statusStyle, title: title)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(PajiTheme.textMuted)
                }
                Spacer()
                PajiGlyphView(.watch, size: 44)
            }

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(PajiTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .background(PajiTheme.panel.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: PajiTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PajiTheme.cardRadius, style: .continuous)
                .stroke(PajiTheme.cyan.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct StepProgressView: View {
    var currentStep: SetupStep

    var body: some View {
        PajiStepRail(
            currentIndex: max(0, SetupStep.wizardSteps.firstIndex(of: currentStep) ?? 0),
            steps: SetupStep.wizardSteps.map(\.title)
        )
        .padding(.horizontal, 2)
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
                .foregroundStyle(.white)
            content
        }
        .padding(16)
        .background(PajiTheme.panel.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: PajiTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PajiTheme.cardRadius, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
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
                .font(.headline.weight(.semibold))
                .padding(.vertical, 5)
        }
        .buttonStyle(.borderedProminent)
        .tint(PajiTheme.cyan)
        .foregroundStyle(PajiTheme.ink)
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
    var glyph: PajiGlyph = .playBurst
    var artworkName: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let artworkName {
                Image(artworkName)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: 86, height: 86)
                    .accessibilityHidden(true)
            } else {
                PajiGlyphView(glyph, size: 48)
                    .padding(8)
                    .background(PajiTheme.panel.opacity(0.82))
                    .clipShape(RoundedRectangle(cornerRadius: PajiTheme.cardRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: PajiTheme.cardRadius, style: .continuous)
                            .stroke(PajiTheme.cyan.opacity(0.16), lineWidth: 1)
                    )
                    .frame(width: 56, height: 56)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(PajiTheme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(PajiTheme.panelElevated.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: PajiTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PajiTheme.cardRadius, style: .continuous)
                .stroke(PajiTheme.cyan.opacity(0.16), lineWidth: 1)
        )
    }
}

private struct CapturePicker: View {
    var files: [ReceivedSyncedFile]
    @Binding var selectedURL: URL?

    var body: some View {
        if files.count > 1 {
            Picker("选择录制", selection: $selectedURL) {
                ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                    Text("第 \(index + 1) 次录制")
                        .tag(Optional(file.fileURL))
                }
            }
            .pickerStyle(.menu)
        } else if files.first != nil {
            SummaryRow(label: "录制", value: "第 1 次")
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
        let maxEnergy = max(
            reduced.map { $0.1.userAcceleration.magnitude + 0.25 * $0.1.rotationRate.magnitude }.max() ?? 1,
            0.01
        )

        return reduced.map { offset, sample in
            let time = sample.timestamp - first.timestamp
            let energy = sample.userAcceleration.magnitude + 0.25 * sample.rotationRate.magnitude
            return SignalPoint(id: "\(offset)-energy", time: time, value: energy / maxEnergy, series: "动作强度")
        }
    }

    private var duration: Double {
        guard let last = points.last else { return 0 }
        return max(last.time, .leastNonzeroMagnitude)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                SignalLegend(color: .accentColor, label: "动作强度")
                Spacer()
                Text("拖动下面的开始和结束，保留真正的动作部分")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            Chart {
                ForEach(points) { point in
                    LineMark(
                        x: .value("时间", point.time),
                        y: .value("归一化", point.value),
                        series: .value("信号", point.series)
                    )
                    .lineStyle(StrokeStyle(lineWidth: 2.4))
                    .foregroundStyle(by: .value("信号", point.series))
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
                "动作强度": Color.accentColor,
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
            SummaryMetric(title: "已选时长", value: durationText)
            SummaryMetric(title: "片段状态", value: qualityText)
        }
    }

    private var durationText: String {
        guard let first = samples.first, let last = samples.last else { return "0.0s" }
        return String(format: "%.1fs", max(0, last.timestamp - first.timestamp))
    }

    private var qualityText: String {
        guard let first = samples.first, let last = samples.last else { return "待选择" }
        let duration = max(0, last.timestamp - first.timestamp)
        if duration < 0.25 {
            return "偏短"
        }
        if duration > 8 {
            return "偏长"
        }
        return "可用"
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

private struct AcceptedGestureRecording: Identifiable, Equatable {
    var id = UUID()
    var sourceURL: URL?
    var samples: [MotionSample]
}

private struct SampleCollectionStatusView: View {
    var plan: GestureSampleCollectionPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: plan.isReady ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundStyle(plan.isReady ? PajiTheme.lime : PajiTheme.cyan)
                Text("\(plan.acceptedCount)/\(plan.requiredCount) 次录制")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text(plan.isReady ? "可保存" : "继续录制")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(plan.isReady ? PajiTheme.lime : PajiTheme.cyan)
            }
            PajiSyncProgressBar(
                progress: plan.requiredCount == 0 ? 0 : Double(plan.acceptedCount) / Double(plan.requiredCount),
                isActive: !plan.isReady
            )
            Text(plan.message)
                .font(.footnote)
                .foregroundStyle(PajiTheme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(PajiTheme.panelElevated.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: PajiTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PajiTheme.cardRadius, style: .continuous)
                .stroke(PajiTheme.border, lineWidth: 1)
        )
    }
}

private struct GestureTestSummary: Equatable {
    var totalEventCount = 0
    var correctTriggerCount = 0
    var wrongTriggerCount = 0
    var targetRejectedCount = 0
    var otherRejectedCount = 0
    var audioPlayedCount = 0

    init() {}

    init(events: [WatchRecognitionEventSummary], targetProfile: GestureProfile) {
        totalEventCount = events.count
        for event in events {
            let isTarget = event.profileID == targetProfile.id
                || event.profileName.caseInsensitiveCompare(targetProfile.name) == .orderedSame
            if event.triggered, isTarget {
                correctTriggerCount += 1
            } else if event.triggered {
                wrongTriggerCount += 1
            } else if isTarget {
                targetRejectedCount += 1
            } else {
                otherRejectedCount += 1
            }
            if event.audioPlayed {
                audioPlayedCount += 1
            }
        }
    }

    var missedHintCount: Int {
        max(0, 5 - correctTriggerCount)
    }
}

private struct TestModeSummaryView: View {
    var summary: GestureTestSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TestMetricView(title: "正确触发", value: "\(summary.correctTriggerCount)/5", color: .green)
                TestMetricView(title: "播错动作", value: "\(summary.wrongTriggerCount)", color: summary.wrongTriggerCount > 0 ? .red : .secondary)
                TestMetricView(title: "未通过", value: "\(summary.targetRejectedCount)", color: summary.targetRejectedCount > 0 ? .orange : .secondary)
            }
            Text(testHint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var testHint: String {
        if summary.totalEventCount == 0 {
            return "还没有收到 Watch 识别事件。先做几次动作，结果会自动同步到这里。"
        }
        if summary.wrongTriggerCount > 0 {
            return "出现播错动作，需要继续补录或等下一轮融合识别收紧冲突。"
        }
        if summary.correctTriggerCount >= 5 {
            return "5 次测试都正确触发，可以进入下一轮真实使用测试。"
        }
        if summary.targetRejectedCount > 0 {
            return "Watch 已看到相似动作但没有通过，后续应把这些片段作为补录样本或优化 variant。"
        }
        return "如果你已经做满 5 次但触发不足，说明部分动作没有被切出，需要继续看 Watch trace。"
    }
}

private struct TestMetricView: View {
    var title: String
    var value: String
    var color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.weight(.semibold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TestEventRow: View {
    var event: WatchRecognitionEventSummary
    var targetProfileID: UUID

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var isTarget: Bool {
        event.profileID == targetProfileID
    }

    private var icon: String {
        if event.triggered, isTarget { return "checkmark.circle.fill" }
        if event.triggered { return "exclamationmark.triangle.fill" }
        return "xmark.circle"
    }

    private var color: Color {
        if event.triggered, isTarget { return .green }
        if event.triggered { return .red }
        return .orange
    }

    private var title: String {
        if event.triggered, isTarget { return "正确触发：\(event.profileName)" }
        if event.triggered { return "播错为：\(event.profileName)" }
        return "未触发"
    }

    private var detail: String {
        var parts: [String] = []
        if let variantLabel = event.variantLabel {
            parts.append(variantLabel)
        }
        if !event.recognizerKind.isEmpty {
            parts.append(event.recognizerKind)
        }
        if let rejectReason = event.rejectReason {
            parts.append(rejectReason)
        }
        return parts.isEmpty ? event.outcome : parts.joined(separator: " · ")
    }
}

private struct PhoneGestureAsset: Identifiable, Equatable {
    var fileURL: URL
    var profile: GestureProfile

    var id: UUID { profile.id }
    var deduplicationKey: String { "\(profile.name.lowercased())|\(profile.kind.rawValue)" }
    var templateCount: Int { profile.templates.count }
    var soundName: String {
        if let sequence = profile.soundSequence, sequence.count > 1 {
            return "\(sequence.count) 段音效"
        }
        return profile.sound?.fileName ?? "未绑定音效"
    }
    var isLegacyUntitled: Bool {
        profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("untitled") == .orderedSame
    }
}

private struct GestureAssetRow: View {
    var asset: PhoneGestureAsset
    var open: () -> Void
    var record: () -> Void
    var test: () -> Void
    var resync: () -> Void
    var delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: open) {
                HStack(spacing: 12) {
                    PajiStatusOrb(style: .stable, glyph: .recordGesture, active: false)
                        .frame(width: 50, height: 50)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(asset.profile.name)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text("\(asset.templateCount) 次录制 · \(asset.soundName)")
                            .font(.caption)
                            .foregroundStyle(PajiTheme.textMuted)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PajiTheme.textMuted)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: 8) {
                Label(asset.soundName, systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(PajiTheme.textMuted)
                    .lineLimit(1)
                Spacer()
                Button(action: record) {
                    Label("补录", systemImage: "record.circle")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("补录")
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(action: test) {
                    Label("测试", systemImage: "scope")
                        .labelStyle(.iconOnly)
                }
                .accessibilityLabel("测试")
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(action: resync) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .accessibilityLabel("重新同步")
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(role: .destructive, action: delete) {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("删除")
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(PajiTheme.panelElevated.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: PajiTheme.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PajiTheme.cardRadius, style: .continuous)
                .stroke(PajiTheme.cyan.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct MotionTrajectorySceneView: UIViewRepresentable {
    var samples: [MotionSample]
    var trimStartFraction: Double
    var trimEndFraction: Double
    var playbackFraction: Double

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = SCNScene()
        view.backgroundColor = UIColor.secondarySystemGroupedBackground
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        MotionTrajectoryRenderer.ensureCamera(in: view.scene)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        MotionTrajectoryRenderer.render(
            samples: samples,
            trimStartFraction: trimStartFraction,
            trimEndFraction: trimEndFraction,
            playbackFraction: playbackFraction,
            in: uiView.scene
        )
    }
}

private enum MotionTrajectoryRenderer {
    static func ensureCamera(in scene: SCNScene?) {
        guard let scene else { return }
        if scene.rootNode.childNode(withName: "motion-camera", recursively: false) == nil {
            let cameraNode = SCNNode()
            cameraNode.name = "motion-camera"
            cameraNode.camera = SCNCamera()
            cameraNode.camera?.fieldOfView = 46
            cameraNode.position = SCNVector3(0, 0.9, 5.2)
            cameraNode.eulerAngles = SCNVector3(-0.18, 0, 0)
            scene.rootNode.addChildNode(cameraNode)
        }

        if scene.rootNode.childNode(withName: "motion-light", recursively: false) == nil {
            let lightNode = SCNNode()
            lightNode.name = "motion-light"
            lightNode.light = SCNLight()
            lightNode.light?.type = .omni
            lightNode.light?.intensity = 600
            lightNode.position = SCNVector3(0, 3, 4)
            scene.rootNode.addChildNode(lightNode)
        }
    }

    static func render(
        samples: [MotionSample],
        trimStartFraction: Double,
        trimEndFraction: Double,
        playbackFraction: Double,
        in scene: SCNScene?
    ) {
        guard let scene else { return }
        ensureCamera(in: scene)
        scene.rootNode.childNodes
            .filter { $0.name == "motion-content" }
            .forEach { $0.removeFromParentNode() }

        let root = SCNNode()
        root.name = "motion-content"
        scene.rootNode.addChildNode(root)

        addAxes(to: root)

        let points = trajectoryPoints(for: samples)
        guard points.count >= 2 else {
            addEmptyMessagePlane(to: root)
            return
        }

        root.addChildNode(lineNode(points: points, color: UIColor.systemGray3, opacity: 0.72))

        let startIndex = clampedIndex(fraction: min(trimStartFraction, trimEndFraction), count: points.count)
        let endIndex = clampedIndex(fraction: max(trimStartFraction, trimEndFraction), count: points.count)
        if endIndex > startIndex {
            let trimmed = Array(points[startIndex...endIndex])
            root.addChildNode(lineNode(points: trimmed, color: UIColor.systemOrange, opacity: 1))
        }

        let cursorIndex = clampedIndex(fraction: playbackFraction, count: points.count)
        let sampleIndex = clampedIndex(fraction: playbackFraction, count: samples.count)
        let cursor = watchNode(sample: samples[sampleIndex])
        cursor.position = points[cursorIndex]
        root.addChildNode(cursor)

        let startMarker = sphereNode(radius: 0.045, color: UIColor.systemGreen)
        startMarker.position = points[startIndex]
        root.addChildNode(startMarker)

        let endMarker = sphereNode(radius: 0.045, color: UIColor.systemOrange)
        endMarker.position = points[endIndex]
        root.addChildNode(endMarker)
    }

    private static func trajectoryPoints(for samples: [MotionSample]) -> [SCNVector3] {
        guard samples.count >= 2 else { return [] }
        let stride = max(samples.count / 700, 1)
        let reduced = samples.enumerated().compactMap { offset, sample in
            offset % stride == 0 ? sample : nil
        }

        var points: [SCNVector3] = []
        points.reserveCapacity(reduced.count)
        var velocity = SCNVector3Zero
        var position = SCNVector3Zero
        var previousTimestamp = reduced.first?.timestamp ?? 0

        for sample in reduced {
            let dt = Float(min(max(sample.timestamp - previousTimestamp, 1.0 / 120.0), 0.05))
            previousTimestamp = sample.timestamp
            let acceleration = SCNVector3(
                Float(sample.userAcceleration.x),
                Float(sample.userAcceleration.y),
                Float(sample.userAcceleration.z)
            )
            velocity = (velocity + acceleration * dt) * 0.88
            position = position + velocity * dt
            points.append(position)
        }

        if spatialSpan(points) < 0.01 {
            points = reduced.map {
                SCNVector3(
                    Float($0.userAcceleration.x),
                    Float($0.userAcceleration.y),
                    Float($0.userAcceleration.z)
                )
            }
        }

        return normalized(points)
    }

    private static func normalized(_ points: [SCNVector3]) -> [SCNVector3] {
        guard !points.isEmpty else { return [] }
        let center = points.reduce(SCNVector3Zero, +) / Float(points.count)
        let centered = points.map { $0 - center }
        let span = max(spatialSpan(centered), 0.001)
        let scale = Float(2.6) / span
        return centered.map { $0 * scale }
    }

    private static func spatialSpan(_ points: [SCNVector3]) -> Float {
        guard let first = points.first else { return 0 }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        var minZ = first.z
        var maxZ = first.z

        for point in points {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
            minZ = min(minZ, point.z)
            maxZ = max(maxZ, point.z)
        }

        return max(maxX - minX, max(maxY - minY, maxZ - minZ))
    }

    private static func lineNode(points: [SCNVector3], color: UIColor, opacity: CGFloat) -> SCNNode {
        let source = SCNGeometrySource(vertices: points)
        let indices = (0..<(points.count - 1)).flatMap { [Int32($0), Int32($0 + 1)] }
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = color.withAlphaComponent(opacity)
        material.emission.contents = color.withAlphaComponent(opacity * 0.35)
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    private static func sphereNode(radius: CGFloat, color: UIColor) -> SCNNode {
        let sphere = SCNSphere(radius: radius)
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.emission.contents = color.withAlphaComponent(0.25)
        sphere.materials = [material]
        return SCNNode(geometry: sphere)
    }

    private static func watchNode(sample: MotionSample) -> SCNNode {
        let root = SCNNode()

        let forearm = SCNCylinder(radius: 0.035, height: 0.72)
        let forearmMaterial = SCNMaterial()
        forearmMaterial.diffuse.contents = UIColor.systemGray2.withAlphaComponent(0.82)
        forearm.materials = [forearmMaterial]
        let forearmNode = SCNNode(geometry: forearm)
        forearmNode.position = SCNVector3(0, -0.42, -0.02)
        root.addChildNode(forearmNode)

        let body = SCNBox(width: 0.34, height: 0.24, length: 0.08, chamferRadius: 0.035)
        let bodyMaterial = SCNMaterial()
        bodyMaterial.diffuse.contents = UIColor.label
        bodyMaterial.emission.contents = UIColor.systemBlue.withAlphaComponent(0.08)
        body.materials = [bodyMaterial]
        let bodyNode = SCNNode(geometry: body)
        root.addChildNode(bodyNode)

        let face = SCNBox(width: 0.26, height: 0.17, length: 0.012, chamferRadius: 0.018)
        let faceMaterial = SCNMaterial()
        faceMaterial.diffuse.contents = UIColor.systemBlue.withAlphaComponent(0.78)
        faceMaterial.emission.contents = UIColor.systemBlue.withAlphaComponent(0.35)
        face.materials = [faceMaterial]
        let faceNode = SCNNode(geometry: face)
        faceNode.position = SCNVector3(0, 0, 0.048)
        root.addChildNode(faceNode)

        if let attitude = sample.attitude {
            root.orientation = SCNQuaternion(
                Float(attitude.x),
                Float(attitude.y),
                Float(attitude.z),
                Float(attitude.w)
            )
        }

        return root
    }

    private static func addAxes(to root: SCNNode) {
        root.addChildNode(lineNode(points: [SCNVector3(-1.4, 0, 0), SCNVector3(1.4, 0, 0)], color: .systemRed, opacity: 0.34))
        root.addChildNode(lineNode(points: [SCNVector3(0, -1.4, 0), SCNVector3(0, 1.4, 0)], color: .systemGreen, opacity: 0.34))
        root.addChildNode(lineNode(points: [SCNVector3(0, 0, -1.4), SCNVector3(0, 0, 1.4)], color: .systemBlue, opacity: 0.34))
    }

    private static func addEmptyMessagePlane(to root: SCNNode) {
        let plane = SCNPlane(width: 1.6, height: 0.8)
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.systemGray5
        plane.materials = [material]
        let node = SCNNode(geometry: plane)
        node.opacity = 0.6
        root.addChildNode(node)
    }

    private static func clampedIndex(fraction: Double, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return max(0, min(count - 1, Int(round(Double(count - 1) * fraction))))
    }
}

private func + (lhs: SCNVector3, rhs: SCNVector3) -> SCNVector3 {
    SCNVector3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z)
}

private func - (lhs: SCNVector3, rhs: SCNVector3) -> SCNVector3 {
    SCNVector3(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z)
}

private func * (lhs: SCNVector3, rhs: Float) -> SCNVector3 {
    SCNVector3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs)
}

private func / (lhs: SCNVector3, rhs: Float) -> SCNVector3 {
    SCNVector3(lhs.x / rhs, lhs.y / rhs, lhs.z / rhs)
}
