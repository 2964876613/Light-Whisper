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
- Simplify review tightened the shake path by querying the `onlyAll: true` album first and only falling back to `onlyAll: false` when needed, instead of concatenating and scanning both sources every time.
- `_GalleryImageResolution` now has explicit success/failure constructors so the success path can treat `imagePath` as guaranteed by contract rather than re-checking null/empty at the callsite.
- The mixed `PhotoManager` + `permission_handler` permission status read remains intentionally in place for now because `PhotoManager` is still the runtime request source while `permission_handler` provides the most direct settings handoff integration already used in the project.
- `ContinuousChatScreen` currently loses direct image context after entry: it only receives `initialAssistantText` and `initialContextHint`, then all later follow-ups go through `DoubaoApiService.chatWithText(...)` without `input_image`.
- The main false-blur failure mode is architectural, not just image quality: detail questions in continuous chat are being answered without the original image.
- Approved design direction is a text-first mixed router: ordinary follow-ups stay on text, while questions containing detail/position/reading/counting cues trigger a new image-aware follow-up path.
- The new image-aware follow-up path should reuse existing image preparation logic in `DoubaoApiService` but use a narrower prompt that answers the requested detail directly.
- The text route must stop inheriting the visual safety fallback style so ordinary follow-up questions no longer collapse into `画面模糊，无法判断`.
- `ChatScreen` now needs to propagate the original `imagePath` into `ContinuousChatScreen`; without that, image-aware follow-up cannot re-open the captured image.
- `ContinuousChatScreen` can use a simple keyword heuristic locally to switch between `chatWithText(...)` and image-aware follow-up without introducing a separate classifier layer.
- `DoubaoApiService` should keep two distinct follow-up prompts: a text follow-up prompt that answers naturally, and a visual follow-up prompt that answers only the requested detail.
- Missing-image degradation should happen before the image-aware request is attempted so the app never implies it re-checked a photo that is no longer available.
