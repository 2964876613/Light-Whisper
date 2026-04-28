import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../services/doubao_api_service.dart';

class LiveVisionScreen extends StatefulWidget {
  const LiveVisionScreen({super.key});

  @override
  State<LiveVisionScreen> createState() => _LiveVisionScreenState();
}

class _LiveVisionScreenState extends State<LiveVisionScreen> {
  final DoubaoApiService _aiService = DoubaoApiService();
  final FlutterTts _tts = FlutterTts();

  CameraController? _cameraController;
  Timer? _loopTimer;

  bool _isRunning = true;
  bool _isRequesting = false;
  String _latestResult = '正在启动实时感知';
  String _singleQuestion = '这是什么画面';

  @override
  void initState() {
    super.initState();
    _setupTts();
    _initCameraAndLoop();
  }

  Future<void> _setupTts() async {
    await _tts.setLanguage('zh-CN');
    await _tts.setSpeechRate(0.42);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
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
        ResolutionPreset.medium,
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
    if (!_isRunning || _isRequesting) return;
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    if (controller.value.isTakingPicture) return;

    _isRequesting = true;
    try {
      final frame = await controller.takePicture();
      final imageFile = File(frame.path);
      final answer = await _aiService.analyzeImage(
        imageFile,
        singleQuestion: _singleQuestion,
      );
      if (!mounted || !_isRunning) return;

      setState(() {
        _latestResult = answer;
      });

      await _tts.stop();
      await _tts.speak(answer);
    } catch (_) {
      if (!mounted || !_isRunning) return;
      setState(() {
        _latestResult = DoubaoApiService.fallbackMessage;
      });
    } finally {
      _isRequesting = false;
    }
  }

  Future<void> _stopAndExit() async {
    if (!_isRunning) return;
    _isRunning = false;
    _loopTimer?.cancel();
    _loopTimer = null;
    await _tts.stop();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _isRunning = false;
    _loopTimer?.cancel();
    _tts.stop();
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPressUp: _stopAndExit,
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 12),
              const Text(
                '实时感知中（松手退出）',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: TextField(
                  onChanged: (value) {
                    _singleQuestion = value.trim().isEmpty ? '这是什么画面' : value.trim();
                  },
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    hintText: '输入单轮问题（例如：这是什么页面）',
                    hintStyle: TextStyle(color: Colors.white54),
                    filled: true,
                    fillColor: Colors.white12,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: _cameraController != null && _cameraController!.value.isInitialized
                      ? CameraPreview(_cameraController!)
                      : const Center(
                          child: CircularProgressIndicator(color: Colors.white),
                        ),
                ),
              ),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                child: Text(
                  _latestResult,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }
}
