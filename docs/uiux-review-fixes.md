# UI/UX review corrections

## Implemented behavior

The review corrections cover the Mac and iPhone interfaces. They do not change authentication, certificate checks, pairing authority, the single-active-Pi limit or request replay rules.

| Review issue | Correction |
| --- | --- |
| Mac text could be lost before session selection | The native editor does not accept text without a loaded session. Both modes explain that a session must be chosen or resumed. Loaded-session drafts, native selection, undo and IME behavior remain available. |
| An offline phone dialog could block recovery | Close dismisses only the local sheet. The Mac request remains pending and can be reopened explicitly. Errors appear inside the sheet; Reconnect is available while offline. |
| Loaded phone conversations had no direct recovery | A disconnected conversation has a direct Reconnect action. Cached tool/thinking disclosure and Latest remain usable. Send, Stop, remote attachments and answers remain unavailable offline. |
| Long Mac extension requests could overflow | Request text has its own bounded scroll area. Response fields, errors and answer/cancel controls remain outside that area. Pending or acknowledged answers cannot be sent again while state catches up. |
| Listen addresses became stale | Settings refreshes the list when opened and provides Refresh addresses while iPhone access is stopped. Refresh keeps an available selection and never replaces identity, revokes devices or starts a listener. No available address prevents startup. |
| Phone notices lost severity; Forget was immediate | A compact row shows warning/error counts. Tap it for complete severity-labeled notices, widgets, status and diagnostics in a scrollable sheet. Reserved host recovery instructions remain visible above the composer. Forget uses a named alert with Cancel and explains local credential deletion and re-pairing. |
| The Files inspector stayed empty on app-level pages | Context-free Files/Activity content is hidden without clearing the saved visibility choice. Explicit Session controls can still identify loaded work from another page. Files/Activity tab selection returns to the loaded conversation when required. |
| The empty Mac conversation said idle | The header, Pi footer and toolbar use No session loaded. The composer gives session-selection guidance rather than Enter to send. |
| Optional networking appeared before local setup | Pi and folder access appears first. The optional section and its controls consistently use iPhone access. |

Dialog presentation tracks host/session context, connection generation, request ID and the in-flight answer token. Local dismissal is separate from acknowledgement. Reconnect does not replay an answer. Old completion callbacks cannot restore a locked/forgotten connection, clear a replacement request's busy state or reopen an acknowledged request from a delayed snapshot.

## Verification

Verified on this Mac with the configured Xcode schemes and iPhone 17 Pro simulator, iOS 26.5:

- 86 distinct focused Mac tests pass across three batches: an 84-test batch plus two isolated native-menu/inspector tests.
- 16 phone model/authentication tests pass. They include 13 recovery/notice/Forget tests and three existing authentication regressions.
- Four primary-phone UI smoke checks pass. They cover offline local Close, cached reading, reconnect/reopen without replay, severity, status/widgets with no typed notices, and Forget cancellation.
- Unsigned Mac and iPhone simulator builds pass.
- Independent source review found no remaining blocking issue after the duplicate-answer, notice-content and inspector-tab corrections.
- Local Markdown targets and `git diff --check` pass.

The combined Mac attempt passed 55 tests but failed two menu-dependent checks. Both passed in separate processes. The final accepted batch excludes those two checks and adds existing native editor regressions; it passes 84 tests. This is not a single-process full-suite pass. The earlier fixture compilation, accessibility lookup and IME-settling failures are not passing evidence.

The grouped Mac Settings form does not expose its drawn buttons through this in-process accessibility fixture. Its layout check uses local Vision text recognition of the private hosted window, in memory, to verify section order and click Refresh addresses. This does not prove VoiceOver navigation. No image is added to Git, no model provider is contacted, and no user window is used for that check.

## Repeat the focused checks

Run from the repository root. These use the existing project configuration; keep the developer-directory override local to the command environment.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"
xcodegen generate --spec project.yml

xcodebuild -quiet -project PiRemote.xcodeproj -scheme PiRemoteMac \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/pi-remote-apps-mac \
  -parallel-testing-enabled NO \
  -only-testing:PiRemoteMacTests/MacSetupUXTests \
  -only-testing:PiRemoteMacTests/PiExtensionDialogTests \
  -only-testing:PiRemoteMacTests/MacDesktopChromeTests \
  -only-testing:PiRemoteMacTests/PiPresentationTests \
  -only-testing:PiRemoteMacTests/PiConversationInteractionTests \
  -only-testing:PiRemoteMacTests/MacInterfaceStructureTests \
  -only-testing:PiRemoteMacTests/PiEditorNativeTests \
  -only-testing:PiRemoteMacTests/CompanionPresentationTests/testServerAndSessionStatusAreIndependent \
  -only-testing:PiRemoteMacTests/CompanionPresentationTests/testRemoteAccessSummaryDoesNotDependOnSessionRunState \
  -skip-testing:PiRemoteMacTests/MacInterfaceStructureTests/testContextualActionsAreReachableInNativeSessionMenuForBothAliases \
  -skip-testing:PiRemoteMacTests/MacInterfaceStructureTests/testInspectorTabChangesFromSettingsRetainVisibleContextWithoutActivatingPi \
  CODE_SIGNING_ALLOWED=NO test
```

Run each excluded test in a separate `xcodebuild` invocation with the same Mac destination, derived-data path and serial-test option, using only that test's `-only-testing` filter. Both isolated commands passed.

```sh
xcodebuild -quiet -project PiRemote.xcodeproj -scheme PiRemote \
  -destination 'platform=iOS Simulator,id=6622EB8D-23E3-4E92-9262-21CF896CD300' \
  -derivedDataPath /tmp/pi-remote-apps-ios -parallel-testing-enabled NO \
  -only-testing:PiRemoteTests/PhoneRecoveryTests \
  -only-testing:PiRemoteTests/AuthenticationTests CODE_SIGNING_ALLOWED=NO test

xcodebuild -quiet -project PiRemote.xcodeproj -scheme PiRemoteInterface \
  -destination 'platform=iOS Simulator,id=6622EB8D-23E3-4E92-9262-21CF896CD300' \
  -derivedDataPath /tmp/pi-remote-apps-ios -parallel-testing-enabled NO \
  -only-testing:PiRemoteInterfaceTests/PhoneRecoveryInterfaceTests CODE_SIGNING_ALLOWED=NO test
```

The unsigned build commands remain in [native app verification](native-apps.md#automated-checks). Temporary logs include `/tmp/pi-uiux-mac-accepted-batch.log`, `/tmp/pi-uiux-context-menu-isolated.log`, `/tmp/pi-uiux-inspector-tabs-isolated.log`, `/tmp/pi-uiux-phone-model-final.log`, `/tmp/pi-uiux-phone-ui-tests-final.log`, `/tmp/pi-uiux-mac-build.log` and `/tmp/pi-uiux-ios-build.log`.

## Compact phone notice follow-up

Long warnings previously occupied up to 180 points above the composer. With the keyboard open, this left little space for the transcript. General extension content now uses one single-line summary with a minimum 44-point touch target. The detail sheet keeps complete selectable text and a fixed Close action. Opening details does not run a command or change the draft. Reserved typed `recovery` notices keep their existing bounded inline display.

Verified on the iPhone 17 Pro simulator, iOS 26.5:

- All 14 `PhoneRecoveryTests` pass, including count/plural handling, long text, typed severity and legacy fallback.
- Four focused `PhoneRecoveryInterfaceTests` pass: compact severity counts and sheet dismissal, a 30-line MCP-style warning with the keyboard open, visible reserved recovery, and status/widgets with no typed notices.
- The long-warning check confirms that the transcript and Send remain visible, complete warning text reaches the sheet, and Close remains available after scrolling.
- `git diff --check` passes. The product and fixture compile as part of these simulator test runs.

Repeat the model command above with `PhoneRecoveryTests`. For the interface command, select only these four methods:

1. `testWarningAndErrorUseCompactSummaryWithCompleteDetails`
2. `testLongWarningDoesNotReduceTranscriptWithKeyboardOpen`
3. `testRecoveryInstructionStaysVisibleOutsideDetails`
4. `testStatusWidgetsAndRecoveryStayInDetailsWithoutTypedNotices`

The first filtered interface invocation selected zero tests and is not passing evidence. After project regeneration and fixture launch-argument updates, the result bundle confirms four tests passed with no failures or skips. Logs: `/tmp/pi-phone-notice-model.log` and `/tmp/pi-phone-notice-ui.log`. No physical-device or live VoiceOver check was run.

## Limits

The user app and its active Pi work were not restarted or replaced. These corrections have hosted/native and simulator evidence, not a new normally launched provider workflow or full VoiceOver/physical-keyboard acceptance. No broad UI/E2E matrix, physical-device, off-site or signing/distribution check was run. Earlier acceptance limits in `PLAN.md` remain open.
