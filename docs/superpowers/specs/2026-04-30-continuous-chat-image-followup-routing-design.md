# Continuous chat image follow-up routing design

## Goal
Reduce false `画面模糊，无法判断` replies during continuous chat by keeping normal follow-up questions on the text path while automatically restoring image context for detail-oriented questions that require re-reading the original image.

## Problem
The current flow sends the image only during the first `ChatScreen` analysis. After the user enters `ContinuousChatScreen`, follow-up questions are handled by `DoubaoApiService.chatWithText(...)`, which only sends text history and the latest question.

That means the model no longer has direct access to the original image during continuous chat. When the user asks about details such as position, text, count, color, or distant objects, the model must guess from the prior summary. A conservative prompt then often collapses into `画面模糊，无法判断`, even when the original image was clear.

## Desired behavior
Continuous chat should behave as a mixed-routing system:
- normal follow-up questions continue as text chat
- detail-oriented follow-up questions automatically re-send the original image
- text-only questions should not inherit the same conservative fallback used by visual safety analysis
- visual fallback should only be used when the user asks for image detail and that specific detail cannot be read clearly

## Scope
This design covers:
- preserving the original `imagePath` from `ChatScreen` into `ContinuousChatScreen`
- adding lightweight question routing in `ContinuousChatScreen`
- adding a new image-aware follow-up API in `DoubaoApiService`
- separating prompt behavior between text follow-up and image follow-up

Out of scope:
- changing the initial single-turn image analysis behavior
- changing shake/double-tap capture behavior
- replacing the current ASR interaction model
- introducing a classifier model or server-side routing layer

## Chosen approach
Adopt a keyword-based mixed router with text-first defaults:
1. Preserve the original image path when entering `ContinuousChatScreen`.
2. Route each follow-up question through a lightweight local decision function.
3. Keep ordinary questions on the existing text chat path.
4. Send the original image again only when the question strongly signals image-detail intent.
5. Use a dedicated visual follow-up prompt that answers the asked detail directly instead of repeating the general obstacle/risk broadcast style.

This is the lightest solution that preserves current UX, keeps most follow-ups fast, and fixes the main failure mode without turning every continuous-chat turn into a full visual request.

## Routing design
### Default route
The default route remains text chat. Questions that do not clearly require image re-inspection continue using `chatWithText(...)`.

Examples:
- `这是什么店`
- `这个一般是做什么的`
- `我下一步怎么过去`
- `这个有危险吗`

These should prefer a normal conversational answer and should not immediately fall back to `画面模糊，无法判断` just because no image is resent.

### Visual-detail route
Questions that clearly ask for image detail should trigger image-aware follow-up.

Initial keyword groups:
- position: `左边`, `右边`, `前面`, `后面`, `上面`, `下面`, `远处`, `近处`
- detail reading: `写了什么`, `数字`, `号码`, `颜色`, `牌子`, `招牌`, `文字`
- object precision: `哪一个`, `那个`, `这个细节`, `具体一点`, `仔细看`, `重新看`, `看清`
- counting: `几个人`, `几个`, `多少个`

Examples:
- `左边是什么`
- `招牌写了什么`
- `远处有几个人`
- `那个红色的是什么`

These questions should re-send the original image and ask the model to answer the requested detail only.

### Non-goal for routing
Do not try to build a perfect semantic classifier in this version. A lightweight keyword heuristic is sufficient for the first implementation, provided the keyword list is explicit and easy to tune.

## Data flow changes
### `ChatScreen`
When navigating into `ContinuousChatScreen`, pass through the original `imagePath` in addition to the existing `initialAssistantText` and `initialContextHint`.

### `ContinuousChatScreen`
Add a routing helper such as `_shouldUseImageFollowup(String question)`.

At follow-up time:
- if the helper returns false, continue with `chatWithText(...)`
- if the helper returns true and `imagePath` is available, call the new image-aware follow-up API
- if the helper returns true but `imagePath` is missing or unreadable, fall back gracefully instead of pretending the image is available

The existing chat history should remain part of both routes so the assistant still understands the recent conversation context.

### `DoubaoApiService`
Add a new method dedicated to image-based follow-up, conceptually:
- input: `imageFile`, `history`, `latestQuestion`
- processing: reuse existing image preparation/compression/base64 logic
- request shape: include `input_image` and the current follow-up question
- output: plain text answer suitable for TTS and current UI behavior

This method should be separate from both:
- `analyzeImageWithFallback(...)` for the first image summary
- `chatWithText(...)` for text-only conversation

## Prompt strategy
### Text follow-up prompt
The text route should act like a normal assistant continuing the conversation from the current context. It should not inherit the strong image-uncertainty fallback from the visual safety prompt.

Requirements:
- answer ordinary follow-up questions naturally
- allow explanation and general guidance based on recent context
- avoid defaulting to `画面模糊，无法判断`
- only redirect to image limitations when the route actually depends on unavailable visual evidence

### Visual follow-up prompt
The visual route should answer the user’s specific question about the image, not repeat the entire initial obstacle/risk summary.

Requirements:
- focus on the requested detail only
- answer briefly and directly for TTS
- when the relevant detail is unreadable, use a localized fallback such as `这部分看不清，无法判断`
- do not replace a narrow detail failure with a full-scene generic failure

Examples:
- User asks `左边那个牌子写了什么` -> answer the sign text if readable
- If unreadable -> `左边牌子的字看不清，无法判断`

## Fallback behavior
### Text route fallback
For text follow-ups, do not use the image-blur fallback as the default. Prefer a normal conversational response or a neutral uncertainty response if the answer is not supported by context.

### Visual route fallback
Use a scoped fallback only when the requested visual detail is genuinely unreadable.

### Missing image in continuous chat
If the router chooses the visual route but the continuous chat screen does not have a valid image path:
- do not pretend to inspect the image
- degrade gracefully to a clear response such as `当前没有可用图片，无法重新核对这个细节`
- optionally fall back to text context only if that still produces a meaningful answer

## Performance expectations
- most turns remain on the text path, so average response time should stay close to current behavior
- only detail-oriented questions pay the additional image-upload cost
- this avoids the latency and cost of always resending the image

## Code touchpoints
### `lib/screens/chat_screen.dart`
Pass the original `imagePath` into `ContinuousChatScreen` when opening the follow-up screen.

### `lib/screens/continuous_chat_screen.dart`
Primary routing changes:
- add `imagePath` field to the widget
- add the image-follow-up routing helper
- branch `_sendFollowupQuestion(...)` between text and visual follow-up
- preserve chat history on both routes

### `lib/services/doubao_api_service.dart`
Add a new image-aware follow-up method and a prompt tailored for detail answers.

## Acceptance criteria
1. Ordinary follow-up questions no longer frequently return `画面模糊，无法判断`.
2. Detail-oriented questions automatically trigger image-aware follow-up.
3. Visual fallback appears only when the requested detail cannot actually be read.
4. Continuous chat still preserves conversation history across both routes.
5. If image context is unavailable, the system degrades explicitly instead of faking image inspection.
6. Text follow-up latency remains close to current behavior for non-visual questions.

## Manual test scenarios
1. Initial image summary -> enter continuous chat -> ask `这是什么店`
   - expected: normal conversational answer, no blur fallback by default

2. Ask `左边是什么`
   - expected: image-aware follow-up path is used

3. Ask `招牌写了什么`
   - expected: image-aware follow-up path is used; if the sign is readable, answer the text directly

4. Ask `那个红色的是什么`
   - expected: image-aware follow-up path is used

5. Ask `我下一步怎么过去`
   - expected: default text route unless the implementation explicitly classifies it as a visual-detail question later

6. Force a case where `imagePath` is unavailable in continuous chat
   - expected: clear degradation response rather than a fake visual answer

## Recommendation summary
Keep continuous chat text-first, automatically restore image context only for detail-oriented questions, and split text versus visual prompts so normal conversation no longer inherits the generic `画面模糊，无法判断` behavior.