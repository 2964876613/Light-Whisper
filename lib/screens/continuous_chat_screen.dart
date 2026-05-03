import 'dart:async'; // 提供 unawaited/Future 等异步工具
import 'dart:io'; // 提供 File，用于图片追问时读取本地图片

import 'package:flutter/material.dart'; // Flutter UI 基础组件
import 'package:flutter/services.dart'; // 触觉反馈能力
import 'package:vibration/vibration.dart'; // 设备振动能力

import '../services/doubao_api_service.dart'; // AI 服务：文本追问/图片追问
import '../services/speech_service.dart'; // ASR 编排服务：按住说话流程
import '../services/tts_service.dart'; // TTS 播报服务
import '../widgets/frosted_primitives.dart'; // 玻璃风 UI 组件

/// 连续对话页面：
/// - 接收首轮回答作为对话起点；
/// - 支持长按说话、识别、发送追问、播报回复；
/// - 根据问题内容决定走文本追问还是图片追问。
class ContinuousChatScreen extends StatefulWidget {
  const ContinuousChatScreen({
    super.key, // Flutter 组件标识
    required this.initialAssistantText, // 首轮回答文本（上一页传入）
    this.initialContextHint = '', // 首轮上下文提示（可选）
    this.imagePath, // 原始图片路径（可选，图片追问时使用）
  });

  final String initialAssistantText; // 初始 AI 回复
  final String initialContextHint; // 初始上下文提示
  final String? imagePath; // 原图路径

  @override
  State<ContinuousChatScreen> createState() => _ContinuousChatScreenState(); // 创建状态对象
}

/// 状态流转：
/// 1) 长按开始 -> 启动 ASR；
/// 2) 长按结束 -> 停止 ASR 并得到问题；
/// 3) 问题路由 -> 文本追问或图片追问；
/// 4) 更新 UI 并 TTS 播报。
class _ContinuousChatScreenState extends State<ContinuousChatScreen> {
  static const double _exitSwipeVelocityThreshold = 250; // 右滑返回速度阈值

  final DoubaoApiService _aiService = DoubaoApiService(); // AI 请求服务实例
  final SpeechService _speechService = SpeechService(); // 语音识别服务实例
  bool _isLoading = false; // 是否正在等待 AI 回复
  bool _isRecording = false; // 是否处于“按住说话”视觉状态
  bool _isAsrRunning = false; // ASR 是否正在运行（防重复开始/结束）
  String _liveSpeechText = ''; // 实时识别中的临时文本
  String _currentReply = ''; // 当前显示的 AI 回复文本

  final List<Map<String, String>> _chatHistory = []; // 简单会话历史（role/content）

  @override
  void initState() {
    super.initState(); // 先执行父类初始化
    _currentReply = widget.initialAssistantText; // 首次显示上一页传入的首轮回答
    _chatHistory.add({'role': 'assistant', 'content': widget.initialAssistantText}); // 把首轮回答写入历史，便于后续上下文追问
  }

  @override
  void dispose() {
    unawaited(TtsService.instance.stop()); // 页面退出时停止播报，避免串音
    unawaited(_speechService.cancelListening()); // 页面退出时取消 ASR，避免后台继续占用资源
    super.dispose(); // 执行父类销毁
  }

  /// 错误时的振动反馈。
  Future<void> _vibrateError() async {
    final hasVibrator = await Vibration.hasVibrator(); // 先确认设备支持振动
    if (!hasVibrator) return; // 不支持则直接返回
    await Vibration.vibrate(duration: 180, amplitude: 200); // 错误反馈使用稍长且较强振动
  }

  /// 统一播报方法。
  Future<void> _speak(String text) async {
    await TtsService.instance.speak(text); // 调用全局 TTS 服务播报
  }

  /// 错误反馈：先振动，再播报错误文案。
  Future<void> _speakError(String message) async {
    await _vibrateError(); // 先给触觉反馈
    await _speak(message); // 再给语音反馈
  }

  /// 长按开始时触发：校验并启动语音识别。
  Future<void> _onLongPressStart() async {
    if (_isAsrRunning || _isLoading) return; // ASR 已运行或 AI 正处理中时禁止再次启动

    final initStatus = await _speechService.ensurePermissionAndInitStatus(); // 检查权限与初始化状态
    if (initStatus != AsrInitStatus.ready) {
      final message = switch (initStatus) {
        AsrInitStatus.permissionDenied => '麦克风权限未授予，请在设置中开启', // 权限被拒绝
        AsrInitStatus.recognizerUnavailable => '语音识别服务连接失败，请检查网络后重试', // 识别器不可用
        AsrInitStatus.initFailed => '语音识别配置缺失，请检查 .env', // 配置缺失
        AsrInitStatus.ready => '', // 理论不会走到这里，仅满足 switch 完整性
      };
      if (message.isNotEmpty) {
        await _speakError(message); // 有错误文案则播报
      }
      return; // 初始化失败时结束流程
    }

    await HapticFeedback.heavyImpact(); // 成功进入录音态前给一次重触觉
    await TtsService.instance.stop(); // 先停止当前播报，避免录音和播报同时进行

    if (!mounted) return; // 页面已销毁则停止
    setState(() {
      _isRecording = true; // 打开录音视觉态
      _isAsrRunning = true; // 标记 ASR 运行中
      _liveSpeechText = ''; // 清空上一轮临时识别文本
    });

    try {
      await _speechService.startListening(
        onText: (value) {
          if (!mounted) return; // 防止页面销毁后 setState
          if (_liveSpeechText == value) return; // 文本未变化则不刷新
          setState(() {
            _liveSpeechText = value; // 实时显示最新识别中间结果
          });
        },
      );
    } catch (_) {
      if (!mounted) return; // 页面已销毁则不处理
      setState(() {
        _isRecording = false; // 回退录音态
        _isAsrRunning = false; // 回退 ASR 运行标记
      });
      await _speakError('语音识别启动失败'); // 提示启动失败
    }
  }

  /// 长按结束时触发：停止识别并发送追问。
  Future<void> _onLongPressEnd() async {
    if (!_isAsrRunning) return; // 只有在 ASR 运行中才允许结束

    await HapticFeedback.mediumImpact(); // 结束录音给中等触觉反馈

    if (!_speechService.isListening) {
      await Future.delayed(const Duration(milliseconds: 380)); // 某些设备上 stop 前可能短暂不同步，稍等一会
    }

    String finalText = ''; // 最终识别结果
    try {
      finalText = await _speechService.stopListeningAndGetFinalText(); // 停止并取最终文本
    } catch (_) {
      await _speakError('语音识别结束失败'); // 停止失败时提示
    }

    if (!mounted) return; // 页面销毁则停止
    setState(() {
      _isRecording = false; // 关闭录音态
      _isAsrRunning = false; // 标记 ASR 已结束
    });

    final question = finalText.trim().isNotEmpty ? finalText.trim() : _liveSpeechText.trim(); // 优先最终文本，空时回退中间文本
    if (question.isEmpty) {
      await _speakError('没有识别到有效语音'); // 两者都空则提示无有效语音
      return;
    }

    await _sendFollowupQuestion(question); // 发送追问
  }

  /// 判断当前问题是否更适合走“图片细节追问”。
  bool _shouldUseImageFollowup(String question) {
    final normalized = question.trim(); // 去掉首尾空白
    if (normalized.isEmpty) {
      return false; // 空问题直接走文本（实际上上游已拦）
    }

    const keywords = [
      '左边', // 方位细节关键词
      '右边',
      '前面',
      '后面',
      '上面',
      '下面',
      '远处',
      '近处',
      '写了什么', // 文字读取类关键词
      '数字',
      '号码',
      '颜色', // 属性细节关键词
      '牌子',
      '招牌',
      '文字',
      '哪一个', // 指代确认关键词
      '那个',
      '这个细节',
      '具体一点', // 要求更细节关键词
      '仔细看',
      '重新看',
      '看清',
      '几个人', // 计数关键词
      '几个',
      '多少个',
    ];

    return keywords.any(normalized.contains); // 命中任一关键词则走图片追问
  }

  /// 根据问题类型决定请求路径。
  Future<String> _resolveFollowupReply(String question) async {
    if (_shouldUseImageFollowup(question)) {
      final imagePath = widget.imagePath?.trim(); // 读取并清理图片路径
      if (imagePath == null || imagePath.isEmpty) {
        return '当前没有可用图片，无法重新核对这个细节'; // 需要图片但无图时明确降级
      }
      return _aiService.followupWithImage(
        imageFile: File(imagePath), // 图片追问需要传图片
        history: _chatHistory, // 携带历史上下文
        latestQuestion: question, // 当前问题
      );
    }

    return _aiService.chatWithText(
      history: _chatHistory, // 文本追问也带历史
      latestQuestion: question, // 当前问题
    );
  }

  /// 发送追问，更新历史与 UI，并播报回复。
  Future<void> _sendFollowupQuestion(String text) async {
    if (_isLoading || text.trim().isEmpty) return; // 正在处理中或空问题时不重复发送

    final question = text.trim(); // 清理问题文本
    setState(() {
      _isLoading = true; // 进入加载态
      _chatHistory.add({'role': 'user', 'content': question}); // 先把用户问题写入历史
    });

    try {
      final assistantReply = await _resolveFollowupReply(question); // 获取 AI 回复

      if (!mounted) return; // 页面销毁则停止
      setState(() {
        _currentReply = assistantReply; // 更新当前展示回复
        _chatHistory.add({'role': 'assistant', 'content': assistantReply}); // 把助手回复写入历史
        _isLoading = false; // 退出加载态
      });

      await _speak(assistantReply); // 播报助手回复
    } catch (_) {
      if (!mounted) return; // 页面销毁则停止
      setState(() {
        _isLoading = false; // 异常也要退出加载态
      });
      await _speakError('网络超时，请稍后重试'); // 统一网络异常提示
    }
  }

  /// 生成底部提示文案。
  String _buildBottomHintText() {
    if (_isRecording) return '正在聆听，请继续按住屏幕'; // 录音中提示
    if (_isLoading) return '处理中，请稍候'; // AI 处理中提示
    return '按住屏幕任意位置提问'; // 默认提示
  }

  /// 处理右滑返回手势。
  void _handleDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0; // 获取主方向速度
    if (velocity > _exitSwipeVelocityThreshold) {
      Navigator.of(context).pop(); // 速度足够则返回
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.lwTheme; // 读取主题 token
    return GlassScaffold(
      body: Semantics(
        label: '连续对话页面，长按屏幕提问，向右滑动返回', // 整页无障碍说明
        child: GestureDetector(
          behavior: HitTestBehavior.opaque, // 空白区域也响应手势
          onHorizontalDragEnd: _handleDragEnd, // 右滑返回
          onLongPressStart: (_) => _onLongPressStart(), // 长按开始录音
          onLongPressEnd: (_) => _onLongPressEnd(), // 长按结束并提问
          child: Stack(
            children: [
              SafeArea(
                child: Column(
                  children: [
                    SizedBox(height: t.space16), // 顶部留白
                    Text(
                      '连续对话', // 页面标题
                      style: TextStyle(
                        color: t.textPrimary,
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: t.space24), // 标题与内容间距
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: t.space24), // 内容区左右边距
                        child: GlassCard(
                          useMediumSurface: true,
                          padding: EdgeInsets.all(t.space16),
                          child: _isLoading
                              ? Center(
                                  child: CircularProgressIndicator(color: t.primaryAccent), // 加载中动画
                                )
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (widget.initialContextHint.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(bottom: 10),
                                        child: Text(
                                          widget.initialContextHint, // 首轮上下文提示
                                          style: TextStyle(
                                            color: t.warningAccent,
                                            fontSize: 15,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    Text(
                                      _currentReply, // 当前 AI 回复正文
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
                    Padding(
                      padding: EdgeInsets.fromLTRB(t.space24, t.space12, t.space24, t.space24), // 底部提示区域边距
                      child: GlassCard(
                        useMediumSurface: true,
                        padding: EdgeInsets.all(t.space12),
                        child: Text(
                          _buildBottomHintText(), // 动态提示文案
                          textAlign: TextAlign.center,
                          style: TextStyle(color: t.textPrimary, fontSize: 16),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              IgnorePointer(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220), // 录音态边框动画时长
                  curve: Curves.easeOut, // 录音态边框动画曲线
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: _isRecording ? t.recordingAccent : Colors.transparent, // 录音时显示高亮边框
                      width: _isRecording ? 3 : 0, // 录音时边框宽度
                    ),
                    color: _isRecording
                        ? t.recordingAccent.withValues(alpha: 0.12) // 录音时淡色遮罩
                        : Colors.transparent, // 非录音时透明
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
