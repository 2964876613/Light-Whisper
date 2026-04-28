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
  static const String _defaultVisionPrompt = '请详细描述这张图片的内容';
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

