import 'package:flutter/foundation.dart';

import 'tts_service.dart';

enum TtsState {
  uninitialized,
  binding,
  ready,
  failed,
}

class TtsManager {
  TtsManager._();

  static final TtsManager instance = TtsManager._();

  final ValueNotifier<TtsState> state = ValueNotifier<TtsState>(TtsState.uninitialized);

  Future<bool>? _initFuture;

  Future<bool> ensureReady() {
    if (state.value == TtsState.ready) {
      return Future.value(true);
    }

    final inflight = _initFuture;
    if (inflight != null) {
      return inflight;
    }

    state.value = TtsState.binding;
    final future = Future<bool>.value(true);
    _initFuture = future;
    return future.whenComplete(() {
      if (state.value == TtsState.binding) {
        state.value = TtsState.ready;
      }
      _initFuture = null;
    });
  }

  Future<bool> speakSafely(String text) async {
    final content = text.trim();
    if (content.isEmpty) {
      return false;
    }

    await ensureReady();
    final ok = await TtsService.instance.speak(content);
    state.value = ok ? TtsState.ready : TtsState.failed;
    return ok;
  }

  Future<void> stop() async {
    await TtsService.instance.stop();
  }
}
