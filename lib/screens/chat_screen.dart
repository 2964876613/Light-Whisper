import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:provider/provider.dart';

import '../models/capture_source.dart';
import '../providers/user_tier_provider.dart';
import '../services/doubao_api_service.dart';

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

  bool _isLoading = true;
  bool _ttsFinished = false;
  bool _isRecording = false;
  String _aiResult = '';

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
    });

    await _tts.speak(result);
  }

  @override
  void dispose() {
    unawaited(_tts.stop());
    super.dispose();
  }

  void _handleDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity > 250) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isProUser = context.watch<UserTierProvider>().isProUser;
    final canTalk = isProUser && _ttsFinished;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Semantics(
        label: '对话页面，右滑返回首页',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragEnd: _handleDragEnd,
          child: SafeArea(
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
                      label: _isLoading ? '正在分析图片并播报' : 'AI解析内容：$_aiResult',
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

    return Row(
      children: [
        Expanded(
          child: Semantics(
            textField: true,
            enabled: canTalk,
            label: canTalk ? '输入框可用' : '输入框等待播报结束后可用',
            child: TextField(
              enabled: canTalk,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: canTalk ? '可继续提问这张图' : '播报中，请稍候',
                hintStyle: const TextStyle(color: Colors.white54),
                filled: true,
                fillColor: Colors.black,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Semantics(
          button: true,
          enabled: canTalk,
          label: canTalk ? '长按语音输入按钮' : '语音按钮等待播报结束后可用',
          child: GestureDetector(
            onLongPressStart: canTalk
                ? (_) {
                    setState(() {
                      _isRecording = true;
                    });
                  }
                : null,
            onLongPressEnd: canTalk
                ? (_) {
                    setState(() {
                      _isRecording = false;
                    });
                  }
                : null,
            child: Container(
              height: 54,
              width: 54,
              decoration: BoxDecoration(
                color: canTalk ? Colors.white : Colors.white24,
                shape: BoxShape.circle,
              ),
              child: Icon(
                _isRecording ? Icons.mic : Icons.mic_none,
                color: Colors.black,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
