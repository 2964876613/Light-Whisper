import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:provider/provider.dart';
import 'package:vibration/vibration.dart';

import '../models/capture_source.dart';
import '../providers/user_tier_provider.dart';
import '../services/doubao_api_service.dart';
import '../services/speech_service.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.captureSource,
    required this.imagePath,
  });

  final CaptureSource captureSource;
  final String? imagePath;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final FlutterTts _tts = FlutterTts();
  final DoubaoApiService _aiVisionService = DoubaoApiService();
  final SpeechService _speechService = SpeechService();
  final TextEditingController _textController = TextEditingController();

  bool _isLoading = true;
  bool _ttsFinished = false;
  bool _isRecording = false;
  bool _isAsrRunning = false;
  String _aiResult = '';
  String _liveSpeechText = '';

  final List<Map<String, String>> _chatHistory = [];

  @override
  void initState() {
    super.initState();
    _setupTts();
    _simulateAnalyzeAndSpeak();
  }

  Future<void> _setupTts() async {
    await _tts.setLanguage('zh-CN');
    await _tts.setSpeechRate(0.44);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    _tts.setCompletionHandler(() {
      if (!mounted) return;
      setState(() {
        _ttsFinished = true;
      });
    });

    _tts.setErrorHandler((_) {
      if (!mounted) return;
      setState(() {
        _ttsFinished = true;
      });
    });
  }

  Future<void> _simulateAnalyzeAndSpeak() async {
    final path = widget.imagePath;
    final result = path == null || path.isEmpty
        ? DoubaoApiService.fallbackMessage
        : await _aiVisionService.analyzeImage(File(path));

    if (!mounted) return;
    setState(() {
      _aiResult = result;
      _isLoading = false;
      _chatHistory
        ..clear()
        ..add({'role': 'assistant', 'content': result});
    });

    await _tts.speak(result);
  }

  @override
  void dispose() {
    unawaited(_tts.stop());
    unawaited(_speechService.cancelListening());
    _textController.dispose();
    super.dispose();
  }

  void _handleDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity > 250) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _vibrateError() async {
    final hasVibrator = await Vibration.hasVibrator();
    if (!hasVibrator) return;
    await Vibration.vibrate(duration: 180, amplitude: 200);
  }

  Future<void> _speakError(String message) async {
    await _vibrateError();
    await _tts.speak(message);
  }

  Future<void> _onScreenLongPressStart() async {
    if (_isAsrRunning || _isLoading) return;

    final ready = await _speechService.ensurePermissionAndInit();
    if (!ready) {
      await _speakError('麦克风权限不可用，请检查设置');
      return;
    }

    await HapticFeedback.heavyImpact();
    await _tts.stop();

    if (!mounted) return;
    setState(() {
      _isRecording = true;
      _isAsrRunning = true;
      _liveSpeechText = '';
      _textController.text = '';
    });

    try {
      await _speechService.startListening(
        onText: (value) {
          if (!mounted) return;
          setState(() {
            _liveSpeechText = value;
            _textController.text = value;
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

  Future<void> _onScreenLongPressEnd() async {
    if (!_isAsrRunning) return;

    await HapticFeedback.mediumImpact();

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

    final cleaned = finalText.trim().isNotEmpty ? finalText.trim() : _liveSpeechText.trim();
    if (cleaned.isEmpty) {
      await _speakError('没有识别到有效语音');
      return;
    }

    _textController.text = cleaned;
    await _sendFollowupQuestion(cleaned);
  }

  Future<void> _sendFollowupQuestion(String text) async {
    if (text.trim().isEmpty) return;

    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _ttsFinished = false;
      _chatHistory.add({'role': 'user', 'content': text.trim()});
    });

    try {
      final assistantReply = await _aiVisionService.chatWithText(
        history: _chatHistory,
        latestQuestion: text.trim(),
      );

      if (!mounted) return;
      setState(() {
        _aiResult = assistantReply;
        _chatHistory.add({'role': 'assistant', 'content': assistantReply});
        _isLoading = false;
      });

      await _tts.speak(assistantReply);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
      await _speakError('网络超时，请稍后重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isProUser = context.watch<UserTierProvider>().isProUser;
    final canTalk = isProUser && _ttsFinished && !_isLoading;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Semantics(
        label: '长按屏幕开启对话',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragEnd: _handleDragEnd,
          onLongPressStart: canTalk ? (_) => _onScreenLongPressStart() : null,
          onLongPressEnd: canTalk ? (_) => _onScreenLongPressEnd() : null,
          child: Stack(
            children: [
              SafeArea(
                child: Column(
                  children: [
                    const SizedBox(height: 16),
                    Semantics(
                      header: true,
                      label: '光语解析结果',
                      child: const Text(
                        '光语解析',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Semantics(
                          liveRegion: true,
                          label: _isLoading ? '正在处理中' : 'AI解析内容：$_aiResult',
                          child: Container(
                            width: double.infinity,
                            color: Colors.black,
                            padding: const EdgeInsets.all(16),
                            child: _isLoading
                                ? const Center(
                                    child: CircularProgressIndicator(color: Colors.white),
                                  )
                                : Text(
                                    _aiResult,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 21,
                                      height: 1.45,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                      child: _buildInputArea(isProUser: isProUser, canTalk: canTalk),
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
                      color: _isRecording ? Colors.lightBlueAccent : Colors.transparent,
                      width: _isRecording ? 4 : 0,
                    ),
                    color: _isRecording
                        ? Colors.lightBlueAccent.withValues(alpha: 0.12)
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

  Widget _buildInputArea({required bool isProUser, required bool canTalk}) {
    if (!isProUser) {
      return Semantics(
        label: '当前为免费用户，单次解析结束后不支持继续对话',
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          color: Colors.black,
          child: const Text(
            '免费模式：已完成单次播报',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 16),
          ),
        ),
      );
    }

    return Semantics(
      label: canTalk ? '按住屏幕任意位置提问' : '播报中，请稍候',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        color: Colors.black,
        child: Text(
          _isRecording
              ? '正在聆听，请继续按住屏幕'
              : (canTalk ? '按住屏幕任意位置提问' : '播报中，请稍候'),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
      ),
    );
  }
}
