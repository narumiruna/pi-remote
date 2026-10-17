# Mac UX/UI review follow-up

## Goal

Resolve the five Mac review findings: unconfirmed Quit during active work, inconsistent close actions, blocked access to the working conversation from Overview, unclear inspector labels and missing common palette actions. Preserve local operation without an iPhone connection, saved history, drafts and existing safety checks.

Status: implementation and automated checks pass. Acceptance is blocked on normal-launch/provider operation, live keyboard/VoiceOver review and native Session controls menu selection. This plan is not complete and must remain in the repository.

## Context

The following context describes the review baseline before these changes. The review used source and existing hosted-view captures, not a normal app launch or live accessibility checks.

- `Apps/macOS/PiRemoteMacApp.swift` sends ordinary termination directly to `CompanionModel.shutdown()`. Shutdown stops the listener and coordinator without an active-work confirmation.
- `Apps/macOS/CompanionWindow.swift` provides the guarded Close Session workflow and sidebar visibility changes. `Apps/Shared/SessionViews.swift` separately exposes Close Pi session through direct RPC.
- Overview disables every Open button while Pi works, including the loaded session. The toolbar provides a separate Active session route.
- The inspector's Tools tab contains session controls; Activity contains tool results and extension diagnostics.
- The palette includes Overview, New session, Toggle Inspector and native slash navigation, but omits common existing app actions.
- `Tests/MacTests/CompanionTests.swift` and `Tests/MacTests/CompanionPresentationTests.swift` provide model, close-safety, native-input and layout fixtures. `project.yml` includes `PiRemoteMacTests` in the `PiRemoteMac` scheme.
- Product requirements and existing limits are in `README.md`, `PLAN.md` and `docs/mac-interface.md`. Earlier checks do not prove the proposed fixes.

## Non-Goals

- No concurrent runtimes, protocol changes, storage migrations, session deletion or new settings.
- No theme, authentication, certificate, pairing or signing changes.
- No change to iPhone close semantics or navigation.
- No broad UI/E2E matrix or retired compact-device checks.
- Do not modify other saved plans as part of this work.

## Plan

### 1. Confirm shutdown and action boundaries

- [x] Trace ordinary Quit, coordinator shutdown, run-state classification and both close routes. Source review completed before implementation; boundaries and regression cases are recorded below.

Discovery evidence (2026-10-17):

- `CompanionDelegate.applicationShouldTerminate` is the common ordinary Quit entry. Menu-bar Quit calls `NSApplication.terminate`; Command-Q uses native application termination. The delegate currently returns terminateLater and replies after model shutdown.
- `HostSnapshot.working` treats every phase except idle/interrupted/unavailable as working. Quit must also account for unknown outcomes, in-flight mutations and lifecycle/recovery state from the authoritative coordinator, not just the observed UI snapshot.
- `HostCoordinator.shutdown` sets `closing` before its first suspension, cancels utility work, marks working history interrupted and awaits bounded child shutdown. `RPCProcess.shutdown` closes input, waits, then terminates/kills the child if needed. Ordinary shutdown has no resume/replay action.
- Existing close consent uses private process/work generations and session context. Quit needs separate local-only consent that also covers waiting/recovering and pending mutations; close consent intentionally rejects those states. Admission must close in the same coordinator turn as consent validation so a phone cannot start new work between validation and shutdown.
- `SessionControls` can accept an optional Mac close callback and disabled reason. Only the Mac inspector supplies them; iPhone retains its existing direct Close Pi session path. The callback must remain available for a working session and use `beginClose`, not the idle-only shared Session section.
- Regression cases: active/idle/cancelled/repeated Quit, stale session/work consent, completion while confirming, rejected post-admission mutations, inspector close with failures/pending state/oversized drafts, busy Overview navigation and stale palette actions.

### 2. Confirm ordinary Quit when work can be interrupted

- [x] Add one confirmation flow for ordinary application termination, including Command-Q and menu-bar Quit. Show Cancel and Stop work and quit when active, waiting or uncertain work can be interrupted. Explain that quitting disconnects phones, stops managed Pi and cannot undo file changes. Cancel must leave work and connections unchanged; idle Quit must remain direct. Acceptance: delegate/model tests cover each ordinary entry point, Cancel, idle exit and confirmed shutdown exactly once.
- [x] Guard the asynchronous termination decision against duplicate Quit requests and changed work while the dialog is open. Refresh consent when the captured work is no longer current. Keep OS-forced termination outside the confirmation guarantee. Acceptance: focused tests cover repeat requests, changed session/work, completed work and balanced termination replies without hanging or repeated shutdown.

### 3. Use one Mac Close Session workflow

- [x] Route the Mac inspector close action through the existing guarded Close Session workflow instead of its direct RPC path. Use the same label, confirmation, draft flush and visibility behavior as the row/header actions. Keep the current iPhone path unchanged. Acceptance: model/native-view tests show that row, header and inspector close keep history and drafts, hide the same entry only after success, and preserve it after failure or uncertain outcome.
- [x] Verify working-session confirmation, Cancel, stale work, pending dialogs and oversized-draft rejection through the inspector entry point. Acceptance: focused tests retain the existing close guards; no new direct Stop/Close sequence bypasses the host confirmation token.

### 4. Keep the working conversation accessible

- [x] Change the loaded session's Overview action to View conversation and allow it while Pi works. Route it to UI selection only, without resume RPC, process replacement or Stop. Keep other sessions' activation restrictions. Acceptance: an active-run test opens the loaded conversation from Overview without changing process/session identity, transcript, queue or draft; another session cannot interrupt the run.

### 5. Match inspector labels to content

- [ ] Rename the Mac Tools tab to Session, including internal routing, help text and accessibility labels. Keep Files and Activity unchanged; keep tool output and extension diagnostics in Activity. Acceptance: native-view tests verify Files/Session/Activity at 900 × 600 and 1300 × 800 points, and Session controls still opens the correct inspector tab.

Implemented label/routing changes and native tab/close checks pass at both sizes. Both Session controls menu routes select Session in source. Actual header/context-menu selection remains open for the live desktop review; the hosted AppKit menu-tracking fixture did not complete.

### 6. Make common actions searchable

- [x] Add Add workspace, Settings, Devices and Rename session to the existing palette. Reuse current routes and availability checks; do not create a second action framework. Rename must target the displayed, loaded idle session and remain unavailable for unrelated saved metadata. Acceptance: tests verify search, Return and pointer dispatch, explicit activation only, disabled-state reasons and draft retention for each added action.
- [x] Verify palette transitions while work, pending dialogs or close operations change availability. Acceptance: stale selection cannot execute an action that is no longer allowed; navigation does not start Pi, stop work or approve dialogs.

### 7. Verify the combined interface and update documentation

- [x] Run focused Mac model and presentation tests for the changed paths, then the unsigned Mac build using the configured `PiRemoteMac` scheme. Acceptance: record exact commands, test counts, failures/skips and result paths here. Do not regenerate the project unless target configuration changes.
- [ ] Check a normally launched Mac app: choose a workspace, start installed Pi, send an instruction, read the reply, return from Overview during work, cancel Quit, then explicitly stop and close. Check confirmed Quit separately with controlled work. Local use must not require starting the listener or pairing. Acceptance: record observed results and distinguish fixture checks from installed-Pi behavior; do not use valuable active work for interruption checks.
- [ ] Review the changed controls at both window sizes with keyboard-only navigation and VoiceOver. Verify dialog focus, Cancel/Escape, palette transitions, inspector labels and focus return. Acceptance: record live results; hosted captures alone do not complete this check. Leave unavailable checks open with the required external action.
- [x] Update `README.md`, the affected requirements/status in `PLAN.md`, `docs/mac-interface.md` and the Mac overview in `docs/native-apps.md` after behavior is verified. Acceptance: documented labels, Quit/close semantics and verification limits match the implementation; proposed behavior is not described as tested behavior.

Blocked checks require an attended desktop session with VoiceOver enabled and working desktop input. The command process reports Accessibility trusted false, Screen capture access false and VoiceOver enabled false in `/tmp/pi-remote-review-desktop-status.log`. No permission prompt or accessibility setting was changed. Complete the normal-launch flow and live controls/menu review above; hosted tests cannot substitute for them.

## Verification Evidence

All commands run from the repository root with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --no-parallel --scratch-path /tmp/pi-remote-review-host
swift test --no-parallel --sanitize=thread --scratch-path /tmp/pi-remote-review-tsan \
  --filter 'HostTests\.(quitConfirmation|reserveShutdown|closeConfirmation)'
xcodebuild -quiet -project PiRemote.xcodeproj -scheme PiRemoteMac \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/pi-remote-review-main \
  CODE_SIGNING_ALLOWED=NO -resultBundlePath /tmp/pi-remote-review-mac-final-3.xcresult test
xcodebuild -quiet -project PiRemote.xcodeproj -scheme PiRemoteMac \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/pi-remote-review-main \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -quiet -project PiRemote.xcodeproj -scheme PiRemote \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/pi-remote-review-phone \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -quiet -project PiRemote.xcodeproj -scheme PiRemote \
  -destination 'platform=iOS Simulator,id=6622EB8D-23E3-4E92-9262-21CF896CD300' \
  -derivedDataPath /tmp/pi-remote-review-phone CODE_SIGNING_ALLOWED=NO \
  -only-testing:PiRemoteTests/PhoneTests/testMacTextAttachmentPreservesDraftAndRejectsStaleOrLockedActions \
  -only-testing:PiRemoteTests/PhoneTests/testDraftsSurviveSessionChangesAndBackgroundWithoutAutomaticReplacement \
  -only-testing:PiRemoteTests/PhoneTests/testStaleEditorOffersCannotReplaceAnotherSessionsDraft \
  -resultBundlePath /tmp/pi-remote-review-phone-1.xcresult test
```

Verified results:

- All 168 root tests pass: `/tmp/pi-remote-review-root-final-2.log`.
- All 19 focused host close/Quit tests pass with Thread Sanitizer: `/tmp/pi-remote-review-tsan-final.log`. Parameterized cases also pass; no sanitizer failure was reported.
- All 81 Mac tests pass with zero failures/skips: `/tmp/pi-remote-review-mac-final-3.xcresult`, log `/tmp/pi-remote-review-mac-final-3.log`. This includes native delegate replies, nonblocking alert presentation with no/free/occupied parent window, Escape, changed consent, paired TLS Cancel, idle/working inspector close, failure/unknown/pending guards, draft/history retention, unchanged Overview runtime PID/state and palette search/Return/pointer/stale dispatch.
- Unsigned Mac and iOS simulator builds pass (exit 0): `/tmp/pi-remote-review-mac-build-final.log`, `/tmp/pi-remote-review-phone-build-final.log`.
- Three focused product tests pass with zero failures/skips on iPhone 17 Pro, iOS 26.5: `/tmp/pi-remote-review-phone-1.xcresult`, log `/tmp/pi-remote-review-phone-1.log`. All shared-view additions are Mac-conditional; the iPhone close code is unchanged. No retired compact suite ran.
- Parent review of `/tmp/pi-remote-mac-ux-captures/review-session-labels-{900,1300}.png`, `review-overview-working-900.png` and `review-inspector-working-900.png` confirms tab density, retained conversation/composer and full-height panes after close. These are layout caches, not system-color/contrast or normal-launch evidence. Synthetic folder errors in label fixtures are not installed-Pi failures. Images are not committed.
- `project.yml` adds only the Mac termination delegate source to the Mac test target. `xcodegen generate --spec project.yml` regenerated the ignored local project after that configuration change. Dependencies, deployment and signing settings are unchanged.
- Complete source/test diff review covers correctness, security, lifecycle safety, compatibility, regressions and scope. No wire format, credentials, catalog/session format or iPhone behavior changed. Read-only requests do not count as Quit mutations. RPC-cancellation and journal-commit unknown outcomes retain consent protection after unrelated read errors; successful explicit Stop/lifecycle changes end that interruption risk.

PR #7 startup correction:

- Review R1 found that Quit awaited network startup before it could cancel startup. A blocked version check reproduced the delay in `/tmp/pi-remote-pr7-startup-before.xcresult`; the four-second reply check failed on the original code. Cleanup then cancelled startup; the old termination task reported busy after shutdown.
- `requestTermination` now checks authoritative host consent without awaiting startup. Accepted shutdown still cancels startup before waiting. Cancel does not cancel network startup.
- All 23 `CompanionTests` pass with zero failures/skips in `/tmp/pi-remote-pr7-model-final.xcresult`; log `/tmp/pi-remote-pr7-model-final.log`. The new fixture checks normal and TERM-ignoring blocked version children, a reply within four seconds, child exit and no listener start. The Cancel test also proves that network startup can finish while local Pi work remains active. Existing stale-consent and duplicate-reply checks pass.
- Command: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -quiet -project PiRemote.xcodeproj -scheme PiRemoteMac -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/pi-remote-review-main CODE_SIGNING_ALLOWED=NO -only-testing:PiRemoteMacTests/CompanionTests -resultBundlePath /tmp/pi-remote-pr7-model-final.xcresult test`.
- The unsigned Mac build passes with the same scheme, destination and derived-data path; log `/tmp/pi-remote-pr7-mac-build.log`. Earlier full-suite, root, sanitizer and phone checkpoints above were not rerun for this Mac-only correction. The live acceptance checks remain open. See the [review ledger](../reviews/2026-10-17_pr-7-review.md).

PR #7 storage-failure correction:

- Review R4 found that a successful Pi mutation followed by `.storageFailure` did not retain Quit consent. The corrected Rename fixture reproduces this on the original code in `/tmp/pi-remote-pr7-storage-before-2.log`. Its first attempt used an unsupported top-level `plutil` JSON conversion; `/tmp/pi-remote-pr7-storage-before.log` records that harness failure, not product evidence.
- The host now retains `.storageFailure` for admitted mutations, as it does for `.unknownOutcome`. A later read error cannot clear consent. Successful explicit Stop/lifecycle recovery still clears the flag. Read-only failures do not set it.
- All 169 root tests, 20 focused host tests normally and with Thread Sanitizer, and 23 focused Mac model/delegate tests pass. The unsigned Mac build passes. Logs: `/tmp/pi-remote-pr7-storage-{root,host,tsan,model}-final.log`, `/tmp/pi-remote-pr7-storage-mac-build.log`; Mac result bundle: `/tmp/pi-remote-pr7-storage-model-final.xcresult`.
- The new host test covers confirmed Quit and successful Stop/Close recovery after a catalog write failure. It checks that Pi accepted the rename, Quit requires consent, an unrelated read error cannot hide uncertainty and unconfirmed Quit is rejected. Exact commands and outcomes are in the [review ledger](../reviews/2026-10-17_pr-7-review.md). Phone and full presentation checks were not repeated for this host-only correction. The live acceptance checks remain open.

Failure record and limits:

- The first Quit fixture lacked `new_session` support; the changed-session test failed with incompatiblePi. The fixture now implements that core reply and the full Mac suite passes.
- Native delegate tests initially used an async AppKit overload without await and an old selector spelling. Both compile errors were corrected; the delegate/presenter tests pass.
- Initial presentation checks expected Tools and missed SwiftUI mouse-up dispatch. Expectations now use Session; the pointer helper delivers mouse-up after mouse-down returns. A native menu-tracking fixture hung and was removed after its own test processes were cleaned up. Actual Session controls menu dispatch remains an open manual check, not a pass.
- Capture review found a wrapped visible Inspector label and collapsed panes after closing to a workspace. The redundant visible label is hidden while the accessibility label remains in source. The center pane now has a viewport-derived minimum height and empty inspector tabs stay at the top. New frame assertions reproduce and verify these corrections. Two attempted outer-frame-only fixes failed; an intermediate frame-argument ordering error did not compile. Final checks pass.
- Hosted AppKit did not export the picker container's synthetic accessibility label/identifier. Failed direct-label assertions were not accepted as VoiceOver proof. Tests verify native segment titles, density and selection; live accessibility remains open.
- Status-only desktop checks do not establish normal app launch, real-provider operation, complete keyboard-only use, VoiceOver output or live contrast. No real-provider request was sent in this work.

## Completion Checklist

- [ ] Every task above has passing acceptance evidence; material unknowns are resolved and unavailable checks remain open.
- [x] Ordinary Quit requires consent before interrupting work; Cancel has no shutdown side effects.
- [x] All Mac Close Session entry points use the same guarded behavior; saved history and drafts survive.
- [x] Overview opens the working conversation without runtime mutation; Files/Session/Activity labels match their contents.
- [x] Common palette actions use existing routes, protect drafts and reject stale or unavailable actions.
- [ ] Focused tests, unsigned build, normal-launch workflow and live keyboard/VoiceOver checks have recorded results. Shared-view changes have focused iPhone regression evidence if they affect compiled phone code.
- [x] Documentation paths resolve, `git diff --check` passes and the final diff contains only in-scope changes. Verified 84 local documentation links, referenced source paths and the new verification anchor; reviewed source, tests, configuration and documentation before commit.

Delete this plan only after every task and completion check passes. Report its path and verified results in the handoff.
