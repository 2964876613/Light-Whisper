import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:vibration/vibration.dart';

import '../models/capture_source.dart';
import '../providers/user_tier_provider.dart';
import '../services/doubao_api_service.dart';
import '../services/tts_service.dart';
import '../widgets/frosted_primitives.dart';
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

  Future<void> _vibrate({required int durationMs, int? amplitude}) async {
    try {
      await HapticFeedback.heavyImpact();
    } catch (_) {}

    try {
      final hasVibrator = await Vibration.hasVibrator();
      if (!hasVibrator) return;
      if (amplitude == null) {
        await Vibration.vibrate(duration: durationMs);
      } else {
        await Vibration.vibrate(duration: durationMs, amplitude: amplitude);
      }
    } catch (_) {}
  }

  Future<void> _openContinuousChat() async {
    if (_isJumpingToContinuous || _isLoading || !_ttsFinished) return;

    await _vibrate(durationMs: 60, amplitude: 180);
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
          imagePath: widget.imagePath,
        ),
      ),
    );

    if (!mounted) return;
    await _vibrate(durationMs: 40, amplitude: 120);
    setState(() {
      _isJumpingToContinuous = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isProUser = context.watch<UserTierProvider>().isProUser;
    final canEnterContinuous = isProUser && !_isLoading && _ttsFinished;

    final t = context.lwTheme;
    return GlassScaffold(
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
                    SizedBox(height: t.space16),
                    Semantics(
                      header: true,
                      label: '光语解析结果',
                      child: Text(
                        '光语解析',
                        style: TextStyle(
                          color: t.textPrimary,
                          fontSize: 24,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    SizedBox(height: t.space24),
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: t.space24),
                        child: Semantics(
                          liveRegion: true,
                          label: _buildResultSemanticsLabel(),
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
                                            style: TextStyle(
                                              color: t.primaryAccent,
                                              fontSize: 15,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                      Text(
                                        _aiResult,
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
                    ),
                    Padding(
                      padding: EdgeInsets.fromLTRB(t.space24, t.space12, t.space24, t.space24),
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
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _isJumpingToContinuous ? t.recordingAccent : Colors.transparent,
                      width: _isJumpingToContinuous ? 3 : 0,
                    ),
                    color: _isJumpingToContinuous
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
        return const Color(0xFFE45B5B);
      case 'high':
        return const Color(0xFFEF8B52);
      case 'medium':
        return const Color(0xFFF1B357);
      case 'low':
        return const Color(0xFF67B886);
      default:
        return const Color(0xFFF1B357);
    }
  }

  Widget _buildInputArea({required bool isProUser, required bool canEnterContinuous}) {
    if (!isProUser) {
      final t = context.lwTheme;
      return Semantics(
        label: '当前为免费用户，仅支持单次播报',
        child: GlassCard(
          useMediumSurface: true,
          padding: EdgeInsets.all(t.space12),
          child: Text(
            _isLoading || !_ttsFinished ? '免费模式：正在单次播报' : '免费模式：单次播报已完成',
            textAlign: TextAlign.center,
            style: TextStyle(color: t.textPrimary, fontSize: 16),
          ),
        ),
      );
    }

    final hintText = !canEnterContinuous
        ? (_isLoading || !_ttsFinished ? '正在播报，请稍候' : '暂不可进入连续对话')
        : '长按屏幕进入连续对话';

    final t = context.lwTheme;
    return Semantics(
      label: hintText,
      child: GlassCard(
        useMediumSurface: true,
        padding: EdgeInsets.all(t.space12),
        child: Text(
          _isJumpingToContinuous ? '正在进入连续对话' : hintText,
          textAlign: TextAlign.center,
          style: TextStyle(color: t.textPrimary, fontSize: 16),
        ),
      ),
    );
  }
}
