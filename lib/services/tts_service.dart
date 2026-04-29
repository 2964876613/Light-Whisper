import 'dart:convert';
import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class TtsService {
  TtsService._internal();

  static final TtsService instance = TtsService._internal();

  final Dio _dio = Dio();
  AudioPlayer? _player;

  Future<bool> speak(String text) async {
    final content = text.trim();
    if (content.isEmpty) return false;

    try {
      // 1. 严格读取语音专属 Key，移除任何大模型 Key 的备选 fallback
      final apiKey = dotenv.env['TTS_API_KEY']?.trim() ?? '';
      if (apiKey.isEmpty) {
        throw Exception('Missing TTS_API_KEY in .env');
      }

      // 2. 读取 Resource ID，如果没有配置则默认使用最新的 2.0 模型
      final resourceId =
          (dotenv.env['TTS_API_RESOURCE_ID']?.trim().isNotEmpty ?? false)
              ? dotenv.env['TTS_API_RESOURCE_ID']!.trim()
              : 'seed-tts-2.0';

      final response = await _dio.post(
        'https://openspeech.bytedance.com/api/v3/tts/unidirectional',
        options: Options(
          // 必须开启流式接收响应，否则 Dio 可能会截断数据
          responseType: ResponseType.plain, 
          headers: {
            'X-Api-Key': apiKey,
            'X-Api-Resource-Id': resourceId,
            'Content-Type': 'application/json',
          },
        ),
        data: {
          'user': {'uid': 'lightwhisper_user'},
          'req_params': {
            'text': content,
            'speaker': 'zh_female_vv_uranus_bigtts',
            'audio_params': {
              'format': 'mp3',
              'sample_rate': 24000,
            },
          },
        },
      );

      final body = response.data;
      String fullBase64Audio = '';

      // 3. 处理分块传输的“多行 JSON 字符串”
      if (body is String) {
        // 按换行符切开每一小块
        final lines = body.split('\n');
        for (var line in lines) {
          if (line.trim().isEmpty) continue;
          
          try {
            final chunk = jsonDecode(line);
            // 提取出每一块里面的 base64 音频碎片并拼接到总字符串上
            if (chunk['data'] != null && chunk['data'] is String) {
              fullBase64Audio += chunk['data'] as String;
            }
            // 拦截并抛出服务端的业务报错（如鉴权失败等）
            if (chunk.containsKey('code') && chunk['code'] != 0 && chunk['code'] != 20000000) {
              debugPrint('[TTS] Server Warning: ${chunk['message']}');
            }
          } catch (e) {
            // 如果某一行不是合法 JSON，忽略它继续往下走，防止整段崩溃
            debugPrint('[TTS] 忽略无法解析的行: $e');
          }
        }
      } 
      // 4. 兼容性兜底：如果服务器因为文本太短，一次性返回了一个完整的字典
      else if (body is Map<String, dynamic>) {
        if (body['data'] != null) {
          fullBase64Audio = body['data'] as String;
        }
      }

      if (fullBase64Audio.isEmpty) {
        throw Exception('TTS返回的音频数据为空或解析失败');
      }

      // 5. 将拼接完整的 Base64 字符串一次性解码成音频流
      final Uint8List bytes = base64Decode(fullBase64Audio);

      // 6. 重置播放器并播放最新音频
      await _player?.stop();
      await _player?.dispose();
      _player = AudioPlayer();
      await _player!.play(BytesSource(bytes));

      return true;
    } catch (e, st) {
      debugPrint('[TTS] cloud speak failed: $e');
      
      // 7. 核心排错日志
      if (e is DioException) {
        debugPrint('[TTS] HTTP Status: ${e.response?.statusCode}');
        debugPrint('[TTS] 火山引擎真实报错内容: ${e.response?.data}');
      }
      
      debugPrint('$st');
      try {
        await HapticFeedback.heavyImpact(); // 物理震动兜底
      } catch (_) {}
      return false;
    }
  }

  Future<void> stop() async {
    try {
      await _player?.stop();
    } catch (e) {
      debugPrint('[TTS] stop failed: $e');
    }
  }
}