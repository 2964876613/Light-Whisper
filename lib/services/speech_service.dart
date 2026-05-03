import 'package:flutter/foundation.dart'; // ValueChanged 类型
import 'package:flutter_dotenv/flutter_dotenv.dart'; // 读取 .env 配置
import 'package:permission_handler/permission_handler.dart'; // 麦克风权限请求

import 'asr_service.dart'; // 底层 ASR 录音+WebSocket 服务

/// ASR 初始化状态。
enum AsrInitStatus {
  ready, // 权限与配置都可用
  permissionDenied, // 麦克风权限拒绝
  recognizerUnavailable, // 识别器异常/不可用
  initFailed, // 配置缺失等初始化失败
}

/// 面向页面层的语音识别编排服务：
/// - 权限检查；
/// - 初始化状态管理；
/// - 启停识别与文本回传。
class SpeechService {
  SpeechService({AsrService? asrService})
      : _asrService = asrService ?? AsrService.instance; // 允许注入，默认用单例

  final AsrService _asrService; // 底层识别服务实例

  String _lastPartialText = ''; // 最近一次中间识别文本
  AsrInitStatus _lastInitStatus = AsrInitStatus.initFailed; // 最近初始化状态

  bool get isListening => _asrService.isRecording; // 对外暴露当前是否在录音
  AsrInitStatus get lastInitStatus => _lastInitStatus; // 对外暴露最近初始化状态

  /// 快捷入口：只关心是否可用。
  Future<bool> ensurePermissionAndInit() async {
    final status = await ensurePermissionAndInitStatus(); // 获取细粒度状态
    return status == AsrInitStatus.ready; // 转成布尔结果
  }

  /// 完整入口：返回细粒度状态，便于上层给不同提示文案。
  Future<AsrInitStatus> ensurePermissionAndInitStatus() async {
    final micStatus = await Permission.microphone.request(); // 请求麦克风权限
    if (!micStatus.isGranted) {
      _lastInitStatus = AsrInitStatus.permissionDenied; // 更新状态为权限拒绝
      return _lastInitStatus; // 返回
    }

    final apiKey = dotenv.env['ASR_API_KEY']?.trim() ?? ''; // 读取 ASR key
    final resourceId = dotenv.env['ASR_API_RESOURCE_ID']?.trim() ?? ''; // 读取 ASR 资源 id
    if (apiKey.isEmpty || resourceId.isEmpty) {
      _lastInitStatus = AsrInitStatus.initFailed; // 配置缺失
      return _lastInitStatus; // 返回失败状态
    }

    _lastInitStatus = AsrInitStatus.ready; // 配置与权限都可用
    return _lastInitStatus; // 返回就绪状态
  }

  /// 启动监听并通过回调持续返回识别文本。
  Future<void> startListening({
    required ValueChanged<String> onText, // 中间文本回调
    String localeId = 'zh_CN', // 预留语言参数（当前底层固定 zh-CN）
  }) async {
    _lastPartialText = ''; // 每轮开始前清空上次缓存
    debugPrint('[ASR] startListening locale=$localeId'); // 调试日志
    final ok = await ensurePermissionAndInit(); // 先检查权限/配置
    if (!ok) {
      throw Exception('麦克风权限未授予或语音识别服务不可用'); // 让上层做统一错误反馈
    }

    if (_asrService.isRecording) {
      return; // 已在录音中则不重复启动
    }

    try {
      await _asrService.startRecording((text, isDefinite) {
        final value = text.trim(); // 清理回调文本
        if (value.isEmpty) {
          return; // 空字符串不回传
        }
        _lastPartialText = value; // 缓存最新中间文本
        onText(value); // 通知上层刷新 UI
      });
      _lastInitStatus = AsrInitStatus.ready; // 成功启动后标记 ready
    } catch (e) {
      debugPrint('[ASR] startListening failed: $e'); // 记录错误
      final message = e.toString(); // 错误文案
      if (message.contains('Missing ASR_')) {
        _lastInitStatus = AsrInitStatus.initFailed; // 配置缺失
      } else {
        _lastInitStatus = AsrInitStatus.recognizerUnavailable; // 其他异常按识别器不可用处理
      }
      rethrow; // 抛给上层做交互提示
    }
  }

  /// 停止监听并返回最终文本。
  /// 优先使用底层最终文本，空时回退中间文本缓存，减少“空识别”体感。
  Future<String> stopListeningAndGetFinalText() async {
    final words = (await _asrService.stopRecording()).trim(); // 停止并取最终结果
    debugPrint('[ASR] stop result words="$words" cached="$_lastPartialText"'); // 调试日志
    if (words.isNotEmpty) {
      return words; // 有最终结果直接返回
    }
    return _lastPartialText.trim(); // 否则回退中间结果
  }

  /// 取消当前监听，不返回文本。
  Future<void> cancelListening() async {
    await _asrService.cancelRecording(); // 委托底层取消
  }
}
