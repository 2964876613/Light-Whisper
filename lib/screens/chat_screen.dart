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
  String _safetyHint = '';
  String _contextHint = '';
  String _safetyLevel = '';

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

    String result;
    String hint = '';
    String contextHint = '';
    String safetyLevel = '';

    if (path == null || path.isEmpty) {
      result = DoubaoApiService.fallbackMessage;
    } else {
      final structured = await _aiVisionService.analyzeImageStructured(File(path));
      result = structured?.ttsText ?? DoubaoApiService.fallbackMessage;
      hint = _buildSafetyHint(structured?.safetyLevel, structured?.safetyConfidence);
      contextHint = _buildContextHint(structured?.raw);
      safetyLevel = structured?.safetyLevel ?? '';
    }

    if (!mounted) return;
    setState(() {
      _aiResult = result;
      _safetyHint = hint;
      _contextHint = contextHint;
      _safetyLevel = safetyLevel;
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
                          label: _buildResultSemanticsLabel(),
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
                                      if (_safetyHint.isNotEmpty)
                                        Padding(
                                          padding: const EdgeInsets.only(bottom: 8),
                                          child: Text(
                                            _safetyHint,
                                            style: TextStyle(
                                              color: _safetyHintColor(_safetyLevel),
                                              fontSize: 16,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      if (_contextHint.isNotEmpty)
                                        Padding(
                                          padding: const EdgeInsets.only(bottom: 10),
                                          child: Text(
                                            _contextHint,
                                            style: const TextStyle(
                                              color: Colors.lightBlueAccent,
                                              fontSize: 15,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                      Text(
                                        _aiResult,
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

  String _buildSafetyHint(String? level, double? confidence) {
    if (level == null || confidence == null) {
      return '';
    }

    final percent = (confidence * 100).clamp(0, 100).toStringAsFixed(0);
    switch (level) {
      case 'critical':
        return '风险等级：严重（$percent%）';
      case 'high':
        return '风险等级：高（$percent%）';
      case 'medium':
        return '风险等级：中（$percent%）';
      case 'low':
        return '风险等级：低（$percent%）';
      default:
        return '';
    }
  }

  String _buildResultSemanticsLabel() {
    if (_isLoading) {
      return '正在处理中';
    }

    final parts = <String>[];
    if (_safetyHint.isNotEmpty) {
      parts.add(_safetyHint);
    }
    if (_contextHint.isNotEmpty) {
      parts.add(_contextHint);
    }
    parts.add('AI解析内容：$_aiResult');
    return parts.join('。');
  }

  Color _safetyHintColor(String level) {
    switch (level) {
      case 'critical':
        return Colors.redAccent;
      case 'high':
        return Colors.deepOrangeAccent;
      case 'medium':
        return Colors.amber;
      case 'low':
        return Colors.lightGreenAccent;
      default:
        return Colors.amber;
    }
  }

  String _buildContextHint(Map<String, dynamic>? raw) {
    if (raw == null) {
      return '';
    }

    final traffic = raw['traffic_light'];
    final hazards = raw['hazards'];

    final trafficHint = _buildTrafficHint(traffic);
    final hazardHint = _buildFirstHazardHint(hazards);

    if (trafficHint.isNotEmpty && hazardHint.isNotEmpty) {
      return '$trafficHint，$hazardHint';
    }
    if (trafficHint.isNotEmpty) {
      return trafficHint;
    }
    return hazardHint;
  }

  String _buildTrafficHint(dynamic traffic) {
    if (traffic is! Map) {
      return '';
    }

    final state = traffic['state'];
    if (state is! String) {
      return '';
    }

    switch (state) {
      case 'red':
        return '红绿灯：红灯';
      case 'yellow':
        return '红绿灯：黄灯';
      case 'green':
        return '红绿灯：绿灯';
      default:
        return '';
    }
  }

  String _buildFirstHazardHint(dynamic hazards) {
    if (hazards is! List || hazards.isEmpty) {
      return '';
    }

    final first = hazards.first;
    if (first is! Map) {
      return '';
    }

    final direction = first['direction'];
    final type = first['type'];
    if (direction is! String || type is! String) {
      return '';
    }

    final dir = _mapDirection(direction);
    final hazard = _mapHazardType(type);
    if (dir.isEmpty || hazard.isEmpty) {
      return '';
    }

    return '$dir有$hazard';
  }

  String _mapDirection(String value) {
    switch (value) {
      case 'front':
        return '正前方';
      case 'front_left':
        return '左前方';
      case 'front_right':
        return '右前方';
      case 'left':
        return '左侧';
      case 'right':
        return '右侧';
      case 'rear':
        return '后方';
      default:
        return '';
    }
  }

  String _mapHazardType(String value) {
    switch (value) {
      case 'vehicle':
        return '车辆';
      case 'stairs':
        return '台阶';
      case 'pit':
        return '坑洼';
      case 'obstacle':
        return '障碍物';
      default:
        return '';
    }
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
