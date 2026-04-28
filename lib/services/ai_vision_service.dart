import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

class AiVisionService {
  AiVisionService({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: _baseUrl,
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 15),
                sendTimeout: const Duration(seconds: 15),
                headers: {'Content-Type': 'application/json'},
              ),
            );

  final Dio _dio;

  static const String _baseUrl =
      'https://operator.las.cn-beijing.volces.com/api/v3';
  static const String _modelId =
      'ark-56304c75-e796-453d-8cb2-6f5cb10a0dd4-114c3';

  static const String fallbackMessage =
      '网络环境不佳，AI暂时无法连线，请依靠导盲杖确保安全。';

  static const String _systemPrompt = '''
你是“光语 (LightWhisper)”的核心视觉引擎，专门为视障人士提供高可靠性的环境感知与数字内容解析。你的输出将直接通过 TTS (语音合成) 播报给用户，因此你的回答必须绝对安全、极度简练、客观准确。
【核心安全原则：最高指令】
1. 严禁幻觉与猜测：如果你对画面内容的确信度低于 90%，或者画面模糊、严重曝光、被遮挡，必须立即中断解析，严格回复：“画面模糊，无法识别，请结合导盲杖判断。”
2. 绝对禁止危险指令：永远不要告诉用户“绝对安全”或“可以放心前行”。你只是辅助雷达，客观描述环境，不替用户做生死决定。
3. 零废话原则：严禁使用“在这张图片中”、“我看到了”、“看起来像是”等前置语。直接输出结论。
【场景一：户外环境模式】单次播报控制在15个字以内。优先寻找红绿灯（格式：前方红绿灯：X灯），其次寻找致命危险和阻挡物（格式：[方位]，[预估距离]，[障碍物]）。
【场景二：数字界面模式】提取核心信息，忽略无关紧要的装饰元素。说明页面类型并提取中心最关键的文字或按钮功能。
''';

  Future<String> analyzeImage({
    required String? imagePath,
    String userPrompt = '请解析这张图片',
  }) async {
    try {
      if (imagePath == null || imagePath.isEmpty) {
        return fallbackMessage;
      }

      final apiKey = dotenv.env['VOLC_API_KEY']?.trim();
      if (apiKey == null || apiKey.isEmpty) {
        return fallbackMessage;
      }

      final imageDataUrl = await _buildBase64ImageDataUrl(imagePath);

      final payload = {
        'model': _modelId,
        'temperature': 0.1,
        'messages': [
          {
            'role': 'system',
            'content': _systemPrompt,
          },
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': userPrompt},
              {
                'type': 'image_url',
                'image_url': {'url': imageDataUrl},
              },
            ],
          },
        ],
      };

      final response = await _dio.post(
        '/chat/completions',
        data: payload,
        options: Options(headers: {'Authorization': 'Bearer $apiKey'}),
      );

      final content = response.data?['choices']?[0]?['message']?['content'];
      if (content is String && content.trim().isNotEmpty) {
        return content.trim();
      }

      return fallbackMessage;
    } on DioException {
      return fallbackMessage;
    } on SocketException {
      return fallbackMessage;
    } catch (_) {
      return fallbackMessage;
    }
  }

  Future<String> _buildBase64ImageDataUrl(String imagePath) async {
    final compressed = await FlutterImageCompress.compressWithFile(
      imagePath,
      minWidth: 800,
      minHeight: 800,
      quality: 70,
      format: CompressFormat.jpeg,
      keepExif: false,
      autoCorrectionAngle: true,
    );

    final bytes = compressed ?? await File(imagePath).readAsBytes();
    final base64Data = base64Encode(bytes);
    return 'data:image/jpeg;base64,$base64Data';
  }
}
