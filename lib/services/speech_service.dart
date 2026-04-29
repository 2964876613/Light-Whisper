import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:permission_handler/permission_handler.dart';

import 'asr_service.dart';

enum AsrInitStatus {
  ready,
  permissionDenied,
  recognizerUnavailable,
  initFailed,
}

class SpeechService {
  SpeechService({AsrService? asrService})
      : _asrService = asrService ?? AsrService.instance;

  final AsrService _asrService;

  String _lastPartialText = '';
  AsrInitStatus _lastInitStatus = AsrInitStatus.initFailed;

  bool get isListening => _asrService.isRecording;
  AsrInitStatus get lastInitStatus => _lastInitStatus;

  Future<bool> ensurePermissionAndInit() async {
    final status = await ensurePermissionAndInitStatus();
    return status == AsrInitStatus.ready;
  }

  Future<AsrInitStatus> ensurePermissionAndInitStatus() async {
    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      _lastInitStatus = AsrInitStatus.permissionDenied;
      return _lastInitStatus;
    }

    final apiKey = dotenv.env['ASR_API_KEY']?.trim() ?? '';
    final resourceId = dotenv.env['ASR_API_RESOURCE_ID']?.trim() ?? '';
    if (apiKey.isEmpty || resourceId.isEmpty) {
      _lastInitStatus = AsrInitStatus.initFailed;
      return _lastInitStatus;
    }

    _lastInitStatus = AsrInitStatus.ready;
    return _lastInitStatus;
  }

  Future<void> startListening({
    required ValueChanged<String> onText,
    String localeId = 'zh_CN',
  }) async {
    _lastPartialText = '';
    debugPrint('[ASR] startListening locale=$localeId');
    final ok = await ensurePermissionAndInit();
    if (!ok) {
      throw Exception('麦克风权限未授予或语音识别服务不可用');
    }

    if (_asrService.isRecording) {
      return;
    }

    try {
      await _asrService.startRecording((text, isDefinite) {
        final value = text.trim();
        if (value.isEmpty) {
          return;
        }
        _lastPartialText = value;
        onText(value);
      });
      _lastInitStatus = AsrInitStatus.ready;
    } catch (e) {
      debugPrint('[ASR] startListening failed: $e');
      final message = e.toString();
      if (message.contains('Missing ASR_')) {
        _lastInitStatus = AsrInitStatus.initFailed;
      } else {
        _lastInitStatus = AsrInitStatus.recognizerUnavailable;
      }
      rethrow;
    }
  }

  Future<String> stopListeningAndGetFinalText() async {
    final words = (await _asrService.stopRecording()).trim();
    debugPrint('[ASR] stop result words="$words" cached="$_lastPartialText"');
    if (words.isNotEmpty) {
      return words;
    }
    return _lastPartialText.trim();
  }

  Future<void> cancelListening() async {
    await _asrService.cancelRecording();
  }
}
