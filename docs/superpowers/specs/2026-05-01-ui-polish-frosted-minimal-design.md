# UI Polish Design: Frosted Minimal (A)

## 1. Goal

Upgrade the app UI to a modern, premium look using a "Frosted Minimal" iOS-like glass style, with strong visual consistency across all four core screens:

- `lib/screens/home_screen.dart`
- `lib/screens/chat_screen.dart`
- `lib/screens/continuous_chat_screen.dart`
- `lib/screens/live_vision_screen.dart`

Primary objective: improve perceived quality and cohesion without changing existing business behavior.

## 2. Confirmed Design Direction

- Visual direction: **A. Frosted Minimal**
- Rollout strategy: **A. Baseline first, then per-screen deep polish**
- Density preference: **A. Spacious, breathing-room-first layout**

## 3. Approach Options Considered

### Option 1 (Selected): Token-First
Build a global token system first (color, radius, spacing, elevation, typography, motion), map all four pages to it, then do per-screen polish.

- Pros: strongest consistency, lowest long-term drift, easier maintenance
- Cons: early changes feel foundational before dramatic visual impact

### Option 2: Page-First
Redesign each page end-to-end first, unify later.

- Pros: faster visible impact per page
- Cons: high risk of style divergence and later rework

### Option 3: Component-First
Redesign high-frequency components first, then spread to pages.

- Pros: better than page-first on consistency
- Cons: may feel mismatched if page-level structure remains old

## 4. Visual Architecture

Create a `LightwhisperThemeV2` using `ThemeExtension` and a minimal set of reusable primitives.

### 4.1 Core Tokens

- **Neutral base**: cool white + subtle blue-gray scale
- **Glass layer**: two strengths (soft/medium), unified alpha and border luminance
- **Elevation**: three shadow levels only
- **Radius system**:
  - container: 16
  - card: 20
  - primary button: 14
- **Spacing**: 8pt grid, with generous 24/32 spacing in major sections
- **Typography**:
  - titles: SemiBold
  - body: Regular
  - avoid unnecessary heavy weight
- **Motion**: 200-280ms, ease-in-out, no aggressive spring behavior

### 4.2 Global UI Principles

- Prefer lower density over crowded interfaces
- Keep one primary CTA per screen region
- Never sacrifice readability for visual effects

## 5. Component Mapping

Introduce only the minimum shared components needed by the four screens:

- `GlassScaffold`
- `GlassCard`
- `PrimaryPillButton`
- `SoftInput`

Constraints:

- No unrelated abstraction
- No business logic movement into UI primitives
- Components remain style-focused wrappers

## 6. Page-Level Plan

### 6.1 `home_screen.dart`

- Rebuild first-screen hierarchy and spacing rhythm
- Unify card language and primary/secondary action balance
- Ensure immediate visual clarity of main entry actions

### 6.2 `chat_screen.dart`

- Unify top bar, message bubble style, and input area
- Apply glass semantics while preserving message readability
- Keep send/input interaction behavior unchanged

### 6.3 `continuous_chat_screen.dart`

- Reuse chat-level primitives for consistency
- Focus on visual treatment of state transitions
- Keep transition logic unchanged, polish only presentation

### 6.4 `live_vision_screen.dart`

- Prioritize overlay readability on camera preview
- Keep controls minimal and visually stable
- Ensure visual hierarchy does not interfere with critical actions

## 7. State Semantics and Accessibility

- Unify semantic color mapping for loading/recording/listening
- Enforce minimum text contrast for all overlay content
- Keep focus and tap targets clear under translucent layers

## 8. Data Flow and Boundaries

- Do not alter existing business data flow
- Existing Provider/state sources remain authoritative
- UI consumes state via theme and primitives only
- No new business branching added for visual polish

This keeps the change surface in the presentation layer and reduces regression risk.

## 9. Risk Controls

### Risk 1: Glass effects can hurt low-end performance

Mitigation:

- tiered blur levels
- degrade to translucent solid fill on constrained devices

### Risk 2: Light glass can reduce text readability

Mitigation:

- contrast baseline for text
- minimum overlay shade where needed

### Risk 3: Temporary inconsistency during staged migration

Mitigation:

- ship token and primitive baseline first
- then replace per screen in fixed order

## 10. Verification Plan

### 10.1 Golden Coverage

Capture baselines for key states on all four screens:

- default
- loading
- active/listening (where applicable)

### 10.2 Interaction Smoke Tests

- home main entry flow
- chat send flow
- live vision start/exit flow
- continuous chat mode transition flow

### 10.3 Performance Watchpoints

- focus on `live_vision_screen.dart`
- monitor frame pacing and visible jank under overlays

### 10.4 Usability Checks

- primary CTA discoverable within 1 second
- text remains readable in all critical states
- input area remains visually obvious and operable

## 11. Rollout Sequence

1. Add `LightwhisperThemeV2` tokens
2. Introduce shared primitives
3. Migrate screens in order:
   1. `home_screen.dart`
   2. `chat_screen.dart`
   3. `continuous_chat_screen.dart`
   4. `live_vision_screen.dart`
4. Run golden + smoke + performance checks
5. Final pass for consistency and contrast

## 12. Out of Scope

- Any business logic redesign
- New feature additions unrelated to visual polish
- Cross-platform redesign beyond current app surfaces
- Broad refactors not required by this visual direction
