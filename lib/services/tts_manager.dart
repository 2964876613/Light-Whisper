import 'package:flutter/foundation.dart'; // 提供 ValueNotifier，用于状态可观察

import 'tts_service.dart'; // 真实播报能力由 TtsService 提供

/// TTS 生命周期状态。
enum TtsState {
  uninitialized, // 初始态：尚未准备
  binding, // 准备中：正在建立可播报状态
  ready, // 就绪态：可正常播报
  failed, // 失败态：最近一次播报失败
}

/// TTS 状态门面：
/// - 对外暴露简单的“确保可用 + 安全播报”；
/// - 隐藏底层细节，降低页面复杂度。
class TtsManager {
  TtsManager._(); // 私有构造，约束为单例

  static final TtsManager instance = TtsManager._(); // 全局单例实例

  final ValueNotifier<TtsState> state = ValueNotifier<TtsState>(TtsState.uninitialized); // 可监听状态

  Future<bool>? _initFuture; // 并发初始化时复用同一 Future，避免竞态

  /// 确保进入 ready 状态。
  Future<bool> ensureReady() {
    if (state.value == TtsState.ready) {
      return Future.value(true); // 已就绪直接返回
    }

    final inflight = _initFuture; // 读取当前是否有在途初始化
    if (inflight != null) {
      return inflight; // 有在途则复用
    }

    state.value = TtsState.binding; // 进入准备态
    final future = Future<bool>.value(true); // 当前实现为轻量“即刻就绪”占位
    _initFuture = future; // 记录在途 future
    return future.whenComplete(() {
      if (state.value == TtsState.binding) {
        state.value = TtsState.ready; // 完成后转就绪态
      }
      _initFuture = null; // 清空在途标记
    });
  }

  /// 先 ensureReady，再执行播报，并回写状态。
  Future<bool> speakSafely(String text) async {
    final content = text.trim(); // 去掉首尾空白
    if (content.isEmpty) {
      return false; // 空文本不播报
    }

    await ensureReady(); // 先确保可用
    final ok = await TtsService.instance.speak(content); // 实际播报
    state.value = ok ? TtsState.ready : TtsState.failed; // 根据结果更新状态
    return ok; // 返回播报是否成功
  }

  /// 停止当前播报。
  Future<void> stop() async {
    await TtsService.instance.stop(); // 委托给底层服务
  }
}
