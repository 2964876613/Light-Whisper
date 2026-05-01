# Task Plan — TTS Bind Failure Fix Implementation

## Goal
Implement the approved spec at `docs/superpowers/specs/2026-04-29-tts-bind-failure-fix-design.md` to eliminate `speak failed: not bound to TTS engine` by centralizing TTS lifecycle and playback calls.

## Scope
- Add centralized `TtsManager` service.
- Migrate `ChatScreen`, `LiveVisionScreen`, and `ContinuousChatScreen` to manager-only speak path.
- Add validation checks matching the spec acceptance criteria.

## Phases

| Phase | Status | Description | Files |
|---|---|---|---|
| 1 | complete | Implement centralized TTS manager | `lib/services/tts_manager.dart` |
| 2 | complete | Migrate ChatScreen to manager-only TTS | `lib/screens/chat_screen.dart` |
| 3 | complete | Migrate LiveVisionScreen to manager-only TTS | `lib/screens/live_vision_screen.dart` |
| 4 | complete | Migrate ContinuousChatScreen to manager-only TTS | `lib/screens/continuous_chat_screen.dart` |
| 5 | complete | Verify no direct `FlutterTts.speak` remains in screens | `lib/screens/*.dart`, `lib/services/*.dart` |
| 6 | complete | Run analysis/tests and manual validation checklist | project root + runtime device checks |
| 7 | complete | Finalize summary against acceptance criteria | N/A |

## Implementation Notes
- Keep behavior unchanged except TTS call path.
- Preserve existing UI states and gesture flows.
- Ensure TTS failures never block primary flow.

## Acceptance Checks
1. Cold start -> capture -> ChatScreen: first playback succeeds.
2. Re-enter ChatScreen multiple times: first playback succeeds each time.
3. Live vision enter/exit/re-enter: playback remains stable.
4. Continuous chat multi-turn: reply playback works each turn.
5. Logs no longer show `not bound to TTS engine` in validated flows.

## Errors Encountered
| Error | Attempt | Resolution |
|---|---:|---|
| `flutter analyze` returns non-zero due to pre-existing deprecation infos in `speech_service.dart` | 1 | Not part of TTS scope; no new TTS-related analyzer errors introduced |

## Follow-on Task — Shake Gallery Permission Flow Implementation

### Goal
Implement the approved spec at `docs/superpowers/specs/2026-04-30-shake-gallery-permission-design.md` so shake-to-analyze can request gallery permission correctly on Android, distinguish permission failures from no-image failures, and guide users to settings without entering `ChatScreen` on permission failure.

### Scope
- Add Android gallery read permissions in `android/app/src/main/AndroidManifest.xml`
- Refactor `lib/screens/home_screen.dart` to use a permission-first shake flow
- Distinguish granted/image-found, granted/no-image, denied, and permanently-denied outcomes before navigation
- Add home-screen settings dialog and cancellation feedback
- Keep `lib/screens/chat_screen.dart` and `lib/services/doubao_api_service.dart` unchanged unless required by the approved spec

### Phases

| Phase | Status | Description | Files |
|---|---|---|---|
| 8 | complete | Add Android gallery permission declarations | `android/app/src/main/AndroidManifest.xml` |
| 9 | complete | Model explicit gallery resolution outcomes for shake flow | `lib/screens/home_screen.dart` |
| 10 | complete | Implement permission-first shake handling and settings dialog | `lib/screens/home_screen.dart` |
| 11 | complete | Preserve success path and no-image messaging behavior | `lib/screens/home_screen.dart`, `lib/screens/chat_screen.dart` |
| 12 | complete | Run validation for permission/no-image/success branches and summarize results | project root + device/manual checks |

### Implementation Notes
- Keep existing shake detection thresholds, cooldown, and vibration timings unless required by the spec.
- Do not auto-retry after returning from system settings; require the user to shake again.
- Do not navigate to `ChatScreen` for denied or permanently denied permission outcomes.
- Permission failure and no-image failure must produce different UI feedback.

### Acceptance Checks
1. Fresh install with no gallery permission: shake triggers runtime permission prompt, then success path continues after grant.
2. Denied permission: user sees `去设置 / 取消` dialog and stays on home screen.
3. Permanently denied permission: user can open app settings from the dialog and remains on home screen after return.
4. Granted permission with no readable image: user stays on home screen and sees the no-image message only.
5. Granted permission with readable image: shake still navigates to `ChatScreen`, which uploads the selected image to AI unchanged.

### Errors Encountered
| Error | Attempt | Resolution |
|---|---:|---|
| `session-catchup.py` exited with code 49 during planning handoff | 1 | Continued from current planning files and approved spec because the repo state was already readable and no catchup output was provided |
| `flutter analyze lib/screens/home_screen.dart` reported `use_build_context_synchronously` after awaiting the permission dialog | 1 | Added `if (!mounted) return;` before showing the post-dialog snackbar, then re-ran diagnostics successfully |

## Follow-on Task — Continuous Chat Image Follow-up Routing

### Goal
Implement the approved spec at `docs/superpowers/specs/2026-04-30-continuous-chat-image-followup-routing-design.md` so continuous chat stays text-first for ordinary questions, automatically restores image context for detail-oriented follow-up questions, and avoids generic `画面模糊，无法判断` responses when the user is not actually asking for image detail.

### Scope
- Pass `imagePath` from `lib/screens/chat_screen.dart` into `lib/screens/continuous_chat_screen.dart`
- Add keyword-based question routing in `lib/screens/continuous_chat_screen.dart`
- Add a new image-aware follow-up API in `lib/services/doubao_api_service.dart`
- Split text-followup and visual-followup prompt behavior
- Preserve conversation history on both routes
- Add validation coverage for ordinary questions, detail questions, and missing-image fallback

### Phases

| Phase | Status | Description | Files |
|---|---|---|---|
| 13 | complete | Pass original image path into continuous chat entry | `lib/screens/chat_screen.dart`, `lib/screens/continuous_chat_screen.dart` |
| 14 | complete | Add keyword-based follow-up routing in continuous chat | `lib/screens/continuous_chat_screen.dart` |
| 15 | complete | Add image-aware follow-up API and prompt split | `lib/services/doubao_api_service.dart` |
| 16 | complete | Preserve history and define missing-image degradation behavior across both routes | `lib/screens/continuous_chat_screen.dart`, `lib/services/doubao_api_service.dart` |
| 17 | complete | Run validation for normal follow-ups, detail follow-ups, and missing-image cases | project root + device/manual checks |

### Implementation Notes
- Keep ordinary follow-up questions on the existing text route unless they clearly match the image-detail heuristic.
- Start with an explicit keyword heuristic, not a classifier model.
- Do not change the initial single-turn image analysis flow.
- Visual follow-up should answer the asked detail directly rather than repeating the obstacle/risk summary template.
- Text follow-up should no longer inherit the global image-blur fallback behavior.

### Acceptance Checks
1. Ordinary follow-up questions no longer frequently return `画面模糊，无法判断`.
2. Detail-oriented follow-up questions automatically trigger the image-aware route.
3. Visual fallback appears only when the requested detail cannot be read from the image.
4. Continuous chat preserves conversation history on both text and visual routes.
5. If `imagePath` is unavailable, the app degrades explicitly instead of pretending to inspect the image.
6. Non-visual follow-up latency stays close to current behavior.

### Errors Encountered
| Error | Attempt | Resolution |
|---|---:|---|
| `session-catchup.py` exited with code 49 during continuous-chat planning handoff | 1 | Continued from current planning files and approved spec because the repo state and prior planning context were already available |
