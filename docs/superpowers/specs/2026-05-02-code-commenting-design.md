# Code Commenting Design (Chinese-first)

## 1. Goal
Provide high-value, Chinese-first structured comments for `lib/services` and `lib/screens` so the code can be studied in depth without drowning in noisy line-by-line annotations.

## 2. Scope
- In scope:
  - `lib/services/**/*.dart`
  - `lib/screens/**/*.dart`
- Out of scope:
  - Other `lib/` directories for this phase
  - Non-comment refactors, behavior changes, and feature additions

## 3. Commenting Strategy (Layered Deep Annotation)

### 3.1 File-level comments
At each target file top, explain:
1) responsibility,
2) collaborators/dependencies,
3) design tradeoff boundaries (what this file intentionally does not handle).

### 3.2 Type-level comments
For classes/enums, explain role and lifecycle semantics where relevant.

### 3.3 Method-level comments
For public methods (mandatory) and complex private methods (selective), include:
1) what it does,
2) why this design is chosen,
3) important preconditions/side effects/input-output semantics.

### 3.4 Logic-block comments
For complex async and branch logic only, explain business/technical motivation of the branch; avoid restating obvious syntax.

## 4. Directory-specific Rules

### 4.1 `lib/services`
- Every service file gets a file header comment.
- All externally used methods get method comments.
- Async chains with meaningful state transitions get concise before/after-await intent comments.
- Retry/throttle/synchronization logic gets explicit why-comments.

### 4.2 `lib/screens`
- Every screen file gets a file header comment describing page purpose, entry semantics, and interaction path.
- In `build`, annotate structural sections (app bar/main content/action area), not each widget line.
- Event handlers must describe state transitions and navigation intent.

## 5. Style Rules
- Language: Chinese-first.
- Preference: explain "why" before "what".
- No placeholder terms (`TODO`, `TBD`) in final comments.
- Keep comments synchronized with actual behavior in the same edit.
- Avoid redundant comments for self-evident statements.

## 6. Execution Order
1. Annotate `lib/services` first.
2. Annotate `lib/screens` second.
3. Perform per-file self-check immediately after each file edit.

## 7. Quality Gates
A file passes only when all are true:
1) File-level responsibility/dependency/tradeoff is documented.
2) Public methods have independently understandable Chinese comments.
3) Complex async/branch logic has motivation comments.
4) No contradictory, stale, or placeholder comments remain.

## 8. Testing & Validation
- Static validation:
  - `flutter analyze` should remain clean or unchanged from baseline.
- Behavioral safety:
  - No runtime logic change is introduced; comment-only edits.

## 9. Risks & Mitigations
- Risk: Over-commenting creates maintenance burden.
  - Mitigation: comment only meaningful boundaries and motivations.
- Risk: Under-commenting misses hard-to-read logic.
  - Mitigation: enforce quality gate #3 for complex async/branch code.

## 10. Deliverables
- Updated comments in:
  - `lib/services/**/*.dart`
  - `lib/screens/**/*.dart`
- Completion summary by file list with key annotated points.
