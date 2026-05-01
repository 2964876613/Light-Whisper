import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';

import '../services/doubao_api_service.dart';
import '../services/speech_service.dart';
import '../services/tts_service.dart';
import '../widgets/frosted_primitives.dart';

class ContinuousChatScreen extends StatefulWidget {
  const ContinuousChatScreen({
    super.key,
    required this.initialAssistantText,
    this.initialContextHint = '',
    this.imagePath,
  });

  final String initialAssistantText;
  final String initialContextHint;
  final String? imagePath;

  @override
  State<ContinuousChatScreen> createState() => _ContinuousChatScreenState();
}

class _ContinuousChatScreenState extends State<ContinuousChatScreen> {
  static const double _exitSwipeVelocityThreshold = 250;

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

  bool _shouldUseImageFollowup(String question) {
    final normalized = question.trim();
    if (normalized.isEmpty) {
      return false;
    }

    const keywords = [
      '左边',
      '右边',
      '前面',
      '后面',
      '上面',
      '下面',
      '远处',
      '近处',
      '写了什么',
      '数字',
      '号码',
      '颜色',
      '牌子',
      '招牌',
      '文字',
      '哪一个',
      '那个',
      '这个细节',
      '具体一点',
      '仔细看',
      '重新看',
      '看清',
      '几个人',
      '几个',
      '多少个',
    ];

    return keywords.any(normalized.contains);
  }

  Future<String> _resolveFollowupReply(String question) async {
    if (_shouldUseImageFollowup(question)) {
      final imagePath = widget.imagePath?.trim();
      if (imagePath == null || imagePath.isEmpty) {
        return '当前没有可用图片，无法重新核对这个细节';
      }
      return _aiService.followupWithImage(
        imageFile: File(imagePath),
        history: _chatHistory,
        latestQuestion: question,
      );
    }

    return _aiService.chatWithText(
      history: _chatHistory,
      latestQuestion: question,
    );
  }

  Future<void> _sendFollowupQuestion(String text) async {
    if (_isLoading || text.trim().isEmpty) return;

    final question = text.trim();
    setState(() {
      _isLoading = true;
      _chatHistory.add({'role': 'user', 'content': question});
    });

    try {
      final assistantReply = await _resolveFollowupReply(question);

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

  String _buildBottomHintText() {
    if (_isRecording) return '正在聆听，请继续按住屏幕';
    if (_isLoading) return '处理中，请稍候';
    return '按住屏幕任意位置提问';
  }

  void _handleDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity > _exitSwipeVelocityThreshold) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.lwTheme;
    return GlassScaffold(
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
                    SizedBox(height: t.space16),
                    Text(
                      '连续对话',
                      style: TextStyle(
                        color: t.textPrimary,
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: t.space24),
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: t.space24),
                        child: GlassCard(
                          useMediumSurface: true,
                          padding: EdgeInsets.all(t.space16),
                          child: _isLoading
                              ? Center(
                                  child: CircularProgressIndicator(color: t.primaryAccent),
                                )
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (widget.initialContextHint.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(bottom: 10),
                                        child: Text(
                                          widget.initialContextHint,
                                          style: TextStyle(
                                            color: t.warningAccent,
                                            fontSize: 15,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    Text(
                                      _currentReply,
                                      style: TextStyle(
                                        color: t.textPrimary,
                                        fontSize: 21,
                                        height: 1.45,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(t.space24, t.space12, t.space24, t.space24),
                      child: GlassCard(
                        useMediumSurface: true,
                        padding: EdgeInsets.all(t.space12),
                        child: Text(
                          _buildBottomHintText(),
                          textAlign: TextAlign.center,
                          style: TextStyle(color: t.textPrimary, fontSize: 16),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              IgnorePointer(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _isRecording ? t.recordingAccent : Colors.transparent,
                      width: _isRecording ? 3 : 0,
                    ),
                    color: _isRecording
                        ? t.recordingAccent.withValues(alpha: 0.12)
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
