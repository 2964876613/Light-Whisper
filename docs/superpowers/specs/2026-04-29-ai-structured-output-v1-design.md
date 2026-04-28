# AI Structured Output v1 Design (方案1)

## 1. 目标与范围

本设计用于完善“光语”当前 AI 能力链路，采用最小改动方案（单次调用 + 强约束 JSON），在不改变现有业务主流程的前提下，显著降低幻觉风险并提升可解析性。

本阶段仅覆盖：
- 图像理解请求的结构化输出约束
- 本地 JSON 校验与失败回退
- 多轮上下文截断策略
- 视觉 token 基础降本策略
- 最小可观测性指标

不覆盖：
- 双模型/双阶段推理链路
- 后端网关改造
- 新增复杂策略编排服务

## 2. 现状问题

当前链路可用但不可控：
- AI 返回以自然语言为主，缺乏稳定结构
- 多轮历史仅追加，缺少窗口化截断
- 图像上传策略无分级，成本与延迟不稳定
- 缺少可量化的结构成功率与 fallback 触发率指标

## 3. 设计原则

1. 逻辑不改：保留现有单次请求主链路（analyzeImage/chatWithText）。
2. 安全优先：低置信度或格式异常时宁可拒答，不冒险描述。
3. 机器可判定：输出必须可 JSON 解析并通过字段校验。
4. 极简播报：最终播报文本保持短句、可直接 TTS。

## 4. 输出契约（JSON Schema v1）

模型必须仅输出单个 JSON 对象，不得包含 markdown、解释文本或额外前后缀。

```json
{
  "scene_type": "outdoor|digital|unknown",
  "summary": "string<=20字",
  "safety": {
    "level": "low|medium|high|critical",
    "confidence": 0.0,
    "fallback_needed": true
  },
  "hazards": [
    {
      "type": "vehicle|stairs|pit|obstacle|unknown",
      "direction": "front|front_left|front_right|left|right|rear|unknown",
      "distance_m": 0.0,
      "confidence": 0.0
    }
  ],
  "traffic_light": {
    "state": "red|yellow|green|none|unknown",
    "confidence": 0.0
  },
  "ocr_focus": [
    {
      "text": "string",
      "role": "button|title|amount|label|unknown",
      "confidence": 0.0
    }
  ],
  "tts_text": "最终播报短句（<=15字）"
}
```

### 强约束规则

- 所有顶层键必须存在，不允许省略。
- 枚举字段仅允许白名单值。
- `confidence` 取值范围 `[0, 1]`。
- 关键字段（`safety`, `hazards`, `traffic_light`）任一置信度低于 0.9，必须 `fallback_needed=true`。
- `fallback_needed=true` 时，`tts_text` 必须为安全兜底句。

## 5. Prompt 设计（单次调用）

### 5.1 System Prompt 职责

保留现有安全底线（禁猜测、禁绝对安全承诺、低置信中断）。

### 5.2 User Prompt 职责

追加“结构化输出协议”：
- 仅输出 JSON
- 强制字段完整
- 明确枚举与单位（距离单位米）
- 低置信触发 fallback 规则

### 5.3 推理参数

若接口支持温度参数，设置低温（建议 0~0.2）以降低格式漂移。

## 6. 客户端校验与回退

在当前 `_extractResponseText` 结果之后，增加轻量校验流程：

1. `jsonDecode` 失败 -> fallback
2. 字段缺失/类型错误 -> fallback
3. 枚举值非法 -> fallback
4. 关键置信度不达标且未触发 fallback -> fallback
5. 校验通过 -> 使用 `tts_text` 播报并展示

fallback 文案继续复用现有安全兜底句，保证行为一致。

## 7. 多轮上下文截断策略

在 `chatWithText(history, latestQuestion)` 保持接口不变，仅增加历史裁剪：

- 始终保留 system 消息
- 仅保留最近 4~6 轮 user/assistant
- 单条内容超限按字符裁剪（建议 120 字）
- 安全相关轮次优先保留（方位/危险/红绿灯）

目标：降低 token 增长，稳定延迟。

## 8. 视觉 Token 降本策略

保留单次视觉请求架构，仅优化输入图：

- 上传前压缩（复用现有 `flutter_image_compress`）
- 长边限制建议 1024~1280（按效果回归择优）
- 默认中等 JPEG 质量
- 保留失败回退，不引入二次重试链路

## 9. 可观测性与验收标准

### 9.1 指标

- JSON 解析成功率
- fallback 触发率
- 端到端延迟 p50/p95
- 平均请求体大小

### 9.2 v1 验收门槛

- JSON 解析成功率 >= 95%
- 高风险场景误判“可安全前行” = 0
- 端到端延迟满足产品阈值（默认目标：p95 < 2.5s，视设备/网络可调整）

## 10. 落地顺序

1. 增补 user prompt 的 JSON 协议
2. 增加本地 JSON 校验器与 fallback 规则
3. 接入 history 截断
4. 接入图片压缩上限参数
5. 增加最小埋点并回归测试

## 11. 风险与应对

- 风险：模型偶发输出非 JSON
  - 应对：严格本地校验 + fallback
- 风险：压缩导致识别精度下降
  - 应对：以回归样本对比 1024/1280 与质量参数
- 风险：上下文裁剪导致追问理解下降
  - 应对：优先保留安全语义轮次

## 12. 结论

方案1可在当前架构内以最小改动快速提升安全性与可控性，形成可验证的结构化输出闭环，并为后续演进到双阶段链路打下基础。