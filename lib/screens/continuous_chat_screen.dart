import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';

import '../services/doubao_api_service.dart';
import '../services/speech_service.dart';
import '../services/tts_service.dart';

class ContinuousChatScreen extends StatefulWidget {
  const ContinuousChatScreen({
    super.key,
    required this.initialAssistantText,
    this.initialContextHint = '',
  });

  final String initialAssistantText;
  final String initialContextHint;

  @override
  State<ContinuousChatScreen> createState() => _ContinuousChatScreenState();
}

class _ContinuousChatScreenState extends State<ContinuousChatScreen> {
  final DoubaoApiService _aiService = DoubaoApiService();
  final SpeechService _speechService = SpeechService();
  bool _isLoading = false;
  bool _isRecording = false;
  bool _isAsrRunning = false;
  String _liveSpeechText = '';
  String _currentReply = '';

  final List<Map<String, String>> _chatHistory = [];

  @override
  void initState() {
    super.initState();
    _currentReply = widget.initialAssistantText;
    _chatHistory.add({'role': 'assistant', 'content': widget.initialAssistantText});
  }

  @override
  void dispose() {
    unawaited(TtsService.instance.stop());
    unawaited(_speechService.cancelListening());
    super.dispose();
  }

  Future<void> _vibrateError() async {
    final hasVibrator = await Vibration.hasVibrator();
    if (!hasVibrator) return;
    await Vibration.vibrate(duration: 180, amplitude: 200);
  }

  Future<void> _speak(String text) async {
    await TtsService.instance.speak(text);
  }

  Future<void> _speakError(String message) async {
    await _vibrateError();
    await _speak(message);
  }

  Future<void> _onLongPressStart() async {
    if (_isAsrRunning || _isLoading) return;

    final initStatus = await _speechService.ensurePermissionAndInitStatus();
    if (initStatus != AsrInitStatus.ready) {
      final message = switch (initStatus) {
        AsrInitStatus.permissionDenied => '麦克风权限未授予，请在设置中开启',
        AsrInitStatus.recognizerUnavailable => '语音识别服务连接失败，请检查网络后重试',
        AsrInitStatus.initFailed => '语音识别配置缺失，请检查 .env',
        AsrInitStatus.ready => '',
      };
      if (message.isNotEmpty) {
        await _speakError(message);
      }
      return;
    }

    await HapticFeedback.heavyImpact();
    await TtsService.instance.stop();

    if (!mounted) return;
    setState(() {
      _isRecording = true;
      _isAsrRunning = true;
      _liveSpeechText = '';
    });

    try {
      await _speechService.startListening(
        onText: (value) {
          if (!mounted) return;
          if (_liveSpeechText == value) return;
          setState(() {
            _liveSpeechText = value;
          });
        },
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isRecording = false;
        _isAsrRunning = false;
      });
      await _speakError('语音识别启动失败');
    }
  }

  Future<void> _onLongPressEnd() async {
    if (!_isAsrRunning) return;

    await HapticFeedback.mediumImpact();

    if (!_speechService.isListening) {
      await Future.delayed(const Duration(milliseconds: 380));
    }

    String finalText = '';
    try {
      finalText = await _speechService.stopListeningAndGetFinalText();
    } catch (_) {
      await _speakError('语音识别结束失败');
    }

    if (!mounted) return;
    setState(() {
      _isRecording = false;
      _isAsrRunning = false;
    });

    final question = finalText.trim().isNotEmpty ? finalText.trim() : _liveSpeechText.trim();
    if (question.isEmpty) {
      await _speakError('没有识别到有效语音');
      return;
    }

    await _sendFollowupQuestion(question);
  }

  Future<void> _sendFollowupQuestion(String text) async {
    if (_isLoading || text.trim().isEmpty) return;

    setState(() {
      _isLoading = true;
      _chatHistory.add({'role': 'user', 'content': text.trim()});
    });

    try {
      final assistantReply = await _aiService.chatWithText(
        history: _chatHistory,
        latestQuestion: text.trim(),
      );

      if (!mounted) return;
      setState(() {
        _currentReply = assistantReply;
        _chatHistory.add({'role': 'assistant', 'content': assistantReply});
        _isLoading = false;
      });

      await _speak(assistantReply);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
      await _speakError('网络超时，请稍后重试');
    }
  }

  void _handleDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity > 250) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Semantics(
        label: '连续对话页面，长按屏幕提问，向右滑动返回',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragEnd: _handleDragEnd,
          onLongPressStart: (_) => _onLongPressStart(),
          onLongPressEnd: (_) => _onLongPressEnd(),
          child: Stack(
            children: [
              SafeArea(
                child: Column(
                  children: [
                    const SizedBox(height: 16),
                    const Text(
                      '连续对话',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Container(
                          width: double.infinity,
                          color: Colors.black,
                          padding: const EdgeInsets.all(16),
                          child: _isLoading
                              ? const Center(
                                  child: CircularProgressIndicator(color: Colors.white),
                                )
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (widget.initialContextHint.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(bottom: 10),
                                        child: Text(
                                          widget.initialContextHint,
                                          style: const TextStyle(
                                            color: Colors.yellowAccent,
                                            fontSize: 15,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    Text(
                                      _currentReply,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 21,
                                        height: 1.45,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                      color: Colors.black,
                      child: Text(
                        _isRecording
                            ? '正在聆听，请继续按住屏幕'
                            : (_isLoading ? '处理中，请稍候' : '按住屏幕任意位置提问'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white, fontSize: 16),
                      ),
                    ),
                  ],
                ),
              ),
              IgnorePointer(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _isRecording ? Colors.yellowAccent : Colors.transparent,
                      width: _isRecording ? 4 : 0,
                    ),
                    color: _isRecording
                        ? Colors.yellowAccent.withValues(alpha: 0.1)
                        : Colors.transparent,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
