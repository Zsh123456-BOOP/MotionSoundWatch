# Apple Watch Motion Sound

Apple Watch 动作识别触发音效项目。第一阶段不训练通用 AI 模型，而是围绕单个用户的动作模板库做少样本识别：

- Apple Watch Core Motion 采集手腕运动。
- 每个动作录制 5-10 次，形成个人模板。
- 按动作形态分为 burst、sequence、posture、combo。
- 使用多模板 DTW/KNN、独立阈值、margin、冷却时间和负样本校准控制误触。
- 对 burst 动作先用峰值加速度、动作时长和主轴方向做粗筛，再进入模板匹配。
- Watch 端本地预加载音频，识别成功后低延迟播放。

当前仓库已包含 `MotionSoundCore` Swift Package、Watch 端采集/识别原型，以及用于接收 Watch 文件、远程控制 Watch 采集、Watch 命令回执、Watch 执行状态回传、Watch 端震动/状态提示、按动作统计正/负/调试样本、逐个或批量分享 CSV、向 Watch 同步音频和 Profile JSON 的 iPhone companion 原型。

## Watch App

已生成可打开的 Xcode 工程：

```bash
open MotionSoundWatch.xcodeproj
```

命令行验证：

```bash
xcodebuild -project MotionSoundWatch.xcodeproj -target MotionSoundWatch -configuration Debug -sdk watchsimulator CODE_SIGNING_ALLOWED=NO build
xcodebuild -project MotionSoundWatch.xcodeproj -target MotionSoundPhone -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO build
xcodebuild -project MotionSoundWatch.xcodeproj -target MotionSoundWatch -configuration Debug -sdk watchos CODE_SIGNING_ALLOWED=NO build
xcodebuild -project MotionSoundWatch.xcodeproj -target MotionSoundPhone -configuration Debug -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
```

## 本地验证

```bash
swift test
scripts/check-xcode-watch-env.sh
tools/analyze_motion_csv.py data/raw/punch/*.csv
tools/evaluate_motion_dataset.py data/raw
swift run motion-sound-profile --gesture punch --kind burst --sound punch.wav
```

## 当前重点

1. 真机运行当前 Watch App 原型，采集真实 Apple Watch 传感器数据。
2. 先在 iPhone 上运行 `MotionSoundPhone`，再在 Apple Watch 上运行 `MotionSoundWatch`，验证 CSV/Profile 能通过 WatchConnectivity 传回 iPhone。
3. 用 iPhone 远程采集正样本、负样本和调试样本，并把 CSV 分享回 Mac 做离线分析。
4. 用 `motion-sound-profile` 从第一批正/负样本 CSV 生成 Watch 可加载的 Profile JSON。
5. 用第一批真机数据校准 burst gate 的峰值、方向和时长参数。
6. 参考 MotionTracker、FormFitWatch、k-angama/MotionTracking 建立采集、标注、CSV、Watch-to-phone transfer baseline。
7. 参考 MotionMusicPlayer 建立窗口特征和离线评估 baseline。
8. 用真实样本调 Ring Buffer、Motion Energy、Auto Segmenter 参数。
9. 在真机上验证标准 3 样本 Profile 的模板质量、阈值和 margin。
10. 用真实负样本校准误触风险。
11. 在 iPhone app 选择 Profile JSON 发送到 Watch，验证 checksum、Profile 解码、本地保存和识别器刷新。
12. 在 iPhone app 选择音频发送到 Watch，验证 checksum、本地保存、Watch 端预加载和低延迟播放。
13. 再考虑手机端管理、精准模式和联机。

开源项目借鉴清单见 [docs/open-source-reference-review.md](docs/open-source-reference-review.md)。
