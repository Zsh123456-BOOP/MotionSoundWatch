# 开源参考 Review

本项目不应该闭门从零实现所有模块。下面这些项目只作为产品和工程 baseline：优先复用思路、参数范围、数据格式和测试方法；除非 license 清楚且确实有必要，不复制源码。

## 参考项目

| 项目 | 当前判断 | 可借鉴点 | 本项目落地 |
| --- | --- | --- | --- |
| [ezefranca/WatchShaker](https://github.com/ezefranca/WatchShaker) | MIT license，watchOS 7+，Xcode 15+，定位是 Apple Watch shake 检测 | 灵敏度档位、方向枚举、触发 delay、轻量 Core Motion 包装 | 已转化为 `MotionBurstGate`：峰值加速度、最长时长、主轴方向、burst-only gate |
| [alinachen8/MotionMusicPlayer](https://github.com/alinachen8/MotionMusicPlayer) | 未看到明确 license，不能复制源码 | Watch 采集 motion data、iPhone 音乐/音频体验、Python 特征提取、gesture 数据目录 | 只借数据闭环：CSV、窗口特征、离线评估脚本；Watch 端识别仍保持本地 Swift |
| [Saavan07/FormFitWatch-DataCollector](https://github.com/Saavan07/FormFitWatch-DataCollector) | 未看到明确 license，不能复制源码 | Watch `CMDeviceMotion` 采集、iPhone companion、WatchConnectivity session/file transfer、CSV 数据组织、PyTorch 到 Core ML 管线 | 已借 Watch-to-phone 文件同步和 CSV 保存思路；后续借 split-rep 数据组织和离线评估 |
| [mmahler2/Swift-DTW-KNN](https://github.com/mmahler2/Swift-DTW-KNN) | 未看到明确 license，不能复制源码 | KNN + DTW 的基本结构、曲线距离分类 demo | 只借算法结构；本项目保留零依赖 Swift 实现，并加 watchOS 侧测试 |

## UI 与音频复用 Review

用户体验层不要从零画所有控件，但也不要为了一个 MVP 引入过重框架。当前工程目标是 iOS 17 + watchOS 10，因此优先选择系统框架或兼容这些版本的 Swift Package。

| 项目 / 框架 | 当前判断 | 可借鉴点 | 本项目落地 |
| --- | --- | --- | --- |
| [Apple Swift Charts](https://developer.apple.com/documentation/charts) | 系统框架，适合 iPhone 端数据图 | 动作能量曲线、加速度/陀螺仪简化曲线、裁剪时间轴背景 | 优先用于 2D 时间轴和质量解释，不额外引入图表库 |
| [Apple SceneKit](https://developer.apple.com/documentation/scenekit) | 系统 3D 框架，iPhone 端足够使用 | 归一化动作形态回放、旋转姿态预览、简单 3D path | 用 `SCNView`/SwiftUI wrapper 做轻量 3D，不做 AR、不做人体骨架 |
| [maxxfrazer/SceneKit-SCNLine](https://github.com/maxxfrazer/SceneKit-SCNLine) | MIT license，轻量 SceneKit thick line package | 轨迹线段、当前播放点、动作方向尾迹 | 可作为可选依赖；若引入，只放 iPhone target，不进 Watch target |
| [dmrschmidt/DSWaveformImage](https://github.com/dmrschmidt/DSWaveformImage) | MIT license，SPM，SwiftUI/UIKit，音频波形成熟 | 音频波形、播放进度遮罩、声音起点预览 | 推荐用于 iPhone 音效配置页，避免自研 waveform renderer |
| [buh/CompactSlider](https://github.com/buh/CompactSlider) | MIT license，SwiftUI slider，支持 range selection | 动作裁剪区间、音频起点/音量滑块 | 可先试用于 range trim；若产品交互需要波形/能量图叠加，再做轻量自定义 overlay |
| [AudioKit/AudioKit](https://github.com/AudioKit/AudioKit) | MIT license，成熟但偏重，主要面向 iOS/macOS/tvOS 音频处理 | 后续录音、电平、效果器、复杂音频分析 | MVP 不引入；第一版用 `AVFoundation` + `DSWaveformImage`，等需要录音/效果器再评估 |

## 3D 动作展示边界

不要寻找或引入“把 Watch IMU 直接变成真实 3D 运动轨迹”的库。Apple Watch 的 Core Motion 数据适合描述姿态、旋转、加速度和动作形态，不适合稳定恢复厘米级空间位移；直接积分加速度会快速漂移。

产品上应叫“动作形态”或“动作轨迹回放”，不要承诺真实空间路径。推荐展示三层：

1. 2D 动作能量时间轴：帮助用户找开始和结束。
2. 简化 3D 归一化轨迹：帮助用户理解动作方向和节奏。
3. 姿态小模型或方向箭头：帮助用户确认挥动方向、转腕和峰值点。

## 不采用的方式

- 不把没有明确 license 的代码直接拖进工程。
- 不把 MotionMusicPlayer 的 socket/Python 在线链路放进 Watch 实时识别。
- 不先做 FormFit 类 1D CNN/Core ML 训练，除非真机样本证明模板匹配不足。
- 不用 WatchShaker 直接替代识别器；它只适合 burst 预筛，不适合用户自定义多动作。
- 不为了裁剪页引入 ARKit、人体姿态、点云或大型 3D SDK。
- 不把 AudioKit 作为 MVP 前提；普通音效导入、波形和播放用更轻的方案。

## 下一步可复用任务

1. 已增加第一版 MotionMusicPlayer 风格的离线 CSV 分析脚本：`tools/analyze_motion_csv.py`。
2. 已增加 FormFit 风格的数据目录说明：`data/raw/<gesture>/<session>.csv`、`data/splits/`、`data/reports/`。
3. 给 `MotionBurstGate` 增加灵敏度档位：low、normal、high，对应不同峰值和方向容忍度。
4. 给 iPhone companion 增加采集任务发起能力，减少点 Watch 按钮带来的动作污染。
5. 给 iPhone 裁剪页接入 Swift Charts 能量时间轴，并评估 CompactSlider 是否适合作为区间选择控件。
6. 给 iPhone 音效页接入 DSWaveformImage，先完成本地音频波形、播放进度和声音起点设置。
7. 给 iPhone 动作回放页用 SceneKit + 可选 SCNLine 做归一化动作形态回放。
