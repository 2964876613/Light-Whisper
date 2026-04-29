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
