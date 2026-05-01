import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:vibration/vibration.dart';

import '../models/capture_source.dart';
import '../widgets/frosted_primitives.dart';
import 'chat_screen.dart';
import 'live_vision_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

enum _GalleryAccessStatus {
  success,
  noImage,
  denied,
  permanentlyDenied,
}

class _GalleryImageResolution {
  const _GalleryImageResolution._({
    required this.status,
    this.imagePath,
  });

  const _GalleryImageResolution.success(String imagePath)
      : this._(
          status: _GalleryAccessStatus.success,
          imagePath: imagePath,
        );

  const _GalleryImageResolution.failure(_GalleryAccessStatus status)
      : this._(status: status);

  final _GalleryAccessStatus status;
  final String? imagePath;
}

class _HomeScreenState extends State<HomeScreen> {
  CameraController? _cameraController;
  Future<void>? _cameraInitFuture;
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;

  bool _isCapturing = false;
  bool _cameraUnavailable = false;
  String _cameraStatusText = '正在初始化相机';
  DateTime _lastShakeTime = DateTime.fromMillisecondsSinceEpoch(0);
  static const double _shakeThreshold = 14;
  static const int _shakeHitRequired = 3;
  static const Duration _shakeCooldown = Duration(milliseconds: 1500);
  static const double _lowPassAlpha = 0.85;
  int _shakeHitCount = 0;
  double _gravityX = 0;
  double _gravityY = 0;
  double _gravityZ = 0;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _startShakeListener();
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (!mounted) return;
        setState(() {
          _cameraUnavailable = true;
          _cameraStatusText = '未检测到可用相机，双击可继续无图解析';
        });
        return;
      }

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
        _cameraUnavailable = false;
        _cameraStatusText = '正在初始化相机';
      });

      await initFuture;
      if (!mounted) return;
      setState(() {
        _cameraStatusText = '双击拍一拍 | 摇动进入图片解析\n长按进入实时感知';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _cameraUnavailable = true;
        _cameraStatusText = '相机初始化失败，双击可继续无图解析';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('相机不可用，已切换到无图模式')),
      );
    }
  }

  void _startShakeListener() {
    _accelerometerSubscription = accelerometerEventStream().listen((event) {
      final now = DateTime.now();
      final inCooldown = now.difference(_lastShakeTime) < _shakeCooldown;

      _gravityX = _lowPassAlpha * _gravityX + (1 - _lowPassAlpha) * event.x;
      _gravityY = _lowPassAlpha * _gravityY + (1 - _lowPassAlpha) * event.y;
      _gravityZ = _lowPassAlpha * _gravityZ + (1 - _lowPassAlpha) * event.z;

      final linearX = event.x - _gravityX;
      final linearY = event.y - _gravityY;
      final linearZ = event.z - _gravityZ;
      final delta = linearX.abs() + linearY.abs() + linearZ.abs();

      if (inCooldown) {
        if (_shakeHitCount != 0) {
          _shakeHitCount = 0;
        }
        return;
      }

      if (delta > _shakeThreshold) {
        _shakeHitCount += 1;
      } else {
        _shakeHitCount = 0;
      }

      if (_shakeHitCount >= _shakeHitRequired) {
        _shakeHitCount = 0;
        _lastShakeTime = now;
        _handleShakeCapture();
      }
    });
  }

  Future<void> _vibrate({required int durationMs}) async {
    try {
      await HapticFeedback.heavyImpact();
    } catch (_) {}

    try {
      final hasVibrator = await Vibration.hasVibrator();
      if (!hasVibrator) return;
      await Vibration.vibrate(duration: durationMs);
    } catch (_) {}
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

    final controller = _cameraController;
    var paused = false;
    try {
      if (controller != null &&
          controller.value.isInitialized &&
          !controller.value.isPreviewPaused) {
        await controller.pausePreview();
        paused = true;
      }
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            captureSource: CaptureSource.camera,
            imagePath: captured?.path,
          ),
        ),
      );
    } finally {
      if (paused && mounted) {
        try {
          await controller?.resumePreview();
        } catch (_) {}
      }
    }
  }

  Future<String?> _findFirstReadableImagePath(
    List<AssetPathEntity> albums,
  ) async {
    for (final album in albums) {
      final assets = await album.getAssetListPaged(page: 0, size: 20);
      for (final asset in assets) {
        final file = await asset.file;
        if (file != null) {
          return file.path;
        }
      }
    }
    return null;
  }

  Future<_GalleryImageResolution> _resolveLatestGalleryImage() async {
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.hasAccess) {
      final photoStatus = await Permission.photos.status;
      if (photoStatus.isPermanentlyDenied || photoStatus.isRestricted) {
        return const _GalleryImageResolution.failure(
          _GalleryAccessStatus.permanentlyDenied,
        );
      }
      return const _GalleryImageResolution.failure(_GalleryAccessStatus.denied);
    }

    final filter = FilterOptionGroup(
      orders: [
        const OrderOption(type: OrderOptionType.createDate, asc: false),
      ],
    );

    final allAlbums = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: true,
      filterOption: filter,
    );
    final allAlbumPath = await _findFirstReadableImagePath(allAlbums);
    if (allAlbumPath != null) {
      return _GalleryImageResolution.success(allAlbumPath);
    }

    final fallbackAlbums = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      onlyAll: false,
      filterOption: filter,
    );
    final fallbackPath = await _findFirstReadableImagePath(fallbackAlbums);
    if (fallbackPath != null) {
      return _GalleryImageResolution.success(fallbackPath);
    }

    return const _GalleryImageResolution.failure(_GalleryAccessStatus.noImage);
  }

  Future<void> _showGalleryPermissionDialog() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('需要相册权限'),
        content: const Text('摇一摇识别需要读取相册中的最近图片，请先开启相册权限。'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
            },
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop();
              await openAppSettings();
            },
            child: const Text('去设置'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleShakeCapture() async {
    if (_isCapturing || !mounted) return;
    _isCapturing = true;

    await _vibrate(durationMs: 220);
    final resolution = await _resolveLatestGalleryImage();

    if (!mounted) return;
    _isCapturing = false;

    switch (resolution.status) {
      case _GalleryAccessStatus.success:
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChatScreen(
              captureSource: CaptureSource.shake,
              imagePath: resolution.imagePath!,
            ),
          ),
        );
        return;
      case _GalleryAccessStatus.noImage:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未读取到可用图片')),
        );
        return;
      case _GalleryAccessStatus.denied:
      case _GalleryAccessStatus.permanentlyDenied:
        await _showGalleryPermissionDialog();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未开启相册权限，无法读取图片')),
        );
        return;
    }
  }

  Future<void> _openLiveVisionMode() async {
    if (_isCapturing || !mounted) return;
    _isCapturing = true;

    await _vibrate(durationMs: 60);

    final controller = _cameraController;
    if (mounted) {
      setState(() {
        _cameraController = null;
        _cameraInitFuture = null;
        _cameraUnavailable = false;
        _cameraStatusText = '正在切换到实时感知';
      });
    }

    try {
      await controller?.dispose();
    } catch (_) {}

    if (!mounted) return;

    try {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => const LiveVisionScreen(),
        ),
      );
    } finally {
      if (mounted) {
        _isCapturing = false;
        _initializeCamera();
      }
    }
  }

  Widget _buildCameraFallback() {
    final message = _cameraUnavailable
        ? '当前设备无可用相机\n可双击继续无图解析'
        : '正在连接相机...';

    final t = context.lwTheme;
    return Semantics(
      label: message,
      child: ColoredBox(
        color: t.surfaceGlassMedium,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(t.space24),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: t.textSecondary,
                fontSize: 16,
                height: 1.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _accelerometerSubscription?.cancel();
    _cameraController?.dispose();
    _cameraController = null;
    _cameraInitFuture = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.lwTheme;
    return GlassScaffold(
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
                  return _buildCameraFallback();
                },
              )
            else
              _buildCameraFallback(),
            Container(color: t.surfaceGlassSoft.withValues(alpha: 0.08)),
            Semantics(
              button: true,
              label: '全屏触控层，双击后拍照并进入解析',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onDoubleTap: _handleDoubleTapCapture,
                onLongPressStart: (_) => _openLiveVisionMode(),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.only(bottom: t.space32 + t.space4),
                child: Semantics(
                  liveRegion: true,
                  label: '提示：双击拍一拍，摇动进入图片解析，长按进入实时感知',
                  child: GlassCard(
                    useMediumSurface: true,
                    padding: EdgeInsets.symmetric(
                      horizontal: t.space16,
                      vertical: t.space12,
                    ),
                    child: Text(
                      _cameraStatusText,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: t.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
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
