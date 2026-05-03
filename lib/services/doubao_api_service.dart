import 'dart:convert'; // JSON/base64 编解码
import 'dart:io'; // File 读写与存在性检查

import 'package:dio/dio.dart'; // HTTP 请求客户端
import 'package:flutter/foundation.dart'; // debugPrint / kDebugMode
import 'package:flutter_dotenv/flutter_dotenv.dart'; // 读取 .env 配置
import 'package:flutter_image_compress/flutter_image_compress.dart'; // 图片压缩

/// 结果类型：用于上层区分成功/失败路径。
enum ImageAnalysisResultKind {
  textFallbackSuccess, // 成功拿到可播报文本
  networkFailure, // 网络或接口异常
  emptyResponseFailure, // 返回为空或无法解析
}

/// 轻量视觉结构化信息。
class LiteVisionMeta {
  const LiteVisionMeta({
    required this.obstacleText, // 障碍文本
    required this.riskLevel, // 风险等级
    required this.briefDescription, // 简短描述
  });

  final String obstacleText; // 障碍
  final String riskLevel; // 风险
  final String briefDescription; // 描述
}

/// 图像分析统一结果模型。
class ImageAnalysisResult {
  const ImageAnalysisResult({
    required this.kind, // 结果类型
    required this.ttsText, // 供 TTS 直接播报的文本
    this.rawText, // 原始模型文本（可选）
    this.liteMeta, // 结构化轻量信息（可选）
  });

  final ImageAnalysisResultKind kind; // 类型
  final String ttsText; // 播报文本
  final String? rawText; // 原文
  final LiteVisionMeta? liteMeta; // 结构化信息
}

/// 豆包视觉/对话 API 服务：
/// - 图片分析；
/// - 文本追问；
/// - 图片追问；
/// - 返回文本清洗与兜底。
class DoubaoApiService {
  DoubaoApiService({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: _baseUrl, // 基础 URL
                connectTimeout: const Duration(seconds: 60), // 连接超时
                receiveTimeout: const Duration(seconds: 60), // 接收超时
                sendTimeout: const Duration(seconds: 60), // 发送超时
                headers: const {'Content-Type': 'application/json'}, // 默认 JSON
              ),
            );

  final Dio _dio; // HTTP 客户端

  static const String _baseUrl = 'https://ark.cn-beijing.volces.com/api/v3'; // 火山 API 基址
  static const String _responsesPath = '/responses'; // responses 端点

  static const String _safetySystemPrompt = '''你是光语视觉助手。只输出客观结论，给盲人语音播报。
规则：
1) 不猜测，不确定就返回固定句：画面模糊，无法识别，请结合导盲杖判断。
2) 不给“绝对安全/可放心前行”这类结论。
3) 输出简短，直接给结果。'''; // 标准视觉提示词

  static const String _safetySystemPromptLite = '''你是光语视觉助手。
请只输出一行：障碍:xxx；风险:低|中|高；描述:xxx
要求：客观、简短，不要JSON，不要解释，不要换行。
不确定时返回：障碍:未明确；风险:中；描述:画面模糊，无法识别'''; // 轻量结构化提示词

  static const String _textFollowupSystemPrompt = '''你是光语连续对话助手。
请基于已有上下文直接回答用户问题，允许做简短解释和常识性说明。
不要默认回复“画面模糊，无法判断”。只有当问题必须依赖当前不可用的视觉细节时，才明确说明当前无法重新核对图片细节。'''; // 文本追问提示词

  static const String _imageFollowupSystemPrompt = '''你是光语视觉追问助手。
只回答用户当前追问的那个图片细节，不要重复整张图的障碍/风险总结。
要求：简短、客观、适合语音播报。
如果当前追问的那部分确实看不清，就只回答：这部分看不清，无法判断。'''; // 图片追问提示词

  static const String fallbackMessage = '网络环境不佳，AI暂时无法连线，请依靠导盲杖确保安全。'; // 网络兜底
  static const String recognitionFallbackMessage = '画面信息不足，暂时无法稳定识别，请调整角度后重试。'; // 识别兜底
  static const int _maxTtsLength = 120; // 播报文本最大长度

  String get _modelId => dotenv.env['VOLC_MODEL_ID']?.trim() ?? ''; // 模型 ID
  String get _apiKey => dotenv.env['ARK_API_KEY']?.trim() ?? ''; // API Key

  /// 单轮图片分析。
  Future<ImageAnalysisResult> analyzeImageWithFallback(
    File imageFile, {
    String? singleQuestion, // 可选单问句
    bool preferLitePrompt = false, // 是否使用轻量提示词
  }) async {
    final totalStopwatch = Stopwatch()..start(); // 总耗时统计
    debugPrint('--- 📸 开始解析图片 (Doubao Vision) ---'); // 日志
    debugPrint('👉 接收到的图片路径: ${imageFile.path}'); // 日志

    if (!await imageFile.exists()) {
      debugPrint('❌ 错误: 图片文件不存在！'); // 文件不存在
      return const ImageAnalysisResult(
        kind: ImageAnalysisResultKind.emptyResponseFailure, // 空响应失败
        ttsText: recognitionFallbackMessage, // 返回识别兜底
      );
    }

    if (_apiKey.isEmpty || _modelId.isEmpty) {
      debugPrint('❌ 错误: API Key 或 Model ID 为空！请检查 .env 文件。'); // 配置缺失
      return const ImageAnalysisResult(
        kind: ImageAnalysisResultKind.networkFailure, // 归类为网络/配置失败
        ttsText: fallbackMessage, // 网络兜底
      );
    }

    File? preparedImage; // 预处理后文件（可能与原图不同）
    try {
      preparedImage = await _prepareImageForUpload(imageFile); // 压缩图片
      final imageDataUrl = await _buildBase64ImageDataUrl(preparedImage); // 生成 data URL

      final systemPrompt = preferLitePrompt ? _safetySystemPromptLite : _safetySystemPrompt; // 选择提示词
      final payload = {
        'model': _modelId, // 模型 id
        'input': [
          {
            'role': 'system', // 系统角色
            'content': [
              {'type': 'input_text', 'text': systemPrompt}, // 系统提示词
            ],
          },
          {
            'role': 'user', // 用户角色
            'content': [
              {'type': 'input_image', 'image_url': imageDataUrl}, // 图片输入
              {
                'type': 'input_text',
                'text': _singleTurnPrompt(
                  singleQuestion, // 问题
                  preferLitePrompt: preferLitePrompt, // 提示词模式
                ),
              },
            ],
          }
        ],
      };

      final response = await _dio.post(
        _responsesPath, // 调用 responses
        data: payload, // 请求体
        options: Options(
          headers: {
            'Authorization': 'Bearer $_apiKey', // Bearer 鉴权
          },
        ),
      );

      final parsed = _extractResponseText(response.data); // 提取文本
      if (parsed.isEmpty) {
        return const ImageAnalysisResult(
          kind: ImageAnalysisResultKind.emptyResponseFailure, // 空解析失败
          ttsText: recognitionFallbackMessage, // 识别兜底
        );
      }

      final liteMeta = _parseLiteVisionMeta(parsed); // 解析轻量结构
      final fallbackText = _buildFallbackSpeechText(parsed); // 提取可播报文本
      if (fallbackText.isEmpty) {
        return ImageAnalysisResult(
          kind: ImageAnalysisResultKind.emptyResponseFailure, // 依然失败
          ttsText: recognitionFallbackMessage, // 兜底
          rawText: parsed, // 保留原文
          liteMeta: liteMeta, // 保留结构
        );
      }

      final resolvedText = liteMeta?.briefDescription.isNotEmpty == true
          ? _clipTtsText(liteMeta!.briefDescription) // 优先轻量描述
          : fallbackText; // 否则用回退文本
      return ImageAnalysisResult(
        kind: ImageAnalysisResultKind.textFallbackSuccess, // 成功
        ttsText: resolvedText, // 返回播报文本
        rawText: parsed, // 原文
        liteMeta: liteMeta, // 结构
      );
    } catch (e) {
      debugPrint('❌ 网络请求或处理异常: $e'); // 异常日志
      if (e is DioException && e.response != null) {
        debugPrint('接口状态码: ${e.response?.statusCode}'); // 状态码
        debugPrint('接口内容: ${e.response?.data}'); // 响应内容
      }
      return const ImageAnalysisResult(
        kind: ImageAnalysisResultKind.networkFailure, // 网络失败
        ttsText: fallbackMessage, // 网络兜底
      );
    } finally {
      totalStopwatch.stop(); // 停止计时
      debugPrint('⏱️ 总耗时: ${totalStopwatch.elapsedMilliseconds}ms'); // 打印耗时
      if (preparedImage != null &&
          preparedImage.path != imageFile.path &&
          await preparedImage.exists()) {
        try {
          await preparedImage.delete(); // 删除临时压缩图
        } catch (_) {}
      }
    }
  }

  /// 文本追问。
  Future<String> chatWithText({
    required List<Map<String, String>> history, // 对话历史
    required String latestQuestion, // 最新问题
  }) async {
    final latest = latestQuestion.trim(); // 清理问题
    if (latest.isEmpty) {
      return fallbackMessage; // 空问题直接兜底
    }

    final input = _buildTextConversationInput(
      history: history, // 历史
      latestQuestion: latest, // 最新问题
      systemPrompt: _textFollowupSystemPrompt, // 文本追问提示词
    );

    return _sendTextConversationRequest(
      input: input, // 输入
      errorLabel: '文本对话请求异常', // 错误标签
    );
  }

  /// 图片追问。
  Future<String> followupWithImage({
    required File imageFile, // 原图
    required List<Map<String, String>> history, // 历史
    required String latestQuestion, // 最新问题
  }) async {
    if (_apiKey.isEmpty || _modelId.isEmpty) {
      return fallbackMessage; // 配置缺失兜底
    }

    final latest = latestQuestion.trim(); // 清理问题
    if (latest.isEmpty) {
      return fallbackMessage; // 空问题兜底
    }

    if (!await imageFile.exists()) {
      return '当前没有可用图片，无法重新核对这个细节'; // 无图明确降级
    }

    File? preparedImage; // 预处理图
    try {
      preparedImage = await _prepareImageForUpload(imageFile); // 压缩
      final imageDataUrl = await _buildBase64ImageDataUrl(preparedImage); // data URL
      final input = <Map<String, dynamic>>[
        {
          'role': 'system',
          'content': [
            {'type': 'input_text', 'text': _imageFollowupSystemPrompt}, // 图片追问系统提示
          ],
        },
      ];

      for (final message in _truncateHistory(history)) {
        final role = message['role']?.trim(); // 角色
        final content = message['content']?.trim(); // 文本
        if (role == null || content == null || role.isEmpty || content.isEmpty) {
          continue; // 非法记录跳过
        }
        if (role != 'user' && role != 'assistant') {
          continue; // 非 user/assistant 跳过
        }
        if (role == 'user' && content == latest) {
          continue; // 避免重复添加当前问题
        }
        input.add({
          'role': role,
          'content': [
            {'type': 'input_text', 'text': content},
          ],
        });
      }

      input.add({
        'role': 'user',
        'content': [
          {'type': 'input_image', 'image_url': imageDataUrl}, // 图片
          {
            'type': 'input_text',
            'text': '请只根据这张图片回答当前问题：$latest', // 当前问题
          },
        ],
      });

      return _sendTextConversationRequest(
        input: input, // 输入
        errorLabel: '图片追问请求异常', // 标签
      );
    } catch (e) {
      debugPrint('图片追问异常: $e'); // 异常日志
      if (e is DioException && e.response != null) {
        debugPrint('接口报错: ${e.response?.data}'); // 详情
      }
      return fallbackMessage; // 兜底
    } finally {
      if (preparedImage != null &&
          preparedImage.path != imageFile.path &&
          await preparedImage.exists()) {
        try {
          await preparedImage.delete(); // 删除临时图
        } catch (_) {}
      }
    }
  }

  /// 构建文本会话输入。
  List<Map<String, dynamic>> _buildTextConversationInput({
    required List<Map<String, String>> history, // 历史
    required String latestQuestion, // 最新问题
    required String systemPrompt, // 系统提示词
  }) {
    final input = <Map<String, dynamic>>[
      {
        'role': 'system',
        'content': [
          {'type': 'input_text', 'text': systemPrompt}, // 系统提示
        ],
      },
    ];

    for (final message in _truncateHistory(history)) {
      final role = message['role']?.trim(); // 角色
      final content = message['content']?.trim(); // 内容
      if (role == null || content == null || role.isEmpty || content.isEmpty) {
        continue; // 非法记录跳过
      }
      if (role != 'user' && role != 'assistant') {
        continue; // 仅保留 user/assistant
      }
      if (role == 'user' && content == latestQuestion) {
        continue; // 避免重复当前问题
      }
      input.add({
        'role': role,
        'content': [
          {'type': 'input_text', 'text': content}, // 历史文本
        ],
      });
    }

    input.add({
      'role': 'user',
      'content': [
        {'type': 'input_text', 'text': latestQuestion}, // 当前问题
      ],
    });

    return input; // 返回组装结果
  }

  /// 发送文本会话请求。
  Future<String> _sendTextConversationRequest({
    required List<Map<String, dynamic>> input, // 输入
    required String errorLabel, // 错误标签
  }) async {
    if (_apiKey.isEmpty || _modelId.isEmpty) {
      return fallbackMessage; // 配置缺失兜底
    }

    try {
      final payload = {
        'model': _modelId, // 模型 id
        'input': input, // 输入
      };

      final response = await _dio.post(
        _responsesPath, // 端点
        data: payload, // 请求体
        options: Options(
          headers: {
            'Authorization': 'Bearer $_apiKey', // 鉴权头
          },
        ),
      );

      final parsed = _extractResponseText(response.data); // 提取文本
      if (parsed.isEmpty) {
        return fallbackMessage; // 空文本兜底
      }
      return parsed; // 正常返回
    } catch (e) {
      debugPrint('===== $errorLabel ====='); // 标签日志
      debugPrint(e.toString()); // 错误日志
      if (e is DioException && e.response != null) {
        debugPrint('接口详细报错: ${e.response?.data}'); // 响应报错
      }
      debugPrint('==========================');
      return fallbackMessage; // 异常兜底
    }
  }

  /// 尝试把文本解析为 JSON 对象。
  Map<String, dynamic>? _decodeJsonObject(String raw) {
    final direct = _tryDecode(raw); // 直接解析
    if (direct != null) {
      return direct; // 成功返回
    }

    final firstBrace = raw.indexOf('{'); // 首个左花括号
    final lastBrace = raw.lastIndexOf('}'); // 最后右花括号
    if (firstBrace < 0 || lastBrace <= firstBrace) {
      return null; // 无合法包围区
    }

    final candidate = raw.substring(firstBrace, lastBrace + 1); // 截取候选 JSON
    return _tryDecode(candidate); // 再尝试一次
  }

  /// 安全 JSON decode。
  Map<String, dynamic>? _tryDecode(String input) {
    try {
      final decoded = jsonDecode(input); // decode
      if (decoded is Map<String, dynamic>) {
        return decoded; // 仅接受对象
      }
      return null; // 非对象返回 null
    } catch (_) {
      return null; // 解析失败返回 null
    }
  }

  /// 解析轻量协议文本（障碍/风险/描述）。
  LiteVisionMeta? _parseLiteVisionMeta(String raw) {
    final cleaned = raw
        .replaceAll(RegExp(r'```(?:json)?', caseSensitive: false), ' ') // 去代码块头
        .replaceAll('```', ' ') // 去代码块尾
        .replaceAll('\n', '；') // 换行归一成分号
        .replaceAll('\r', '；')
        .trim(); // 去空白
    if (cleaned.isEmpty) {
      return null; // 空文本返回 null
    }

    final segments = cleaned
        .split(RegExp(r'[；;]')) // 分段
        .map((s) => s.trim()) // 去空白
        .where((s) => s.isNotEmpty) // 去空段
        .toList();

    String obstacle = ''; // 障碍
    String risk = ''; // 风险
    String description = ''; // 描述

    for (final segment in segments) {
      final normalized = segment.replaceAll('：', ':'); // 中英文冒号归一
      final idx = normalized.indexOf(':'); // 找 key:value 分隔
      if (idx <= 0 || idx >= normalized.length - 1) {
        continue; // 非法段跳过
      }
      final key = normalized.substring(0, idx).trim(); // key
      final value = normalized.substring(idx + 1).trim(); // value
      if (value.isEmpty) {
        continue; // 空 value 跳过
      }

      if (key.contains('障碍')) {
        obstacle = value; // 命中障碍
      } else if (key.contains('风险')) {
        risk = value; // 命中风险
      } else if (key.contains('描述')) {
        description = value; // 命中描述
      }
    }

    if (description.isEmpty) {
      description = _extractDescriptionFromLabeledLine(cleaned); // 再尝试从 labeled line 提取
    }
    if (description.isEmpty) {
      description = _buildFallbackSpeechText(raw); // 仍为空则回退通用提取
    }

    if (risk.isEmpty) {
      risk = _inferRiskLevel('$obstacle $description'); // 缺失风险则启发式推断
    }

    if (obstacle.isEmpty) {
      obstacle = '未明确'; // 缺失障碍默认值
    }

    if (description.isEmpty) {
      return null; // 仍无描述则视为解析失败
    }

    return LiteVisionMeta(
      obstacleText: obstacle, // 障碍
      riskLevel: risk, // 风险
      briefDescription: _clipTtsText(description), // 截断后描述
    );
  }

  /// 从“描述:xxx”样式里提取描述。
  String _extractDescriptionFromLabeledLine(String raw) {
    final normalized = raw.replaceAll('：', ':'); // 冒号归一
    final match = RegExp(r'描述\s*:\s*(.+?)(?=(；|;|$))').firstMatch(normalized); // 正则提取
    final text = match?.group(1)?.trim() ?? ''; // 取分组
    return text; // 返回
  }

  /// 启发式推断风险等级。
  String _inferRiskLevel(String text) {
    final lower = text.toLowerCase(); // 小写副本
    final highKeys = ['车辆', '车流', '台阶', '坑', '施工', '快速接近']; // 高风险词
    final mediumKeys = ['障碍', '拥挤', '昏暗', '湿滑']; // 中风险词
    final lowKeys = ['通畅', '无明显障碍']; // 低风险词

    if (highKeys.any((k) => text.contains(k) || lower.contains(k))) {
      return '高'; // 高
    }
    if (mediumKeys.any((k) => text.contains(k) || lower.contains(k))) {
      return '中'; // 中
    }
    if (lowKeys.any((k) => text.contains(k) || lower.contains(k))) {
      return '低'; // 低
    }
    return '未知'; // 未知
  }

  /// 从多种格式提取可播报文本。
  String _buildFallbackSpeechText(String raw) {
    final decoded = _decodeJsonObject(raw); // 尝试 JSON 提取
    if (decoded != null) {
      final ttsText = _clipTtsText(_nonEmptyString(decoded['tts_text']) ?? ''); // 优先 tts_text
      if (ttsText.isNotEmpty) {
        return ttsText;
      }

      final summary = _clipTtsText(_nonEmptyString(decoded['summary']) ?? ''); // 次选 summary
      if (summary.isNotEmpty) {
        return summary;
      }

      final ocrFocus = decoded['ocr_focus']; // 再尝试 OCR focus
      if (ocrFocus is List) {
        for (final item in ocrFocus) {
          final map = _asStringMap(item); // 转 map
          final text = _clipTtsText(_nonEmptyString(map?['text']) ?? ''); // 取 text
          if (text.isNotEmpty) {
            return text;
          }
        }
      }
    }

    final extracted = _extractQuotedField(raw, 'tts_text') ??
        _extractQuotedField(raw, 'summary'); // 正则兜底提取
    if (extracted != null) {
      final clipped = _clipTtsText(extracted); // 截断
      if (clipped.isNotEmpty) {
        return clipped;
      }
    }

    final cleanedText = raw
        .replaceAll(RegExp(r'```(?:json)?', caseSensitive: false), ' ') // 去代码块
        .replaceAll('```', ' ')
        .replaceAll(RegExp(r'\s+'), ' ') // 合并空白
        .trim(); // trim
    if (cleanedText.isEmpty) {
      return ''; // 空
    }
    if (cleanedText.startsWith('{') && cleanedText.endsWith('}')) {
      return ''; // 纯 JSON 但没提取到有用字段
    }
    return _clipTtsText(cleanedText); // 作为纯文本返回
  }

  /// 用正则提取 quoted 字段值。
  String? _extractQuotedField(String raw, String fieldName) {
    final match = RegExp('"$fieldName"\\s*:\\s*"([^"\\n]+)"').firstMatch(raw); // 正则
    final value = match?.group(1)?.trim(); // 提取值
    if (value == null || value.isEmpty) {
      return null; // 无值
    }
    return value; // 返回
  }

  /// 截断播报文本长度。
  String _clipTtsText(String value) {
    final trimmed = value.trim(); // 清理
    if (trimmed.isEmpty) {
      return ''; // 空
    }
    return trimmed.length > _maxTtsLength
        ? trimmed.substring(0, _maxTtsLength) // 超长截断
        : trimmed; // 否则原样
  }

  /// 动态对象安全转 Map<String, dynamic>。
  Map<String, dynamic>? _asStringMap(dynamic value) {
    if (value is Map) {
      try {
        return Map<String, dynamic>.from(value); // 尝试转换
      } catch (_) {
        return null; // 转换失败
      }
    }
    return null; // 非 map
  }

  /// 非空字符串提取。
  String? _nonEmptyString(dynamic value) {
    if (value is! String) {
      return null; // 非字符串
    }
    final trimmed = value.trim(); // trim
    return trimmed.isEmpty ? null : trimmed; // 空则 null
  }

  /// 截断历史窗口：限制轮数和单条长度。
  List<Map<String, String>> _truncateHistory(List<Map<String, String>> history) {
    const maxRounds = 6; // 最多 6 条
    const maxChars = 120; // 每条最多 120 字

    final filtered = history
        .where((m) => (m['role'] == 'user' || m['role'] == 'assistant')) // 只保留 user/assistant
        .toList();

    final start = filtered.length > maxRounds ? filtered.length - maxRounds : 0; // 计算窗口起点
    final window = filtered.sublist(start); // 截取窗口

    return window.map((message) {
      final role = message['role'] ?? ''; // 角色
      final content = (message['content'] ?? '').trim(); // 内容
      final clipped =
          content.length > maxChars ? content.substring(0, maxChars) : content; // 长度截断
      return {'role': role, 'content': clipped}; // 返回规范化项
    }).toList();
  }

  /// 单轮提示词拼接。
  String _singleTurnPrompt(
    String? question, {
    bool preferLitePrompt = false, // 是否轻量模式
  }) {
    final q = question?.trim(); // 清理问题
    if (preferLitePrompt) {
      if (q == null || q.isEmpty) {
        return '只基于当前图片输出一行：障碍:xxx；风险:低|中|高；描述:xxx。不要JSON，不要解释。'; // 轻量无问题模板
      }
      return '只基于当前图片回答问题：$q。输出一行：障碍:xxx；风险:低|中|高；描述:xxx。不要JSON，不要解释。'; // 轻量有问题模板
    }

    if (q == null || q.isEmpty) {
      return '只基于当前图片输出一行：障碍:xxx；风险:低|中|高；描述:xxx。不要JSON，不要解释。'; // 标准无问题模板
    }
    return '只基于当前图片回答问题：$q。输出一行：障碍:xxx；风险:低|中|高；描述:xxx。不要JSON，不要解释。'; // 标准有问题模板
  }

  /// 图片预处理：压缩后上传，失败则回退原图。
  Future<File> _prepareImageForUpload(File imageFile) async {
    try {
      final compressed = await FlutterImageCompress.compressAndGetFile(
        imageFile.path, // 源路径
        '${imageFile.path}.compressed.jpg', // 目标路径
        minWidth: 720, // 最小宽
        minHeight: 720, // 最小高
        quality: 90, // 质量
        format: CompressFormat.jpeg, // 格式
      );
      if (compressed == null) {
        return imageFile; // 压缩失败回退原图
      }
      return File(compressed.path); // 返回压缩图
    } catch (_) {
      return imageFile; // 异常回退原图
    }
  }

  /// 生成 data:image/...;base64,... URL。
  Future<String> _buildBase64ImageDataUrl(File imageFile) async {
    final bytes = await imageFile.readAsBytes(); // 读字节
    final base64Data = base64Encode(bytes); // 编码
    final ext = _detectImageExt(imageFile.path); // 检测扩展名
    return 'data:image/$ext;base64,$base64Data'; // 拼接 data URL
  }

  /// 从路径推断图片扩展名。
  String _detectImageExt(String path) {
    final lower = path.toLowerCase(); // 小写
    if (lower.endsWith('.png')) return 'png';
    if (lower.endsWith('.webp')) return 'webp';
    if (lower.endsWith('.gif')) return 'gif';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'jpeg';
    return 'jpeg'; // 默认 jpeg
  }

  /// 从 responses 返回体中提取文本。
  String _extractResponseText(dynamic data) {
    if (data is! Map) {
      return ''; // 非对象返回空
    }

    final output = data['output']; // output 列表
    if (output is List) {
      for (final item in output) {
        if (item is Map) {
          final content = item['content'];
          if (content is List) {
            for (final segment in content) {
              if (segment is Map) {
                final text = segment['text']; // 段文本
                if (text is String && text.trim().isNotEmpty) {
                  return text.trim(); // 命中首个非空文本即返回
                }
              }
            }
          }
        }
      }
    }

    final outputText = data['output_text']; // 备用字段
    if (outputText is String && outputText.trim().isNotEmpty) {
      return outputText.trim(); // 非空则返回
    }

    return ''; // 最终返回空
  }
}
