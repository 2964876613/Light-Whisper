# Progress Log

## Session 2026-04-29
- Created planning files for implementation tracking.
- Loaded approved design spec:
  - `docs/superpowers/specs/2026-04-29-tts-bind-failure-fix-design.md`
- Defined phased implementation plan with file-level scope and acceptance checks.
- Implemented `lib/services/tts_manager.dart` with centralized lifecycle state, serialized init, `ensureReady`, `speakSafely`, and `stop`.
- Migrated TTS call path in:
  - `lib/screens/chat_screen.dart`
  - `lib/screens/live_vision_screen.dart`
  - `lib/screens/continuous_chat_screen.dart`
- Verified direct `FlutterTts.speak` only remains inside `lib/services/tts_manager.dart`.
- Ran `flutter analyze`; result is non-zero due to existing deprecated `speech_to_text` API usage in `lib/services/speech_service.dart` (not introduced by this change).
- Added TTS resilience for real-device timing variance: `TtsManager.speakSafely` now performs one automatic rebind-and-retry when first speak fails (220ms delayed retry).
- Strengthened speak failure detection for OEM devices: `_speakOnce` now validates result code + post-call state + error-callback flag before treating speak as success.
- Hardened TTS init against false-ready states: error callback is registered before language config, and init now retries up to 3 attempts with callback-based probe before marking `ready`.
- Added strict init success gating by validating plugin return values (`setLanguage`, `setSpeechRate`, `setVolume`, `setPitch`, `awaitSpeakCompletion`) before entering `ready` state.
- Replaced manager path with active-polling `TtsService` (`lib/services/tts_service.dart`) and migrated all three screens to `TtsService.instance.speak/stop`.
- New TTS init strategy now uses up to 10 probe attempts (500ms interval) via `isLanguageAvailable('zh-CN')` before marking initialized.
- Added non-crashing ASR fallback: `SpeechService.ensurePermissionAndInit` now catches `PlatformException(recognizerNotAvailable)` and returns `false` instead of throwing.
- Reduced noisy TTS stop errors on unbound devices: `TtsService.stop()` now no-ops when engine is not initialized.
