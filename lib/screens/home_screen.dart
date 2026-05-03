import 'dart:async'; // 定时器、异步工具

import 'package:camera/camera.dart'; // 相机预览与拍照
import 'package:flutter/material.dart'; // Flutter 基础 UI
import 'package:flutter/services.dart'; // 触觉反馈
import 'package:permission_handler/permission_handler.dart'; // 权限状态读取与跳设置
import 'package:photo_manager/photo_manager.dart'; // 相册权限与最近图片读取
import 'package:sensors_plus/sensors_plus.dart'; // 加速度传感器（摇一摇）
import 'package:vibration/vibration.dart'; // 设备振动

import '../models/capture_source.dart'; // 入口来源枚举
import '../services/voice_settings_service.dart'; // 语音包配置服务
import '../widgets/frosted_primitives.dart'; // 玻璃风 UI 组件
import 'chat_screen.dart'; // 单次解析页
import 'live_vision_screen.dart'; // 实时感知页

/// 首页：
/// - 承载相机预览；
/// - 处理三种主入口手势（双击拍照、摇一摇、长按实时感知）；
/// - 处理下拉语音包选择器。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key}); // 无额外参数，纯入口页

  @override
  State<HomeScreen> createState() => _HomeScreenState(); // 创建状态对象
}

/// 摇一摇取图流程的结果状态。
enum _GalleryAccessStatus {
  success, // 成功获取到可读图片
  noImage, // 权限正常但未找到可读图片
  denied, // 权限被拒绝（可再次请求）
  permanentlyDenied, // 权限永久拒绝/受限（需跳系统设置）
}

/// 摇一摇解析结果封装：
/// - status 表示结果类型；
/// - imagePath 在 success 时才有值。
class _GalleryImageResolution {
  const _GalleryImageResolution._({
    required this.status, // 必填结果状态
    this.imagePath, // 可选图片路径
  });

  const _GalleryImageResolution.success(String imagePath)
      : this._(
          status: _GalleryAccessStatus.success, // 标记成功状态
          imagePath: imagePath, // 带上成功路径
        );

  const _GalleryImageResolution.failure(_GalleryAccessStatus status)
      : this._(status: status); // 失败态不带路径

  final _GalleryAccessStatus status; // 结果状态
  final String? imagePath; // 成功时的路径
}

/// 首页状态管理：相机、摇一摇、语音包面板、页面跳转门控。
class _HomeScreenState extends State<HomeScreen> {
  CameraController? _cameraController; // 当前相机控制器
  Future<void>? _cameraInitFuture; // 相机初始化 Future，供 FutureBuilder 使用
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription; // 摇一摇监听订阅

  bool _isCapturing = false; // 是否正在执行拍照/跳转流程（防重复）
  bool _cameraUnavailable = false; // 相机是否不可用
  String _cameraStatusText = '正在初始化相机'; // 底部状态提示文案
  DateTime _lastShakeTime = DateTime.fromMillisecondsSinceEpoch(0); // 上次触发摇一摇的时间
  static const double _shakeThreshold = 14; // 摇动判定阈值
  static const int _shakeHitRequired = 3; // 连续命中次数（降低误触）
  static const Duration _shakeCooldown = Duration(milliseconds: 1500); // 摇一摇冷却时间
  static const double _lowPassAlpha = 0.85; // 低通滤波参数（提取重力分量）
  int _shakeHitCount = 0; // 当前连续命中计数
  double _gravityX = 0; // X 轴估计重力
  double _gravityY = 0; // Y 轴估计重力
  double _gravityZ = 0; // Z 轴估计重力

  bool _showVoiceSelector = false; // 是否显示语音包选择器
  String _selectedVoiceId = VoiceSettingsService.defaultVoiceId; // 当前选中语音包 id
  Timer? _voiceSelectorTimer; // 语音选择器自动隐藏计时器

  static const Duration _voiceSelectorAutoHideDelay = Duration(
    milliseconds: 2500, // 面板自动隐藏延时
  );
  static const double _voiceSelectorRevealVelocityThreshold = 350; // 下拉唤起语音包面板的速度阈值

  @override
  void initState() {
    super.initState(); // 父类初始化
    _initializeCamera(); // 启动相机初始化
    _startShakeListener(); // 启动摇一摇监听
    unawaited(_loadVoiceSelection()); // 异步读取上次语音包选择
  }

  /// 加载持久化语音包选择并更新 UI。
  Future<void> _loadVoiceSelection() async {
    final id = await VoiceSettingsService.resolveValidVoiceIdOrDefault(); // 读取并校验 id
    if (!mounted) return; // 页面销毁则不更新状态
    setState(() {
      _selectedVoiceId = id; // 更新当前选中项
    });
  }

  /// 初始化相机并更新提示文案。
  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras(); // 获取设备可用相机列表
      if (cameras.isEmpty) {
        if (!mounted) return; // 页面销毁则停止
        setState(() {
          _cameraUnavailable = true; // 标记相机不可用
          _cameraStatusText = '未检测到可用相机，双击可继续无图解析'; // 给用户降级提示
        });
        return;
      }

      final backCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back, // 优先后置相机
        orElse: () => cameras.first, // 没有后置时回退第一颗
      );

      final controller = CameraController(
        backCamera, // 使用选中的相机
        ResolutionPreset.medium, // 中等分辨率，平衡清晰度与性能
        enableAudio: false, // 这里只拍图，不录音
      );

      final initFuture = controller.initialize(); // 启动相机初始化

      setState(() {
        _cameraController = controller; // 挂到状态中
        _cameraInitFuture = initFuture; // 让 FutureBuilder 可监听
        _cameraUnavailable = false; // 可用状态
        _cameraStatusText = '正在初始化相机'; // 初始化中提示
      });

      await initFuture; // 等待初始化完成
      if (!mounted) return; // 页面销毁则停止
      setState(() {
        _cameraStatusText = '双击拍一拍 | 摇动进入图片解析\n长按进入实时感知\n下拉进入语音选择'; // 初始化完成后的操作说明
      });
    } catch (_) {
      if (!mounted) return; // 页面销毁则停止
      setState(() {
        _cameraUnavailable = true; // 标记不可用
        _cameraStatusText = '相机初始化失败，双击可继续无图解析'; // 降级提示
      });
      _showSnackBar('相机不可用，已切换到无图模式'); // 额外 snackbar 提示
    }
  }

  /// 启动加速度监听，实现摇一摇识别入口。
  void _startShakeListener() {
    _accelerometerSubscription = accelerometerEventStream().listen((event) {
      final now = DateTime.now(); // 当前时间
      final inCooldown = now.difference(_lastShakeTime) < _shakeCooldown; // 是否在冷却期

      _gravityX = _lowPassAlpha * _gravityX + (1 - _lowPassAlpha) * event.x; // 更新 X 重力估计
      _gravityY = _lowPassAlpha * _gravityY + (1 - _lowPassAlpha) * event.y; // 更新 Y 重力估计
      _gravityZ = _lowPassAlpha * _gravityZ + (1 - _lowPassAlpha) * event.z; // 更新 Z 重力估计

      final linearX = event.x - _gravityX; // 去重力后的线性加速度 X
      final linearY = event.y - _gravityY; // 去重力后的线性加速度 Y
      final linearZ = event.z - _gravityZ; // 去重力后的线性加速度 Z
      final delta = linearX.abs() + linearY.abs() + linearZ.abs(); // 合成振动强度

      if (inCooldown) {
        if (_shakeHitCount != 0) {
          _shakeHitCount = 0; // 冷却期重置计数
        }
        return; // 冷却期不触发
      }

      if (delta > _shakeThreshold) {
        _shakeHitCount += 1; // 达到阈值则计数+1
      } else {
        _shakeHitCount = 0; // 没达到则中断连续命中
      }

      if (_shakeHitCount >= _shakeHitRequired) {
        _shakeHitCount = 0; // 命中后先清零
        _lastShakeTime = now; // 记录触发时间，进入冷却
        _handleShakeCapture(); // 执行摇一摇流程
      }
    });
  }

  /// 统一振动反馈。
  Future<void> _vibrate({required int durationMs}) async {
    try {
      await HapticFeedback.heavyImpact(); // 系统级触觉
    } catch (_) {}

    try {
      final hasVibrator = await Vibration.hasVibrator(); // 检查设备振动能力
      if (!hasVibrator) return; // 不支持则直接结束
      await Vibration.vibrate(duration: durationMs); // 触发振动
    } catch (_) {}
  }

  /// 双击入口：拍照并进入单次解析页。
  Future<void> _handleDoubleTapCapture() async {
    if (_isCapturing || _showVoiceSelector) return; // 正在捕获或面板展开时不响应
    _isCapturing = true; // 上锁，防重复触发

    await _vibrate(durationMs: 30); // 轻振反馈

    XFile? captured; // 拍照结果
    try {
      if (_cameraController != null &&
          _cameraController!.value.isInitialized &&
          !_cameraController!.value.isTakingPicture) {
        captured = await _cameraController!.takePicture(); // 满足条件时拍照
      }
    } catch (_) {}

    if (!mounted) return; // 页面销毁则停止
    _isCapturing = false; // 解锁

    final controller = _cameraController; // 缓存控制器引用
    var paused = false; // 记录是否暂停过预览
    try {
      if (controller != null &&
          controller.value.isInitialized &&
          !controller.value.isPreviewPaused) {
        await controller.pausePreview(); // 进入下一页前暂停预览，减少资源占用
        paused = true; // 标记已暂停
      }
      if (!mounted) return; // 页面销毁则停止
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            captureSource: CaptureSource.camera, // 标记来源为相机
            imagePath: captured?.path, // 拍到图则带图路径，失败则为空
          ),
        ),
      );
    } finally {
      if (paused && mounted) {
        try {
          await controller?.resumePreview(); // 返回首页后恢复预览
        } catch (_) {}
      }
    }
  }

  /// 在给定相册列表中，查找第一张可读图片路径。
  Future<String?> _findFirstReadableImagePath(
    List<AssetPathEntity> albums,
  ) async {
    for (final album in albums) { // 逐个相册遍历
      final assets = await album.getAssetListPaged(page: 0, size: 20); // 每个相册只取前 20 张，控制耗时
      for (final asset in assets) { // 遍历资源
        final file = await asset.file; // 转本地文件
        if (file != null) {
          return file.path; // 找到第一张可读文件即返回
        }
      }
    }
    return null; // 全部找不到返回空
  }

  /// 摇一摇取最近图片：区分权限问题与无图问题。
  Future<_GalleryImageResolution> _resolveLatestGalleryImage() async {
    final permission = await PhotoManager.requestPermissionExtend(); // 请求相册权限
    if (!permission.hasAccess) {
      final photoStatus = await Permission.photos.status; // 读取更细粒度系统权限状态
      if (photoStatus.isPermanentlyDenied || photoStatus.isRestricted) {
        return const _GalleryImageResolution.failure(
          _GalleryAccessStatus.permanentlyDenied, // 永久拒绝/受限
        );
      }
      return const _GalleryImageResolution.failure(_GalleryAccessStatus.denied); // 普通拒绝
    }

    final filter = FilterOptionGroup(
      orders: [
        const OrderOption(type: OrderOptionType.createDate, asc: false), // 按创建时间倒序，优先最新
      ],
    );

    final allAlbums = await PhotoManager.getAssetPathList(
      type: RequestType.image, // 只取图片
      onlyAll: true, // 先尝试系统“全部图片”聚合相册
      filterOption: filter,
    );
    final allAlbumPath = await _findFirstReadableImagePath(allAlbums); // 在“全部相册”里找首张可读图
    if (allAlbumPath != null) {
      return _GalleryImageResolution.success(allAlbumPath); // 找到即成功返回
    }

    final fallbackAlbums = await PhotoManager.getAssetPathList(
      type: RequestType.image, // 只取图片
      onlyAll: false, // 回退到逐个相册扫描
      filterOption: filter,
    );
    final fallbackPath = await _findFirstReadableImagePath(fallbackAlbums); // 再找一次
    if (fallbackPath != null) {
      return _GalleryImageResolution.success(fallbackPath); // 找到即成功
    }

    return const _GalleryImageResolution.failure(_GalleryAccessStatus.noImage); // 权限正常但无可读图
  }

  /// 统一 snackbar 提示。
  void _showSnackBar(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message))); // 直接显示消息
  }

  /// 权限被拒绝时弹窗，引导用户去系统设置。
  Future<void> _showGalleryPermissionDialog() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('需要相册权限'), // 标题
        content: const Text('摇一摇识别需要读取相册中的最近图片，请先开启相册权限。'), // 内容说明
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop(); // 取消并关闭弹窗
            },
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(dialogContext).pop(); // 先关弹窗
              await openAppSettings(); // 打开系统设置
            },
            child: const Text('去设置'),
          ),
        ],
      ),
    );
  }

  /// 摇一摇入口主流程。
  Future<void> _handleShakeCapture() async {
    if (_isCapturing || !mounted) return; // 正在执行其他流程或页面无效时退出
    _isCapturing = true; // 上锁

    await _vibrate(durationMs: 220); // 摇一摇成功触发后给更强反馈
    final resolution = await _resolveLatestGalleryImage(); // 获取图片/权限结果

    if (!mounted) return; // 页面销毁则停止
    _isCapturing = false; // 解锁

    switch (resolution.status) {
      case _GalleryAccessStatus.success:
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChatScreen(
              captureSource: CaptureSource.shake, // 标记来源为摇一摇
              imagePath: resolution.imagePath!, // 成功分支保证非空
            ),
          ),
        );
        return;
      case _GalleryAccessStatus.noImage:
        _showSnackBar('未读取到可用图片'); // 无图提示
        return;
      case _GalleryAccessStatus.denied:
      case _GalleryAccessStatus.permanentlyDenied:
        await _showGalleryPermissionDialog(); // 权限类问题先弹窗
        if (!mounted) return; // 弹窗返回后再次检查页面
        _showSnackBar('未开启相册权限，无法读取图片'); // 再给一句短提示
        return;
    }
  }

  /// 长按入口：切换到实时感知页。
  Future<void> _openLiveVisionMode() async {
    if (_isCapturing || _showVoiceSelector || !mounted) return; // 门控：忙碌中/面板展开/页面无效都不进入
    _isCapturing = true; // 上锁

    await _vibrate(durationMs: 60); // 切换前反馈

    final controller = _cameraController; // 缓存当前相机控制器
    if (mounted) {
      setState(() {
        _cameraController = null; // 先从 UI 解绑当前控制器
        _cameraInitFuture = null; // 清理初始化 future
        _cameraUnavailable = false; // 切换中暂不显示不可用态
        _cameraStatusText = '正在切换到实时感知'; // 状态文案
      });
    }

    try {
      await controller?.dispose(); // 释放首页相机，避免和实时页争用
    } catch (_) {}

    if (!mounted) return; // 页面销毁则停止

    try {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => const LiveVisionScreen(), // 进入实时感知页
        ),
      );
    } finally {
      if (mounted) {
        _isCapturing = false; // 解锁
        _initializeCamera(); // 返回首页后重新初始化相机
      }
    }
  }

  /// 相机不可用或初始化中时的替代视图。
  Widget _buildCameraFallback() {
    final message = _cameraUnavailable
        ? '当前设备无可用相机\n可双击继续无图解析' // 不可用提示
        : '正在连接相机...'; // 初始化中提示

    final t = context.lwTheme; // 读取主题 token
    return Semantics(
      label: message, // 无障碍读取同一条提示
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

  /// 关闭语音包面板。
  void _hideVoiceSelector() {
    if (!mounted || !_showVoiceSelector) return; // 页面无效或本来就隐藏时不处理
    setState(() {
      _showVoiceSelector = false; // 设为隐藏
    });
  }

  /// 展示语音包面板。
  void _showVoiceSelectorPanel() {
    if (_showVoiceSelector) {
      _resetVoiceSelectorTimer(); // 已展开则仅重置自动隐藏计时
      return;
    }
    setState(() {
      _showVoiceSelector = true; // 首次展开
    });
    _resetVoiceSelectorTimer(); // 启动自动隐藏计时
  }

  /// 重置语音包面板自动隐藏计时器。
  void _resetVoiceSelectorTimer() {
    _voiceSelectorTimer?.cancel(); // 取消旧计时
    _voiceSelectorTimer = Timer(_voiceSelectorAutoHideDelay, _hideVoiceSelector); // 新计时到点后隐藏
  }

  /// 处理垂直拖拽结束，满足速度阈值时展开语音包面板。
  void _handleVerticalDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0; // 读取竖直方向速度
    if (_isCapturing) return; // 执行关键流程时不响应
    if (velocity <= _voiceSelectorRevealVelocityThreshold) return; // 速度不够则忽略
    _showVoiceSelectorPanel(); // 满足条件展开面板
  }

  /// 选择语音包并持久化。
  Future<void> _selectVoice(String id) async {
    final resolved = VoiceSettingsService.resolveValidVoiceIdOrDefaultSync(id); // 同步校验 id 合法性
    await VoiceSettingsService.setSelectedVoiceId(resolved); // 持久化保存
    if (!mounted) return; // 页面销毁则停止
    setState(() {
      _selectedVoiceId = resolved; // 更新当前选中项
      _showVoiceSelector = false; // 选择后自动收起
    });
    _voiceSelectorTimer?.cancel(); // 关闭自动隐藏计时
  }

  /// 构建语音包选择卡片。
  Widget _buildVoiceSelectorCard() {
    final t = context.lwTheme; // 读取主题 token
    if (VoiceSettingsService.catalog.isEmpty) {
      return const SizedBox.shrink(); // 无可选项时不渲染
    }

    return Align(
      alignment: Alignment.bottomCenter, // 固定在底部中央
      child: Padding(
        padding: EdgeInsets.fromLTRB(t.space24, t.space24, t.space24, t.space32 + 80), // 给底部提示条留出空间
        child: GlassCard(
          useMediumSurface: true,
          padding: EdgeInsets.all(t.space12),
          child: Column(
            mainAxisSize: MainAxisSize.min, // 只占内容高度
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '选择语音包', // 面板标题
                style: TextStyle(
                  color: t.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              SizedBox(height: t.space8), // 标题与列表间距
              ...VoiceSettingsService.catalog.map((voice) { // 动态渲染每个语音项
                final selected = voice.id == _selectedVoiceId; // 当前项是否已选中
                return InkWell(
                  onTap: () => _selectVoice(voice.id), // 点击选择
                  child: Padding(
                    padding: EdgeInsets.symmetric(vertical: t.space8),
                    child: Row(
                      children: [
                        Icon(
                          selected ? Icons.radio_button_checked : Icons.radio_button_off, // 单选视觉状态
                          color: selected ? t.primaryAccent : t.textSecondary,
                          size: 18,
                        ),
                        SizedBox(width: t.space8),
                        Expanded(
                          child: Text(
                            voice.label, // 语音包展示名
                            style: TextStyle(
                              color: selected ? t.primaryAccent : t.textPrimary,
                              fontSize: 14,
                              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _accelerometerSubscription?.cancel(); // 取消摇一摇监听
    _voiceSelectorTimer?.cancel(); // 取消自动隐藏计时
    _cameraController?.dispose(); // 释放相机资源
    _cameraController = null; // 清空引用
    _cameraInitFuture = null; // 清空初始化 future
    super.dispose(); // 执行父类销毁
  }

  @override
  Widget build(BuildContext context) {
    final t = context.lwTheme; // 读取主题 token
    return GlassScaffold(
      body: Semantics(
        label: '首页相机区域，双击拍照，摇动手机进入数字模式', // 页面无障碍总提示
        child: Stack(
          fit: StackFit.expand, // 子组件铺满全屏
          children: [
            if (_cameraController != null && _cameraInitFuture != null)
              FutureBuilder<void>(
                future: _cameraInitFuture, // 监听相机初始化状态
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.done &&
                      _cameraController!.value.isInitialized) {
                    return CameraPreview(_cameraController!); // 初始化完成后显示相机预览
                  }
                  return _buildCameraFallback(); // 未完成或失败时显示替代视图
                },
              )
            else
              _buildCameraFallback(), // 控制器为空时显示替代视图
            Container(color: t.surfaceGlassSoft.withValues(alpha: 0.08)), // 轻微蒙层，提升文字可读性
            Semantics(
              button: true, // 触控层可视作一个操作区域
              label: '全屏触控层，双击后拍照并进入解析', // 无障碍提示
              child: GestureDetector(
                behavior: HitTestBehavior.opaque, // 全屏都可触发手势
                onDoubleTap: _showVoiceSelector ? null : _handleDoubleTapCapture, // 面板展开时禁用双击拍照
                onLongPressStart: _showVoiceSelector ? null : (_) => _openLiveVisionMode(), // 面板展开时禁用长按切换
                onVerticalDragEnd: _handleVerticalDragEnd, // 下拉唤起语音包
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter, // 底部状态条位置
              child: Padding(
                padding: EdgeInsets.only(bottom: t.space32 + t.space4),
                child: Semantics(
                  liveRegion: true, // 文案变化时可被辅助功能感知
                  label: '提示：双击拍一拍，摇动进入图片解析，长按进入实时感知，下滑可选语音包',
                  child: GlassCard(
                    useMediumSurface: true,
                    padding: EdgeInsets.symmetric(
                      horizontal: t.space16,
                      vertical: t.space12,
                    ),
                    child: Text(
                      _cameraStatusText, // 底部动态状态文案
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
            if (_showVoiceSelector) _buildVoiceSelectorCard(), // 条件渲染语音包浮层
          ],
        ),
      ),
    );
  }
}
