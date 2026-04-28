import 'dart:async';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:vibration/vibration.dart';

import '../models/capture_source.dart';
import 'chat_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  CameraController? _cameraController;
  Future<void>? _cameraInitFuture;
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;

  bool _isCapturing = false;
  DateTime _lastShakeTime = DateTime.fromMillisecondsSinceEpoch(0);
  static const double _shakeThreshold = 20;
  static const Duration _shakeCooldown = Duration(milliseconds: 1500);

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _startShakeListener();
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) return;

      final backCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        backCamera,
        ResolutionPreset.medium,
        enableAudio: false,
      );

      final initFuture = controller.initialize();

      setState(() {
        _cameraController = controller;
        _cameraInitFuture = initFuture;
      });

      await initFuture;
      if (!mounted) return;
      setState(() {});
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('相机初始化失败，请检查权限后重试')),
      );
    }
  }

  void _startShakeListener() {
    _accelerometerSubscription = accelerometerEventStream().listen((event) {
      final now = DateTime.now();
      final delta = (event.x.abs() + event.y.abs() + event.z.abs());
      final inCooldown = now.difference(_lastShakeTime) < _shakeCooldown;

      if (delta > _shakeThreshold && !inCooldown) {
        _lastShakeTime = now;
        _handleShakeCapture();
      }
    });
  }

  Future<void> _vibrate({required int durationMs}) async {
    final hasVibrator = await Vibration.hasVibrator();
    if (!hasVibrator) return;
    await Vibration.vibrate(duration: durationMs);
  }

  Future<void> _handleDoubleTapCapture() async {
    if (_isCapturing) return;
    _isCapturing = true;

    await _vibrate(durationMs: 30);

    XFile? captured;
    try {
      if (_cameraController != null &&
          _cameraController!.value.isInitialized &&
          !_cameraController!.value.isTakingPicture) {
        captured = await _cameraController!.takePicture();
      }
    } catch (_) {}

    if (!mounted) return;
    _isCapturing = false;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          captureSource: CaptureSource.camera,
          imagePath: captured?.path,
        ),
      ),
    );
  }

  Future<void> _handleShakeCapture() async {
    if (_isCapturing || !mounted) return;
    _isCapturing = true;

    await _vibrate(durationMs: 220);

    if (!mounted) return;
    _isCapturing = false;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const ChatScreen(
          captureSource: CaptureSource.shake,
          imagePath: null,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _accelerometerSubscription?.cancel();
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Semantics(
        label: '首页相机区域，双击拍照，摇动手机进入数字模式',
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_cameraController != null && _cameraInitFuture != null)
              FutureBuilder<void>(
                future: _cameraInitFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.done &&
                      _cameraController!.value.isInitialized) {
                    return CameraPreview(_cameraController!);
                  }
                  return const ColoredBox(color: Colors.black);
                },
              )
            else
              const ColoredBox(color: Colors.black),
            BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(color: Colors.black.withValues(alpha: 0.12)),
            ),
            Semantics(
              button: true,
              label: '全屏触控层，双击后拍照并进入解析',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: _handleDoubleTapCapture,
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 36),
                child: Semantics(
                  liveRegion: true,
                  label: '提示：双击拍一拍，摇动进入数字模式',
                  child: const Text(
                    '双击拍一拍 | 摇动进入数字模式',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
