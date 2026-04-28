import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';

class SpeechService {
  SpeechService({SpeechToText? speechToText})
      : _speechToText = speechToText ?? SpeechToText();

  final SpeechToText _speechToText;

  bool _initialized = false;

  bool get isListening => _speechToText.isListening;

  Future<bool> ensurePermissionAndInit() async {
    final micStatus = await Permission.microphone.request();
    if (!micStatus.isGranted) {
      return false;
    }

    if (_initialized) {
      return true;
    }

    _initialized = await _speechToText.initialize();
    return _initialized;
  }

  Future<void> startListening({
    required ValueChanged<String> onText,
    String localeId = 'zh_CN',
  }) async {
    if (!_initialized) {
      final ok = await ensurePermissionAndInit();
      if (!ok) {
        throw Exception('麦克风权限未授予或语音识别不可用');
      }
    }

    if (_speechToText.isListening) {
      return;
    }

    await _speechToText.listen(
      localeId: localeId,
      listenMode: ListenMode.dictation,
      onResult: (SpeechRecognitionResult result) {
        onText(result.recognizedWords.trim());
      },
      pauseFor: const Duration(seconds: 2),
      listenFor: const Duration(seconds: 30),
      partialResults: true,
      cancelOnError: true,
    );
  }

  Future<String> stopListeningAndGetFinalText() async {
    if (!_speechToText.isListening) {
      return '';
    }

    await _speechToText.stop();

    final words = _speechToText.lastRecognizedWords.trim();
    return words;
  }

  Future<void> cancelListening() async {
    if (_speechToText.isListening) {
      await _speechToText.cancel();
    }
  }
}
