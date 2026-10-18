# Mac inspector review corrections

## Goal

Resolve the six Files, Session and Activity findings from the debug-mode review. Keep inspector tab changes separate from conversation navigation and Pi execution.

## Context

The reviewed Desktop window was 1104 × 829 with a saved, unloaded session. Files used bordered blue buttons, three navigation rows and visible dotfiles. Session discarded saved-session metadata. Activity was unavailable without a loaded session. `CompanionWindow.showInspector` also changed the central destination for Files and Activity.

## Non-Goals

- Do not change host RPC, authentication, session files or iPhone behavior.
- Do not start Pi, restart the user's app or replace its current build.
- Preserve the existing unrelated `Package.swift` edit.

## Plan

- [x] Inspect the current UI, inspector routing, shared directory browser and configured native test scheme. Evidence: debug captures and source review.
- [x] Keep all inspector tab changes on the current destination. Label loaded-session Activity explicitly and retain an explicit View active session action. Verify native tab changes preserve destination, host snapshot and draft.
- [x] Replace Mac Files button chips with neutral full-width rows. Compact non-selecting path navigation and move Copy full path to an actions menu. Preserve explicit resolved-path review in selecting flows. Verify native controls at 260 and 320 points.
- [x] Hide dotfiles by default only in Mac non-selecting Files. Add Show hidden files and a truthful filtered-page message. Preserve pagination, faults and preview/navigation actions. Verify private directory fixtures.
- [x] Show selected saved-session metadata in Session, use compact empty states, and allow Activity to explain why output is unavailable. Verify saved-only, active, different saved selection and global destinations.
- [x] Run focused Mac regressions, unsigned Mac/iOS builds and independent diff review. Evidence: 48 tests pass across three serialized batches, both unsigned builds pass and independent final source review finds no actionable defects. [Results and fixture limits](../mac-inspector-review.md) record exact logs and captures; README.md and PLAN.md are updated.

## Completion Checklist

- [x] Six findings have implementation and focused acceptance evidence. Files tests cover 260/320-point widths; context/metadata and existing presentation regressions pass.
- [x] Focused tests and unsigned builds pass; `git diff --check` and local documentation links pass. See the verification document for final batch summaries.
- [x] Review the revised hosted captures at minimum and standard inspector widths. No captures enter Git. The filtered-empty explanation is visible after a verified native scroll-position correction.
- [x] Review the revised normal app's saved-session states through debug mode. Evidence: Files, Session and Activity pass in Desktop and Pi modes at 1104 × 829; native inspector hide/Files reopen preserves the selected saved session; final bounded status matches the starting value. The running app already had the revised UI, so no restart was needed. See the verification document's normal-app section.
- [ ] Blocked: finish live loaded-session context checks after the user opens a session, or obtain explicit acceptance of this limit. Debug controls cannot start Pi. More actions/path/preview controls are outside the current native-click allowlist and retain native-fixture evidence only. Live VoiceOver/provider checks are not part of the focused evidence.

Keep this plan while a required check remains open. Delete it only after all completion checks pass or the user accepts the remaining handoff limit.
