# TTS Bind Failure Fix Design

Date: 2026-04-29  
Project: lightwhisper

## 1. Background and Problem Statement

Current Android logs show stable and repeated TTS failures:

- `speak failed: not bound to TTS engine`

Observed behavior is reproducible every time (not intermittent), which indicates a deterministic initialization-path defect rather than occasional timing jitter.

Impact:

- ChatScreen first playback can fail.
- LiveVisionScreen periodic playback can fail.
- ContinuousChatScreen reply playback can fail.
- Core voice-first accessibility experience is degraded.

## 2. Goals and Non-Goals

### Goals

- Eliminate `not bound to TTS engine` failures in normal app flows.
- Provide one unified TTS lifecycle and call path for all screens.
- Keep user flow unblocked even when TTS is temporarily unavailable.
- Make TTS state and failure reasons observable through consistent logs.

### Non-Goals

- No redesign of ASR (speech_to_text) logic.
- No UI redesign.
- No vendor-specific native Android TTS plugin rewrite.

## 3. Recommended Approach

Use a centralized `TtsManager` service as the only TTS entry point.

Why this approach:

- Fixes root cause at lifecycle boundary instead of patching per-screen symptoms.
- Avoids repeated per-screen initialization and race conditions.
- Gives one place for retries, logging, and fallback behavior.

## 4. Architecture and Component Boundaries

### 4.1 New Component

Add: `lib/services/tts_manager.dart`

Primary responsibilities:

- Own one `FlutterTts` instance.
- Own TTS lifecycle state (`uninitialized`, `binding`, `ready`, `failed`).
- Serialize initialization via shared in-flight future.
- Provide safe playback API.

Proposed API surface:

- `Future<bool> ensureReady()`
- `Future<bool> speakSafely(String text)`
- `Future<void> stop()`
- Optional state exposure for UI/diagnostics (`ValueNotifier<TtsState>`)

### 4.2 Screen Integration Changes

- `lib/screens/chat_screen.dart`
  - Remove direct `_tts` lifecycle ownership.
  - Replace direct speak calls with `TtsManager.instance.speakSafely(...)`.
  - On playback failure, set local completion state so flow remains usable.

- `lib/screens/live_vision_screen.dart`
  - Replace direct speak path with manager.
  - Keep existing duplicate-text suppression behavior.

- `lib/screens/continuous_chat_screen.dart`
  - Replace direct speak path with manager.
  - Continue calling `stop()` before ASR capture start.

### 4.3 Behavioral Rule

No screen may call raw `FlutterTts.speak()` directly after migration. All playback goes through `TtsManager`.

## 5. Data Flow and Concurrency

### 5.1 First Playback Flow

1. Screen requests playback through `speakSafely(text)`.
2. Manager checks state:
   - `ready`: speak immediately.
   - otherwise: call `ensureReady()`.
3. `ensureReady()` uses shared `_initFuture` lock so concurrent callers wait on one bind attempt.
4. If bind succeeds: proceed with speak.
5. If bind fails: return `false` to caller without crashing.

### 5.2 Playback Semantics

- Before each speak, manager calls `stop()` to reduce overlap artifacts.
- `speakSafely` returns success/failure status to caller.
- Callers update UI state according to result, but do not block the main feature flow.

## 6. Error Handling and Fallback Behavior

Unified fallback policy when `speakSafely` returns `false`:

- ChatScreen: mark playback stage complete and allow normal next-step gesture flow.
- LiveVisionScreen: keep text updates active even if voice is unavailable.
- ContinuousChatScreen: preserve ASR + text QA path and provide one controlled voice-unavailable prompt strategy.

Do not throw unhandled TTS exceptions to UI thread.

## 7. Observability

Introduce consistent log prefix: `[TTS]`

Minimum logs:

- init start / success / failure
- state transitions
- speak attempt + result
- failure reason (including bind failures)

Primary acceptance signal in logs:

- No `speak failed: not bound to TTS engine` during validated flows.

## 8. Validation and Acceptance Criteria

### 8.1 Manual Regression on Device

1. Cold start -> Home -> capture -> ChatScreen: first playback succeeds.
2. Repeat enter/exit ChatScreen 5 times: first playback succeeds each time.
3. Home -> LiveVisionScreen -> exit -> re-enter: playback remains stable.
4. ChatScreen -> ContinuousChatScreen multi-turn flow: each assistant reply can be played.
5. Fast navigation / background-foreground transitions: no bind error regressions.

### 8.2 Failure-Mode Validation

When TTS init is unavailable, app remains interactive and does not deadlock any primary user path.

### 8.3 Done Definition

- Functional: stable playback in three screens.
- Technical: no recurring `not bound` errors in normal flows.
- UX: degraded voice path does not block core accessibility interaction.

## 9. Scope Control

This spec is intentionally limited to TTS lifecycle stabilization and playback reliability. It does not include unrelated refactors.

## 10. Risks and Mitigations

- Risk: hidden direct `FlutterTts` usage remains in code.
  - Mitigation: grep and remove all direct `speak` callsites outside manager.

- Risk: vendor-specific engine behavior differs across devices.
  - Mitigation: keep manager stateful and failure-aware; validate on at least one OPPO/OPlus device and one non-OPlus Android device.

- Risk: regressions in timing-sensitive gesture flows.
  - Mitigation: preserve existing UI state transitions and only swap playback backend path.
