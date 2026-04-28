import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

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
  
  static const String _defaultVisionPrompt = '''你是“光语 (LightWhisper)”的核心视觉引擎，专门为视障人士提供高可靠性的环境感知与数字内容解析。你的输出将直接通过 TTS (语音合成) 播报给用户，因此你的回答必须绝对安全、极度简练、客观准确。

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
  static const String fallbackMessage = '网络环境不佳，AI暂时无法连线，请依靠导盲杖确保安全。';

  String get _modelId => dotenv.env['VOLC_MODEL_ID']?.trim() ?? '';

  String get _apiKey => dotenv.env['ARK_API_KEY']?.trim() ?? '';

  Future<String> analyzeImage(File imageFile) async {
    if (!await imageFile.exists()) {
      return fallbackMessage;
    }

    if (_apiKey.isEmpty || _modelId.isEmpty) {
      return fallbackMessage;
    }

    try {
      final imageDataUrl = await _buildBase64ImageDataUrl(imageFile);

      final payload = {
        'model': _modelId,
        'input': [
          {
            'role': 'user',
            'content': [
              {'type': 'input_image', 'image_url': imageDataUrl},
              {'type': 'input_text', 'text': _defaultVisionPrompt},
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
        return fallbackMessage;
      }
      return parsed;
    } catch (e) {
      print("===== 网络请求引发了异常 =====");
      print(e.toString());
      
      // 因为你用了 Dio，如果是接口报错（比如 Key 不对、格式错误），这段能打印出火山引擎官方的具体报错原因
      if (e is DioException && e.response != null) {
        print("接口详细报错: ${e.response?.data}");
      }
      
      print("==============================");
      return fallbackMessage;
    }
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

