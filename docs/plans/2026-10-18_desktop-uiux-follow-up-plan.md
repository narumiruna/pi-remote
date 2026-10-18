# Desktop UI/UX follow-up

## Goal

Resolve the five remaining Desktop review findings without changing session ownership, authentication, pairing authority or debug safety boundaries.

Status: all five implementations, documentation and focused acceptance checks pass. PR delivery is pending. See [verified evidence and remaining limits](../desktop-uiux-follow-up.md).

## Initial review evidence

The live review used Desktop/light at 1104 × 829, with six saved sessions, no loaded session and iPhone access off.

| Finding | Evidence | Main files |
| --- | --- | --- |
| Native debug clicks fail for visible Sidebar and Pi commands controls | Both returned `target_unavailable`; corresponding semantic actions worked | `Apps/macOS/MacDebugClick.swift`, `Apps/macOS/MacDebugInteraction.swift`, `Apps/macOS/CompanionWindow.swift`; `Tests/MacTests/MacDebugInteractionTests.swift` |
| Closed Overview rows still offer Close | Observed live; the availability guard does not exclude closed saved rows | `Apps/macOS/CompanionWindow.swift`, `Apps/macOS/CompanionModel.swift` |
| Paired devices with the same name are indistinguishable when collapsed | Two live rows displayed iPhone; source confirmation does not identify the chosen device | `Apps/macOS/CompanionConnectionViews.swift` |
| Executable-change guidance does not match an idle loaded child | Source-confirmed, not live-tested: the UI disables only during work, but the coordinator requires no RPC child | `Apps/macOS/CompanionConnectionViews.swift`, `Apps/macOS/CompanionModel.swift`; `Packages/PiRemoteHost/Sources/PiRemoteHost/HostCoordinator.swift` |
| Sidebar width changes during navigation | Approximately 235 → 210 points without a resize request; cause is unverified | `Apps/macOS/CompanionWindow.swift` |

Earlier fixes for no-session input, empty status, local-first Settings and irrelevant inspectors must remain intact. This is not a full streaming, keyboard or VoiceOver acceptance review.

## Boundaries

- Keep fixed debug click targets, app-window ownership, visibility/enabled checks, cancellation, lookup bounds and uncertain-outcome handling.
  - Do not bypass a failed lookup with arbitrary coordinates, desktop input, global Accessibility permissions or relaxed protected-surface checks.
  - Do not treat a semantic fallback as proof that a native click works.
- Tests must use private models, preferences and disposable device credentials. Never revoke a production pairing, replace connection identity or stop the user's Pi work.
- Close and executable changes remain explicit user actions. No automatic session closure, activation, prompt submission or replay is permitted.
- Do not add a general device-renaming system, telemetry, new runtime settings or a UI redesign.

## Plan

- [x] Establish focused reproductions before changing behavior.
  - Reproduce both native-click failures in a normally launched app. Compare its view/accessibility exposure with the hosted fixture that injects `accessibilityEnabled: true`; treat this mismatch as a hypothesis until verified.
  - Record only bounded failure-stage codes or booleans. Do not log real accessibility trees, labels, drafts, prompts, credentials or tool output.
  - Repeat sidebar hide/show and Overview/conversation/Settings navigation at the same window size. Record width before/after and confirm that no divider or window resize occurred.
  - Add regressions for closed rows, duplicate device names and loaded-idle executable selection using private fixtures.

- [x] Make supported native toolbar clicks work in the real app.
  - Use the smallest app-local exposure or lookup correction supported by the reproduction. Enable any debug-specific exposure only while debug mode is enabled.
  - Verify Sidebar toggles without changing destination, session or draft. Verify Pi commands opens its ordinary panel and can be closed without command execution.
  - Keep unavailable, hidden, disabled, clipped, ambiguous, foreign-window and protected targets rejected. Retain lookup cancellation and no-retry tests.
  - Acceptance: both named native clicks return success and produce their intended UI result in the normally launched app. Hosted-only success is insufficient.

- [x] Make session-row actions match session state.
  - Show Reopen for closed saved rows; remove or disable their Close action with a clear reason. Retain Open/View conversation for the appropriate states.
  - Keep UI availability separate from coordinator request deduplication and idempotent close handling.
  - Check Overview, contextual actions and shared Close availability for consistency. Preserve working-session confirmation, stale-target rejection, history and drafts.
  - Acceptance: closed rows cannot dispatch a redundant Close; explicit Reopen uses existing idle-only activation rules and restores sidebar visibility without prompt replay.

- [x] Identify paired devices before revocation.
  - Show the existing device ID or a collision-safe short form beside duplicate names. Do not require disclosure expansion to distinguish rows.
  - Include the selected device name and identity in the revocation confirmation. Bind consent to that device; never silently retarget after a list update.
  - Acceptance: two identically named devices remain distinguishable, including short-ID collisions. Cancel changes no credential or connection; confirmation revokes only the chosen disposable fixture device and does not stop Pi.

- [x] Make executable availability and recovery truthful.
  - Determine the smallest authoritative coordinator signal for whether an executable change is allowed. Do not infer process existence solely from a selected saved-session ID.
  - When an RPC child exists, explain that the loaded Pi session must be closed before changing the executable. Provide access to the existing explicit session controls; do not close implicitly.
  - Keep coordinator admission checks authoritative if state changes while the file picker is open. Permit recovery when no child exists, including unavailable/interrupted saved-session states when otherwise allowed.
  - Acceptance: idle/working/starting/stopping child states produce correct availability or recovery text; the executable-specific path does not advise only Stop or wait for an idle child. Cancelling selection preserves the executable, session and draft.

- [x] Correct sidebar width persistence after the cause is reproduced.
  - Distinguish the preferred divider width from transient layout allocation. Prevent hide/show or automatic window constraints from overwriting the user's preferred width.
  - Retain native resizing and valid bounds; do not force a width that cannot fit the window.
  - Acceptance: a user-resized width survives repeated hide/show and destination changes at a fixed size, within two points. Check the 900 × 600 minimum and the reviewed 1104 × 829 size. Test restart restoration separately with isolated preferences.
  - If the drift cannot be reproduced, record the exact conditions and leave the finding open rather than guessing a fix.

- [x] Verify and document the completed corrections.
  - Use the configured `PiRemoteMac` scheme in [project configuration](../../project.yml) and the [verified native commands](../native-apps.md#automated-checks). Select focused debug, model, presentation and native interaction tests; do not substitute broad suite counts for matching evidence.
  - Run the unsigned Mac build, independent source review, local documentation target checks and `git diff --check`.
  - Repeat the relevant normally launched debug checks. Keep native-click evidence separate from semantic navigation, and keep captured content separate from native chrome or protected panels.
  - Update `README.md`, `PLAN.md` and affected verification documents only with implemented behavior and actual results. Report blocked live checks and the user action needed to continue.

## Completion Checklist

- [x] Native Sidebar and Pi commands clicks pass normal-launch checks without weakening debug protections.
- [x] Closed sessions have state-correct actions; close/reopen safety regressions pass.
- [x] Duplicate devices and revocation consent identify the exact target; Cancel preserves access.
- [x] Executable selection uses truthful child-state guidance and retains authoritative host guards.
- [x] Sidebar drift is reproduced and fixed, with fixed-size and restoration checks passing.
- [x] Focused tests, unsigned build, independent review, documentation paths and whitespace checks pass. Unrun streaming, physical keyboard, VoiceOver and other acceptance checks remain explicit limits. Evidence: 130 Mac passes plus one existing root-only skip; eight host passes normally and with Thread Sanitizer; unsigned product build and private separate-process native-click check pass; two independent reviews report no actionable findings.

- [ ] Deliver the focused branch as a pull request with verified results and explicit remaining limits.

## Rollback / Recovery

Revert the affected UI/model changes if needed; no session or credential migration is planned. Disable debug mode to revoke interaction access. Preserve existing sessions, drafts, pairing records and layout preferences. Do not reset user preferences or replace connection identity as a recovery shortcut.
