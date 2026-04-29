import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

enum ImageAnalysisResultKind {
  textFallbackSuccess,
  networkFailure,
  emptyResponseFailure,
}

class LiteVisionMeta {
  const LiteVisionMeta({
    required this.obstacleText,
    required this.riskLevel,
    required this.briefDescription,
  });

  final String obstacleText;
  final String riskLevel;
  final String briefDescription;
}

class ImageAnalysisResult {
  const ImageAnalysisResult({
    required this.kind,
    required this.ttsText,
    this.rawText,
    this.liteMeta,
  });

  final ImageAnalysisResultKind kind;
  final String ttsText;
  final String? rawText;
  final LiteVisionMeta? liteMeta;
}

class DoubaoApiService {
  DoubaoApiService({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: _baseUrl,
                connectTimeout: const Duration(seconds: 60),
                receiveTimeout: const Duration(seconds: 60),
                sendTimeout: const Duration(seconds: 60),
                headers: const {'Content-Type': 'application/json'},
              ),
            );

  final Dio _dio;

  static const String _baseUrl = 'https://ark.cn-beijing.volces.com/api/v3';
  static const String _responsesPath = '/responses';

  static const String _safetySystemPrompt = '''你是光语视觉助手。只输出客观结论，给盲人语音播报。
规则：
1) 不猜测，不确定就返回固定句：画面模糊，无法识别，请结合导盲杖判断。
2) 不给“绝对安全/可放心前行”这类结论。
3) 输出简短，直接给结果。''';

  static const String _safetySystemPromptLite = '''你是光语视觉助手。
请只输出一行：障碍:xxx；风险:低|中|高；描述:xxx
要求：客观、简短，不要JSON，不要解释，不要换行。
不确定时返回：障碍:未明确；风险:中；描述:画面模糊，无法识别''';

  static const String fallbackMessage = '网络环境不佳，AI暂时无法连线，请依靠导盲杖确保安全。';
  static const String recognitionFallbackMessage = '画面信息不足，暂时无法稳定识别，请调整角度后重试。';
  static const int _maxTtsLength = 120;

  String get _modelId => dotenv.env['VOLC_MODEL_ID']?.trim() ?? '';
  String get _apiKey => dotenv.env['ARK_API_KEY']?.trim() ?? '';

  Future<ImageAnalysisResult> analyzeImageWithFallback(
    File imageFile, {
    String? singleQuestion,
    bool preferLitePrompt = false,
  }) async {
    final totalStopwatch = Stopwatch()..start();
    debugPrint('--- 📸 开始解析图片 (Doubao Vision) ---');
    debugPrint('👉 接收到的图片路径: ${imageFile.path}');

    if (!await imageFile.exists()) {
      debugPrint('❌ 错误: 图片文件不存在！');
      return const ImageAnalysisResult(
        kind: ImageAnalysisResultKind.emptyResponseFailure,
        ttsText: recognitionFallbackMessage,
      );
    }

    debugPrint('🔑 读取到的 API Key: ${_apiKey.isNotEmpty ? "已读取(长度${_apiKey.length})" : "为空"}');
    debugPrint('🧠 读取到的 Model ID: ${_modelId.isNotEmpty ? "已读取($_modelId)" : "为空"}');

    if (_apiKey.isEmpty || _modelId.isEmpty) {
      debugPrint('❌ 错误: API Key 或 Model ID 为空！请检查 .env 文件。');
      return const ImageAnalysisResult(
        kind: ImageAnalysisResultKind.networkFailure,
        ttsText: fallbackMessage,
      );
    }

    File? preparedImage;
    try {
      final prepareStopwatch = Stopwatch()..start();
      debugPrint('🔄 正在准备图片和 Payload...');
      preparedImage = await _prepareImageForUpload(imageFile);
      final imageDataUrl = await _buildBase64ImageDataUrl(preparedImage);
      prepareStopwatch.stop();
      debugPrint('⏱️ 预处理耗时: ${prepareStopwatch.elapsedMilliseconds}ms');

      final systemPrompt = preferLitePrompt ? _safetySystemPromptLite : _safetySystemPrompt;
      final payload = {
        'model': _modelId,
        'input': [
          {
            'role': 'system',
            'content': [
              {'type': 'input_text', 'text': systemPrompt},
            ],
          },
          {
            'role': 'user',
            'content': [
              {'type': 'input_image', 'image_url': imageDataUrl},
              {
                'type': 'input_text',
                'text': _singleTurnPrompt(
                  singleQuestion,
                  preferLitePrompt: preferLitePrompt,
                ),
              },
            ],
          }
        ],
      };

      final requestStopwatch = Stopwatch()..start();
      debugPrint('🚀 正在向火山引擎发起请求 (地址: $_baseUrl$_responsesPath)...');
      final response = await _dio.post(
        _responsesPath,
        data: payload,
        options: Options(
          headers: {
            'Authorization': 'Bearer $_apiKey',
          },
        ),
      );
      requestStopwatch.stop();
      debugPrint('⏱️ 请求耗时: ${requestStopwatch.elapsedMilliseconds}ms');

      final parseStopwatch = Stopwatch()..start();
      debugPrint('✅ 请求成功！正在提取文本数据...');
      final parsed = _extractResponseText(response.data);
      if (parsed.isEmpty) {
        debugPrint('⚠️ 警告: 提取到的文本为空。服务器原始返回数据: ${response.data}');
        return const ImageAnalysisResult(
          kind: ImageAnalysisResultKind.emptyResponseFailure,
          ttsText: recognitionFallbackMessage,
        );
      }

      if (kDebugMode) {
        final preview = parsed.length > 200 ? '${parsed.substring(0, 200)}...' : parsed;
        debugPrint('🤖 AI 返回原文预览: $preview');
      }

      final liteMeta = _parseLiteVisionMeta(parsed);
      parseStopwatch.stop();
      debugPrint('⏱️ 解析耗时: ${parseStopwatch.elapsedMilliseconds}ms');

      final fallbackText = _buildFallbackSpeechText(parsed);
      if (fallbackText.isEmpty) {
        return ImageAnalysisResult(
          kind: ImageAnalysisResultKind.emptyResponseFailure,
          ttsText: recognitionFallbackMessage,
          rawText: parsed,
          liteMeta: liteMeta,
        );
      }

      final resolvedText = liteMeta?.briefDescription.isNotEmpty == true
          ? _clipTtsText(liteMeta!.briefDescription)
          : fallbackText;
      return ImageAnalysisResult(
        kind: ImageAnalysisResultKind.textFallbackSuccess,
        ttsText: resolvedText,
        rawText: parsed,
        liteMeta: liteMeta,
      );
    } catch (e) {
      debugPrint('❌ 网络请求或处理异常 (catch块):');
      debugPrint(e.toString());

      if (e is DioException && e.response != null) {
        debugPrint('接口详细报错状态码: ${e.response?.statusCode}');
        debugPrint('接口详细报错内容: ${e.response?.data}');
      }
      return const ImageAnalysisResult(
        kind: ImageAnalysisResultKind.networkFailure,
        ttsText: fallbackMessage,
      );
    } finally {
      totalStopwatch.stop();
      debugPrint('⏱️ 总耗时: ${totalStopwatch.elapsedMilliseconds}ms');
      if (preparedImage != null &&
          preparedImage.path != imageFile.path &&
          await preparedImage.exists()) {
        try {
          await preparedImage.delete();
        } catch (_) {}
      }
    }
  }

  Future<String> chatWithText({
    required List<Map<String, String>> history,
    required String latestQuestion,
  }) async {
    if (_apiKey.isEmpty || _modelId.isEmpty) {
      return fallbackMessage;
    }

    final latest = latestQuestion.trim();
    if (latest.isEmpty) {
      return fallbackMessage;
    }

    try {
      final input = <Map<String, dynamic>>[
        {
          'role': 'system',
          'content': [
            {'type': 'input_text', 'text': _safetySystemPrompt},
          ],
        },
      ];

      for (final message in _truncateHistory(history)) {
        final role = message['role']?.trim();
        final content = message['content']?.trim();
        if (role == null || content == null || role.isEmpty || content.isEmpty) {
          continue;
        }
        if (role != 'user' && role != 'assistant') {
          continue;
        }

        if (role == 'user' && content == latest) {
          continue;
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
          {'type': 'input_text', 'text': latest},
        ],
      });

      final payload = {
        'model': _modelId,
        'input': input,
      };

      final response = await _dio.post(
        _responsesPath,
        data: payload,
        options: Options(
          headers: {
            'Authorization': 'Bearer $_apiKey',
          },
        ),
      );

      final parsed = _extractResponseText(response.data);
      if (parsed.isEmpty) {
        return fallbackMessage;
      }
      return parsed;
    } catch (e) {
      debugPrint('===== 文本对话请求异常 =====');
      debugPrint(e.toString());
      if (e is DioException && e.response != null) {
        debugPrint('接口详细报错: ${e.response?.data}');
      }
      debugPrint('==========================');
      return fallbackMessage;
    }
  }

  Map<String, dynamic>? _decodeJsonObject(String raw) {
    final direct = _tryDecode(raw);
    if (direct != null) {
      return direct;
    }

    final firstBrace = raw.indexOf('{');
    final lastBrace = raw.lastIndexOf('}');
    if (firstBrace < 0 || lastBrace <= firstBrace) {
      return null;
    }

    final candidate = raw.substring(firstBrace, lastBrace + 1);
    return _tryDecode(candidate);
  }

  Map<String, dynamic>? _tryDecode(String input) {
    try {
      final decoded = jsonDecode(input);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  LiteVisionMeta? _parseLiteVisionMeta(String raw) {
    final cleaned = raw
        .replaceAll(RegExp(r'```(?:json)?', caseSensitive: false), ' ')
        .replaceAll('```', ' ')
        .replaceAll('\n', '；')
        .replaceAll('\r', '；')
        .trim();
    if (cleaned.isEmpty) {
      return null;
    }

    final segments = cleaned
        .split(RegExp(r'[；;]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    String obstacle = '';
    String risk = '';
    String description = '';

    for (final segment in segments) {
      final normalized = segment.replaceAll('：', ':');
      final idx = normalized.indexOf(':');
      if (idx <= 0 || idx >= normalized.length - 1) {
        continue;
      }
      final key = normalized.substring(0, idx).trim();
      final value = normalized.substring(idx + 1).trim();
      if (value.isEmpty) {
        continue;
      }

      if (key.contains('障碍')) {
        obstacle = value;
      } else if (key.contains('风险')) {
        risk = value;
      } else if (key.contains('描述')) {
        description = value;
      }
    }

    if (description.isEmpty) {
      description = _extractDescriptionFromLabeledLine(cleaned);
    }
    if (description.isEmpty) {
      description = _buildFallbackSpeechText(raw);
    }

    if (risk.isEmpty) {
      risk = _inferRiskLevel('$obstacle $description');
    }

    if (obstacle.isEmpty) {
      obstacle = '未明确';
    }

    if (description.isEmpty) {
      return null;
    }

    return LiteVisionMeta(
      obstacleText: obstacle,
      riskLevel: risk,
      briefDescription: _clipTtsText(description),
    );
  }

  String _extractDescriptionFromLabeledLine(String raw) {
    final normalized = raw.replaceAll('：', ':');
    final match = RegExp(r'描述\s*:\s*(.+?)(?=(；|;|$))').firstMatch(normalized);
    final text = match?.group(1)?.trim() ?? '';
    return text;
  }

  String _inferRiskLevel(String text) {
    final lower = text.toLowerCase();
    final highKeys = ['车辆', '车流', '台阶', '坑', '施工', '快速接近'];
    final mediumKeys = ['障碍', '拥挤', '昏暗', '湿滑'];
    final lowKeys = ['通畅', '无明显障碍'];

    if (highKeys.any((k) => text.contains(k) || lower.contains(k))) {
      return '高';
    }
    if (mediumKeys.any((k) => text.contains(k) || lower.contains(k))) {
      return '中';
    }
    if (lowKeys.any((k) => text.contains(k) || lower.contains(k))) {
      return '低';
    }
    return '未知';
  }

  String _buildFallbackSpeechText(String raw) {
    final decoded = _decodeJsonObject(raw);
    if (decoded != null) {
      final ttsText = _clipTtsText(_nonEmptyString(decoded['tts_text']) ?? '');
      if (ttsText.isNotEmpty) {
        return ttsText;
      }

      final summary = _clipTtsText(_nonEmptyString(decoded['summary']) ?? '');
      if (summary.isNotEmpty) {
        return summary;
      }

      final ocrFocus = decoded['ocr_focus'];
      if (ocrFocus is List) {
        for (final item in ocrFocus) {
          final map = _asStringMap(item);
          final text = _clipTtsText(_nonEmptyString(map?['text']) ?? '');
          if (text.isNotEmpty) {
            return text;
          }
        }
      }
    }

    final extracted = _extractQuotedField(raw, 'tts_text') ??
        _extractQuotedField(raw, 'summary');
    if (extracted != null) {
      final clipped = _clipTtsText(extracted);
      if (clipped.isNotEmpty) {
        return clipped;
      }
    }

    final cleanedText = raw
        .replaceAll(RegExp(r'```(?:json)?', caseSensitive: false), ' ')
        .replaceAll('```', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleanedText.isEmpty) {
      return '';
    }
    if (cleanedText.startsWith('{') && cleanedText.endsWith('}')) {
      return '';
    }
    return _clipTtsText(cleanedText);
  }

  String? _extractQuotedField(String raw, String fieldName) {
    final match = RegExp('"$fieldName"\\s*:\\s*"([^"\\n]+)"').firstMatch(raw);
    final value = match?.group(1)?.trim();
    if (value == null || value.isEmpty) {
      return null;
    }
    return value;
  }

  String _clipTtsText(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    return trimmed.length > _maxTtsLength
        ? trimmed.substring(0, _maxTtsLength)
        : trimmed;
  }

  Map<String, dynamic>? _asStringMap(dynamic value) {
    if (value is Map) {
      try {
        return Map<String, dynamic>.from(value);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  String? _nonEmptyString(dynamic value) {
    if (value is! String) {
      return null;
    }
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  List<Map<String, String>> _truncateHistory(List<Map<String, String>> history) {
    const maxRounds = 6;
    const maxChars = 120;

    final filtered = history
        .where((m) => (m['role'] == 'user' || m['role'] == 'assistant'))
        .toList();

    final start = filtered.length > maxRounds ? filtered.length - maxRounds : 0;
    final window = filtered.sublist(start);

    return window.map((message) {
      final role = message['role'] ?? '';
      final content = (message['content'] ?? '').trim();
      final clipped =
          content.length > maxChars ? content.substring(0, maxChars) : content;
      return {'role': role, 'content': clipped};
    }).toList();
  }

  String _singleTurnPrompt(
    String? question, {
    bool preferLitePrompt = false,
  }) {
    final q = question?.trim();
    if (preferLitePrompt) {
      if (q == null || q.isEmpty) {
        return '只基于当前图片输出一行：障碍:xxx；风险:低|中|高；描述:xxx。不要JSON，不要解释。';
      }
      return '只基于当前图片回答问题：$q。输出一行：障碍:xxx；风险:低|中|高；描述:xxx。不要JSON，不要解释。';
    }

    if (q == null || q.isEmpty) {
      return '只基于当前图片输出一行：障碍:xxx；风险:低|中|高；描述:xxx。不要JSON，不要解释。';
    }
    return '只基于当前图片回答问题：$q。输出一行：障碍:xxx；风险:低|中|高；描述:xxx。不要JSON，不要解释。';
  }

  Future<File> _prepareImageForUpload(File imageFile) async {
    try {
      final compressed = await FlutterImageCompress.compressAndGetFile(
        imageFile.path,
        '${imageFile.path}.compressed.jpg',
        minWidth: 720,
        minHeight: 720,
        quality: 75,
        format: CompressFormat.jpeg,
      );
      if (compressed == null) {
        return imageFile;
      }
      return File(compressed.path);
    } catch (_) {
      return imageFile;
    }
  }

  Future<String> _buildBase64ImageDataUrl(File imageFile) async {
    final bytes = await imageFile.readAsBytes();
    final base64Data = base64Encode(bytes);
    final ext = _detectImageExt(imageFile.path);
    return 'data:image/$ext;base64,$base64Data';
  }

  String _detectImageExt(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'png';
    if (lower.endsWith('.webp')) return 'webp';
    if (lower.endsWith('.gif')) return 'gif';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'jpeg';
    return 'jpeg';
  }

  String _extractResponseText(dynamic data) {
    if (data is! Map) {
      return '';
    }

    final output = data['output'];
    if (output is List) {
      for (final item in output) {
        if (item is Map) {
          final content = item['content'];
          if (content is List) {
            for (final segment in content) {
              if (segment is Map) {
                final text = segment['text'];
                if (text is String && text.trim().isNotEmpty) {
                  return text.trim();
                }
              }
            }
          }
        }
      }
    }

    final outputText = data['output_text'];
    if (outputText is String && outputText.trim().isNotEmpty) {
      return outputText.trim();
    }

    return '';
  }
}
