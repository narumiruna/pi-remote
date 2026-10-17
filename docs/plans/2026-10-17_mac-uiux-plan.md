# Mac UI/UX corrections

## Goal

Resolve all five Mac UI/UX review findings: indirect command access, duplicate Files navigation, oversized controls, repeated header status and clipped folder navigation. Keep the conversation primary and preserve existing Pi capabilities and safety checks.

Status: all five UI corrections are implemented. Focused automated checks and layout review pass. Normal app launch, breadcrumb-menu selection and the full Mac keyboard/accessibility review remain open; this plan is not complete.

## Context

The following observations describe the review baseline, before these corrections.

- `Apps/macOS/CompanionWindow.swift` opens Tools from the composer Commands action. Commands are near the bottom of `Apps/Shared/SessionViews.swift`.
- Files is available as a conversation tab, an inspector tab and a composer shortcut. The first replaces the conversation; the last opens the inspector.
- Shared conversation, directory and session views apply 44-point minimum sizes on Mac and iPhone.
- The global header shows server, device, version and execution status. The session header repeats execution status.
- `Apps/Shared/DirectoryBrowser.swift` shows an editable absolute path and a separate resolved-path row. Both compete for space in the 260–320-point inspector.
- Existing captures show layouts at 900 × 600 and 1300 × 800 points. `Tests/MacTests/CompanionPresentationTests.swift` provides hosted-view capture and native interaction helpers. These captures do not establish live colors or a normal app workflow.
- `README.md`, `PLAN.md` and `docs/mac-interface.md` require local use without a listener, separate execution and UI selection, bounded sheets, draft retention and no prompt replay.

## Non-Goals

- No protocol, authentication, storage-format, signing or deployment changes.
- No concurrent Pi sessions, terminal, new theme or generic UI configuration system.
- No removal of command arguments, runtime settings, history, file attachment or lifecycle features.
- No broad UI/E2E matrix or inactive compact-device checks.

## Plan

- [x] Confirm the existing interaction and test seams before edits. Inspect command dispatch, session-scoped requests, directory validation and native control discovery. Select stable accessibility identifiers for new interactions. Evidence: record the affected files and focused test cases here; resolve any test-harness limitation before relying on capture-only checks.

- [x] Make Commands open a dedicated command picker from the Mac composer. Reuse the current command list, arguments and dispatch behavior; keep session context checks, busy restrictions, error feedback and empty-command feedback. Share tightly coupled command UI only where this prevents duplicate dispatch logic. Evidence: a rendered-button interaction opens visible commands without scrolling through Tools; selecting a fixture command dispatches its name and arguments once; a stale session action is rejected.

- [x] Make the Mac inspector the single Files destination. Remove Files from the conversation tabs; keep Chat and History. Route the composer Files action to the inspector and retain the inspector Files tab. Preserve file preview, text attachment, path copying and Finder reveal. Evidence: both entry points reach the same file browser, the conversation stays visible, and preview/attachment actions retain the correct session context.

- [x] Use native Mac control density in the affected shared views. Replace unconditional touch-sized minimums with platform-specific sizing for composer buttons, tool/thinking disclosures, directory navigation and rows, and session-control actions. Use system sizes rather than a new sizing framework. Keep iPhone touch targets unchanged. Evidence: reviewed 900 × 600 and 1300 × 800 captures show readable labels, a complete composer and less vertical waste; native key events verify text-field focus and input, rendered actions activate, and long Tools content still scrolls. Full keyboard-only navigation remains in the completion checklist.

- [x] Consolidate header status on Mac. Keep one execution-state label in the session header when that session is displayed. On other destinations, retain a compact active-session status and the existing Active session and Stop actions. Replace separate server/device labels with one remote-access summary that opens listener and authenticated-device details; distinguish remote access off, listening without devices and connected devices. Move Pi version information to Settings while retaining its existing session-controls location. Evidence: state checks cover stopped/listening/connected and idle/working/unavailable states; minimum-width captures show no clipped primary actions or repeated execution label for the displayed active session.

- [x] Implement simplified Mac folder navigation. Show a compact breadcrumb for the resolved folder, a standard-sized parent action, Copy full path and an explicit Edit path action. Keep the full canonical path available through selectable text or a clearly labelled detail view. Open the existing path editor on demand; retain Go as navigation only. In folder-selection sheets, keep resolved-path review and the explicit Add workspace or Start Pi Here action. Evidence: at 260- and 320-point inspector widths, long paths do not displace folder rows or primary actions; parent navigation and canonical-path copying pass an isolated-clipboard test; edited, failed and pending paths cannot select the previous folder; Go never creates a session. Breadcrumb-menu activation still needs the manual check below.
    - [ ] Manually select a breadcrumb ancestor and verify the resolved path changes without session creation. Native menu tracking blocked the automated attempt; its 300-second timeout is retained in `/tmp/pi-remote-uiux-mac-folder-actions-3.log`. Two earlier attempts queried an unopened, lazily populated menu and failed. Do not treat the rendered breadcrumb alone as selection evidence.

- [x] Add focused regression coverage in `Tests/MacTests/CompanionPresentationTests.swift` and the existing Mac-model or directory-browser tests as needed. Use actual rendered-control interactions where practical, not only model assignment or screenshot generation. Cover Commands routing and dispatch, unified Files routing, remote-access details, density and path-editor recovery. Evidence: routing assertions require a Commands sheet instead of Tools and only Chat/History tabs; the old routing cannot satisfy them. All 22 final Mac tests pass, including existing draft, busy-switch and no-replay checks. No pre-change binary comparison was run.

- [x] Verify the changed UI with the existing `PiRemoteMac` scheme and `PiRemoteMacTests` target in `project.yml` and the Xcode project. Run focused tests and an unsigned Mac build using the documented configuration; record exact commands and results. Review fresh captures for idle and working sessions, another selected workspace, remote access off/on, Commands, Tools and folder selection. Use 900 × 600 and 1300 × 800 windows and 260/320-point inspectors. Evidence: passing results and reviewed artifacts recorded in `docs/mac-interface.md`, with capture limitations stated.

- [ ] BLOCKED: Verify normal local Mac operation without a listener or phone pairing. The existing app is running under Xcode and the agent process has no Accessibility access. Do not stop that app or change privacy permissions. The user must close the existing instance and perform the normal-launch flow, or authorize a safe alternative. Launch the rebuilt app normally, select a folder, start installed Pi, send an instruction, view a reply and stop work. Use private session storage or a disposable workspace and avoid unrelated user data. Evidence: record observed results separately from hosted-view/model checks; if the check cannot run, leave it open and state the required user action.

- [x] Verify the shared iPhone UI remains unchanged. Build the `PiRemote` simulator target with the existing unsigned configuration. Run only focused checks affected by shared-view changes on iPhone 17 Pro, iOS 26.5: composer/Stop, command access, directory path editing and file preview/attachment. Evidence: passing build and relevant focused smoke results; retain 44-point touch targets. Do not run the inactive iPhone SE matrix.

- [x] Update affected documentation after verification. Keep the overview in `README.md`, design requirements and remaining checks in `PLAN.md`, and observed behavior/evidence in `docs/mac-interface.md`. Scope the 44-point touch-target requirement to iPhone while specifying native Mac sizes. Document the single Files destination, direct Commands access, status details and Edit path flow. Evidence: documentation matches tested behavior and all referenced repository paths exist.

## Verification record

- Discovery: `CompanionModel.scopedRequest(for:)` rejects changed session contexts before dispatch. `SessionCommandActions` shares dispatch and arguments between Tools and the dedicated picker, with an in-flight guard. The directory model clears failed/pending selection. New controls have `mac-composer-commands`, `mac-composer-files`, `mac-remote-access`, `session-command-*` and `mac-folder-*` identifiers.
- Unsigned Mac build passes using the existing `PiRemoteMac` scheme, `/tmp/pi-remote-mac-ux` derived data and `CODE_SIGNING_ALLOWED=NO`. Final log: `/tmp/pi-remote-uiux-mac-build-final.log`.
- All 22 Mac tests pass with zero failures/skips in `/tmp/pi-remote-uiux-mac-final.xcresult`. The additional parent/copy test uses the existing clipboard-writer environment with a private pasteboard; the user's clipboard is unchanged. Current test commands and reviewed layout evidence are recorded in `docs/mac-interface.md#uiux-correction-verification`.
- The final unsigned iOS simulator build also passes after the clipboard-writer change. Log: `/tmp/pi-remote-uiux-ios-build-final.log`.
- iPhone 17 Pro, iOS 26.5: unsigned product build and all nine directory-browser model tests pass. Three focused UI checks pass for keyboard/Stop/draft, Commands/editor access and file preview/attachment. Evidence: `/tmp/pi-remote-uiux-iphone-evidence/commands.sh`, `build.xcresult`, `directory-model.xcresult` and `interface.xcresult`.
- The fourth phone UI check initially stopped at an obsolete 375 × 667 assertion. The test now requires the active device's 402 × 874 viewport. Triple-tap replacement then selected only part of the existing path; explicit Select All fixes the test input without removing any safety assertion. The typed-path navigation/recovery/explicit-start check passes in `/tmp/pi-remote-uiux-iphone-evidence/path-select-all.xcresult`. Parent review confirms complete keyboard and error captures in `path-captures/`.
- The phone checks are focused fixture/model checks, not signed installation, real-provider or off-site evidence. Mac hosted-view checks are not proof of normal app launch, live colors or full keyboard/accessibility behavior.

## Risks

- Shared UI edits can reduce iPhone targets or alter layout. Limit density and navigation changes to Mac and run the focused phone checks above.
- Status consolidation can hide active work or connection failures. Keep Stop and Active session visible when relevant; expose listener and authenticated-device states separately in details.
- A hidden path editor can obscure an unresolved edit. Keep the edited/pending/error state visible and block selection until successful resolution; never silently use the previous folder.
- Existing hosted captures are not proof of normal launch, system colors or contrast. Require the normal local workflow separately and report unavailable checks without completion claims.

## Completion Checklist

- [ ] All five findings have implemented corrections and passing acceptance evidence in the tasks above.
- [ ] Commands, Files, Stop, History, file attachment and folder selection remain accessible by keyboard and have clear accessibility labels.
- [x] Fresh captures pass the specified window/inspector review; sheets remain bounded with a visible dismissal action.
- [ ] Focused Mac tests, unsigned Mac/iOS builds, normal local workflow and relevant iPhone smoke checks pass with recorded results.
- [x] No credentials, real prompt text, pairing data or tool output were added to routine logs or committed artifacts.
- [x] `git diff --check` passes; documentation paths are valid; unrelated work and project/signing settings remain unchanged.
- [ ] Update `PLAN.md` with the final outcome, preserve verification evidence in `docs/mac-interface.md`, and delete this temporary plan only after every task and completion check passes.
