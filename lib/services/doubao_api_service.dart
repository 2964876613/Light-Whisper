import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

class StructuredVisionResult {
  const StructuredVisionResult({
    required this.sceneType,
    required this.safetyLevel,
    required this.safetyConfidence,
    required this.fallbackNeeded,
    required this.ttsText,
    required this.raw,
  });

  final String sceneType;
  final String safetyLevel;
  final double safetyConfidence;
  final bool fallbackNeeded;
  final String ttsText;
  final Map<String, dynamic> raw;
}

class DoubaoApiService {
  DoubaoApiService({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: _baseUrl,
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 15),
                sendTimeout: const Duration(seconds: 15),
                headers: const {'Content-Type': 'application/json'},
              ),
            );

  final Dio _dio;

  static const String _baseUrl = 'https://ark.cn-beijing.volces.com/api/v3';
  static const String _responsesPath = '/responses';

  static const String _safetySystemPrompt = '''你是“光语 (LightWhisper)”的核心视觉引擎，专门为视障人士提供高可靠性的环境感知与数字内容解析。你的输出将直接通过 TTS (语音合成) 播报给用户，因此你的回答必须绝对安全、极度简练、客观准确。

【核心安全原则：最高指令】
1. 严禁幻觉与猜测：如果你对画面内容的确信度低于90%，或者画面模糊、严重曝光、被遮挡，必须立即中断解析，严格回复：“画面模糊，无法识别，请结合导盲杖判断。”
2. 绝对禁止危险指令：永远不要告诉用户“绝对安全”或“可以放心前行”。你只是辅助雷达，客观描述环境，不替用户做生死决定。
3. 零废话原则：严禁使用“在这张图片中”、“我看到了”、“看起来像是”等前置语。直接输出结论。

【场景一：户外环境模式（当识别到自然环境照片时）】
请按以下优先级进行扫描并输出，单次播报控制在15个字以内：
1. 交通信号：首先寻找红绿灯。格式：“前方红绿灯：[红/绿/黄]灯”。
2. 致命危险：寻找台阶下沉、坑洼、行驶中的车辆。格式：“[方位]，[预估距离]，[危险物]”。
3. 阻挡物：寻找电线杆、共享单车、墙壁。格式：“[方位]，[预估距离]，[障碍物]”。
示例输出：“正前方，两米，共享单车阻挡。”

【场景二：数字界面模式（当识别到手机截图或海报时）】
提取核心信息，忽略无关紧要的装饰元素。
1. 明确类型：一句话概括这是什么页面（如：微信聊天界面、淘宝商品页、街边菜单）。
2. 核心提取：提取画面中心最关键的文字或按钮功能。
示例输出：“支付页面。中心是‘确认付款’按钮，金额五十元。”

【用户对话处理（针对 Pro 用户追问）】
当用户就刚才的图片进行语音追问时，你的回答依然需要遵循“极简且客观”的原则，直接回答用户关于方位、颜色、文字的具体问题，不要延展任何无关信息。''';

  static const String _structuredJsonUserPrompt = '''请严格按以下要求返回：
1) 只返回一个 JSON 对象，不要返回 markdown、代码块、解释文本或任何前后缀。
2) 所有顶层字段必须存在，不可省略。
3) 若任何关键判断确信度低于0.9，必须 fallback_needed=true，且 tts_text 必须是“画面模糊，无法识别，请结合导盲杖判断。”。
4) distance_m 单位为米，confidence 范围为 0 到 1。
5) 枚举值必须严格来自给定集合。

JSON 格式如下：
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
''';

  static const String fallbackMessage = '网络环境不佳，AI暂时无法连线，请依靠导盲杖确保安全。';
  static const String recognitionFallbackMessage = '画面信息不足，暂时无法稳定识别，请调整角度后重试。';
  static const String _safetyFallbackTts = '画面模糊，无法识别，请结合导盲杖判断。';

  String get _modelId => dotenv.env['VOLC_MODEL_ID']?.trim() ?? '';

  String get _apiKey => dotenv.env['ARK_API_KEY']?.trim() ?? '';

  Future<String> analyzeImage(File imageFile, {String? singleQuestion}) async {
    final response = await _analyzeImageStructuredWithStatus(
      imageFile,
      singleQuestion: singleQuestion,
    );
    if (response.result != null) {
      return response.result!.ttsText;
    }
    return response.networkError ? fallbackMessage : recognitionFallbackMessage;
  }

  Future<StructuredVisionResult?> analyzeImageStructured(
    File imageFile, {
    String? singleQuestion,
  }) async {
    final response = await _analyzeImageStructuredWithStatus(
      imageFile,
      singleQuestion: singleQuestion,
    );
    return response.result;
  }

  Future<({StructuredVisionResult? result, bool networkError})>
      _analyzeImageStructuredWithStatus(
    File imageFile, {
    String? singleQuestion,
  }) async {
    if (!await imageFile.exists()) {
      return (result: null, networkError: false);
    }

    if (_apiKey.isEmpty || _modelId.isEmpty) {
      return (result: null, networkError: true);
    }

    File? preparedImage;
    try {
      preparedImage = await _prepareImageForUpload(imageFile);
      final imageDataUrl = await _buildBase64ImageDataUrl(preparedImage);

      final payload = {
        'model': _modelId,
        'input': [
          {
            'role': 'system',
            'content': [
              {'type': 'input_text', 'text': _safetySystemPrompt},
            ],
          },
          {
            'role': 'user',
            'content': [
              {'type': 'input_image', 'image_url': imageDataUrl},
              {
                'type': 'input_text',
                'text': _singleTurnPrompt(singleQuestion),
              },
            ],
          }
        ],
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
        return (result: null, networkError: false);
      }

      return (result: _parseStructuredResult(parsed), networkError: false);
    } catch (e) {
      debugPrint('===== 网络请求引发了异常 =====');
      debugPrint(e.toString());

      if (e is DioException && e.response != null) {
        debugPrint('接口详细报错: ${e.response?.data}');
      }

      debugPrint('==============================');
      return (result: null, networkError: true);
    } finally {
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

  StructuredVisionResult? _parseStructuredResult(String raw) {
    final map = _decodeJsonObject(raw);
    if (map == null) {
      return null;
    }

    const sceneTypes = {'outdoor', 'digital', 'unknown'};
    const safetyLevels = {'low', 'medium', 'high', 'critical'};
    const hazardTypes = {'vehicle', 'stairs', 'pit', 'obstacle', 'unknown'};
    const hazardDirections = {
      'front',
      'front_left',
      'front_right',
      'left',
      'right',
      'rear',
      'unknown',
    };
    const trafficLightStates = {'red', 'yellow', 'green', 'none', 'unknown'};
    const ocrRoles = {'button', 'title', 'amount', 'label', 'unknown'};

    final sceneType = map['scene_type'];
    final summary = map['summary'];
    final safety = map['safety'];
    final hazards = map['hazards'];
    final trafficLight = map['traffic_light'];
    final ocrFocus = map['ocr_focus'];
    final ttsText = map['tts_text'];

    if (sceneType is! String || !sceneTypes.contains(sceneType)) return null;
    if (summary is! String) return null;
    if (safety is! Map<String, dynamic>) return null;
    if (hazards is! List) return null;
    if (trafficLight is! Map<String, dynamic>) return null;
    if (ocrFocus is! List) return null;
    if (ttsText is! String || ttsText.trim().isEmpty) return null;

    final safetyLevel = safety['level'];
    final safetyConfidence = _toDouble(safety['confidence']);
    final fallbackNeeded = safety['fallback_needed'];
    if (safetyLevel is! String || !safetyLevels.contains(safetyLevel)) return null;
    if (safetyConfidence == null || safetyConfidence < 0 || safetyConfidence > 1) {
      return null;
    }
    if (fallbackNeeded is! bool) return null;

    for (final item in hazards) {
      if (item is! Map<String, dynamic>) return null;
      final type = item['type'];
      final direction = item['direction'];
      final distance = _toDouble(item['distance_m']);
      final confidence = _toDouble(item['confidence']);
      if (type is! String || !hazardTypes.contains(type)) return null;
      if (direction is! String || !hazardDirections.contains(direction)) {
        return null;
      }
      if (distance == null || distance < 0) return null;
      if (confidence == null || confidence < 0 || confidence > 1) return null;
    }

    final trafficState = trafficLight['state'];
    final trafficConfidence = _toDouble(trafficLight['confidence']);
    if (trafficState is! String || !trafficLightStates.contains(trafficState)) {
      return null;
    }
    if (trafficConfidence == null || trafficConfidence < 0 || trafficConfidence > 1) {
      return null;
    }

    for (final item in ocrFocus) {
      if (item is! Map<String, dynamic>) return null;
      final text = item['text'];
      final role = item['role'];
      final confidence = _toDouble(item['confidence']);
      if (text is! String) return null;
      if (role is! String || !ocrRoles.contains(role)) return null;
      if (confidence == null || confidence < 0 || confidence > 1) return null;
    }

    final hasLowHazardConfidence = hazards.isNotEmpty && hazards.any((item) {
      if (item is! Map<String, dynamic>) return true;
      final confidence = _toDouble(item['confidence']);
      return confidence == null || confidence < 0.9;
    });

    final shouldFallback =
        safetyConfidence < 0.9 || trafficConfidence < 0.9 || hasLowHazardConfidence;

    if (shouldFallback && fallbackNeeded != true) {
      return null;
    }

    final resolvedTts = fallbackNeeded == true
        ? _safetyFallbackTts
        : (ttsText.trim().length > 30 ? ttsText.trim().substring(0, 30) : ttsText.trim());

    return StructuredVisionResult(
      sceneType: sceneType,
      safetyLevel: safetyLevel,
      safetyConfidence: safetyConfidence,
      fallbackNeeded: fallbackNeeded,
      ttsText: resolvedTts,
      raw: map,
    );
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

  double? _toDouble(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    return null;
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

  String _singleTurnPrompt(String? question) {
    final q = question?.trim();
    if (q == null || q.isEmpty) {
      return _structuredJsonUserPrompt;
    }
    return '$_structuredJsonUserPrompt\n\n用户本轮问题：$q\n只回答当前这张图，不要引用历史对话。';
  }

  Future<File> _prepareImageForUpload(File imageFile) async {
    try {
      final compressed = await FlutterImageCompress.compressAndGetFile(
        imageFile.path,
        '${imageFile.path}.compressed.jpg',
        minWidth: 1280,
        minHeight: 1280,
        quality: 78,
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
