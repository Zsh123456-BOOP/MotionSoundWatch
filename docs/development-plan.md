# Apple Watch 动作识别音效开发计划

## 产品定义

产品不是固定动作识别器，而是用户自定义动作音效触发器：

```text
用户录自己的动作
-> 绑定自己的声音
-> 保存为动作 Profile
-> Apple Watch 进入主动监听模式
-> 再做相似动作
-> Watch 本地低延迟播放对应声音
```

第一版目标是：用户可录制多个动作、每个动作绑定一个声音、Watch 本地识别与播放、尽量减少误触发、不依赖云端、不要求用户照着官方动作做。

MVP 不做通用大模型、不做全天后台监听、不先做联机。先证明真实手表能稳定采集动作、个人模板能区分常见动作、本地音频触发延迟可接受。

## 复用与参考原则

不要从零闭门实现所有模块。开发前先参考成熟项目和官方样例，但只复用适合 Watch 本地实时产品的部分。

更细的开源项目 review、license 边界和落地任务见 `docs/open-source-reference-review.md`。

| 来源 | 可借鉴点 | 不直接照搬的原因 | 本项目处理方式 |
| --- | --- | --- | --- |
| WatchShaker | watchOS 轻量加速度阈值、方向判断、灵敏度档位、冷却 delay | 只适合 shake/burst 粗检测，不支持用户多模板、负样本、DTW、音频 Profile | 借鉴 burst 预触发、灵敏度档位、方向特征，不作为完整识别器 |
| MotionMusicPlayer | Apple Watch 采集 IMU、CSV 导出、iPhone 接收、Python 特征提取、滑动窗口分类 | 依赖外部 Python/socket/离线模型，不适合 Watch 本地低延迟独立运行 | 借鉴数据采集字段、CSV 调试、窗口特征和 holdout 数据组织 |
| MotionTracker | Watch 采集原始 Core Motion，iPhone 端标注动作开始/结束，导出成配对 CSV | 偏研究数据采集，不是实时触发产品 | 借鉴“手表采集 + 手机标注 + 文件导出”的真机数据闭环 |
| FormFitWatch-DataCollector | Watch 端倒计时/armed recording、CSV 保存、WatchConnectivity session transfer、Core ML 管线 | 偏康/康复动作评分场景，模型和 UI 不直接适配 | 借鉴从手机发起采集、session 文件同步、离线训练数据组织 |
| k-angama/MotionTracking | Core Motion 字段完整，Watch 端采样，iPhone 端文件列表和 CSV export | 使用较旧 WatchKit 架构，且含 location/background 逻辑，不适合直接迁入 | 借鉴字段命名、CSV 导出、传输管理，不引入 location 依赖 |
| Apple WatchConnectivity 官方样例/文档 | iPhone/Watch application context、user info、file transfer | 只能提供同步机制，不解决动作识别 | 用于 Profile 和音频文件同步，真机验证 `transferFile` |
| Apple Core Motion 官方文档 | `CMMotionManager`、DeviceMotion、采样间隔、motion availability | 只提供传感器 API，不提供产品级 pipeline | 作为采集层基准，业务逻辑放在 `MotionSoundCore` |
| DTW/KNN 现有算法实现 | 距离归一化、窗口约束、重采样、KNN 聚合、负样本阈值 | Swift/watchOS 可直接用的维护良好库很少，引入依赖收益低 | 保持零依赖 Swift 实现，但按成熟 DTW 设计补窗口约束和测试 |

复用边界：

- 可以复用思想、参数范围、数据格式、测试方法。
- 不直接复制大段第三方源码，除非确认 license、维护状态和 watchOS 兼容性。
- Watch 端核心识别保持本地、轻量、可测试，不依赖 Python 服务、云端模型或 iPhone 实时回传。
- 开源项目只作为 baseline。最终准确率以我们自己的真机数据和负样本测试为准。

## iPhone 与 Watch 分工

```text
iPhone App
├── 创建动作与录制向导
├── 远程控制 Watch 开始 / 结束采集
├── 动作形态回放、能量时间轴、片段裁剪
├── 声音导入 / 波形预览 / 起点设置
├── 动作重命名、删除、排序
├── 识别严格度、冷却时间、触发时机设置
├── Profile 与音频同步到 Watch
├── 测试记录、误触记录查看
└── 后续联机入口

Apple Watch App
├── Core Motion 采集
├── 响应 iPhone 录制命令
├── 本地模板保存
├── 本地动作识别
├── 本地音频播放
├── Haptic 反馈
└── 主动监听模式
```

识别和声音播放必须尽量放在 Watch 本地完成。iPhone 负责管理、音频处理、同步和调试查看，不应在动作命中后临时从 iPhone 拉音频。

产品交互上，iPhone 是主控台，Watch 是低干扰采集和播放端。录制阶段不要要求用户点 Watch；Watch 页面只显示状态、当前动作名和必要提示。

## iPhone 主控录制向导

第一版 iPhone 应该做成五步向导，而不是调试面板：

```text
1. 创建动作
2. 录制动作
3. 裁剪动作片段
4. 配置声音
5. 保存并同步到 Watch
```

### 1. 创建动作

用户只需要填写动作名，并选择动作类型：

- 短促动作：挥拳、甩腕、下劈。
- 连续动作：转腕、完整挥舞、变身动作。
- 姿态动作：举手保持、手腕朝上。

高级参数如阈值、margin、采样率、CSV 文件名不在主流程显示。它们进入日志和开发者诊断入口。

### 2. 录制动作

```text
iPhone 点击开始
-> iPhone 显示 3 秒倒计时
-> Watch 震动提示
-> Watch 延迟 200ms-300ms 后开始采集
-> 用户做动作
-> iPhone 点击结束
-> Watch 停止采集并传回原始数据
```

用户只面对两个主要按钮：开始录制、结束录制。Watch 端不提供录制按钮，避免点击动作污染传感器数据。

录制完成后先显示“已收到动作数据”，再进入裁剪页。传输失败时只提示“没有收到手表数据，请重试”，详细 WatchConnectivity 状态写入日志。

### 3. 裁剪动作片段

裁剪页的目标是让用户快速选出真正的动作段，而不是看懂传感器数据。

页面结构：

- 顶部：动作形态回放，不承诺真实空间路径。
- 中部：动作能量时间轴，标出峰值和静止区。
- 底部：可拖动的开始 / 结束裁剪手柄。
- 底部主按钮：播放片段、使用这个片段、重新录制。

动作形态回放使用归一化数据：

```text
userAcceleration + rotationRate + gravity/attitude
-> timestamp 重采样
-> 坐标归一化
-> 能量曲线
-> 简化 2D/3D 轨迹
```

不要把加速度积分后的路径当作真实位移展示。产品文案使用“动作形态”“动作轨迹回放”“动作节奏”，不使用“真实空间轨迹”。

推荐复用：

- Swift Charts：动作能量时间轴。
- SceneKit：轻量 3D 动作形态回放。
- SceneKit-SCNLine：可选，用于更好看的轨迹线。
- CompactSlider：可选，用于 range trim 手柄。

### 4. 配置声音

第一版先支持从 iPhone 文件导入音频。后续再做录音和音效库。

声音配置项：

- 音频文件。
- 播放起点。
- 音量。
- 触发时机：动作峰值附近 / 动作结束后。
- 冷却时间。

推荐复用：

- `AVFoundation`：播放、预加载、音量、文件校验。
- DSWaveformImage：音频波形、播放进度、声音起点预览。

MVP 不引入 AudioKit。等需要手机录音、音效处理、混响、变声或更复杂的音频分析时再评估。

### 5. 保存并同步

保存时 iPhone 生成 Profile：

```text
动作名
动作类型
裁剪后的模板
采样率和时间戳
质量评分
阈值和 margin
冷却时间
音频文件元信息
checksum
版本号
```

同步到 Watch 后，Watch 做本地校验：

```text
Profile JSON 可解码
模板数量足够
音频文件存在
checksum 正确
播放器可 prepareToPlay
```

同步成功后，用户看到“已同步到手表，可以开始监听”。失败时给出可执行提示，详细错误写入本地日志。

## 动作类型

第一版先支持两类，后续扩展到四类：

| 类型 | 例子 | 识别方式 | 声音触发时机 | 优先级 |
| --- | --- | --- | --- | --- |
| burst | 挥拳、甩腕、下劈 | 峰值检测 + 短窗口模板匹配 | 峰值附近，允许 100ms-200ms 确认 | MVP |
| sequence | 转腕、完整挥舞、变身动作 | 自动裁剪 + 重采样 + DTW/KNN | 动作结束后 | MVP |
| posture | 举手保持、手腕朝上 | gravity/attitude 稳定检测 | 保持达到阈值后 | 第二阶段 |
| combo | 左挥 -> 转腕 -> 下劈 | 子动作状态机 | 最后一段完成后 | 第二阶段 |

不要用一个算法识别所有动作。短促挥拳需要低延迟，长序列动作需要等片段完整，姿态动作更像条件判断，组合动作需要状态机。

## 录制流程

录制时不要让点击手表按钮污染动作数据。推荐流程：

```text
点击开始
-> 3、2、1 倒计时
-> Watch 震动提示
-> 延迟 200ms-300ms 后正式采集
-> 用户做动作
-> 系统自动裁剪
-> 录制完成
```

也可以从 iPhone 发起录制，让 Watch 只负责震动和采集。

录制模式：

- 快速模式：录 1 次，可保存，但标记低可靠。
- 标准模式：录 3 次。
- 精准模式：录 5-8 次 + 负样本校准。

时长不是硬限制，只做质量提示：

- `< 0.2s`：可能是噪声，只适合极强 burst。
- `0.2s-0.8s`：适合挥拳、甩腕、下劈。
- `0.8s-4s`：适合普通自定义动作、转腕、变身动作。
- `4s-8s`：可以保存，但建议拆成 combo。
- `> 8s`：不建议做成单个动作。

## 负样本校准

每个正式动作都应有“不要做目标动作”的校准：

```text
请随便活动 10 秒，但不要做刚才录的动作。
例如抬手、转手腕、走两步、自然晃动。
```

负样本用于学习用户日常动作、识别容易混淆的动作、自动设置每个动作的阈值和严格度。如果动作和日常动作太像，系统应提示提高严格度、重新录制或换一个动作。

## Watch 采集数据

每帧保存：

```text
timestamp
userAcceleration.x/y/z
rotationRate.x/y/z
gravity.x/y/z
attitude quaternion
```

采样建议：

- 录制模式：50Hz-100Hz。
- 监听 idle：25Hz-50Hz。
- 候选动作出现后：临时提高到 75Hz-100Hz。

实现上不能假设固定帧间隔，必须使用 timestamp 重采样。

## 坐标系与佩戴上下文

Apple Watch 原始坐标会受左手/右手、表冠方向、表带松紧、内外侧佩戴、坐姿站姿、初始姿势影响。

每个 Profile 保存 `WearContext`：佩戴手腕、表冠方向、Watch 型号、系统版本。

第一版策略：

- 保存录制时的佩戴手腕和表冠方向。
- 监听时如果佩戴方式变化，提示准确率可能下降。
- 允许快速重新校准。
- 不承诺左右手通用。

后续可做 gravity 坐标归一化、方向无关特征、左右手镜像兼容。

## 识别 Pipeline

```text
Core Motion Stream
-> Ring Buffer
-> Motion Energy
-> Segmenter 候选动作切片
-> Gesture Kind 判断
-> Feature Gate 候选过滤
-> Profile Matcher
-> Threshold + Margin + Cooldown
-> Audio/Haptic Trigger
-> Log 记录
```

Ring Buffer：

- burst：最近 1.5s。
- sequence：最近 5s-8s。
- combo：最近 10s。

Motion Energy：

```text
accMag = sqrt(ax^2 + ay^2 + az^2)
gyroMag = sqrt(gx^2 + gy^2 + gz^2)
jerkMag = abs(accMag[t] - accMag[t-1]) / dt
motionEnergy = accMag + 0.25 * gyroMag + 0.1 * jerkMag
```

Segmenter 状态机：

```text
idle -> candidateStarted -> activeGesture -> maybeEnding -> finalized -> matching -> cooldown
```

## 匹配与阈值

每个动作独立阈值，不使用全局 `distance < x`。

阈值来自：

- 正样本内部两两距离。
- 负样本到该动作模板的距离。
- 与其他动作的相似度。

触发必须同时满足：

- `bestDistance < profile.threshold`
- `secondBestDistance - bestDistance > profile.marginThreshold`
- 动作类型匹配。
- 当前片段持续时间和能量合理。
- 当前动作不在 cooldown。

如果第一名和第二名很接近，说明系统分不清，应不触发，而不是强行播放最像的声音。

## 音频与 Haptic

Watch 进入监听模式前：

```text
1. 检查 Profile 是否完整
2. 检查音频文件是否存在
3. 校验 checksum
4. 初始化播放器
5. prepareToPlay()
6. 开始 Core Motion 监听
```

触发时机：

- burst：peak 附近触发，可延迟 100ms-200ms 确认。
- sequence：动作结束后触发。
- posture：保持时间达标后触发。
- combo：最后一个子动作达标后触发。

音频必须已同步到 Watch 本地。断开 iPhone 后，Watch 仍应能播放已同步音效。

## 主动监听与电量

MVP 使用主动监听模式：

```text
用户打开 App -> 点击开始监听 -> App 在监听模式运行 -> 用户退出后停止监听
```

不要第一版承诺全天后台监听，也不要把 App 伪装成 workout app。

电量策略：

- idle 低频采样。
- 候选动作出现后临时提高采样率。
- 触发后进入 cooldown。
- 长时间无动作降低频率。
- 低电量时提示降低灵敏度。
- 用户退出监听时立即 `stopDeviceMotionUpdates()`。

Extended Runtime Session 放到稳定性阶段验证，不作为 MVP 前提。

## 误触与漏触反馈

每次触发后短暂显示：

```text
播放了：拳击音效
[正确] [不是这个动作]
```

用户点击“不是这个动作”：

```text
1. 保存刚才触发片段
2. 加入该动作 negativeTemplates
3. 重新计算 threshold 和 margin
4. 经常误触时自动提高 strictness
```

漏识别时：

```text
动作详情页 -> 刚才我做了这个动作但没识别 -> 从最近 buffer 选择片段 -> 加入 pending positive -> 用户确认后加入模板
```

不要自动把每次成功触发都加入正样本，必须人工确认，避免越学越坏。

## 日志与指标

每次候选动作记录：

```text
timestamp
gestureKindDetected
duration
peakAcc
peakGyro
bestProfileId
bestDistance
secondBestDistance
threshold
margin
triggered
audioPlayed
batteryLevel
wristLocation
crownOrientation
```

MVP 指标：

- false triggers / hour
- missed triggers / 20 attempts
- trigger latency
- audio start latency
- battery drain during 10 min listening
- profile creation success rate
- 用户是否能理解动作质量低的原因

## MVP 阶段

### 阶段 0：技术验证

目标：确认真实 Apple Watch 数据能区分典型动作。

任务：

- 拉取和阅读参考项目，只保留适合本项目的采集、阈值、窗口、同步思路。
- 建立参考基线：WatchShaker 式加速度阈值、MotionTracker/FormFit 式采集标注、MotionMusicPlayer 式滑动窗口特征、本项目 DTW 模板匹配。
- Watch 端采集 Core Motion。
- 保存 CSV/JSON。
- iPhone 或 Mac 导出。
- 用 Swift 或 Python 画曲线。
- 采集空挥拳、甩腕、转腕一圈、抬手看表、走路摆臂、随机晃动。

验收：

- 同一动作曲线形态相似。
- 不同动作距离明显不同。
- 抬手看表不会轻易匹配到挥拳。

### 阶段 1：动作录制器

iPhone 端：

- 五步向导骨架：创建动作、录制、裁剪、配音、同步。
- 从 iPhone 发起开始 / 结束录制。
- 倒计时和 Watch 震动提示。
- 接收 Watch 原始动作数据。
- 动作能量时间轴。
- 手动裁剪开始 / 结束片段。
- 基础动作形态回放。

Watch 端：

- 接收 iPhone 录制命令。
- Core Motion 采集。
- 停止后保存原始样本并传回 iPhone。
- 只显示状态，不显示调试数据。

此阶段先不做实时识别，先保证录制数据干净。

### 阶段 2：音频管理和同步

iPhone 端：导入音频、波形预览、设置声音起点、设置音量、绑定动作、同步到 Watch。

Watch 端：接收音频文件、校验 checksum、本地保存、预加载、手动测试播放。

验收：断开 iPhone 后 Watch 仍能播放已同步音效。

### 阶段 3：burst 识别

实现 motion energy、peak 检测、peak window 截取、feature gate、短窗口 DTW/correlation、threshold + margin、cooldown、音效播放。

验收：空挥拳快速触发，普通抬手看表和随机轻微晃动不触发，连续挥拳不会连播失控。

### 阶段 4：sequence 识别

实现动作开始/结束检测、自动裁剪、重采样、多模板 DTW/KNN、冲突检测、动作结束后播放。

验收：同一动作快做慢做都能识别，相似动作不会随便混淆，普通走路摆臂不触发。

### 阶段 5：精准模式

加入负样本校准、动作质量评分、误触反馈、漏触反馈、自动阈值调整、每动作独立 strictness。这是从 demo 变成可用产品的关键阶段。

### 阶段 6：后台、功耗和稳定性

处理主动监听模式、Extended Runtime Session 探索、低电量策略、采样频率自适应、音频预加载、日志压缩、崩溃恢复。

### 阶段 7：联机功能

只同步事件，不同步原始 IMU：

```json
{
  "userId": "u123",
  "gestureId": "g456",
  "gestureName": "挥拳",
  "soundId": "s789",
  "confidence": 0.91,
  "timestamp": 1760000000.123
}
```

原始运动数据默认留在本地。上传调试数据必须明确征得用户同意。

## 模块划分

```text
Watch App
├── MotionService
│   ├── CoreMotionManagerWrapper
│   ├── RingBuffer
│   └── MotionSample
├── GestureRecording
│   ├── RecorderStateMachine
│   ├── AutoSegmenter
│   ├── TemplateBuilder
│   └── QualityEvaluator
├── GestureRecognition
│   ├── MotionEnergyDetector
│   ├── BurstMatcher
│   ├── SequenceMatcher
│   ├── PoseMatcher
│   ├── ConflictChecker
│   └── ThresholdEngine
├── Audio
│   ├── SoundAssetStore
│   ├── AudioPreloader
│   └── SoundPlayer
├── Sync
│   ├── WatchConnectivityClient
│   ├── ProfileSync
│   └── AudioFileSync
└── Diagnostics
    ├── RecognitionLogStore
    ├── FalseTriggerStore
    └── DebugExporter
```

## 当前实现状态

下一阶段产品、测试音效、UI 简化、音效序列和复杂动作规划见 `docs/next-stage-product-plan.md`。

已完成：

- `MotionSoundCore` Swift Package。
- 核心模型：`MotionSample`、`MotionTemplate`、`GestureProfile`、`WearContext`、`SoundAsset`。
- Ring Buffer、Motion Energy、流式 Segmenter。
- TemplateBuilder、QualityEvaluator、ProfileBuilder、ProfileArchive JSON 编解码。
- GestureProfileFileStore 本地 JSON 文件保存、读取、列表、删除。
- GestureRecognitionRuntime 根据已保存 Profile 做实时识别、冷却控制和日志记录。
- GestureFeedbackEngine 可把误触片段加入目标动作负样本并重算阈值。
- 多模板 DTW/KNN 基础匹配。
- 每动作独立阈值与 margin 字段。
- 负样本校准接口。
- 冷却控制。
- Burst gate 粗筛：对 burst 动作先检查峰值加速度、最长时长和主轴方向，避免弱抖动或方向明显不对的动作进入 DTW/KNN。
- 识别日志 `RecognitionLogEntry`。
- Watch 端采集和音频播放原型源码。
- Watch 原型支持导出单次模板 JSON、导出/保存原始 Motion CSV、快速 Profile JSON、标准 3 正样本 + 负样本 Profile、保存 Profile 到本地 Documents、WatchConnectivity 文件发送队列、接收 iPhone 同步音频、checksum 校验、本地保存音频、预加载 Profile 绑定音频、burst gate + 已保存 Profile 实时匹配，并通过“不是这个动作”把误触加入负样本。
- iPhone 原型 target `MotionSoundPhone` 支持接收 Watch `transferFile` 发送的 CSV/Profile 文件，并保存到 `MotionSoundIncoming/`；同时支持选择音频文件和 Profile JSON，通过 `transferFile` + checksum 同步到 Watch，并支持从 iPhone 发起 Watch 开始/停止录制命令。远程采集可标记正样本、负样本或调试样本，停止命令可要求 Watch 自动保存带样本类型的 CSV 并传回 iPhone，iPhone 文件列表可直接分享 CSV，减少点 Watch 按钮带来的动作污染。实时命令有即时回执，Watch 执行后还会回传 `recordingStatus`，用于在 iPhone 上确认实际录制状态、样本数和 CSV 队列文件名。Watch 接收 Profile JSON 时会校验 checksum、解码确认 Profile 合法、保存到 `GestureProfiles/`，然后刷新本地识别器。
- Watch target 已声明 `WKCompanionAppBundleIdentifier = com.zhongsuhua.MotionSoundPhone`，并保留 `WKRunsIndependentlyOfCompanionApp = true`，用于真实配对 iPhone + Apple Watch 的 WatchConnectivity 验证。
- MotionSampleCSVCodec 和 MotionRecordingFileStore 已提供稳定 CSV 字段和 `MotionRecordings/` 本地保存，便于和 MotionTracker/FormFit/MotionMusicPlayer 的数据管线对齐。
- 单元测试。
- 初步开源参考调研：WatchShaker 用于 burst baseline，MotionTracker/FormFitWatch/k-angama MotionTracking 用于采集、标注、CSV、同步 baseline，MotionMusicPlayer 用于窗口特征和离线分类 baseline，Swift-DTW-KNN 只作为 DTW/KNN 结构参考，Apple 官方文档用于 Core Motion 与 WatchConnectivity 边界。

下一步：

1. 把 iPhone 原型改成五步向导，不再把调试字段放在主页面。
2. 把 Watch 原型改成纯状态页，只响应 iPhone 命令采集和同步。
3. 真机验证 iPhone 点击开始、倒计时、Watch 震动、Watch 采集、iPhone 点击结束、数据传回。
4. 接入 Swift Charts 能量时间轴，支持拖动裁剪开始 / 结束。
5. 接入 SceneKit 动作形态回放，先做归一化轨迹和当前播放点。
6. 接入 DSWaveformImage，完成音频波形、播放进度和声音起点设置。
7. 生成裁剪后的 Profile，并同步 Profile + 音频到 Watch。
8. 用第一批真机数据校准 burst gate：`minimumPeakAcceleration`、`maximumDuration`、主轴方向容忍度和冷却 delay。
9. 增加 MotionTracker/FormFit baseline：从手机发起采集、Watch 保存 CSV、传回 iPhone/Mac、动作开始结束标注，并按 `positive`、`negative`、`debug` 样本类型整理数据。
10. 增加 MotionMusicPlayer baseline：固定窗口特征导出和离线评估脚本，用来对比 DTW 模板匹配。
11. 用真实样本调 `startEnergyThreshold`、`endEnergyThreshold`、pre-roll 和 post-roll。
12. 在真机上验证标准录制模式：每个动作 3 次正样本 + 日常负样本 + 自动质量评分。
13. 真机验证 Watch 本地预加载和触发播放延迟。
14. 记录 Xcode 模拟器 runtime 下载状态；当前可先用真机，不阻塞采集和播放验证。
