# 豆包流式 ASR 接入设计

Date: 2026-04-30  
Project: lightwhisper

## 1. 背景与问题

当前项目中的语音识别实现依赖系统 `speech_to_text` 能力，存在两个限制：

- 识别链路依赖设备侧系统识别器，无法统一云端模型能力。
- 现有长按说话交互拿不到底层 PCM 流，无法按火山引擎大模型流式 ASR 的 WebSocket 协议接入。

本次要将连续对话场景的 ASR 能力切换为火山引擎（豆包）大模型流式识别，并统一使用自定义二进制协议上传音频。

## 2. 目标与非目标

### 2.1 目标

- 在 Flutter 侧建立豆包 ASR WebSocket 长连接。
- 使用 `record` 采集 Android 麦克风 PCM 流，参数固定为 16000Hz / 16bit / mono。
- 严格按大端序发送三类请求包：首包配置、音频包、结束包。
- 解析服务端返回的二进制帧，提取 `result.text` 与 `result.utterances`。
- 同时支持中间结果与最终结果回调，并做去重，避免 UI 抖动。
- 完全移除 `speech_to_text` 路径，统一改走新的云端 ASR 服务。
- 保持现有 `ContinuousChatScreen` 长按说话交互基本不变。

### 2.2 非目标

- 本期只支持 Android，不覆盖 iOS 和桌面端。
- 不实现自动重连或后台持续识别。
- 不改造连续对话页面的交互布局。
- 不扩展到视觉页或其他未使用 `SpeechService` 的场景。

## 3. 方案选择

采用 A 方案：新增底层 `AsrService`，并保留 `SpeechService` 作为轻量适配层。

推荐原因：

- 满足新增 `lib/services/asr_service.dart` 的结构要求。
- 让 WebSocket、录音流、二进制协议、回包聚合都收口在一个底层服务中。
- 让 `lib/screens/continuous_chat_screen.dart` 继续依赖 `SpeechService`，避免页面直接感知协议细节。
- 便于后续在其他页面复用相同 ASR 能力，而不把状态机散落在 UI 中。

不采用直接让页面依赖 `AsrService` 的方案，因为会把协议与会话状态处理暴露给页面层。

不采用把所有逻辑继续塞在 `SpeechService` 的方案，因为会混合底层传输逻辑与上层兼容接口，后续维护成本更高。

## 4. 架构与组件边界

### 4.1 新增组件：`lib/services/asr_service.dart`

新增单例 `AsrService`，作为豆包流式 ASR 的唯一底层入口。

建议公开接口：

- `Future<void> startRecording(Function(String text, bool isDefinite) onResult)`
- `Future<String> stopRecording()`
- `Future<void> cancelRecording()`
- `bool get isRecording`

职责边界：

- 校验 `.env` 中的 `ASR_API_KEY` 与 `ASR_API_RESOURCE_ID`
- 请求并检查 Android 麦克风权限
- 建立 WebSocket 长连接并附带握手 headers
- 发送首包配置
- 启动 PCM 流录音并持续发送音频包
- 解析服务端返回的二进制消息
- 聚合中间结果与最终结果
- 结束时清理录音流、消息订阅与连接状态

### 4.2 改造组件：`lib/services/speech_service.dart`

`SpeechService` 保留为兼容层，但内部不再依赖 `speech_to_text`。

保留现有页面已使用的方法名：

- `ensurePermissionAndInitStatus()`
- `startListening({required ValueChanged<String> onText})`
- `stopListeningAndGetFinalText()`
- `cancelListening()`

内部全部委托给 `AsrService.instance`。

### 4.3 页面边界

`lib/screens/continuous_chat_screen.dart` 继续通过 `SpeechService` 使用 ASR，不直接依赖 WebSocket 或协议实现。

页面保留现有职责：

- 长按开始/结束录音
- 显示当前识别文本
- 结束后将最终问题文本发送给 `DoubaoApiService`
- 负责错误播报与页面状态切换

## 5. 配置与依赖改动

### 5.1 `pubspec.yaml`

新增依赖：

- `record`
- `web_socket_channel`
- `uuid`

移除依赖：

- `speech_to_text`

### 5.2 环境变量

从 `dotenv` 中读取：

- `ASR_API_KEY`
- `ASR_API_RESOURCE_ID`

若任一缺失，`AsrService.startRecording()` 直接抛出异常，错误文案明确指出 `.env` 配置缺失。

## 6. WebSocket 握手与请求协议

### 6.1 连接地址

固定使用：

- `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async`

### 6.2 握手 Header

建立 WebSocket 时必须包含：

- `X-Api-Key`
- `X-Api-Resource-Id`
- `X-Api-Request-Id`：使用 `Uuid().v4()` 生成
- `X-Api-Sequence`：固定为 `-1`

### 6.3 客户端发包格式

所有发送给服务端的数据包统一为：

- `Header(4字节) + Payload Size(4字节) + Payload`

`Payload Size` 必须使用 Big Endian 大端序。

统一封装方法：

```dart
Uint8List _packData(List<int> header, List<int> payload) {
  final ByteData bd = ByteData(4);
  bd.setUint32(0, payload.length, Endian.big);
  final sizeBytes = bd.buffer.asUint8List();
  return Uint8List.fromList([...header, ...sizeBytes, ...payload]);
}
```

### 6.4 三类客户端请求

#### A. Full Client Request

- Header: `[0x11, 0x10, 0x10, 0x00]`
- Payload: UTF-8 编码 JSON 字符串

Payload 结构：

- `user.uid`
- `audio.format = "pcm"`
- `audio.rate = 16000`
- `audio.bits = 16`
- `audio.channel = 1`
- `audio.language = "zh-CN"`
- `request.model_name = "bigmodel"`
- `request.enable_ddc = true`

该包在 WebSocket 建立成功后立即发送，且必须早于任何音频包。

#### B. Audio Only Request

- Header: `[0x11, 0x20, 0x00, 0x00]`
- Payload: 录音采集到的原始 PCM 字节流

每收到一段录音字节流，就封装为一个音频包并立即发送。

#### C. Last Audio Request

- Header: `[0x11, 0x22, 0x00, 0x00]`
- Payload: 空字节数组

在用户松手结束录音时发送，作为结束包。

## 7. 录音流设计

### 7.1 录音方式

Android 端使用 `record` 的流式录音能力，不落盘。

录音参数固定为：

- `encoder: AudioEncoder.pcm16bits`
- `sampleRate: 16000`
- `numChannels: 1`

这样采集得到的字节流可直接作为 PCM Payload 上传，无需转码。

### 7.2 启动时序

`startRecording()` 的顺序固定为：

1. 校验环境变量
2. 检查并请求麦克风权限
3. 建立 WebSocket 连接
4. 发送 Full Client Request
5. 启动 `record.startStream()`
6. 订阅字节流并持续发送 Audio Only Request
7. 监听服务端回包并解析识别结果

如发现上一轮会话未清干净，应先强制清理，再启动新一轮会话，避免并发录音与并发连接。

## 8. 服务端回包解析设计

### 8.1 回包格式

服务端返回格式为：

- `Header(4字节) + Sequence(4字节) + Payload Size(4字节) + Payload`

解析时跳过前 12 字节，再读取 Payload。

### 8.2 Payload 解析步骤

1. 将消息转换为 `Uint8List`
2. 若长度小于 12，视为无效帧并忽略
3. 取 `bytes.sublist(12)` 作为 Payload
4. 使用 UTF-8 解码为字符串
5. 对字符串执行 `jsonDecode`
6. 从 JSON 中提取 `result.text` 与 `result.utterances`

### 8.3 目标字段

重点解析以下字段：

- `result`
- `result.text`
- `result.utterances`
- `result.utterances[i].text`
- `result.utterances[i].definite`

语义约定：

- `definite == false`：当前分句仍在识别中，属于中间文本
- `definite == true`：当前分句已识别完成，属于最终文本

## 9. 结果聚合与回调策略

### 9.1 内部状态缓存

`AsrService` 内部维护以下缓存：

- `_committedText`：已经确定的稳定文本
- `_liveText`：当前未完成分句的中间文本
- `_finalText`：最近一次 `result.text` 返回的完整文本
- `_lastCallbackText` 与 `_lastCallbackDefinite`：用于防止重复回调

### 9.2 回调策略

对外回调使用：

- `onResult(String text, bool isDefinite)`

处理原则：

- 收到 `definite == false` 的 utterance 时，回调当前分句文本，`isDefinite = false`
- 收到 `definite == true` 的 utterance 时，回调当前分句文本，`isDefinite = true`
- 相同的 `(text, isDefinite)` 组合不重复回调

### 9.3 文本聚合策略

每次收到合法 JSON 时：

1. 若 `result.text` 非空，更新 `_finalText`
2. 遍历 `result.utterances`
3. 对每个分句：
   - 若 `definite == false`，刷新 `_liveText`
   - 若 `definite == true`，将该句写入稳定文本区，且避免重复追加

聚合结果用于两个目的：

- 向 UI 持续提供当前正在识别的内容
- 在 `stopRecording()` 时返回尽可能完整的最终文本

### 9.4 最终返回值规则

`stopRecording()` 返回值优先级：

1. 优先返回非空的 `_finalText`
2. 否则返回 `_committedText + _liveText`
3. 仍为空则返回空字符串

## 10. 停止与取消时序

### 10.1 停止录音

`stopRecording()` 顺序：

1. 停止本地录音流
2. 发送 Last Audio Request
3. 等待一个短暂收尾窗口接收最终结果
4. 关闭 WebSocket
5. 取消订阅并清理资源
6. 返回最终文本

收尾窗口控制在短时间内，避免长按松手后界面明显卡住。

### 10.2 取消录音

`cancelRecording()` 用于页面销毁或异常终止场景。

取消时：

- 停止录音流
- 关闭 WebSocket
- 不保证发送 Last Audio Request
- 直接清理会话资源

`stopRecording()` 与 `cancelRecording()` 都必须幂等，多次调用不得抛出状态异常。

## 11. 错误处理策略

### 11.1 启动前错误

以下错误应立即终止启动：

- `.env` 缺少 `ASR_API_KEY`
- `.env` 缺少 `ASR_API_RESOURCE_ID`
- 麦克风权限未授予
- `record` 启动失败
- WebSocket 握手失败

### 11.2 运行中错误

运行中的错误分两类：

- 会话级错误：连接关闭、录音流中断、协议发送失败
  - 处理：结束本次会话并清理资源
- 单帧解析错误：帧长度异常、Payload 解码失败、JSON 解析失败
  - 处理：记录日志并跳过该帧，不中断整次会话

### 11.3 错误对上层的暴露

`SpeechService` 继续对页面暴露 `AsrInitStatus`，但语义调整为：

- `ready`
- `permissionDenied`
- `recognizerUnavailable`：表示云端 ASR 服务不可用、握手失败或连接失败
- `initFailed`

因此页面错误文案也要同步调整，不再提示“系统语音识别服务不可用”。

## 12. 页面与兼容层改造

### 12.1 `SpeechService` 适配行为

- `ensurePermissionAndInitStatus()`：改为检查权限与环境变量可用性
- `startListening()`：调用 `AsrService.startRecording()`，将底层 `onResult(text, isDefinite)` 适配为当前页面使用的 `onText(text)`
- `stopListeningAndGetFinalText()`：调用 `AsrService.stopRecording()`
- `cancelListening()`：调用 `AsrService.cancelRecording()`

### 12.2 `ContinuousChatScreen` 改动范围

尽量保持 `lib/screens/continuous_chat_screen.dart` 的交互不变：

- 长按开始录音
- 持续显示当前识别文本
- 松手后拿到最终文本并发送问答请求

需要调整的重点只有错误提示语义：

- 原先“设备未提供系统语音识别服务”改为“语音识别服务连接失败，请检查网络或配置”之类的云端错误提示。

## 13. 验收标准

### 13.1 代码级验收

- `pubspec.yaml` 已新增 `record`、`web_socket_channel`、`uuid`
- `pubspec.yaml` 已移除 `speech_to_text`
- 已新增 `lib/services/asr_service.dart`
- `lib/services/speech_service.dart` 已改为 `AsrService` 适配层

### 13.2 功能验收

1. 长按开始录音时，能成功建立 WebSocket 并发送首包配置
2. 说话过程中，页面能持续收到中间识别文本
3. 分句完成时，页面能收到最终文本，且不会因重复回调导致抖动
4. 松手时，能发送 Last Audio Request，并返回最终完整文本
5. `.env` 缺失配置时，会给出明确错误提示
6. 麦克风权限未授予时，会给出明确错误提示
7. 网络异常或连接关闭时，会结束本次会话并清理状态，不留下假录音状态

### 13.3 回归验收

- 连续对话页长按开始/结束交互保持稳定
- 结束识别后，提问文本仍能正常发送到 `DoubaoApiService`
- TTS 停止与后续播报逻辑不被本次改动破坏

## 14. 风险与应对

- 风险：服务端在一次响应中重复返回已确定分句，导致文本重复追加
  - 应对：在稳定文本提交路径增加去重逻辑，不按原样盲目拼接

- 风险：结束包发出后最终结果到达稍慢，导致 `stopRecording()` 提前返回
  - 应对：保留短暂收尾窗口，只等待有限时间，不无限阻塞

- 风险：录音或连接状态未正确释放，影响下一次长按
  - 应对：将清理逻辑统一收口到一个内部方法，在启动前和结束后都调用

## 15. 范围控制

本设计只覆盖 Android 连续对话场景下的豆包流式 ASR 接入，不包含多平台支持、自动重连或其他页面的进一步扩展。