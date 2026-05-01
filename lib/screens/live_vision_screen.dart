import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/doubao_api_service.dart';
import '../services/speech_service.dart';
import '../services/tts_service.dart';
import '../widgets/frosted_primitives.dart';

class LiveVisionScreen extends StatefulWidget {
  const LiveVisionScreen({super.key});

  static final ValueNotifier<int> _exitSignal = ValueNotifier<int>(0);

  static void requestExit() {
    _exitSignal.value++;
  }

  @override
  State<LiveVisionScreen> createState() => _LiveVisionScreenState();
}

class _LiveVisionScreenState extends State<LiveVisionScreen> {
  static const double _exitSwipeVelocityThreshold = 250;

  final DoubaoApiService _aiService = DoubaoApiService();
  final SpeechService _speechService = SpeechService();

  CameraController? _cameraController;
  Timer? _loopTimer;

  bool _isRunning = true;
  bool _isExiting = false;
  bool _isRequesting = false;
  bool _isRecording = false;
  bool _isAsrRunning = false;
  bool _isAskingAi = false;
  int _interactionEpoch = 0;
  String _latestResult = '正在启动实时感知';  String _lastSpokenText = '';
  String _latestFramePath = '';
  String _liveSpeechText = '';

  @override
  void initState() {
    super.initState();
    LiveVisionScreen._exitSignal.addListener(_handleExternalExit);
    _initCameraAndLoop();
  }

  Future<void> _initCameraAndLoop() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (!mounted) return;
        setState(() {
          _latestResult = DoubaoApiService.fallbackMessage;
        });
        return;
      }

      final back = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        back,
        ResolutionPreset.low,
        enableAudio: false,
      );

      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _cameraController = controller;
        _latestResult = '实时感知已开启';
      });

      _loopTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
        _analyzeCurrentFrame();
      });
      _analyzeCurrentFrame();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _latestResult = DoubaoApiService.fallbackMessage;
      });
    }
  }

  Future<void> _analyzeCurrentFrame() async {
    if (!_isRunning || _isRequesting || _isAsrRunning || _isAskingAi) return;
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isTakingPicture) return;

    _isRequesting = true;
    final requestEpoch = _interactionEpoch;
    try {
      final frame = await controller.takePicture();
      final imageFile = File(frame.path);
      _latestFramePath = frame.path;
      final analysis = await _aiService
          .analyzeImageWithFallback(
            imageFile,
            preferLitePrompt: true,
          )
          .timeout(const Duration(seconds: 10));
      final answer = analysis.ttsText;
      if (!mounted || !_isRunning || _isExiting) return;
      if (requestEpoch != _interactionEpoch || _isAsrRunning || _isAskingAi) return;

      if (_latestResult != answer) {
        setState(() {
          _latestResult = answer;
        });
      }

      await _speakSafely(answer);
    } on TimeoutException {
      if (!mounted || !_isRunning || _isExiting) return;
      if (requestEpoch != _interactionEpoch || _isAsrRunning || _isAskingAi) return;
      const timeoutHint = '识别较慢，已跳过本轮';
      if (_latestResult != timeoutHint) {
        setState(() {
          _latestResult = timeoutHint;
        });
      }
      await _speakSafely(timeoutHint);
    } catch (_) {
      if (!mounted || !_isRunning || _isExiting) return;
      if (requestEpoch != _interactionEpoch || _isAsrRunning || _isAskingAi) return;
      setState(() {
        _latestResult = DoubaoApiService.fallbackMessage;
      });
      await _speakSafely(DoubaoApiService.fallbackMessage);
    } finally {
      _isRequesting = false;
    }
  }

  Future<void> _speakSafely(String text) async {
    if (_lastSpokenText == text) return;
    final ok = await TtsService.instance.speak(text);
    if (ok) {
      _lastSpokenText = text;
    }
  }

  Future<void> _onLongPressStart() async {
    if (!_isRunning || _isExiting || _isAsrRunning) {
      return;
    }

    _interactionEpoch += 1;

    final initStatus = await _speechService.ensurePermissionAndInitStatus();
    if (initStatus != AsrInitStatus.ready) {
      final message = switch (initStatus) {
        AsrInitStatus.permissionDenied => '麦克风权限未授予，请在设置中开启',
        AsrInitStatus.recognizerUnavailable => '语音识别服务连接失败，请检查网络后重试',
        AsrInitStatus.initFailed => '语音识别配置缺失，请检查 .env',
        AsrInitStatus.ready => '',
      };
      if (message.isNotEmpty) {
        setState(() {
          _latestResult = message;
        });
        await _speakSafely(message);
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
      _latestResult = '正在聆听，请继续按住屏幕';
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
      await _speakSafely('语音识别启动失败');
    }
  }

  Future<void> _onLongPressEnd() async {
    if (!_isAsrRunning || _isExiting) return;

    await HapticFeedback.mediumImpact();

    if (!_speechService.isListening) {
      await Future.delayed(const Duration(milliseconds: 380));
    }

    String finalText = '';
    try {
      finalText = await _speechService.stopListeningAndGetFinalText();
    } catch (_) {
      if (mounted) {
        setState(() {
          _isRecording = false;
          _isAsrRunning = false;
          _latestResult = '语音识别结束失败';
        });
      }
      await _speakSafely('语音识别结束失败');
      return;
    }

    if (!mounted) return;
    setState(() {
      _isRecording = false;
      _isAsrRunning = false;
    });

    final question = finalText.trim().isNotEmpty ? finalText.trim() : _liveSpeechText.trim();
    if (question.isEmpty) {
      setState(() {
        _latestResult = '没有识别到有效语音';
      });
      await _speakSafely('没有识别到有效语音');
      return;
    }

    await _askAiWithQuestion(question);
  }

  Future<void> _askAiWithQuestion(String question) async {
    if (_isExiting || !_isRunning || _isAskingAi) return;

    setState(() {
      _isAskingAi = true;
      _latestResult = 'AI思考中...';
    });

    try {
      final framePath = _latestFramePath.trim();
      final reply = framePath.isEmpty
          ? await _aiService.chatWithText(history: const [], latestQuestion: question)
          : await _aiService.followupWithImage(
              imageFile: File(framePath),
              history: const [],
              latestQuestion: question,
            );

      if (!mounted || _isExiting) return;
      setState(() {
        _latestResult = reply;
        _isAskingAi = false;
      });
      await _speakSafely(reply);
    } catch (_) {
      if (!mounted || _isExiting) return;
      setState(() {
        _isAskingAi = false;
        _latestResult = '网络超时，请稍后重试';
      });
      await _speakSafely('网络超时，请稍后重试');
    }
  }

  void _handleExternalExit() {
    if (!_isRunning || !mounted) return;
    _stopAndExit();
  }

  Future<void> _stopAndExit() async {
    if (!_isRunning || _isExiting) return;
    _isExiting = true;
    _interactionEpoch += 1;
    _isRunning = false;
    _loopTimer?.cancel();
    _loopTimer = null;
    await _speechService.cancelListening();
    await TtsService.instance.stop();
    try {
      await _cameraController?.dispose();
    } catch (_) {}
    _cameraController = null;
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  String _buildLiveStatusHintText() {
    if (_isRecording) return '正在聆听...';
    if (_isAskingAi) return 'AI思考中...';
    return '继续长按可提问';
  }

  void _handleDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity > _exitSwipeVelocityThreshold) {
      HapticFeedback.mediumImpact();
      unawaited(_stopAndExit());
    }
  }

  @override
  void dispose() {
    LiveVisionScreen._exitSignal.removeListener(_handleExternalExit);
    _isRunning = false;
    _loopTimer?.cancel();
    TtsService.instance.stop();
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.lwTheme;
    return GlassScaffold(
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragEnd: _handleDragEnd,
        onLongPressStart: (_) => _onLongPressStart(),
        onLongPressEnd: (_) => _onLongPressEnd(),
        child: Stack(
          children: [
            SafeArea(
              child: Column(
                children: [
              SizedBox(height: t.space12),
              GlassCard(
                useMediumSurface: true,
                margin: EdgeInsets.symmetric(horizontal: t.space24),
                padding: EdgeInsets.symmetric(horizontal: t.space16, vertical: t.space12),
                child: Text(
                  '实时感知中\n长按提问｜左滑退出',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: t.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              SizedBox(height: t.space12),
              Expanded(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: t.space24),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(t.radiusCard),
                    child: _cameraController != null && _cameraController!.value.isInitialized
                        ? IgnorePointer(
                            child: CameraPreview(_cameraController!),
                          )
                        : Center(
                            child: CircularProgressIndicator(color: t.primaryAccent),
                          ),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: t.space24),
                child: GlassCard(
                  useMediumSurface: true,
                  padding: EdgeInsets.all(t.space16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _buildLiveStatusHintText(),
                        style: TextStyle(
                          color: t.textSecondary,
                          fontSize: 14,
                        ),
                      ),
                      SizedBox(height: t.space8),
                      Text(
                        _latestResult,
                        style: TextStyle(
                          color: t.textPrimary,
                          fontSize: 18,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: t.space12),
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
    );
  }
}
