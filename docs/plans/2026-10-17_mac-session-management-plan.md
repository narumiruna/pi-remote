# Herdr-inspired Mac session management

## Goal

Bring Herdr's useful session-management workflows into the native Pi Remote for Mac interface: a session overview, quick navigation, non-destructive session closing, split conversations, concurrent Pi sessions and layout recovery. Preserve the existing light appearance, blue accent, SwiftUI architecture and Pi RPC behavior.

This is a proposed implementation plan, not evidence that these features work. The user selected non-destructive Close Session. Concurrent execution and background process ownership require separate architecture approval before implementation.

## Context

Reference material inspected:

- `/Users/narumi/src/herdr/README.md` describes agent status, multiple workspaces, keyboard/mouse navigation and process persistence.
- `/Users/narumi/src/herdr/docs/next/website/src/content/docs/concepts.mdx` distinguishes workspace, pane, agent state and client/server ownership.
- `/Users/narumi/src/herdr/docs/next/website/src/content/docs/session-state.mdx` distinguishes live processes from restored layout and resumed conversations. These next-version documents are design references, not verification of Herdr behavior.

Current repository evidence:

- `Apps/macOS/CompanionWindow.swift` has a workspace/session sidebar, context menus, a session overview destination, native session workflows and one conversation detail.
- `Apps/macOS/CompanionModel.swift` owns UI selection, display labels, local workspace preferences and bounded per-session drafts. Its workspace rows currently include all catalog sessions.
- `/resume` lists `state.sessions`; successful `openSession(_:)` returns a Boolean. The current implementation separates selection from successful process activation.
- `Packages/PiRemoteHost/Sources/PiRemoteHost/HostCoordinator.swift` implements idle-only `.closeSession`. It shuts down the loaded child and clears live state without deleting saved history.
- `Packages/PiRemoteCore/Sources/PiRemoteCore/AppProtocol.swift` exposes typed, session-bound actions. `HostSnapshot` currently describes one selected runtime.
- `PLAN.md` requires one active Pi process and excludes concurrent active sessions from the first version. Do not silently replace that boundary.
- Existing slash-command work and unrelated local changes are present. Preserve them; do not include them as newly implemented work under this plan.

Herdr's server session and terminal pane are not equivalent to a Pi conversation. Reuse workflow ideas, not terminal mechanics or names that obscure this difference.

## Architecture

### Separate UI state from execution state

- A saved session is a companion-managed conversation in the catalog.
- An open session is visible in the Mac sidebar/layout.
- A loaded session has an associated Pi process. Initially, only one session can be loaded.
- A focused session receives keyboard actions. Focus does not authorize starting, stopping or changing another session.
- Close Session removes the open UI entry and closes that session's loaded process, if any, through existing lifecycle controls. It does not delete its history, workspace or draft.

Store Mac open/closed visibility and view layout in local UI preferences, not in Pi JSONL or the shared session catalog. Older preferences must remain readable. `/resume` must search the complete managed catalog, including closed sessions. Read-only metadata browsing must not start Pi.

### Status presentation

Use authoritative runtime phase, pending requests and errors. Distinguish Working, Waiting for input, Idle, Saved, Interrupted and Unavailable when supported by actual state. Do not label every unloaded saved session Idle. Show unknown state explicitly. Remote connectivity remains separate from Pi execution.

An unread completion indicator is optional only after a reliable completion event and per-client seen-state rule are verified. Do not infer completion from elapsed time or transcript text.

## Execution status

Work is on `narumi/feat/mac-session-management`, based on `f1743a9` (the existing slash-command prerequisite and user files already committed on `main`). No prerequisite changes or `GOAL.md` edits are part of this branch's implementation diff.

The Phase 1 close workflow and Phase 2 navigation are implemented, with focused evidence below. Some Phase 1 failure/recovery checks remain open. Phase 3 discovery is recorded in `docs/mac-session-runtime-design.md`. Concurrency changes the existing shared-selected-runtime behavior to independent device selection; explicit compatibility approval was requested before changing that contract. The proposed resource bound is two loaded processes, including unconfirmed shutdowns. Phases 4–5 remain open where they depend on that decision. This plan must not be deleted or declared complete while those gates remain open.

## Plan

### Phase 1 — Close Session and local visibility

- [x] Trace `.stop`, `.closeSession`, request exclusion, unknown outcomes and draft persistence; document the safe stop-to-idle-to-close sequence in `docs/mac-interface.md`, with evidence from existing host/model tests before changing behavior.
- [x] Add backward-compatible local session-visibility preferences in `CompanionModel.swift`; filter sidebar sessions without filtering the managed catalog or deleting drafts. Verify old-preference decoding, app restart, all-sessions-closed and preservation of the workspace row.
- [x] Add Close Session to the session context menu and a hover/focus row button in `CompanionWindow.swift`; use an accessible label and tooltip, keep keyboard access, and do not let a close-button click select or close the workspace. Verify actual native control activation.
- [x] Close an unloaded saved session without an RPC request; if selected, show its workspace or another explicit neutral destination without activating another session. Verify unchanged catalog/history/draft and unaffected active work in a different session.
- [ ] Close a loaded idle session through a captured, scoped `.closeSession` request; hide it only after confirmed success. Preserve visibility and show recovery guidance on rejection or unknown outcome. Verify duplicate clicks, failed shutdown and stale context. Partial evidence: normal close/reopen, immediate draft flush, oversized-draft rejection and failed activation pass; complete failure/recovery coverage is still required.
- [ ] Require confirmation for a working loaded session. Use a clear Stop and Close action, explain that file changes cannot be undone, then wait for confirmed idle state before closing the same session. Bound the wait and fail visibly; never close after a context change, pending unanswered request or uncertain outcome. Verify cancellation, timeout, remote-client races and no automatic resend.
- [ ] Reopen a closed session through `/resume`; reveal its workspace and restore its UI entry after successful activation. On failure, keep history searchable and display the error without claiming Pi is ready. Verify retained draft, interrupted-session review and restart persistence. Partial evidence: normal close/reopen, immediate draft flush, oversized-draft rejection and failed activation pass; complete failure/recovery coverage is still required.

### Phase 2 — Session overview and quick navigation

- [x] Refine Overview into a compact session list grouped by workspace, with meaningful labels, activity time and truthful status. Provide Open, Close and New Session actions using the same model paths as the sidebar. Verify empty, closed-only, working, waiting, interrupted and error fixtures.
- [x] Add a searchable session switcher using existing display metadata, workspace association and stable IDs; include closed sessions with a clear Saved/Closed distinction. Search must not activate a session. Verify duplicate titles, long paths, keyboard selection and explicit activation.
- [x] Add a native command palette for implemented app actions only; reuse slash/native action availability and existing workflow dispatch rather than adding a second command parser. Verify disabled reasons, Escape, focus return and no execution during search/completion.
- [x] Define and document conflict-free shortcuts for the switcher, palette and Close Session. Route shortcuts to the focused session only; do not override text editing, IME or native window closing without an explicit UI decision. Verify keyboard and mouse paths at practical window sizes.

### Phase 3 — Concurrency discovery and approval gate

- [x] Inventory single-session assumptions in `HostCoordinator`, snapshots, event replay, request tracking, dialogs, drafts, images, history and both app models. Produce a concrete ownership/data-flow design and a list of affected tests before code changes. Evidence: `docs/mac-session-runtime-design.md`; no host/protocol concurrency changes made.
- [x] Define per-session process ownership, independent lifecycle state, scoped stop/close/dialog handling and a bound on simultaneously loaded processes. Use one writer per managed Pi session; do not introduce automatic worktrees or implicit shared-file isolation. Proposed two-process bound and writer reservations are specified in `docs/mac-session-runtime-design.md`; enablement remains gated.
- [x] Define how an existing iPhone client selects and controls a runtime without changing another client's focused session. Specify capability/version negotiation and safe behavior for old clients before any public protocol change. The design retains version-1 encoding, defines per-device projections/replay and identifies the shared-selection semantic change that still requires approval.
- [ ] Obtain explicit approval for concurrent execution, its resource bound and any protocol/storage changes; update the relevant `PLAN.md` boundary only after approval. If approval is deferred, leave this phase and dependent execution tasks open and deliver Phases 1–2 separately.

### Phase 4 — Independent runtimes and split conversations

- [ ] After Phase 3 approval, implement independent runtime ownership with per-session events, mutation guards and teardown. Verify two controlled sessions can work concurrently and stopping/closing one cannot affect the other's process, output, drafts, dialogs or pending actions.
- [ ] Add native resizable split conversations, initially limited to two visible panes. Give each pane an explicit session title, status, draft and scoped actions. Opening a saved conversation for review must not silently start Pi or replace another pane's active work.
- [ ] Keep focus, scrolling, attachments, slash completion and inspector routing pane-specific; prevent duplicate views from creating multiple writers for one session. Define whether duplicate session views are rejected or share the same session draft before implementation; verify that choice.
- [ ] Provide explicit split removal separate from Close Session: removing a view does not stop work, while Close Session uses the established confirmation/lifecycle rules and updates every view of that session. Verify focus recovery and narrow-window behavior without clipped composers.
- [ ] Verify concurrent native workflows with fake runtimes and controlled installed Pi sessions. Include out-of-order events, crashes, stale replies, pending approvals, reconnect, resource-limit failures and one session's unavailable directory. Confirm existing iPhone selection and authentication remain correct.

### Phase 5 — Layout recovery

- [ ] Persist only bounded UI layout, session references, focused pane, workspace expansion and existing drafts; keep prompts/tool output out of new layout records. Verify old/corrupt/unknown-version preference handling without overwriting recoverable state.
- [ ] Restore layout without automatically executing prompts or resuming interrupted tools. Keep missing sessions/directories visible with recovery actions rather than substituting a different directory. Closed sessions must stay closed until explicitly reopened.
- [ ] Document and verify window-close, application-quit and restart semantics separately. Preserve the current companion-owned lifecycle unless a separate background-service design is approved; do not promise Herdr-style detach survival or live process restoration.

### Phase 6 — Validation and documentation

- [ ] Add focused model tests in the configured `Tests/MacTests/CompanionTests.swift` sources and native interaction/layout tests in `CompanionPresentationTests.swift`; verify visibility, reopen, selection, status, focus, drafts, keyboard input and failure states for each implemented phase.
- [x] Run applicable host/protocol/client tests only when those layers change. Obtain test/build invocations from `project.yml`, `PiRemote.xcodeproj` and package configuration; build the Mac app and run the relevant Mac suites with saved logs/result bundles.
- [x] Build the iOS simulator app and run relevant compatibility checks only on the active iPhone 17 Pro, iOS 26.5 simulator. Verify session actions cannot cross session identity and report any unavailable checks separately.
- [ ] Capture and review compact and wide hosted layouts plus a normal-launch interaction check when desktop permissions allow. Check row close controls, confirmation, overview, switcher, palette, splits and recovery states for each delivered phase. Keep images outside Git; do not claim hosted captures prove VoiceOver or live-provider behavior.
- [x] Update `README.md` for implemented behavior, `PLAN.md` for approved boundaries/outcomes and `docs/mac-interface.md` for commands, evidence and limitations. Verify referenced paths, `git diff --check`, unchanged security checks and preservation of unrelated work. Evidence: the full diff and local links were reviewed; `git diff --check` passes and project/signing hashes are unchanged.

## Verification record

- All 59 Mac tests pass with zero failures/skips: `/tmp/pi-remote-management-mac-11.xcresult` and `.log`. The suite includes 43 presentation tests, 11 companion-model tests and five display-name tests.
- Two final initial-capture checks pass: `/tmp/pi-remote-management-mac-12.xcresult`. Parent review covers native pointer close, closed-only workspace guidance, Overview, populated switcher and palette at compact/wide sizes. Captures remain outside Git.
- Unsigned Mac product build passes (exit 0): `/tmp/pi-remote-management-mac-build-final.log`. The iOS simulator product build and three primary-iPhone UI checks pass: `/tmp/pi-remote-management-phone-XJppycTD/`.
- Three focused existing host lifecycle tests passed at the original UI checkpoint: `/tmp/pi-remote-management-host.log`. The PR review correction adds a local-only host confirmation API. Shared protocol encoding, iPhone sources and shared UI remain unchanged.
- Static review found and corrected the initial-snapshot Stop race and invisible pointer hit target. Native checks found and corrected search arrow handling and shortcut registration. Early failed/hung harness bundles remain available; the final passing runs include the corrections.
- PR #6 review correction: 61 Mac tests and ten focused host checks pass (`/tmp/pi-remote-pr6-review/mac-final-2.xcresult`, `/tmp/pi-remote-pr6-review/host-final-2.log`). Host-issued work/lifecycle consent rejects stale Stop actions; ordered close receipts and visibility reconciliation preserve a same-ID reactivation. Pending/completed Stop requests retain deduplication. These checks do not close the other failure/recovery tasks below.
- The current full goal is blocked at the shared-selection compatibility decision. A draft pull request can preserve this verified subset without declaring the full plan complete.
- Missing direct checks remain open: forced close idle-wait timeout, failed/unconfirmed shutdown through the new Mac path, complete interrupted-reopen recovery and keyboard-focus row-button reveal. Existing guard, shortcut, cancellation and normal lifecycle tests are not substitutes for those checks.
- Normal-launch/provider/VoiceOver checks are unavailable: Accessibility and Screen Recording preflight checks are false. No privacy permissions were changed and the user's running debug app was not stopped. Only an identified hung test runner was terminated.

## Non-Goals

- Rebuilding Herdr, embedding a terminal/PTY, adding SSH machine management, supporting other agent runtimes or adding plugins.
- Deleting saved sessions, removing workspace folders or editing Pi session identifiers to implement Close Session.
- Automatic worktrees, automatic interrupted-tool replay, background-service extraction or live process handoff.
- Dark mode, theme switching or a new design system.

## Risks

- Active work may change between confirmation and close. Capture session identity/context, recheck after each await and fail closed on mismatch.
- A close response can be uncertain. Do not hide the session, retry automatically or claim its process stopped without evidence.
- Concurrent Pi processes can edit the same files. Display shared-directory association; registered workspaces are not security sandboxes.
- Multi-session support changes transport assumptions. Gate implementation on explicit approval and client compatibility checks.
- Close controls can conflict with sidebar selection and keyboard window actions. Verify native input, focus and accessibility labels rather than only model callbacks.

## Rollback / Recovery

- Keep session history/catalog formats unchanged for Phases 1–2. Removing the new UI preference state restores catalog visibility without losing conversations or drafts.
- Preserve existing preference bytes before any incompatible later layout migration; handle failed reads without replacing the source record.
- Before concurrency changes, record a downgrade path and stop affected runtimes explicitly. Do not downgrade with live writers or discard unknown outcomes.
- If a later phase fails validation, retain the verified earlier phases and leave later tasks open; do not release unverified lifecycle/protocol changes.

## Completion Checklist

- [ ] Close Session hides only the requested session, preserves its workspace/history/draft, confirms active-work interruption and supports explicit reopening through `/resume`.
- [ ] Overview, switcher and command palette use truthful state, shared action routing and accessible native input without fabricated metadata.
- [ ] Concurrency scope and compatibility decisions are approved before implementation; deferred phases remain explicitly open rather than marked complete.
- [ ] Approved split/runtime features isolate session actions and preserve both Mac and iPhone behavior under failure and reconnect tests.
- [ ] Recovery restores UI state without automatic prompt/tool replay or unsupported process-survival claims.
- [ ] Applicable builds/tests and reviewed captures have recorded evidence; unavailable manual/accessibility/provider checks are listed separately.
- [ ] Documentation, path checks and whitespace checks pass; unrelated work and security boundaries are preserved.
- [ ] All tasks for the agreed scope are verified or explicitly accepted as inapplicable, durable evidence is recorded, and this temporary plan is deleted only after completion.
