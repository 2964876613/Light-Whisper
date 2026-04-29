import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text/speech_recognition_result.dart';

enum AsrInitStatus {
  ready,
  permissionDenied,
  recognizerUnavailable,
  initFailed,
}

class SpeechService {
  SpeechService({SpeechToText? speechToText})
      : _speechToText = speechToText ?? SpeechToText();

  final SpeechToText _speechToText;

  bool _initialized = false;
  String _lastPartialText = '';
  AsrInitStatus _lastInitStatus = AsrInitStatus.initFailed;

  bool get isListening => _speechToText.isListening;
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

    if (_initialized) {
      _lastInitStatus = AsrInitStatus.ready;
      return _lastInitStatus;
    }

    try {
      _initialized = await _speechToText.initialize();
      _lastInitStatus = _initialized ? AsrInitStatus.ready : AsrInitStatus.initFailed;
      return _lastInitStatus;
    } on PlatformException catch (e) {
      debugPrint('[ASR] initialize platform exception: ${e.code} ${e.message}');
      _initialized = false;
      if (e.code == 'recognizerNotAvailable') {
        _lastInitStatus = AsrInitStatus.recognizerUnavailable;
        return _lastInitStatus;
      }
      _lastInitStatus = AsrInitStatus.initFailed;
      return _lastInitStatus;
    } catch (e) {
      debugPrint('[ASR] initialize failed: $e');
      _initialized = false;
      _lastInitStatus = AsrInitStatus.initFailed;
      return _lastInitStatus;
    }
  }

  Future<void> startListening({
    required ValueChanged<String> onText,
    String localeId = 'zh_CN',
  }) async {
    _lastPartialText = '';
    debugPrint('[ASR] startListening locale=$localeId initialized=$_initialized');
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
        final words = result.recognizedWords.trim();
        if (words.isNotEmpty) {
          _lastPartialText = words;
        }
        debugPrint('[ASR] onResult final=${result.finalResult} words="$words"');
        onText(words);
      },
      pauseFor: const Duration(seconds: 4),
      listenFor: const Duration(seconds: 45),
      partialResults: true,
      cancelOnError: true,
    );
  }

  Future<String> stopListeningAndGetFinalText() async {
    if (!_speechToText.isListening) {
      return _lastPartialText.trim();
    }

    await _speechToText.stop();
    await Future.delayed(const Duration(milliseconds: 320));

    final words = _speechToText.lastRecognizedWords.trim();
    debugPrint('[ASR] stop result words="$words" cached="$_lastPartialText"');
    if (words.isNotEmpty) {
      return words;
    }
    return _lastPartialText.trim();
  }

  Future<void> cancelListening() async {
    if (_speechToText.isListening) {
      await _speechToText.cancel();
    }
  }
}
