# Streaming First-Sentence Latency Design

## Goal
Keep final AI answer quality unchanged while making users hear the first sentence faster after photo upload.

## Scope
- In scope: response delivery mode, request/response flow, callback contract, fallback behavior, validation metrics.
- Out of scope: model replacement, prompt semantic changes, business copy rewrite, unrelated refactors.

## Current Bottleneck
From runtime logs:
- image preprocessing: ~36ms
- network/model request: ~7288ms
- local parse: ~3ms

The dominant delay is request/response round-trip and remote inference, not local image preprocessing.

## Approach Options

### Option A (Recommended): Same model + streaming + first-sentence playback
- Keep model and prompt intent unchanged.
- Switch from blocking full response to streaming response handling.
- Trigger TTS/UI as soon as a stable first sentence is available.
- Replace temporary text with final full response when stream ends.

Trade-off:
- Pros: best perceived latency gain, no quality ceiling loss, minimal product behavior change.
- Cons: requires stream parser and two-phase UI/TTS state handling.

### Option B: Same model + upload size guardrails
- Keep quality at 90.
- Add max long-edge guardrail (for very large images only) to reduce upload payload.

Trade-off:
- Pros: can reduce transfer/decode time.
- Cons: benefit depends on input resolution/network; weaker perceived gain than streaming.

### Option C: duplicate request caching
- Cache recent results by image hash + prompt.

Trade-off:
- Pros: near-instant repeated queries.
- Cons: no benefit for first-time captures.

Decision: implement Option A first, then evaluate B, optionally add C.

## Architecture Changes

### 1) Service Layer (doubao_api_service.dart)
Add a streaming entrypoint in parallel with existing non-streaming API:
- `parseImageStream(...)` (new)
- existing `parseImage...` remains as fallback path

Responsibilities:
- Build payload using existing image preparation path.
- Open streaming response channel.
- Incrementally assemble text chunks.
- Emit first-sentence callback once.
- Emit final callback once on stream completion.
- On stream failure/timeout, automatically fallback to non-streaming request.

### 2) Call Site Layer (photo analysis trigger)
Add two callbacks to consumer flow:
- `onFirstChunk(String text)`
- `onFinalResult(String text)`

Behavior:
- first callback updates UI and starts TTS early.
- final callback replaces temporary content with full answer.

### 3) TTS Behavior
Add interruptible playback policy:
- If final text materially differs from first spoken chunk, stop current playback and speak final text.
- If difference is minor, continue without restart.

## Data Flow
1. Capture image.
2. Existing preprocessing/compression.
3. Start streaming request.
4. Receive text chunks and append buffer.
5. When first-sentence threshold is met, emit `onFirstChunk` once.
6. Continue accumulation until stream ends.
7. Emit `onFinalResult` once with full text.
8. If stream fails, fallback to non-streaming and emit final result through existing path.

## First-Sentence Stability Rule
To avoid speaking incomplete fragments, first sentence is considered stable only when:
- at least 14 Chinese characters, and
- contains one delimiter among: `；` `，` `。`

This prevents low-value fragments like `障碍:` from being spoken.

## Error Handling
- Stream connection failure/timeout: fallback to non-streaming API automatically.
- First chunk emitted but final generation fails: keep first chunk and append short failure notice for details.
- Empty final text: keep existing error path unchanged.

## Testing Plan

### Functional
- Stream success: verify first callback and final callback each fire once.
- Stream failure: verify fallback path returns final result.
- TTS interrupt rule: verify restart only when content diff exceeds threshold.

### Performance
Track and compare:
- first-sentence latency P50/P90
- final completion latency P50/P90
- fallback hit rate

Acceptance targets:
- P50 first-sentence latency improves by >= 40% from baseline.
- P90 first-sentence latency < 4s.
- final answer quality unchanged in same model/prompt A/B spot checks.

## Rollout
1. Enable streaming path behind internal runtime switch (default on for development).
2. Collect latency logs for at least 30 real captures.
3. If fallback rate is acceptable and no quality regression observed, keep streaming as primary path.

## Risks and Mitigations
- Risk: unstable early fragments degrade UX.
  - Mitigation: first-sentence stability rule and single-fire callback.
- Risk: duplicated/overlapped TTS.
  - Mitigation: explicit TTS interruption policy.
- Risk: stream format variance.
  - Mitigation: strict parser + fallback to existing non-streaming API.

## Implementation Boundaries
- Do not change model ID.
- Do not reduce prompt semantic constraints.
- Do not remove existing non-streaming path.
