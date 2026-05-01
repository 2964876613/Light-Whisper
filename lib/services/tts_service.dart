import 'dart:convert';
import 'package:audioplayers/audioplayers.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'voice_settings_service.dart';

class _TtsConfig {
  const _TtsConfig({required this.apiKey, required this.resourceId});

  final String apiKey;
  final String resourceId;
}

class TtsService {
  TtsService._internal();

  static final TtsService instance = TtsService._internal();

  final Dio _dio = Dio();
  AudioPlayer? _player;

  Future<bool> speak(String text) async {
    final content = text.trim();
    if (content.isEmpty) return false;

    try {
      final config = _loadConfig();
      final speakerId = await VoiceSettingsService.resolveValidVoiceIdOrDefault();
      final responseBody = await _requestTts(
        content: content,
        speakerId: speakerId,
        apiKey: config.apiKey,
        resourceId: config.resourceId,
      );

      final fullBase64Audio = _extractBase64Audio(responseBody);
      if (fullBase64Audio.isEmpty) {
        throw Exception('TTS返回的音频数据为空或解析失败');
      }

      final Uint8List bytes = base64Decode(fullBase64Audio);
      await _playBytes(bytes);
      return true;
    } catch (e, st) {
      debugPrint('[TTS] cloud speak failed: $e');

      if (e is DioException) {
        debugPrint('[TTS] HTTP Status: ${e.response?.statusCode}');
        debugPrint('[TTS] 火山引擎真实报错内容: ${e.response?.data}');
      }

      debugPrint('$st');
      try {
        await HapticFeedback.heavyImpact();
      } catch (_) {}
      return false;
    }
  }

  _TtsConfig _loadConfig() {
    final apiKey = dotenv.env['TTS_API_KEY']?.trim() ?? '';
    if (apiKey.isEmpty) {
      throw Exception('Missing TTS_API_KEY in .env');
    }

    final resourceId =
        (dotenv.env['TTS_API_RESOURCE_ID']?.trim().isNotEmpty ?? false)
            ? dotenv.env['TTS_API_RESOURCE_ID']!.trim()
            : 'seed-tts-2.0';

    return _TtsConfig(apiKey: apiKey, resourceId: resourceId);
  }

  Future<dynamic> _requestTts({
    required String content,
    required String speakerId,
    required String apiKey,
    required String resourceId,
  }) async {
    final response = await _dio.post(
      'https://openspeech.bytedance.com/api/v3/tts/unidirectional',
      options: Options(
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
          'speaker': speakerId,
          'audio_params': {
            'format': 'mp3',
            'sample_rate': 24000,
          },
        },
      },
    );
    return response.data;
  }

  String _extractBase64Audio(dynamic body) {
    if (body is String) {
      return _extractFromChunkLines(body);
    }
    if (body is Map<String, dynamic>) {
      final data = body['data'];
      if (data is String) return data;
    }
    return '';
  }

  String _extractFromChunkLines(String body) {
    var fullBase64Audio = '';
    final lines = body.split('\n');

    for (final line in lines) {
      if (line.trim().isEmpty) continue;

      try {
        final chunk = jsonDecode(line);
        if (chunk is Map<String, dynamic>) {
          final data = chunk['data'];
          if (data is String) {
            fullBase64Audio += data;
          }

          final code = chunk['code'];
          if (code != null && code != 0 && code != 20000000) {
            debugPrint('[TTS] Server Warning: ${chunk['message']}');
          }
        }
      } catch (e) {
        debugPrint('[TTS] 忽略无法解析的行: $e');
      }
    }

    return fullBase64Audio;
  }

  Future<void> _playBytes(Uint8List bytes) async {
    await _player?.stop();
    await _player?.dispose();
    _player = AudioPlayer();
    await _player!.play(BytesSource(bytes));
  }

  Future<void> stop() async {
    try {
      await _player?.stop();
    } catch (e) {
      debugPrint('[TTS] stop failed: $e');
    }
  }
}