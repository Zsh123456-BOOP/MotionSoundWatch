# Apple Watch 真机开发准备

## 设备前提

- iPhone 已与 Apple Watch 配对。
- Mac 上 Xcode 可识别 iPhone 和 Apple Watch。
- iPhone 和 Apple Watch 都开启开发者模式。
- Apple ID 已登录 Xcode，能给本地调试 app 签名。

## Xcode 操作路线

1. 用 Xcode 打开 `MotionSoundWatch.xcodeproj`。
2. 分别选择 `MotionSoundPhone` 和 `MotionSoundWatch` target，在 Signing & Capabilities 中选择同一个开发团队。
3. 先把 `MotionSoundPhone` 跑到已配对的 iPhone。
4. 再把 `MotionSoundWatch` 跑到真实 Apple Watch。
5. 打开 iPhone app，确认 WatchConnectivity 状态为 activated；再在 Watch app 保存 CSV/Profile 后点“发送 CSV”或“发送 Profile”。
6. 在 iPhone app 点“选择音频发送到 Watch”，选择 `.wav`、`.mp3`、`.m4a`、`.aac`、`.caf`、`.aiff` 或 `.aif` 文件，等待 Watch app 显示已接收音频。
7. 在 Watch app 的“音频文件”输入框里填写同名文件，例如 `punch.wav`，再保存标准 Profile。
8. 后续主动监听阶段再评估是否需要 Background Modes 中的 Audio 能力。

当前 Watch target 已配置：

```text
WKCompanionAppBundleIdentifier = com.zhongsuhua.MotionSoundPhone
WKRunsIndependentlyOfCompanionApp = true
```

这表示 Watch app 可以独立运行，同时明确把 `MotionSoundPhone` 作为配对 iPhone 端，便于真机验证 WatchConnectivity 文件传输。

命令行结构验证：

```bash
xcodebuild -project MotionSoundWatch.xcodeproj -target MotionSoundWatch -configuration Debug -sdk watchsimulator CODE_SIGNING_ALLOWED=NO build
xcodebuild -project MotionSoundWatch.xcodeproj -target MotionSoundPhone -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
xcodebuild -project MotionSoundWatch.xcodeproj -target MotionSoundWatch -configuration Debug -sdk watchos CODE_SIGNING_ALLOWED=NO build
xcodebuild -project MotionSoundWatch.xcodeproj -target MotionSoundPhone -configuration Debug -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
```

当前本机已验证上述命令可以构建通过。若用 `-scheme` 选择 destination 时 Xcode 提示 watchOS/iOS 模拟器组件未安装，需要到 Xcode > Settings > Components 安装对应平台/模拟器；真机联调可以直接选择已连接 iPhone 和已配对 Apple Watch，不依赖模拟器 runtime。

2026-06-01 本机状态：

- `xcodebuild -showsdks` 能看到 iOS、iOS Simulator、watchOS 和 watchOS Simulator SDK。
- `xcrun simctl list runtimes` 暂时没有已安装 runtime。
- `xcodebuild -downloadPlatform iOS` 和 `xcodebuild -downloadPlatform watchOS` 均失败在 Apple MobileAsset catalog 网络层，错误为 general networking error。
- Xcode 的本地语言模型/预测补全下载已关闭，避免 `IDELanguageModelKit` 下载失败反复干扰开发。

因此当前优先走真机路径。模拟器 runtime 以后网络恢复时再通过 Xcode Settings > Components 或 `xcodebuild -downloadPlatform iOS/watchOS` 安装。

## 第一轮真机采样

每个动作建议采：

- 正样本：10 次。
- 负样本：走路、抬腕、放下手、转腕、拿杯子、坐下站起，各 10-20 秒。
- 每条样本记录：动作名、动作类型、佩戴手、表带松紧、主观质量。

Watch 原型里的“保存 CSV”会把当前录制写入 app Documents 下的 `MotionRecordings/` 目录，字段为：

```text
timestamp,userAccelerationX,userAccelerationY,userAccelerationZ,
rotationRateX,rotationRateY,rotationRateZ,
gravityX,gravityY,gravityZ,
attitudeX,attitudeY,attitudeZ,attitudeW
```

Watch 原型里的“保存 Profile”会把当前录制生成的快速 Profile 写入 app Documents 下的 `GestureProfiles/` 目录。快速 Profile 只适合第一轮调试。

标准 Profile 的真机流程：

```text
1. 输入动作名称和类型
2. 录第 1 次动作，停止后点“加入标准样本”
3. 重复到 3/3
4. 录一段日常动作但不要做目标动作，停止后点“加入负样本”
5. 点“保存标准 Profile”
```

标准 Profile 会把 3 个正样本模板和可选负样本保存到同一个动作 Profile，用于后续阈值、margin、误触风险和质量评分。精准模式后续还要扩展到 5-8 次正样本和更完整的负样本校准。

如果要减少点 Watch 按钮造成的数据污染，可以用 iPhone app 的“远程采集”：

```text
1. 在 iPhone app 输入动作名称和类型
2. 选择样本类型：正样本、负样本或调试
3. 点“让 Watch 开始录制”
4. iPhone 先显示命令回执，随后显示 Watch 回传的实际执行状态；Watch 显示 `Remote recording` 并震动后做动作
5. 点“让 Watch 停止录制”
6. 默认会自动保存 CSV 并传回 iPhone，文件名会包含动作名和样本类型；iPhone 会显示 Watch 停止后的样本数和 CSV 队列文件名
7. 在 iPhone 的“样本统计”区确认每个动作的正样本、负样本和调试样本数量
8. 在 iPhone 文件列表点单个文件“分享”或“分享全部”，把 CSV 发到 Mac 或云盘做离线分析
9. 在 Mac 上用 `motion-sound-profile` 生成 Profile JSON
10. 在 iPhone app 点“选择 Profile 发送到 Watch”，把 Profile JSON 同步回 Watch
11. Watch 校验 checksum、解码 Profile、保存到 `GestureProfiles/`，并刷新本地识别器
```

iPhone 会优先使用 `sendMessage` 做实时控制；Watch 暂不可达时会退到 `transferUserInfo` 队列。Watch 收到实时命令会立即回一个命令回执，真正开始/停止录制后还会单独发送 `recordingStatus`，包含执行状态、样本数、CSV 是否已排队和文件名。若“停止后自动传回 CSV”开启，Watch 停止录制后会保存 CSV 并用 `transferFile` 发回 iPhone。

iPhone 同步到 Watch 的文件分两类：音频文件会保存到 `MotionSoundSounds/` 并预加载，Profile JSON 会保存到 `GestureProfiles/` 并触发 Watch 重新加载识别器。Profile 文件会先通过 `GestureProfileCodec` 解码，非法 JSON 不会写入本地 Profile 目录。

## Burst 粗筛真机观察

Watch 端实时识别现在会先经过 burst gate，再进入 DTW/KNN 模板匹配。它只约束 `burst` 动作，`sequence` 和 `posture` 不受影响。默认检查：

```text
minimumPeakAcceleration = 0.55
maximumDuration = 0.9s
requiresDominantAxisMatch = true
axisMismatchMinimumPeakAcceleration = 1.2
```

真机第一轮要记录每次“未触发”是否显示 `Burst gate: peakAccelerationTooLow`、`durationTooLong` 或 `dominantAxisMismatch`。如果真实挥拳经常被 `peakAccelerationTooLow` 挡掉，先降 `minimumPeakAcceleration`；如果抬腕/走路误进匹配，先升 `minimumPeakAcceleration` 或缩短 `maximumDuration`。

保存 CSV 或 Profile 后，Watch 原型会出现“发送 CSV”或“发送 Profile”按钮。当前工程已接入 Watch 端 `WatchConnectivity transferFile` 发送队列，元数据包含：

```text
kind: recordingCSV / gestureProfile
fileName
sentAt
source: MotionSoundWatch
```

iPhone 端已有 `MotionSoundPhone` target，用于激活 `WCSession`、接收 Watch 发送的 CSV/Profile 文件，并保存到 iPhone app Documents 下的 `MotionSoundIncoming/` 目录。`transferFile` 的完整收发必须在真实配对 iPhone + Apple Watch 上验证，模拟器不能作为最终依据。

## 音频同步真机验证

iPhone 端已支持选择音频文件并通过 `WCSession.transferFile` 发送到 Watch，元数据包含：

```text
kind: audioAsset
fileName
sentAt
source: MotionSoundPhone
checksum
```

Watch 端收到后会校验 checksum，并保存到 app Documents 下的 `MotionSoundSounds/` 目录。Watch 播放器会优先使用已预加载的本地音频；如果 Bundle 中没有同名资源，会查找 `MotionSoundSounds/<fileName>`。

验证顺序：

```text
1. iPhone app 选择音频发送到 Watch
2. Watch app 点“刷新音频”，确认列表里出现该文件
3. Watch app 的“音频文件”输入框填写完整文件名
4. 保存标准 Profile
5. 做目标动作，确认识别成功后能播放音频
6. 断开 iPhone 或锁屏后再次测试 Watch 本地播放
```

第一轮必须额外记录：

- 左手 / 右手。
- 表冠方向。
- Watch 型号与 watchOS 版本。
- 是否断开 iPhone 后仍能播放已同步音效。
- 10 分钟主动监听的耗电变化。

## 不要先做

- 不要先做云端识别。
- 不要先做复杂 AI 训练。
- 不要先做多人通用模型。
- 不要先做联机对战或多人同步。
