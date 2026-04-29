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

## Session 2026-04-30
- Approved and wrote design spec:
  - `docs/superpowers/specs/2026-04-30-shake-gallery-permission-design.md`
- Confirmed root cause of missing gallery prompt:
  - `android/app/src/main/AndroidManifest.xml` lacks Android gallery read permission declarations
- Confirmed existing shake analysis chain after path resolution:
  - `lib/screens/home_screen.dart` -> `lib/screens/chat_screen.dart` -> `lib/services/doubao_api_service.dart`
- Converted the approved spec into implementation phases in `task_plan.md`.
- Recorded new findings for explicit outcome branching, settings redirection, and out-of-scope files.
- Planning handoff note: `session-catchup.py` exited with code 49, so planning continued from current files and the approved spec.
- Added Android gallery permission declarations to `android/app/src/main/AndroidManifest.xml`.
- Refactored `lib/screens/home_screen.dart` shake flow to resolve explicit outcomes for success, no-image, denied, and permanently denied before navigation.
- Added home-screen permission dialog with `去设置 / 取消`; denied permission no longer falls through into `ChatScreen`.
- Ran IDE diagnostics and `flutter analyze lib/screens/home_screen.dart`; fixed one `use_build_context_synchronously` lint by guarding with `mounted` after the dialog await.
- Final static validation result for `lib/screens/home_screen.dart`: no diagnostics, `flutter analyze` clean for the updated file.
