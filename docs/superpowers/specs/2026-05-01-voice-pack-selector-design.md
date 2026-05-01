# Voice Pack Selector Design

## 1. Goal

Add multi-voice-pack support for TTS playback, keep a configured default voice, and allow fast in-home-screen switching via a lightweight container (not a full page).

This feature must preserve existing core interaction flows (double-tap capture, shake analyze, long-press live vision) and apply selected voice to all TTS playback paths.

## 2. Confirmed Product Decisions

1. TTS source strategy: Volcano built-in speakers only.
2. Voice pack list:
   - `zh_female_vv_uranus_bigtts` — Vivi 2.0
   - `zh_male_kailangxuezhang_uranus_bigtts` — 开朗学长2.0
   - `zh_male_liangsangmengzai_uranus_bigtts` — 亮嗓萌仔2.0
   - `zh_female_yingtaowanzi_uranus_bigtts` — 樱桃丸子2.0
   - `zh_female_peiqi_uranus_bigtts` — 佩奇猪2.0
   - `zh_male_aojiaobazong_uranus_bigtts` — 傲娇霸总2.0
3. Default voice id: `zh_female_vv_uranus_bigtts`.
4. Persist user selection locally.
5. Trigger entry: full-screen downward swipe on home screen.
6. UI style: show a temporary selector container on home screen; no dedicated settings page.
7. After selecting one voice: auto-hide selector.

## 3. Scope

### In Scope
- Add voice-pack metadata model.
- Add local persistence service for selected speaker id.
- Replace hardcoded speaker in `TtsService` with dynamic selected voice id.
- Add home-screen full-screen downward-swipe trigger for voice selector.
- Add home-screen temporary selector container with single-choice list.
- Auto-hide selector after selection and after idle timeout.

### Out of Scope
- Multi-provider TTS abstraction.
- Cloud-side voice management.
- Separate global settings page.
- Changes to ASR, camera, or AI reasoning flows.

## 4. Architecture

### 4.1 Voice Catalog
Add a static voice catalog (id + label) as the single source of truth.

Suggested placement:
- `lib/models/voice_pack.dart` (value model)
- `lib/services/voice_settings_service.dart` (catalog + persistence)

Model:
- `VoicePack { String id; String label; }`

Catalog content uses the six approved voices above.

### 4.2 Voice Settings Persistence
Introduce `VoiceSettingsService` with:
- `Future<String> getSelectedVoiceId()`
- `Future<void> setSelectedVoiceId(String id)`
- `Future<String> resolveValidVoiceIdOrDefault()`

Behavior:
- If no saved value: return default id.
- If saved value is not in catalog: fallback to default and save default back.

Storage backend:
- Local key-value persistence (SharedPreferences).

Key:
- `selected_tts_voice_id`

### 4.3 TTS Integration
Current `TtsService` sends fixed:
- `speaker: 'zh_female_vv_uranus_bigtts'`

Change:
- Resolve speaker id from `VoiceSettingsService` at call time inside `TtsService.speak`.

Result:
- `ChatScreen`, `LiveVisionScreen`, and `ContinuousChatScreen` continue to call `TtsService` unchanged and automatically use current voice selection.

## 5. Home Screen Interaction Design

## 5.1 Trigger
- Add full-screen downward swipe gesture on `HomeScreen`.
- Trigger condition must be explicit downward movement (velocity threshold) to avoid accidental activation.

## 5.2 Selector Container
- Render a lightweight frosted container overlay on home screen (no route push).
- Content:
  - Title: `选择语音包`
  - Six voice options, single select.
  - Current selection visually highlighted.

## 5.3 Auto-hide
- Hide immediately after successful selection + save.
- Also hide after idle timeout (2.5 seconds) when user does not interact.
- Re-triggering downward swipe resets timeout and reuses single container instance.

## 5.4 Gesture Conflict Rules
When selector is visible:
- Temporarily suppress double-tap capture and long-press live-vision trigger.

When selector is hidden:
- Existing gestures behave exactly as before.

Global safeguards:
- If `_isCapturing == true`, ignore downward-swipe trigger.

## 6. Data Flow

1. App starts -> `HomeScreen` initializes -> selected voice id loaded through `VoiceSettingsService`.
2. User downward-swipes on home screen -> selector container shown.
3. User picks a voice -> id saved locally -> selector hidden.
4. Any screen invokes `TtsService.speak(text)` -> `TtsService` resolves current selected id -> sends Volcano TTS request with that speaker.

## 7. Error Handling

1. Saved id invalid/not found in catalog:
   - fallback to default id `zh_female_vv_uranus_bigtts`
   - write default back to storage.

2. Persistence read/write failure:
   - use default id in-memory for current playback
   - keep existing TTS failure fallback behavior.

3. Selector list unexpectedly empty:
   - do not show selector container
   - log debug warning.

4. TTS HTTP failure:
   - unchanged from existing behavior (`TtsService` returns false and existing caller fallback handles it).

## 8. Testing Plan

### 8.1 Functional
1. Downward swipe on home screen shows selector.
2. Selecting any voice updates highlight and auto-hides selector.
3. Restart app keeps last selected voice.
4. First subsequent playback in each screen uses selected voice.

### 8.2 Gesture Regression
1. Selector hidden: double-tap, shake, and long-press still work.
2. Selector visible: double-tap/long-press are suppressed.
3. Repeated fast downward swipes do not spawn duplicate containers.

### 8.3 Fallback Behavior
1. Corrupted/unknown stored voice id falls back to default.
2. TTS request failure path remains unchanged.

## 9. Acceptance Criteria

1. User can switch voice from home screen without leaving current page.
2. Selection persists across app restarts.
3. Selected voice applies to all TTS playback paths.
4. Selector auto-hides after selection.
5. Existing core gestures and primary flows remain stable.

## 10. Implementation Sequence

1. Add voice model and catalog.
2. Add persistence service and default resolution.
3. Integrate dynamic speaker resolution into `TtsService`.
4. Add downward-swipe trigger and selector overlay to `HomeScreen`.
5. Add selector visibility lifecycle (selection hide + timeout hide).
6. Run static analysis and manual gesture/voice validation.
