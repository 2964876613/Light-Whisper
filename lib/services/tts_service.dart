import 'dart:convert'; // JSON/base64 处理
import 'package:audioplayers/audioplayers.dart'; // 音频播放
import 'package:dio/dio.dart'; // HTTP 请求
import 'package:flutter/foundation.dart'; // 调试日志
import 'package:flutter/services.dart'; // 失败触觉反馈
import 'package:flutter_dotenv/flutter_dotenv.dart'; // 读取 .env 配置

import 'voice_settings_service.dart'; // 语音包选择与合法性

/// TTS 接口配置。
class _TtsConfig {
  const _TtsConfig({required this.apiKey, required this.resourceId}); // 只读配置

  final String apiKey; // 鉴权 key
  final String resourceId; // 资源 id（模型/路由）
}

/// 云端 TTS 服务：
/// - 请求火山语音接口拿到音频；
/// - 解析并播放音频字节；
/// - 对外暴露 speak/stop。
class TtsService {
  TtsService._internal(); // 私有构造，限制单例

  static final TtsService instance = TtsService._internal(); // 全局单例

  final Dio _dio = Dio(); // HTTP 客户端
  AudioPlayer? _player; // 当前播放器实例

  /// 播报文本，成功返回 true。
  Future<bool> speak(String text) async {
    final content = text.trim(); // 清理文本
    if (content.isEmpty) return false; // 空文本直接失败

    try {
      final config = _loadConfig(); // 读取并校验配置
      final speakerId = await VoiceSettingsService.resolveValidVoiceIdOrDefault(); // 获取当前合法语音包
      final responseBody = await _requestTts(
        content: content, // 要播报的文本
        speakerId: speakerId, // 语音人
        apiKey: config.apiKey, // 鉴权 key
        resourceId: config.resourceId, // 资源 id
      );

      final fullBase64Audio = _extractBase64Audio(responseBody); // 解析 base64 音频
      if (fullBase64Audio.isEmpty) {
        throw Exception('TTS返回的音频数据为空或解析失败'); // 空音频视为失败
      }

      final Uint8List bytes = base64Decode(fullBase64Audio); // base64 -> 二进制
      await _playBytes(bytes); // 播放音频
      return true; // 成功
    } catch (e, st) {
      debugPrint('[TTS] cloud speak failed: $e'); // 错误日志

      if (e is DioException) {
        debugPrint('[TTS] HTTP Status: ${e.response?.statusCode}'); // 状态码
        debugPrint('[TTS] 火山引擎真实报错内容: ${e.response?.data}'); // 服务端返回体
      }

      debugPrint('$st'); // 栈日志
      try {
        await HapticFeedback.heavyImpact(); // 失败时给触觉反馈
      } catch (_) {}
      return false; // 失败
    }
  }

  /// 读取并校验 TTS 配置。
  _TtsConfig _loadConfig() {
    final apiKey = dotenv.env['TTS_API_KEY']?.trim() ?? ''; // 读取 key
    if (apiKey.isEmpty) {
      throw Exception('Missing TTS_API_KEY in .env'); // 缺失即抛错
    }

    final resourceId =
        (dotenv.env['TTS_API_RESOURCE_ID']?.trim().isNotEmpty ?? false)
            ? dotenv.env['TTS_API_RESOURCE_ID']!.trim() // 优先使用环境配置
            : 'seed-tts-2.0'; // 否则回退默认资源 id

    return _TtsConfig(apiKey: apiKey, resourceId: resourceId); // 返回配置对象
  }

  /// 发起 TTS 请求。
  Future<dynamic> _requestTts({
    required String content, // 文本
    required String speakerId, // 发音人
    required String apiKey, // 鉴权 key
    required String resourceId, // 资源 id
  }) async {
    final response = await _dio.post(
      'https://openspeech.bytedance.com/api/v3/tts/unidirectional', // 火山 TTS 接口
      options: Options(
        responseType: ResponseType.plain, // 用 plain 保留分块行原始格式
        headers: {
          'X-Api-Key': apiKey, // 鉴权头
          'X-Api-Resource-Id': resourceId, // 资源头
          'Content-Type': 'application/json', // JSON 请求体
        },
      ),
      data: {
        'user': {'uid': 'lightwhisper_user'}, // 用户标识
        'req_params': {
          'text': content, // 待合成文本
          'speaker': speakerId, // 语音包 id
          'audio_params': {
            'format': 'mp3', // 输出格式
            'sample_rate': 24000, // 采样率
          },
        },
      },
    );
    return response.data; // 返回原始响应体
  }

  /// 提取 base64 音频。
  String _extractBase64Audio(dynamic body) {
    if (body is String) {
      return _extractFromChunkLines(body); // 分块行协议解析
    }
    if (body is Map<String, dynamic>) {
      final data = body['data']; // 结构化返回时直接取 data
      if (data is String) return data;
    }
    return ''; // 其他形态返回空
  }

  /// 解析分块行协议并拼接音频。
  String _extractFromChunkLines(String body) {
    var fullBase64Audio = ''; // 聚合结果
    final lines = body.split('\n'); // 逐行分割

    for (final line in lines) {
      if (line.trim().isEmpty) continue; // 跳过空行

      try {
        final chunk = jsonDecode(line); // 每行尝试解析 JSON
        if (chunk is Map<String, dynamic>) {
          final data = chunk['data']; // 每块音频片段
          if (data is String) {
            fullBase64Audio += data; // 逐块拼接
          }

          final code = chunk['code']; // 服务端状态码
          if (code != null && code != 0 && code != 20000000) {
            debugPrint('[TTS] Server Warning: ${chunk['message']}'); // 非成功码记录警告
          }
        }
      } catch (e) {
        debugPrint('[TTS] 忽略无法解析的行: $e'); // 容错：坏行不影响整体
      }
    }

    return fullBase64Audio; // 返回完整音频
  }

  /// 播放字节流音频。
  Future<void> _playBytes(Uint8List bytes) async {
    await _player?.stop(); // 停止旧播放器
    await _player?.dispose(); // 释放旧播放器
    _player = AudioPlayer(); // 新建播放器实例
    await _player!.play(BytesSource(bytes)); // 播放内存字节
  }

  /// 停止播报。
  Future<void> stop() async {
    try {
      await _player?.stop(); // 停止当前播放
    } catch (e) {
      debugPrint('[TTS] stop failed: $e'); // 停止失败仅记录，不抛异常
    }
  }
}
