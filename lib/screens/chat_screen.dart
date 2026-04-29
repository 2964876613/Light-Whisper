import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/capture_source.dart';
import '../providers/user_tier_provider.dart';
import '../services/doubao_api_service.dart';
import '../services/tts_service.dart';
import 'continuous_chat_screen.dart';

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
  final DoubaoApiService _aiVisionService = DoubaoApiService();

  bool _isLoading = true;
  bool _ttsFinished = false;
  bool _isJumpingToContinuous = false;
  String _aiResult = '';
  String _safetyHint = '';
  String _contextHint = '';
  String _safetyLevel = '';


  @override
  void initState() {
    super.initState();
    _simulateAnalyzeAndSpeak();
  }

  Future<void> _speakWithFallbackFinish(String text) async {
    final ok = await TtsService.instance.speak(text);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _ttsFinished = true;
      });
      return;
    }

    Future.delayed(const Duration(seconds: 4), () {
      if (!mounted) return;
      if (_ttsFinished) return;
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
    String liteObstacle = '';
    String liteRisk = '';

    if (path == null || path.isEmpty) {
      result = DoubaoApiService.recognitionFallbackMessage;
    } else {
      final analysis = await _aiVisionService.analyzeImageWithFallback(
        File(path),
        preferLitePrompt: true,
      );
      result = analysis.ttsText;

      final lite = analysis.liteMeta;
      if (lite != null) {
        liteObstacle = lite.obstacleText;
        liteRisk = lite.riskLevel;
        if (lite.briefDescription.trim().isNotEmpty) {
          result = lite.briefDescription.trim();
        }
      }
    }

    if (!mounted) return;
    if (liteObstacle.isNotEmpty || liteRisk.isNotEmpty) {
      final riskText = liteRisk.isEmpty ? '未知' : liteRisk;
      final obstacleText = liteObstacle.isEmpty ? '未明确' : liteObstacle;
      contextHint = '障碍：$obstacleText，风险：$riskText';
    }

    setState(() {
      _aiResult = result;
      _safetyHint = hint;
      _contextHint = contextHint;
      _safetyLevel = safetyLevel;
      _isLoading = false;
      _ttsFinished = false;
    });

    final speakText = _contextHint.isEmpty ? result : '$_contextHint。$result';
    await _speakWithFallbackFinish(speakText);
  }

  @override
  void dispose() {
    unawaited(TtsService.instance.stop());
    super.dispose();
  }

  void _handleDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity > 250) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _openContinuousChat() async {
    if (_isJumpingToContinuous || _isLoading || !_ttsFinished) return;

    await HapticFeedback.heavyImpact();
    await TtsService.instance.stop();

    if (!mounted) return;
    setState(() {
      _isJumpingToContinuous = true;
    });

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ContinuousChatScreen(
          initialAssistantText: _aiResult,
          initialContextHint: _contextHint,
        ),
      ),
    );

    if (!mounted) return;
    setState(() {
      _isJumpingToContinuous = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isProUser = context.watch<UserTierProvider>().isProUser;
    final canEnterContinuous = isProUser && !_isLoading && _ttsFinished;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Semantics(
        label: '播报完成后长按屏幕进入连续对话，向右滑动返回首页',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragEnd: _handleDragEnd,
          onLongPress: canEnterContinuous ? _openContinuousChat : null,
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
                      child: _buildInputArea(
                        isProUser: isProUser,
                        canEnterContinuous: canEnterContinuous,
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
                      color: _isJumpingToContinuous ? Colors.yellowAccent : Colors.transparent,
                      width: _isJumpingToContinuous ? 4 : 0,
                    ),
                    color: _isJumpingToContinuous
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

  Widget _buildInputArea({required bool isProUser, required bool canEnterContinuous}) {
    if (!isProUser) {
      return Semantics(
        label: '当前为免费用户，仅支持单次播报',
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          color: Colors.black,
          child: Text(
            _isLoading || !_ttsFinished ? '免费模式：正在单次播报' : '免费模式：单次播报已完成',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
        ),
      );
    }

    final hintText = !canEnterContinuous
        ? (_isLoading || !_ttsFinished ? '正在播报，请稍候' : '暂不可进入连续对话')
        : '长按屏幕进入连续对话';

    return Semantics(
      label: hintText,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        color: Colors.black,
        child: Text(
          _isJumpingToContinuous ? '正在进入连续对话' : hintText,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 16),
        ),
      ),
    );
  }
}
