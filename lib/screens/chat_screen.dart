import 'dart:async'; // 提供 unawaited/Future 等异步工具
import 'dart:io'; // 提供 File，用于把图片路径包装成文件对象

import 'package:flutter/material.dart'; // Flutter 基础 UI 组件
import 'package:flutter/services.dart'; // 触觉反馈 HapticFeedback
import 'package:provider/provider.dart'; // 读取用户等级状态（是否 Pro）
import 'package:vibration/vibration.dart'; // 设备震动能力

import '../models/capture_source.dart'; // 拍照来源枚举（双击拍照/摇一摇）
import '../providers/user_tier_provider.dart'; // 用户等级 Provider
import '../services/doubao_api_service.dart'; // AI 图像分析服务
import '../services/tts_service.dart'; // 语音播报服务
import '../widgets/frosted_primitives.dart'; // 玻璃风格 UI 组件
import 'continuous_chat_screen.dart'; // 连续对话页面

/// 单次图片解析结果页：
/// 1) 接收上一页传来的图片路径；
/// 2) 调用 AI 解析并播报结果；
/// 3) Pro 用户在播报完成后可长按进入连续对话。
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key, // Flutter 组件标识键，便于树重建时识别实例
    required this.captureSource, // 记录入口来源（相机/摇一摇）
    required this.imagePath, // 传入图片路径（可空，空时走无图兜底）
  });

  final CaptureSource captureSource; // 来源用于业务统计/流程判断（当前文件未直接使用）
  final String? imagePath; // 待分析图片的本地路径

  @override
  State<ChatScreen> createState() => _ChatScreenState(); // 创建可变状态对象
}

/// 页面状态：
/// - _isLoading: 是否还在分析中
/// - _ttsFinished: 播报是否已结束（控制可否进入连续对话）
/// - _isJumpingToContinuous: 是否正在跳转连续对话（防重复触发）
class _ChatScreenState extends State<ChatScreen> {
  static const double _exitSwipeVelocityThreshold = 250; // 右滑返回的最小速度阈值

  final DoubaoApiService _aiVisionService = DoubaoApiService(); // AI 视觉服务实例

  bool _isLoading = true; // 初始为加载中，等待 AI 结果
  bool _ttsFinished = false; // 初始未播报完成
  bool _isJumpingToContinuous = false; // 初始未跳转
  String _aiResult = ''; // AI 主结果文本
  String _safetyHint = ''; // 安全提示文本（预留）
  String _contextHint = ''; // 上下文摘要（如障碍/风险）
  String _safetyLevel = ''; // 风险等级（用于颜色映射）

  @override
  void initState() {
    super.initState(); // 先执行父类初始化
    _simulateAnalyzeAndSpeak(); // 进入页面即开始分析并播报
  }

  /// 播报文本并在可控时间后将页面标记为“播报完成”。
  /// 说明：当前 TTS 没有可靠“播放完成”回调，这里用延时近似完成信号。
  Future<void> _speakWithFallbackFinish(String text) async {
    final ok = await TtsService.instance.speak(text); // 调用云端 TTS 播报
    if (!mounted) return; // 页面已销毁则停止后续 setState
    if (!ok) {
      setState(() {
        _ttsFinished = true; // 播报失败也放行交互，避免卡死
      });
      return;
    }

    Future.delayed(const Duration(seconds: 4), () {
      if (!mounted) return; // 延时回调时页面可能已退出
      if (_ttsFinished) return; // 已完成则不重复 setState
      setState(() {
        _ttsFinished = true; // 到时间后标记播报完成
      });
    });
  }

  /// 执行单次图像分析并触发播报。
  Future<void> _simulateAnalyzeAndSpeak() async {
    final path = widget.imagePath; // 读取路由传入的图片路径

    String result; // 最终要显示/播报的主文本
    String hint = ''; // 预留安全提示
    String contextHint = ''; // 障碍+风险拼接文本
    String safetyLevel = ''; // 预留安全等级
    String liteObstacle = ''; // 轻量模式返回的障碍字段
    String liteRisk = ''; // 轻量模式返回的风险字段

    if (path == null || path.isEmpty) {
      result = DoubaoApiService.recognitionFallbackMessage; // 无图时直接用识别兜底文案
    } else {
      final analysis = await _aiVisionService.analyzeImageWithFallback(
        File(path), // 路径转 File
        preferLitePrompt: true, // 使用轻量提示词，追求简短播报
      );
      result = analysis.ttsText; // 先取服务给出的播报文本

      final lite = analysis.liteMeta; // 尝试读取结构化轻量元信息
      if (lite != null) {
        liteObstacle = lite.obstacleText; // 提取障碍
        liteRisk = lite.riskLevel; // 提取风险
        if (lite.briefDescription.trim().isNotEmpty) {
          result = lite.briefDescription.trim(); // 优先用更简洁描述
        }
      }
    }

    if (!mounted) return; // 异步返回后先检查页面是否仍存在
    if (liteObstacle.isNotEmpty || liteRisk.isNotEmpty) {
      final riskText = liteRisk.isEmpty ? '未知' : liteRisk; // 风险缺失时给默认值
      final obstacleText = liteObstacle.isEmpty ? '未明确' : liteObstacle; // 障碍缺失时给默认值
      contextHint = '障碍：$obstacleText，风险：$riskText'; // 组装上下文摘要
    }

    setState(() {
      _aiResult = result; // 更新主结果
      _safetyHint = hint; // 更新安全提示
      _contextHint = contextHint; // 更新上下文摘要
      _safetyLevel = safetyLevel; // 更新安全等级
      _isLoading = false; // 结束加载态
      _ttsFinished = false; // 新一轮播报开始前重置
    });

    final speakText = _contextHint.isEmpty ? result : '$_contextHint。$result'; // 有上下文就拼接后播报
    await _speakWithFallbackFinish(speakText); // 执行播报并管理完成状态
  }

  @override
  void dispose() {
    unawaited(TtsService.instance.stop()); // 页面销毁时尽快停止播报，避免串音
    super.dispose(); // 执行父类销毁
  }

  /// 根据当前状态生成 Pro 用户底部提示文案。
  String _buildProHintText({required bool canEnterContinuous}) {
    if (!canEnterContinuous) {
      return _isLoading || !_ttsFinished ? '正在播报，请稍候' : '暂不可进入连续对话'; // 区分“加载中”与“已结束但不可进”
    }
    return '长按屏幕进入连续对话'; // 满足条件时给出明确操作指令
  }

  /// 处理水平拖拽结束，速度足够则返回上一页。
  void _handleDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0; // 读取主方向速度
    if (velocity > _exitSwipeVelocityThreshold) {
      Navigator.of(context).pop(); // 触发返回
    }
  }

  /// 统一触觉反馈方法：先系统重击，再尝试振动器。
  Future<void> _vibrate({required int durationMs, int? amplitude}) async {
    try {
      await HapticFeedback.heavyImpact(); // 系统级触觉（兼容多数设备）
    } catch (_) {}

    try {
      final hasVibrator = await Vibration.hasVibrator(); // 查询设备是否支持振动
      if (!hasVibrator) return; // 不支持则直接结束
      if (amplitude == null) {
        await Vibration.vibrate(duration: durationMs); // 不指定强度，走默认
      } else {
        await Vibration.vibrate(duration: durationMs, amplitude: amplitude); // 指定强度
      }
    } catch (_) {}
  }

  /// 进入连续对话页。
  Future<void> _openContinuousChat() async {
    if (_isJumpingToContinuous || _isLoading || !_ttsFinished) return; // 防重入：跳转中/加载中/播报未完成都不允许进入

    await _vibrate(durationMs: 60, amplitude: 180); // 入场前给反馈
    await TtsService.instance.stop(); // 停止当前播报，避免跨页重叠

    if (!mounted) return; // 再次确认页面仍在
    setState(() {
      _isJumpingToContinuous = true; // 标记正在跳转，锁住重复操作
    });

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ContinuousChatScreen(
          initialAssistantText: _aiResult, // 把当前回答带给连续对话页
          initialContextHint: _contextHint, // 把上下文提示带过去
          imagePath: widget.imagePath, // 把原图路径带过去供后续图片追问
        ),
      ),
    );

    if (!mounted) return; // 返回时页面可能已销毁
    await _vibrate(durationMs: 40, amplitude: 120); // 返回后轻反馈
    setState(() {
      _isJumpingToContinuous = false; // 解锁交互
    });
  }

  @override
  Widget build(BuildContext context) {
    final isProUser = context.watch<UserTierProvider>().isProUser; // 监听用户等级变化
    final canEnterContinuous = isProUser && !_isLoading && _ttsFinished; // 连续对话入口开关

    final t = context.lwTheme; // 读取主题 token
    return GlassScaffold(
      body: Semantics(
        label: '播报完成后长按屏幕进入连续对话，向右滑动返回首页', // 无障碍整体提示
        child: GestureDetector(
          behavior: HitTestBehavior.opaque, // 空白区域也接收手势
          onHorizontalDragEnd: _handleDragEnd, // 右滑返回
          onLongPress: canEnterContinuous ? _openContinuousChat : null, // 满足条件才启用长按
          child: Stack(
            children: [
              SafeArea(
                child: Column(
                  children: [
                    SizedBox(height: t.space16), // 顶部留白
                    Semantics(
                      header: true, // 标记为语义标题
                      label: '光语解析结果',
                      child: Text(
                        '光语解析', // 页面标题
                        style: TextStyle(
                          color: t.textPrimary,
                          fontSize: 24,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    SizedBox(height: t.space24), // 标题与内容间距
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: t.space24), // 内容左右内边距
                        child: Semantics(
                          liveRegion: true, // 结果变化可被辅助功能感知
                          label: _buildResultSemanticsLabel(), // 动态语义文本
                          child: GlassCard(
                            useMediumSurface: true,
                            padding: EdgeInsets.all(t.space16),
                            child: _isLoading
                                ? Center(
                                    child: CircularProgressIndicator(color: t.primaryAccent), // 加载中转圈
                                  )
                                : Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      if (_safetyHint.isNotEmpty)
                                        Padding(
                                          padding: const EdgeInsets.only(bottom: 8),
                                          child: Text(
                                            _safetyHint, // 安全提示（若有）
                                            style: TextStyle(
                                              color: _safetyHintColor(_safetyLevel), // 按风险等级着色
                                              fontSize: 16,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      if (_contextHint.isNotEmpty)
                                        Padding(
                                          padding: const EdgeInsets.only(bottom: 10),
                                          child: Text(
                                            _contextHint, // 障碍+风险摘要（若有）
                                            style: TextStyle(
                                              color: t.primaryAccent,
                                              fontSize: 15,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                      Text(
                                        _aiResult, // AI 主输出
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
                      padding: EdgeInsets.fromLTRB(t.space24, t.space12, t.space24, t.space24), // 底部提示区域边距
                      child: _buildInputArea(
                        isProUser: isProUser, // 传入是否 Pro
                        canEnterContinuous: canEnterContinuous, // 传入入口开关
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
                      color: _isJumpingToContinuous ? t.recordingAccent : Colors.transparent, // 跳转中显示高亮边框
                      width: _isJumpingToContinuous ? 3 : 0,
                    ),
                    color: _isJumpingToContinuous
                        ? t.recordingAccent.withValues(alpha: 0.12) // 跳转中显示轻遮罩
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

  /// 组装语义播报文本，供无障碍读取。
  String _buildResultSemanticsLabel() {
    if (_isLoading) {
      return '正在处理中'; // 加载中时返回固定语义
    }

    final parts = <String>[]; // 分段组装，最后用句号拼接
    if (_safetyHint.isNotEmpty) {
      parts.add(_safetyHint); // 先加安全提示
    }
    if (_contextHint.isNotEmpty) {
      parts.add(_contextHint); // 再加上下文摘要
    }
    parts.add('AI解析内容：$_aiResult'); // 最后加主结果
    return parts.join('。'); // 拼成完整语义句
  }

  /// 根据风险等级返回提示色。
  Color _safetyHintColor(String level) {
    switch (level) {
      case 'critical':
        return const Color(0xFFE45B5B); // 极高风险：红
      case 'high':
        return const Color(0xFFEF8B52); // 高风险：橙红
      case 'medium':
        return const Color(0xFFF1B357); // 中风险：橙黄
      case 'low':
        return const Color(0xFF67B886); // 低风险：绿
      default:
        return const Color(0xFFF1B357); // 未知风险：默认中风险色
    }
  }

  /// 构建底部交互提示区（免费用户与 Pro 用户分支）。
  Widget _buildInputArea({required bool isProUser, required bool canEnterContinuous}) {
    if (!isProUser) {
      final t = context.lwTheme; // 读取主题
      return Semantics(
        label: '当前为免费用户，仅支持单次播报', // 无障碍提示
        child: GlassCard(
          useMediumSurface: true,
          padding: EdgeInsets.all(t.space12),
          child: Text(
            _isLoading || !_ttsFinished ? '免费模式：正在单次播报' : '免费模式：单次播报已完成', // 免费模式固定文案
            textAlign: TextAlign.center,
            style: TextStyle(color: t.textPrimary, fontSize: 16),
          ),
        ),
      );
    }

    final hintText = _buildProHintText(canEnterContinuous: canEnterContinuous); // 生成 Pro 文案

    final t = context.lwTheme; // 读取主题
    return Semantics(
      label: hintText, // 无障碍读取提示
      child: GlassCard(
        useMediumSurface: true,
        padding: EdgeInsets.all(t.space12),
        child: Text(
          _isJumpingToContinuous ? '正在进入连续对话' : hintText, // 跳转中替换文案
          textAlign: TextAlign.center,
          style: TextStyle(color: t.textPrimary, fontSize: 16),
        ),
      ),
    );
  }
}
