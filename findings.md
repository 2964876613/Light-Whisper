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
