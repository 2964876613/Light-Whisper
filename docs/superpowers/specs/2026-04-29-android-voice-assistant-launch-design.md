# Android 语音助手唤起设计（A 方案）

## 1. 目标与范围

本设计用于让“光语”可被 Android 语音助手直接唤起，并进入首页（拍一拍/摇一摇界面）。

目标语句：
- “打开光语”

目标行为：
- 冷启动或热启动均可拉起应用
- 进入现有首页（HomeScreen）

本期范围（作业可交付）：
1. Android 应用展示名统一为“光语”
2. 保持 MainActivity 默认启动路径
3. 增加轻量 deep link 兜底：`lightwhisper://open/home`
4. Flutter 业务流程不变（首页仍为拍一拍/摇一摇）

非目标：
- iOS Siri 支持
- 完整 App Actions 能力集成
- 重构现有拍照、摇一摇、对话链路

## 2. 方案选择

采用 A 方案（最小可交付）：
- 核心原则：尽量少改、稳定可演示
- 通过“系统展示名一致 + 标准启动入口 + deep link 兜底”达成语音打开能力

不采用 B/C 原因：
- App Actions 配置与调试成本较高，不符合本次作业节奏
- 快捷方式路径存在设备差异，不如 A 方案稳

## 3. 文件级改动设计

### 3.1 AndroidManifest

文件：`android/app/src/main/AndroidManifest.xml`

改动：
- 保留 `MAIN + LAUNCHER` 启动入口
- 在 `MainActivity` 下新增 `VIEW` intent-filter，用于 deep link：
  - scheme: `lightwhisper`
  - host: `open`
  - pathPrefix: `/home`

目的：
- 语音助手无法稳定命中应用名时，可通过 deep link 方式兜底
- 为后续扩展其他语音入口保留基础能力

### 3.2 应用名

文件：`android/app/src/main/res/values/strings.xml`（若缺失则新增）

改动：
- `app_name` 设置为 `光语`

目的：
- 语音口令“打开光语”与系统展示名一致，提升识别成功率

### 3.3 Flutter 路由

文件：`lib/main.dart`（仅校验，不强制改动）

要求：
- 启动后仍落到首页（HomeScreen）
- 不引入新路由分流逻辑

## 4. 交互与数据流

1. 用户说“打开光语”
2. 语音助手识别应用名并发起启动 intent
3. Android 启动 MainActivity
4. Flutter 正常启动并展示 HomeScreen
5. 若通过 deep link 触发，则同样进入首页路径

## 5. 风险与应对

风险 1：不同安卓机型语音助手识别差异
- 应对：保留 deep link 兜底，演示时可同时准备语音与链接触发

风险 2：应用名更新后未生效
- 应对：卸载重装或清理 launcher 缓存后复测

风险 3：新增 intent-filter 影响现有启动流程
- 应对：仅新增最小匹配规则，不改原有 MAIN/LAUNCHER

## 6. 测试与验收

### 6.1 功能测试

- 语音唤起（冷启动）：说“打开光语”
- 语音唤起（热启动）：后台后再次唤起
- deep link 兜底：触发 `lightwhisper://open/home`

预期：
- 均成功进入首页

### 6.2 回归测试

- 首页双击拍照入口正常
- 摇一摇入口正常
- 对话页播报与语音输入链路正常

### 6.3 验收标准

- 语音命令 3 次中至少 2 次成功进入首页
- deep link 触发 100% 成功
- 无主流程回归问题

## 7. 实施顺序

1. 修改 `strings.xml` 应用名为“光语”
2. 修改 `AndroidManifest.xml` 增加 deep link intent-filter
3. 校验 `main.dart` 启动落点
4. 进行语音/链接/回归测试

## 8. 结论

该方案以最小改动满足“通过语音助手打开光语并进入首页”的作业目标，实施风险低、演示路径清晰、可在当前代码结构下快速完成。