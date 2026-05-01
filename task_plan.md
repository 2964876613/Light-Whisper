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

## Follow-on Task — UI Polish Frosted Minimal

### Goal
Implement the approved spec at `docs/superpowers/specs/2026-05-01-ui-polish-frosted-minimal-design.md` to deliver a modern, premium Frosted Minimal UI across the four core screens while keeping business behavior unchanged.

### Scope
- Add `LightwhisperThemeV2` token system using `ThemeExtension`
- Introduce minimal shared UI primitives (`GlassScaffold`, `GlassCard`, `PrimaryPillButton`, `SoftInput`)
- Migrate and polish all target screens:
  - `lib/screens/home_screen.dart`
  - `lib/screens/chat_screen.dart`
  - `lib/screens/continuous_chat_screen.dart`
  - `lib/screens/live_vision_screen.dart`
- Keep state/data flow unchanged (presentation-layer-only changes)
- Add verification coverage for visual consistency, usability, and performance watchpoints

### Phases

| Phase | Status | Description | Files |
|---|---|---|---|
| 18 | complete | Add `LightwhisperThemeV2` token layer and wire app theme entry points | `lib/main.dart`, theme-related files under `lib/` |
| 19 | complete | Implement shared Frosted Minimal primitives | new/existing UI component files under `lib/` |
| 20 | complete | Migrate `home_screen.dart` to token + primitive baseline | `lib/screens/home_screen.dart` |
| 21 | complete | Migrate `chat_screen.dart` to token + primitive baseline | `lib/screens/chat_screen.dart` |
| 22 | complete | Migrate `continuous_chat_screen.dart` with consistent state visuals | `lib/screens/continuous_chat_screen.dart` |
| 23 | complete | Migrate `live_vision_screen.dart` overlays with readability-first polish | `lib/screens/live_vision_screen.dart` |
| 24 | complete | Validate consistency/readability/performance and summarize | target screens + test artifacts |

### Implementation Notes
- Token-first rollout: baseline consistency first, then per-screen deep polish.
- Prefer spacious layout rhythm (24/32 spacing) and single dominant CTA per major region.
- Glass effects must not reduce text readability or input discoverability.
- Keep blur/elevation at constrained levels to protect runtime performance.
- No business logic refactors or behavior changes in this task.

### Acceptance Checks
1. Four target screens feel visually unified under one product language.
2. Primary CTA remains immediately discoverable on each screen.
3. Overlay text/control readability remains strong, including camera-preview contexts.
4. Core flows (home entry, chat send, live vision start/exit, continuous-chat transitions) behave unchanged.
5. No obvious frame pacing regressions in `live_vision_screen.dart` during normal interactions.

### Errors Encountered
| Error | Attempt | Resolution |
|---|---:|---|
| `session-catchup.py` exited with code 49 during UI planning handoff | 1 | Continued from current planning files and approved spec because repository state and active planning docs were already available |

## Follow-on Task — Voice Pack Selector

### Goal
Implement the approved spec at `docs/superpowers/specs/2026-05-01-voice-pack-selector-design.md` to support multiple Volcano TTS speakers, persistent voice selection, and a home-screen downward-swipe selector container that auto-hides after selection.

### Scope
- Add voice-pack model and fixed catalog (6 approved speakers)
- Add local persistence for selected voice id
- Replace hardcoded speaker in `TtsService` with selected voice id
- Add full-screen downward-swipe trigger on `HomeScreen`
- Add lightweight in-home selector container with single-choice behavior
- Auto-hide selector after selection and idle timeout

### Phases

| Phase | Status | Description | Files |
|---|---|---|---|
| 25 | complete | Add voice model/catalog and persistence service | `lib/models/voice_pack.dart`, `lib/services/voice_settings_service.dart`, `pubspec.yaml` |
| 26 | complete | Integrate dynamic speaker resolution in `TtsService` | `lib/services/tts_service.dart` |
| 27 | complete | Add home-screen downward-swipe trigger and selector container | `lib/screens/home_screen.dart` |
| 28 | complete | Add selector lifecycle (selection hide + timeout hide + conflict guards) | `lib/screens/home_screen.dart` |
| 29 | complete | Validate voice switching persistence and gesture regressions | target files + manual checks |

### Implementation Notes
- Keep ASR/camera/business logic unchanged.
- Do not add a dedicated settings page.
- Selection applies globally via `TtsService` only.
- If stored voice id is invalid, fallback to default and rewrite storage.

### Acceptance Checks
1. Downward swipe on home screen shows selector container.
2. Selecting a voice saves choice and auto-hides selector.
3. App restart keeps selected voice.
4. `ChatScreen`, `LiveVisionScreen`, and `ContinuousChatScreen` use selected voice on next playback.
5. Existing core gestures keep working with no regressions.

### Errors Encountered
| Error | Attempt | Resolution |
|---|---:|---|
| `session-catchup.py` exited with code 49 during voice-pack planning handoff | 1 | Continued from current planning files and approved spec because repository state and planning context were already available |
| `flutter pub get` failed with socket error fetching `shared_preferences` from `https://pub.dev` | 1 | Blocked by network/package registry reachability; continue code edits and require dependency fetch retry when network is available |
