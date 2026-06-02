# MotionSound 下一阶段产品方案

## 当前新基线

Watch 已经能本地播放声音，说明基础链路成立：

```text
iPhone 录制/管理
-> Profile + 音频同步到 Watch
-> Watch 本地识别动作
-> Watch 本地播放音效 + 震动反馈
```

接下来不要继续扩大调试 UI。主线应该切成两层：

- 用户层：动作列表、创建动作、选择声音、测试、开始监听。
- 诊断层：连接状态、采样点、识别候选、距离、阈值、音频路由、触发日志。

用户层必须简单，诊断层必须完整。

## 测试音效库

第一批测试素材使用合法免费来源，不抓取影视、动漫、游戏或特摄的原版音频。原版“奥特曼变身”或特定角色语音即使只是测试，也不适合直接放进项目或 App 包里。可以用以下替代类型做真实测试：

- 挥拳/打击：punch、impact、air hit。
- 转腕/挥舞：whoosh、sweep、sword whoosh。
- 变身/能量：power up、sci-fi power、technology transition。
- 成功/提示：correct tone、level complete、notification。
- 训练鼓励：先用提示音/成功音占位，后续支持用户自录或导入真人鼓励语音。

已下载到本机测试目录：

```text
/Users/zhongsuhua/Downloads/MotionSoundTestAudio
```

并已复制到 iPhone App 的 Documents 根目录：

```text
com.zhongsuhua.MotionSoundPhone/Documents
```

当前测试文件：

- `punch-fast.wav`
- `air-hit.wav`
- `whoosh-fast.wav`
- `whoosh-rocket.wav`
- `sword-whoosh.wav`
- `power-up-electronics.wav`
- `power-up-static.wav`
- `sci-fi-power.wav`
- `game-power-up.wav`
- `correct-tone.wav`
- `level-complete.wav`

素材来源记录在：

```text
/Users/zhongsuhua/Downloads/MotionSoundTestAudio/SOURCES.json
```

来源优先级：

- Mixkit：优先，页面可解析 `.wav` 下载地址，适合快速测试。
- Pixabay：适合找更多 MP3，但下载通常更适合用户手动或 API key。
- Freesound：音效多，但 license 分散，需要逐个检查 CC 条款。
- OpenGameArt：适合游戏音效，但每个资源 license 不同，不能混用不记来源。

## 音频格式策略

产品层支持用户导入：

- `wav`
- `mp3`
- `m4a`
- `aac`
- `caf`
- `aiff` / `aif`

Watch 端已经按后缀接受这些格式。后续要补两件事：

1. iPhone 导入后做 `AVURLAsset` 校验：可解码、时长、文件大小、是否静音。
2. 同步前可选转码：为了 Watch 稳定，统一转为短 `m4a/aac` 或标准 WAV。

用户不需要知道格式细节。UI 只显示“可以播放 / 文件太长 / 文件无法解码 / 已同步到 Watch”。

## UI 简化

### iPhone 首页

首页只做动作管理：

```text
我的动作
├── 新建动作
├── 动作卡片
│   ├── 动作名
│   ├── 绑定音效
│   ├── 最近触发/触发次数
│   ├── 测试
│   └── 更多：编辑、重命名、重新录制、删除、复制、同步
└── 设置/日志入口
```

不在首页显示：

- WatchConnectivity activation state。
- CSV 文件名。
- 样本角色。
- 阈值、margin、distance。
- 音频路由和输出音量。

这些只放在诊断页。

### Watch 页面

Watch 只显示：

```text
MotionSound
正在监听 / 正在录制 / 等待设置
最近触发：动作名
触发次数：N
[测试音效]
```

录制时显示：

```text
正在录制
完成后在 iPhone 点结束
```

不显示采样点、profile 数、连接细节、音量百分比、候选识别摘要。Watch 是产品端，不是调试面板。

## 动作覆盖策略

用户可能想到的动作大致分五类，不应该用一个算法硬识别全部：

| 类型 | 用户例子 | 识别策略 | 播放时机 |
| --- | --- | --- | --- |
| 短促爆发 | 挥拳、下劈、甩腕、拍手势 | 峰值检测 + 短窗口模板匹配 + 能量/主轴 gate | 峰值附近 |
| 连续挥舞 | 画圈、转腕、扫剑、完整变身动作 | 自动分段 + 重采样 + DTW/KNN | 动作结束后 |
| 姿态保持 | 抬手、手腕朝上、举手保持 | gravity/attitude 稳定检测 + hold time | 保持达标后 |
| 组合动作 | 抬手 -> 转腕 -> 下劈 | 子动作状态机 + 超时 + 容错 | 最后一段完成 |
| 计数动作 | 深蹲、弯举、俯卧撑节奏、力量训练次数 | 周期检测 + rep counter + 音效序列 | 每次有效 rep |

当前重点应该先把 `短促爆发` 和 `连续挥舞` 做好。`姿态保持`、`组合动作`、`计数动作`作为第二阶段算法模块，不要混进一个阈值系统。

## 高级音效规则

高级功能不能限制成“第 1 次 A、第 2 次 B、第 3 次 C”。正确模型是“音效序列规则”：

```text
SoundSequenceRule
├── mode
│   ├── single
│   ├── orderedSequence
│   ├── randomNoRepeat
│   ├── loop
│   ├── countMilestone
│   └── comboStep
├── sounds[]
├── resetPolicy
│   ├── never
│   ├── afterSeconds
│   ├── afterMiss
│   └── afterSessionEnd
├── triggerWindowSeconds
├── maxSequenceLength
└── fallbackSound
```

### 场景 1：力量训练

用户录一个“弯举一次”的动作，然后绑定 15 个鼓励音：

```text
第 1 次：开始
第 2 次：很好
第 3 次：继续
...
第 15 次：完成
```

规则：

- 不限制长度，15、30、50 次都可以。
- 如果声音数量少于次数，可以循环或播放默认声音。
- 可以设置 `30 秒内没有下一次则重置计数`。
- 每次 rep 都保存触发日志，方便看漏计/误计。

### 场景 2：连续挥拳趣味音效

用户每次挥拳都播放不同打击音：

```text
punch-fast -> air-hit -> punch-impact -> random whoosh
```

规则：

- `randomNoRepeat` 避免连续两次同一个声音。
- `cooldownSeconds` 防止一次挥拳触发多次。
- 若动作频率很高，允许只震动不播放或缩短声音。

### 场景 3：变身动作

一个完整动作绑定多段声音：

```text
抬手：启动音
转腕：能量蓄力
下劈：完成音
```

这不是单个动作反复计数，而是 `comboStep`。每个子动作都可以有自己的识别窗口、超时和声音。

## 趣味性设计

不要只做“识别后播放声音”，否则很快无聊。可加入：

- 动作连击：连续命中显示连击数。
- 训练模式：目标次数、倒计时、完成音。
- 随机音效包：同一动作随机播放一组相近音效。
- 进阶动作：完成一组 combo 才播放大音效。
- 失败反馈：做得太轻、太慢、方向不对时给一个轻提示。
- 个人音效库：收藏、标签、最近使用。
- 低延迟模式：短促动作优先抢速度。
- 稳定模式：复杂动作优先减少误触。

这些都是产品能力，但不能牺牲识别日志。每次触发都要能解释“为什么触发/为什么没触发”。

## 日志要求

后续复杂动作必须保留完整可追溯日志：

- 每次候选动作：开始/结束时间、duration、sampleCount。
- 识别特征：peak acceleration、peak rotation、energy shape、dominant axis。
- 匹配结果：best profile、distance、threshold、margin、second best。
- 触发结果：triggered、sound file、sequence index、audio played、haptic played。
- 用户反馈：正确、误触、漏触、重新录制。
- Watch 音频状态：文件是否存在、decode 是否成功、output volume、route。
- 同步状态：Profile 和音频 checksum、发送/接收时间。

iPhone 诊断页应该支持：

- 导出最近日志。
- 导出某个动作的训练样本。
- 导出最近 30 次触发/未触发候选。
- 一键复制给 Codex 排障。

## 下一批开发顺序

### 批次 A：产品面整理

1. iPhone 首页改成动作列表。
2. Watch 页面删掉调试显示，只保留状态、触发次数、测试音效。
3. iPhone 增加“诊断日志”入口，把调试信息集中进去。
4. 音频导入明确支持 MP3/WAV/M4A/AAC，并显示可播放性校验。
5. 已保存动作自动同步 Watch，不需要用户额外点同步。

### 批次 B：音效序列

1. 扩展 `SoundAsset` 为 `SoundPlaybackRule` 或新增 `SoundSequenceRule`。
2. Profile 保存多个音频和播放策略。
3. Watch 端根据触发次数选择当前音效。
4. iPhone 端支持添加/排序/删除多个音效。
5. 日志记录 sequence index 和 reset reason。

### 批次 C：复杂动作

1. posture：手腕朝向/保持类动作。
2. rep counter：力量训练计数动作。
3. combo：多个子动作组合。
4. 漏触反馈：从最近 buffer 选片段加入模板。
5. 每类动作独立测试集，不混用同一阈值。

### 批次 D：趣味和稳定性

1. 连击/训练目标/随机音效包。
2. 音频包管理。
3. 更好的动作质量提示。
4. 日志导出和回归测试脚本。
5. 功耗和长时间监听优化。

## 近期判断

现在最应该先做批次 A。Watch 已经能出声，继续堆算法前必须先让普通用户能顺畅完成：

```text
新建动作 -> 录制 -> 裁剪 -> 选音效 -> 保存 -> Watch 自动可用
```

等这个流程干净后，再做音效序列和复杂动作。否则复杂功能会被 UI、音频导入、同步状态这些基础问题拖住。
