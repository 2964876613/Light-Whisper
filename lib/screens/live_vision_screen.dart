import 'dart:async'; // 定时器与超时控制
import 'dart:io'; // File，用于把帧路径转为文件

import 'package:camera/camera.dart'; // 相机预览与拍照
import 'package:flutter/material.dart'; // Flutter UI 组件
import 'package:flutter/services.dart'; // 触觉反馈

import '../services/doubao_api_service.dart'; // AI 服务（图片分析/追问）
import '../services/speech_service.dart'; // ASR 服务（按住提问）
import '../services/tts_service.dart'; // TTS 服务（结果播报）
import '../widgets/frosted_primitives.dart'; // 玻璃风 UI

/// 实时感知页面：
/// - 周期拍帧并播报环境信息；
/// - 支持长按语音提问（追问当前画面细节）；
/// - 支持外部与手势退出。
class LiveVisionScreen extends StatefulWidget {
  const LiveVisionScreen({super.key}); // 无额外构造参数

  static final ValueNotifier<int> _exitSignal = ValueNotifier<int>(0); // 外部退出信号计数器

  static void requestExit() {
    _exitSignal.value++; // 外部调用时递增，触发页面监听器执行退出
  }

  @override
  State<LiveVisionScreen> createState() => _LiveVisionScreenState(); // 创建状态对象
}

/// 页面内部状态：
/// - 自动轮询分析模式；
/// - 长按语音问答模式；
/// 两者互斥，避免相机/音频资源争抢。
class _LiveVisionScreenState extends State<LiveVisionScreen> {
  static const double _exitSwipeVelocityThreshold = 250; // 左/右滑退出速度阈值

  final DoubaoApiService _aiService = DoubaoApiService(); // AI 服务实例
  final SpeechService _speechService = SpeechService(); // ASR 服务实例

  CameraController? _cameraController; // 相机控制器
  Timer? _loopTimer; // 周期分析定时器

  bool _isRunning = true; // 页面主流程是否仍在运行
  bool _isExiting = false; // 是否正在退出（防重入）
  bool _isRequesting = false; // 是否正在执行一轮自动帧分析
  bool _isRecording = false; // 是否处于“按住说话”状态（UI 高亮用）
  bool _isAsrRunning = false; // ASR 是否正在运行
  bool _isAskingAi = false; // 是否正在执行用户主动提问请求
  int _interactionEpoch = 0; // 交互代次，用于丢弃过期异步结果
  String _latestResult = '正在启动实时感知'; // 底部主结果文本
  String _lastSpokenText = ''; // 上次播报文本（避免重复播报）
  String _latestFramePath = ''; // 最近一次拍到的帧路径（追问时使用）
  String _liveSpeechText = ''; // 实时识别中间文本

  @override
  void initState() {
    super.initState(); // 父类初始化
    LiveVisionScreen._exitSignal.addListener(_handleExternalExit); // 监听外部退出请求
    _initCameraAndLoop(); // 启动相机并开始轮询
  }

  /// 初始化相机并启动自动分析循环。
  Future<void> _initCameraAndLoop() async {
    try {
      final cameras = await availableCameras(); // 获取设备相机列表
      if (cameras.isEmpty) {
        if (!mounted) return; // 页面销毁则停止
        setState(() {
          _latestResult = DoubaoApiService.fallbackMessage; // 无相机时显示兜底文案
        });
        return;
      }

      final back = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back, // 优先后置
        orElse: () => cameras.first, // 无后置时回退第一颗
      );

      final controller = CameraController(
        back, // 选中的相机
        ResolutionPreset.low, // 实时模式使用低分辨率，换取更稳定帧率
        enableAudio: false, // 不采集音频
      );

      await controller.initialize(); // 初始化相机
      if (!mounted) {
        await controller.dispose(); // 页面已退出则释放资源
        return;
      }

      setState(() {
        _cameraController = controller; // 保存控制器
        _latestResult = '实时感知已开启'; // 更新状态文案
      });

      _loopTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
        _analyzeCurrentFrame(); // 周期触发自动帧分析
      });
      _analyzeCurrentFrame(); // 立即触发一次，减少首次等待
    } catch (_) {
      if (!mounted) return; // 页面销毁则停止
      setState(() {
        _latestResult = DoubaoApiService.fallbackMessage; // 初始化失败时显示兜底文案
      });
    }
  }

  /// 自动分析当前帧。
  /// 约束：当 ASR/主动问答进行中时暂停自动分析，避免抢占资源与语音冲突。
  Future<void> _analyzeCurrentFrame() async {
    if (!_isRunning || _isRequesting || _isAsrRunning || _isAskingAi) return; // 运行态门控
    final controller = _cameraController; // 缓存控制器引用
    if (controller == null || !controller.value.isInitialized) return; // 无可用相机则跳过
    if (controller.value.isTakingPicture) return; // 正在拍照时不重入

    _isRequesting = true; // 标记本轮请求开始
    final requestEpoch = _interactionEpoch; // 记录本轮代次
    try {
      final frame = await controller.takePicture(); // 拍一帧
      final imageFile = File(frame.path); // 路径转文件
      _latestFramePath = frame.path; // 保存最新帧路径，供追问使用
      final analysis = await _aiService
          .analyzeImageWithFallback(
            imageFile, // 上传当前帧
            preferLitePrompt: true, // 使用轻量提示词，播报更短
          )
          .timeout(const Duration(seconds: 10)); // 避免长时间阻塞循环
      final answer = analysis.ttsText; // 取播报文本
      if (!mounted || !_isRunning || _isExiting) return; // 页面状态失效则丢弃
      if (requestEpoch != _interactionEpoch || _isAsrRunning || _isAskingAi) return; // 代次过期或模式切换则丢弃

      if (_latestResult != answer) {
        setState(() {
          _latestResult = answer; // 仅在文本变化时更新 UI
        });
      }

      await _speakSafely(answer); // 播报新结果
    } on TimeoutException {
      if (!mounted || !_isRunning || _isExiting) return; // 状态无效则丢弃
      if (requestEpoch != _interactionEpoch || _isAsrRunning || _isAskingAi) return; // 代次不匹配则丢弃
      const timeoutHint = '识别较慢，已跳过本轮'; // 超时提示
      if (_latestResult != timeoutHint) {
        setState(() {
          _latestResult = timeoutHint; // 更新超时提示
        });
      }
      await _speakSafely(timeoutHint); // 播报超时提示
    } catch (_) {
      if (!mounted || !_isRunning || _isExiting) return; // 状态无效则丢弃
      if (requestEpoch != _interactionEpoch || _isAsrRunning || _isAskingAi) return; // 代次不匹配则丢弃
      setState(() {
        _latestResult = DoubaoApiService.fallbackMessage; // 更新失败提示
      });
      await _speakSafely(DoubaoApiService.fallbackMessage); // 播报失败提示
    } finally {
      _isRequesting = false; // 本轮结束，释放请求锁
    }
  }

  /// 安全播报：相同文本不重复播报，减少噪音。
  Future<void> _speakSafely(String text) async {
    if (_lastSpokenText == text) return; // 去重
    final ok = await TtsService.instance.speak(text); // 调用 TTS
    if (ok) {
      _lastSpokenText = text; // 仅在成功后更新去重基线
    }
  }

  /// 长按开始：进入语音提问模式。
  Future<void> _onLongPressStart() async {
    if (!_isRunning || _isExiting || _isAsrRunning) {
      return; // 非运行态/退出中/已在 ASR 运行时不处理
    }

    _interactionEpoch += 1; // 切换交互代次，废弃尚未返回的自动分析结果

    final initStatus = await _speechService.ensurePermissionAndInitStatus(); // 校验 ASR 状态
    if (initStatus != AsrInitStatus.ready) {
      final message = switch (initStatus) {
        AsrInitStatus.permissionDenied => '麦克风权限未授予，请在设置中开启',
        AsrInitStatus.recognizerUnavailable => '语音识别服务连接失败，请检查网络后重试',
        AsrInitStatus.initFailed => '语音识别配置缺失，请检查 .env',
        AsrInitStatus.ready => '',
      };
      if (message.isNotEmpty) {
        setState(() {
          _latestResult = message; // 显示错误原因
        });
        await _speakSafely(message); // 播报错误原因
      }
      return;
    }

    await HapticFeedback.heavyImpact(); // 进入录音态前反馈
    await TtsService.instance.stop(); // 停止自动播报，避免与录音冲突

    if (!mounted) return; // 页面已销毁则停止
    setState(() {
      _isRecording = true; // 开启录音 UI 高亮
      _isAsrRunning = true; // 标记 ASR 运行中
      _liveSpeechText = ''; // 清空上轮临时文本
      _latestResult = '正在聆听，请继续按住屏幕'; // 更新状态提示
    });

    try {
      await _speechService.startListening(
        onText: (value) {
          if (!mounted) return; // 页面销毁则不更新
          if (_liveSpeechText == value) return; // 文本未变化不刷新
          setState(() {
            _liveSpeechText = value; // 更新实时识别中间文本
          });
        },
      );
    } catch (_) {
      if (!mounted) return; // 页面销毁则停止
      setState(() {
        _isRecording = false; // 回退 UI 状态
        _isAsrRunning = false; // 回退 ASR 状态
      });
      await _speakSafely('语音识别启动失败'); // 播报启动失败
    }
  }

  /// 长按结束：停止识别并发送用户问题。
  Future<void> _onLongPressEnd() async {
    if (!_isAsrRunning || _isExiting) return; // 非 ASR 态或退出中不处理

    await HapticFeedback.mediumImpact(); // 结束录音反馈

    if (!_speechService.isListening) {
      await Future.delayed(const Duration(milliseconds: 380)); // 兼容部分设备状态同步延迟
    }

    String finalText = ''; // 最终文本
    try {
      finalText = await _speechService.stopListeningAndGetFinalText(); // 停止并获取识别结果
    } catch (_) {
      if (mounted) {
        setState(() {
          _isRecording = false; // 回退状态
          _isAsrRunning = false;
          _latestResult = '语音识别结束失败'; // 更新错误文案
        });
      }
      await _speakSafely('语音识别结束失败'); // 播报错误
      return;
    }

    if (!mounted) return; // 页面销毁则停止
    setState(() {
      _isRecording = false; // 关闭录音 UI
      _isAsrRunning = false; // 关闭 ASR 状态
    });

    final question = finalText.trim().isNotEmpty ? finalText.trim() : _liveSpeechText.trim(); // 优先最终文本，空时回退中间文本
    if (question.isEmpty) {
      setState(() {
        _latestResult = '没有识别到有效语音'; // 更新提示
      });
      await _speakSafely('没有识别到有效语音'); // 播报提示
      return;
    }

    await _askAiWithQuestion(question); // 发送问题
  }

  /// 执行用户主动追问。
  Future<void> _askAiWithQuestion(String question) async {
    if (_isExiting || !_isRunning || _isAskingAi) return; // 门控：退出中/非运行态/已在请求中

    setState(() {
      _isAskingAi = true; // 打开“AI 思考中”状态
      _latestResult = 'AI思考中...'; // 显示处理中提示
    });

    try {
      final framePath = _latestFramePath.trim(); // 读取最新帧路径
      final reply = framePath.isEmpty
          ? await _aiService.chatWithText(history: const [], latestQuestion: question) // 无帧则退化为纯文本追问
          : await _aiService.followupWithImage(
              imageFile: File(framePath), // 有帧则带图追问
              history: const [], // 当前页主动追问不维护长历史，保持轻量
              latestQuestion: question,
            );

      if (!mounted || _isExiting) return; // 页面失效则丢弃结果
      setState(() {
        _latestResult = reply; // 更新回复
        _isAskingAi = false; // 关闭处理中状态
      });
      await _speakSafely(reply); // 播报回复
    } catch (_) {
      if (!mounted || _isExiting) return; // 页面失效则停止
      setState(() {
        _isAskingAi = false; // 关闭处理中状态
        _latestResult = '网络超时，请稍后重试'; // 更新错误文案
      });
      await _speakSafely('网络超时，请稍后重试'); // 播报错误
    }
  }

  /// 外部退出信号回调。
  void _handleExternalExit() {
    if (!_isRunning || !mounted) return; // 非运行态或页面失效时忽略
    _stopAndExit(); // 执行统一退出流程
  }

  /// 统一退出流程：停止循环、停止识别和播报、释放相机、返回上一页。
  Future<void> _stopAndExit() async {
    if (!_isRunning || _isExiting) return; // 防重入
    _isExiting = true; // 标记退出中
    _interactionEpoch += 1; // 递增代次，废弃在途结果
    _isRunning = false; // 关闭运行态
    _loopTimer?.cancel(); // 停止周期任务
    _loopTimer = null; // 清空引用
    await _speechService.cancelListening(); // 停止 ASR
    await TtsService.instance.stop(); // 停止播报
    try {
      await _cameraController?.dispose(); // 释放相机
    } catch (_) {}
    _cameraController = null; // 清空控制器引用
    if (!mounted) return; // 页面销毁则不再导航
    Navigator.of(context).pop(); // 返回上一页
  }

  /// 底部状态提示文本。
  String _buildLiveStatusHintText() {
    if (_isRecording) return '正在聆听...'; // 录音中
    if (_isAskingAi) return 'AI思考中...'; // AI 处理中
    return '继续长按可提问'; // 默认提示
  }

  /// 水平拖拽结束：满足阈值时退出页面。
  void _handleDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0; // 读取速度
    if (velocity > _exitSwipeVelocityThreshold) {
      HapticFeedback.mediumImpact(); // 退出前反馈
      unawaited(_stopAndExit()); // 异步执行退出
    }
  }

  @override
  void dispose() {
    LiveVisionScreen._exitSignal.removeListener(_handleExternalExit); // 移除外部退出监听
    _isRunning = false; // 关闭运行态
    _loopTimer?.cancel(); // 取消轮询
    TtsService.instance.stop(); // 停止播报
    _cameraController?.dispose(); // 释放相机
    super.dispose(); // 父类销毁
  }

  @override
  Widget build(BuildContext context) {
    final t = context.lwTheme; // 读取主题 token
    return GlassScaffold(
      body: GestureDetector(
        behavior: HitTestBehavior.opaque, // 全屏手势区域
        onHorizontalDragEnd: _handleDragEnd, // 滑动退出
        onLongPressStart: (_) => _onLongPressStart(), // 长按开始提问
        onLongPressEnd: (_) => _onLongPressEnd(), // 长按结束发送问题
        child: Stack(
          children: [
            SafeArea(
              child: Column(
                children: [
                  SizedBox(height: t.space12), // 顶部留白
                  GlassCard(
                    useMediumSurface: true,
                    margin: EdgeInsets.symmetric(horizontal: t.space24),
                    padding: EdgeInsets.symmetric(horizontal: t.space16, vertical: t.space12),
                    child: Text(
                      '实时感知中\n长按提问｜左滑退出', // 顶部操作提示
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: t.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  SizedBox(height: t.space12), // 顶部提示与预览间距
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: t.space24), // 预览区左右边距
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(t.radiusCard), // 预览圆角
                        child: _cameraController != null && _cameraController!.value.isInitialized
                            ? IgnorePointer(
                                child: CameraPreview(_cameraController!), // 显示实时预览
                              )
                            : Center(
                                child: CircularProgressIndicator(color: t.primaryAccent), // 相机未就绪时显示加载
                              ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: t.space24), // 结果卡片左右边距
                    child: GlassCard(
                      useMediumSurface: true,
                      padding: EdgeInsets.all(t.space16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _buildLiveStatusHintText(), // 状态提示
                            style: TextStyle(
                              color: t.textSecondary,
                              fontSize: 14,
                            ),
                          ),
                          SizedBox(height: t.space8),
                          Text(
                            _latestResult, // 主结果文本
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
                  SizedBox(height: t.space12), // 底部留白
                ],
              ),
            ),
            IgnorePointer(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220), // 录音态高亮动画
                curve: Curves.easeOut,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _isRecording ? t.recordingAccent : Colors.transparent, // 录音时显示高亮边框
                    width: _isRecording ? 3 : 0,
                  ),
                  color: _isRecording
                      ? t.recordingAccent.withValues(alpha: 0.12) // 录音时显示淡色遮罩
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
