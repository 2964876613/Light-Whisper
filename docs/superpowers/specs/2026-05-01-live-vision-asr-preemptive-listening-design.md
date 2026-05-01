# 实时感知长按聆听灵敏度优化设计（抢占式）

## 1. 背景与目标

当前实时感知页面存在“长按开启聆听不灵敏”的问题，用户反馈最主要场景为：

- AI 正在播报时，长按经常不触发聆听。
- 图像识别请求进行中，长按经常不触发聆听。

本次设计目标：

1. 长按触发聆听具备最高优先级（按下即进入聆听）。
2. 避免旧视觉结果在聆听期间回流打断用户。
3. 保持现有左滑退出、ASR问答、视觉轮询能力不退化。

非目标：

- 不引入新的多轮会话产品能力。
- 不调整模型提示词策略。
- 不新增跨页面架构改造。

## 2. 方案概述

采用“抢占式聆听 + 结果过期丢弃”机制。

核心原则：

- 长按开始时，不再被 `_isRequesting` 阻塞。
- 长按开始时立即打断 TTS 并进入聆听。
- 已发出的视觉请求不强制取消，但其结果在 ASR 会话期间标记为过期并丢弃。

## 3. 状态与数据设计

### 3.1 新增字段

- `int _interactionEpoch = 0;`
  - 用于标识“当前交互时代”。
- 现有字段继续使用：
  - `_isAsrRunning`
  - `_isRecording`
  - `_isAskingAi`
  - `_isRequesting`
  - `_isExiting`

### 3.2 Epoch 规则

- 每次进入聆听（`onLongPressStart`）执行 `++_interactionEpoch`。
- 每次退出页面前（`_stopAndExit`）执行 `++_interactionEpoch`。
- 每次视觉请求发起时记录本地 `requestEpoch = _interactionEpoch`。
- 视觉请求返回时，若 `requestEpoch != _interactionEpoch`，则结果直接丢弃。

## 4. 关键流程设计

### 4.1 长按开始（抢占入口）

执行顺序：

1. 仅拒绝重入条件：`_isExiting` 或 `_isAsrRunning`。
2. `++_interactionEpoch`，使在飞视觉结果立即过期。
3. `stop TTS`，确保用户按下后立即可说话。
4. 更新状态：`_isRecording = true`、`_isAsrRunning = true`。
5. 启动 ASR。

说明：

- 不再以 `_isRequesting` 作为长按阻塞条件。

### 4.2 长按结束（提交问题）

1. 停止 ASR 并获取最终文本。
2. 文本为空则播报提示并返回空闲。
3. 非空则进入 `_isAskingAi = true`。
4. 优先用最近帧图像执行 `followupWithImage`；无帧时退化 `chatWithText`。
5. 播报回复并回到可轮询状态。

### 4.3 视觉轮询与结果落地

发起前检查：

- `_isRunning`
- 非 `_isRequesting`
- 非 `_isAsrRunning`
- 非 `_isAskingAi`

返回后检查：

- `mounted && _isRunning && !_isExiting`
- `requestEpoch == _interactionEpoch`
- 非 `_isAsrRunning` 且非 `_isAskingAi`

若任一条件不满足：

- 不 `setState`
- 不 `speak`
- 直接丢弃结果

### 4.4 退出流程

1. `++_interactionEpoch`，失效所有晚到回调。
2. 取消 ASR。
3. 停止 TTS。
4. 停止 timer。
5. 释放 camera。
6. `Navigator.pop`。

## 5. 用户体验要求

1. 长按任何时刻（包含播报中、识别请求中）都可进入聆听。
2. 聆听时黄框反馈稳定出现。
3. 聆听期间不应被旧视觉结果插播打断。
4. 左滑退出行为保持不变。

## 6. 风险与取舍

### 6.1 接受的取舍

- 允许个别在飞视觉请求“白跑一轮”，以换取长按必触发。

### 6.2 主要风险

- 状态竞争导致偶发 UI 回跳。

### 6.3 风险缓解

- 通过 epoch 比对统一处理结果过期。
- 退出路径统一收口，避免退出后异步回调落地。

## 7. 测试与验收清单

1. 空闲状态连续长按 10 次，10 次均触发聆听。
2. 播报中长按，必须立即打断并进入聆听。
3. 识别请求中长按，必须立即进入聆听，旧结果不播报。
4. 长按松手后问答闭环可完成，结束后恢复轮询。
5. 连续 5 轮“长按-松手”无状态错乱。
6. 聆听中/思考中左滑退出均正常，回主页不冻结。
7. 麦克风拒绝、网络超时路径可恢复，不影响下次长按。

## 8. 实施范围

仅涉及：

- `lib/screens/live_vision_screen.dart`

不涉及：

- `home_screen.dart` 的交互定义
- `continuous_chat_screen.dart` 的流程调整
- 服务层接口签名变更
