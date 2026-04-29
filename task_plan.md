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
