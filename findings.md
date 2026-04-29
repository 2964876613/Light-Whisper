# Findings

## 2026-04-29
- Symptom is deterministic: user reported TTS failure occurs every time.
- Key log signature: `speak failed: not bound to TTS engine`.
- Relevant files:
  - `lib/screens/chat_screen.dart`
  - `lib/screens/live_vision_screen.dart`
  - `lib/screens/continuous_chat_screen.dart`
- Existing architecture currently initializes and uses `FlutterTts` per screen, which can create lifecycle/race issues across navigation and rapid entry flows.
- Approved design direction: centralized `TtsManager` with `ensureReady`, `speakSafely`, and `stop` APIs; all screens route playback through manager only.
- Real-device log confirms false-ready init state can happen on OEM ROMs: `isLanguageAvailable failed: not bound to TTS engine` appears during init while app previously marked init success.
- Mitigation applied: init now registers error callback before language config and uses retry + callback-based probe before setting state to `ready`.
- Latest real-device result indicates both system speech stacks are unavailable on this device state: TTS never binds after 10 probes, and speech_to_text initialize throws `PlatformException(recognizerNotAvailable)`.
- App-side hardening needed: treat ASR unavailability as non-crashing fallback path and avoid calling TTS stop when engine is not initialized.

## 2026-04-30
- `HomeScreen` shake flow currently calls `PhotoManager.requestPermissionExtend()` inside `_pickLatestGalleryImagePath()` and collapses all failures into `null`, so the UI cannot distinguish permission failure from no-image failure.
- `android/app/src/main/AndroidManifest.xml` currently declares only `INTERNET` and `RECORD_AUDIO`; it does not declare `READ_MEDIA_IMAGES` or `READ_EXTERNAL_STORAGE`, which explains why Android never shows a gallery permission prompt.
- Current shake success chain is already valid once a real image path exists: `HomeScreen` passes `latestPath` into `ChatScreen`, and `ChatScreen` calls `DoubaoApiService.analyzeImageWithFallback(File(path), preferLitePrompt: true)`.
- Approved UX direction: permission-first flow, `去设置 / 取消` dialog on denied/permanently denied outcomes, stay on home screen on permission failure, and require the user to shake again after returning from settings.
- `ChatScreen` and `DoubaoApiService` are intentionally out of scope for behavior changes in this task.
- Implementation updated `android/app/src/main/AndroidManifest.xml` to declare `READ_MEDIA_IMAGES` and `READ_EXTERNAL_STORAGE` (`maxSdkVersion=32`).
- `lib/screens/home_screen.dart` now models shake gallery resolution outcomes explicitly via `_GalleryAccessStatus` and `_GalleryImageResolution` before deciding whether to navigate.
- Denied and permanently denied outcomes now stay on the home screen, show a permission dialog with `去设置 / 取消`, and no longer enter `ChatScreen` with a null image path.
- Success path still routes `CaptureSource.shake` with a concrete `imagePath` into `ChatScreen`; no-image remains a distinct snackbar-only path.
