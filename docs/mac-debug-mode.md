# Local Mac debug mode

## Status

The local debug service, Mac controls and repository Pi extension are implemented. Status and capture are read-only. App-only semantic interaction controls are also implemented; see the [interaction plan](plans/2026-10-18_mac-debug-interaction-plan.md). **A normally launched interaction smoke check passes; full acceptance remains incomplete.** Live navigation, appearance, ordinary-panel controls and page scrolling work. Saved-consent relaunch and native draft insertion still need live verification. Earlier session-only builds require one new Enable confirmation in the rebuilt app. Debug consent then persists across launches until explicitly disabled. The [initial implementation plan](plans/2026-10-18_mac-debug-mode-plan.md) retains its earlier acceptance limits.

This is repository development tooling. Normal Mac use, upstream Pi RPC and iPhone access do not depend on this extension.

## Operation

1. Build the Mac app with the verified commands below. A previously running app does not gain this feature until it is replaced and relaunched. Do not interrupt active Pi work without reviewing it.
2. Open **Settings → Local debug mode → Enable debug mode…**. Read the disclosure and confirm. First-time access starts only after confirmation. This saves the choice on this Mac. Later app launches restore debug mode automatically with a fresh capability. Select **Disable debug mode** to clear saved consent and prevent automatic startup.
3. Start Pi in this trusted repository, or reload its extensions. `.pi/extensions/pi-remote-debug.ts` registers three tools:
   - `pi_remote_debug_status`: interface mode, destination category, content dimensions, session-present flag, execution phase, listener-on flag and bounded session/message/dialog counts. It does not return a host snapshot, names, paths, IDs, drafts, conversation text or tool output.
   - `pi_remote_debug_capture`: one PNG of the identified Pi Remote content window, with dimensions, UTC capture time and `method: appkit-view`. An ordinary tool call returns an image. Codemode callers receive `{ image, metadata }` and can display it with `image(result.image)`.
   - `pi_remote_debug_interact`: an explicit `{ action, value }` request for the app-only controls below. Results contain only the action and `outcome: applied`; they never echo text. This means the presentation action was applied, not that physical keyboard/pointer input or a complete workflow was tested.
4. Use **Disable debug mode** in Settings or the persistent bottom indicator to revoke access. Ordinary confirmed Quit closes the current socket but keeps saved consent for the next launch. Cancelling Quit leaves access active. Disable does not stop Pi, send a prompt, change a session or stop iPhone access.

The controls and socket flow are tested in native fixtures. The steps above have not yet passed the separate normally launched product check. The consent text includes persistent debug access, UI controls and saved UI preferences/draft edits. Earlier session-only builds did not save consent, so enable once in the rebuilt app. If automatic startup fails, Settings reports the error and offers Retry and Disable; saved consent alone never reports a running service.

## App-only interaction

| Action | Values |
| --- | --- |
| `navigate` | `conversation`, `overview`, `settings`, `devices` |
| `interface_mode` | `pi`, `desktop` |
| `sidebar` | `show`, `hide` |
| `inspector` | `Files`, `Session`, `Activity`, `hide` |
| `panel` | `commands`, `resume`, `palette`, `hotkeys`, `directory`, `workspace`, `close` |
| `type_text` | Nonempty text, at most 2,048 UTF-8 bytes; NUL is rejected |
| `focus_editor` | `editor` |
| `scroll` | `history_up`, `history_down`, `history_top`, `history_bottom`, `dock_up`, `dock_down`, `page_up`, `page_down` |

- Controls use existing presentation state and identified native views in the one marked, visible app window. They do not inject desktop events or use system Accessibility access. Page scrolling supports Settings, Devices and Overview; other targets fail explicitly.
- Text appends through the native editor without replacing its selection or draft. Native undo remains available. Stale editor text/context, disabled, off-screen and IME-composing editors reject input. No text is submitted. Tool input itself can enter Pi history/model requests; do not use it for secrets.
- Pairing codes, pending approvals, extension requests, editor replacement/resend consent, native modal/confirmation surfaces, secure fields and ambiguous/unavailable windows block interaction. Only an identified ordinary app panel can be closed. Panels still block capture; there is no screenshot protection bypass.
- These controls cannot send prompts, run shell commands, start/stop Pi or networking, create/activate sessions, answer extension requests, approve/revoke devices, or change credentials. Opening a session/folder picker is not selecting or executing an item.
- Each action runs synchronously on MainActor after enablement, cancellation and surface checks. There is no automatic retry. A lost response, timeout or cancellation can occur after an action applied; inspect state before trying again, especially before appending text.

For a registered-tool probe without reloading the current Pi session:

```sh
node .pi/tests/debug-probe.ts interact navigate settings
node .pi/tests/debug-probe.ts status
```

The probe loads the installed extension API. It reports only fixed errors or the action result and does not print the value. This does not prove that a long-running Pi session has reloaded its tool list.

## Capture and privacy limits

- This is a rendered AppKit view snapshot, not a whole-desktop or compositor screenshot. It includes the app's content controls. It excludes native title-bar chrome, sheets, menus, popovers, shadows and content outside that view. It can omit separately composited surfaces. Do not use it as evidence for those surfaces.
- Only a window marked by the product's root view is eligible. Zero windows, multiple marked windows, a hidden app, an ordered-out window or a minimized window returns an error. Another app or an arbitrary window ID cannot be selected. An obscured but otherwise visible app window can still produce a rendered-view snapshot.
- Capture is rejected while pairing data, an extension dialog, an app panel, an attached sheet, a modal window, another visible key-capable app window/panel or a visible native secure text field is present. There is no desktop fallback.
- AppKit content capture needs no Screen Recording permission. The native prototype captured a 900 × 600 window with Screen Recording access absent. ScreenCaptureKit was considered but not invoked because access was absent; it is not a fallback or a supported debug capture method.
- Pixels can contain private conversation text, file paths and secrets displayed in ordinary content. There is no automatic redaction. Enablement discloses that Pi can save captures in session history and send them to its configured model provider.
- The app captures only on a tool request. It does not stream, record or save images to disk by default. Diagnostic logs exclude capture data, capability tokens, pairing data, prompts and tool output. The check probe reports only image metadata, hash and luminance, not pixels.

## Local access and resource limits

The Swift service binds a Unix domain socket, not a TCP port. It does not reuse iPhone TLS, pairing or device credentials. The extension is a client, not a TypeScript backend.

`~/Library/Caches/PiRemoteDebug/` contains:

- `control.sock`: mode `0600`.
- `endpoint.json`: mode `0600`, with protocol version, socket path and a fresh 256-bit capability token per enablement or restored app launch. Never copy it into logs, prompts or Git.
- `server.lock`: mode `0600`. This empty lock file remains after disablement to prevent competing processes from locking different inodes.

The directory must be owned by the current user with mode `0700`. Unsafe ownership, symlinks, hardlinked files and unexpected file types are rejected. Ancestors must be owned by root or the current user and not group/other-writable, except root-owned sticky system directories. Existing live instances cannot be replaced. Stale owned endpoint/socket files can be recovered under the exclusive lock. Cleanup deletes only the artifacts whose owner, device and inode still match this service's files.

Any process with this Mac user's permissions can read the local capability. This is not authentication of a particular Pi project and is not protection from a malicious same-user process. Project trust controls extension loading, not socket access.

| Resource | Limit |
| --- | --- |
| Connected clients | 4; excess clients are rejected |
| Request record | 4,096 bytes, including LF |
| Response record | 3 MiB, including LF |
| Deadline | 5 seconds total per connection/call; no automatic retry |
| Protocol | Version 1; one JSONL request and response per connection, then close |
| Operations | `status`, `capture`, `interact`; no arbitrary forwarding or runtime/credential mutations |
| PNG | 2 MiB; longest edge 1,920 pixels; at most 2,304,000 pixels |
| Status dimensions/counts | Dimensions clamped to 16,384; counts clamped to 10,000 |
| Active captures | 1; another capture is rejected as busy |

Capture draws bounded pixels on MainActor, then encodes PNG on a worker. Disable cancels clients and blocks old responses. Enablement and protected surfaces are checked again after encoding. The client validates response IDs, exact schemas, bounds, PNG framing/CRC and bounded decoded scanlines. It does not return unknown fields or raw errors.

## Verified checks

Local environment: macOS 26.6.2, Xcode 26.6/macOS 26.5 SDK, XcodeGen 2.46.0, Pi 1.3.0 and Node.js 26.10.0. These are observed test versions, not a supported-version range.

Run from the repository root:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate --spec project.yml
xcodebuild -quiet -project PiRemote.xcodeproj -scheme PiRemoteMac \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/pi-remote-debug-mac -parallel-testing-enabled NO \
  -only-testing:PiRemoteMacTests/MacDebugServerTests \
  -only-testing:PiRemoteMacTests/MacDebugControllerTests \
  -only-testing:PiRemoteMacTests/MacDebugInteractionTests \
  -only-testing:PiRemoteMacTests/CompanionTests/testDebugAccessSurvivesCancelledQuitAndClosesOnConfirmedQuit \
  CODE_SIGNING_ALLOWED=NO test
node --test .pi/tests/pi-remote-debug*.test.ts
xcodebuild -quiet -project PiRemote.xcodeproj -scheme PiRemoteMac \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/pi-remote-debug-mac CODE_SIGNING_ALLOWED=NO build
git diff --check
```

Initial checkpoint on 2026-10-18:

- The unsigned product build passes. The final native batch passes 28 tests and skips one root-only ownership test, with no failures. Native tests cover authentication, unsafe paths, deadlines, partial IO, disconnects, bounds, collisions, stale cleanup, token rotation and in-flight revocation; status privacy; protected/unavailable/ambiguous windows; PNG decoding/limits; consent/Cancel; native Disable; cancelled and confirmed Quit; session/draft preservation.
- Product SwiftUI content captures differ between Pi, Desktop light and Desktop dark in hosted windows. Desktop light has greater sampled luminance than dark. Synthetic 900 × 600 and downscaled 1,920 × 1,200 captures decode correctly. These are not normal-launch or full UI responsiveness results.
- One foreign-owner fixture test skips because changing ownership requires root. No privilege was requested. Ownership guards were reviewed; privileged ownership mutation remains untested.
- All 21 extension tests pass. They include trusted project discovery, strict zero-argument schemas, unsafe discovery paths, malformed/bounded image and socket data, timeout, cancellation, concurrency and reload cleanup. Actual installed Pi RPC executes both tools before and after `ctx.reload()` with an explicit local provider fixture, offline and without saved sessions. Installed `ExtensionRunner` supplies real `tui` contexts without opening a terminal renderer. These runtime checks use a fixture socket, not a normally launched product app.
- Eleven focused existing interface-mode and Quit regression tests pass. No iPhone source or protocol changed; broad iPhone/UI suites were not run.
- Independent review found and corrected a server/client socket-name mismatch and missing `queued`/`bash` phases. Native runs also exposed test path-length/symlink fixtures and a banner accessibility grouping defect; these are corrected. Earlier failed runs are not counted as passing evidence.

The regression batch used:

```sh
xcodebuild -quiet -project PiRemote.xcodeproj -scheme PiRemoteMac \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/pi-remote-debug-mac -parallel-testing-enabled NO \
  -only-testing:PiRemoteMacTests/MacInterfaceModeTests \
  -only-testing:PiRemoteMacTests/CompanionTests/testQuitCancelsBlockedVersionStartupBeforeWaitingForItsDeadline \
  -only-testing:PiRemoteMacTests/CompanionTests/testQuitCancelAndDuplicateRequestsLeaveWorkRunningThenConfirmOnce \
  -only-testing:PiRemoteMacTests/CompanionTests/testQuitRefreshesConsentForAcceptedWorkWithoutRunEvents \
  -only-testing:PiRemoteMacTests/CompanionTests/testQuitRefreshesConsentForChangedSession \
  -only-testing:PiRemoteMacTests/CompanionTests/testQuitAfterWorkCompletesNeedsNoSecondConfirmation \
  -only-testing:PiRemoteMacTests/CompanionTests/testTerminationDelegateSharesOneReplyForRepeatedNativeCallbacks \
  -only-testing:PiRemoteMacTests/CompanionTests/testIdleQuitDoesNotPresentConfirmation \
  CODE_SIGNING_ALLOWED=NO test
```

Local logs are `/tmp/pi-remote-debug-focused-tests.log`, `/tmp/pi-remote-debug-regression-tests.log`, `/tmp/pi-remote-debug-extension-tests.log` and `/tmp/pi-remote-debug-build.log`. These are temporary evidence, not committed artifacts.

## Window detection correction

A later probe reached the normally launched Mac app and returned Desktop/Settings/idle status, but dimensions were `0 × 0` and capture returned `window_unavailable`. The app and its Pi child were running. Window detection depended on `NSWindow.identifier`, which SwiftUI owns and can replace after attachment.

Detection now finds the typed marker in the window's current content hierarchy. It neither reads nor changes the window identifier. The transparent 1 × 1 marker ignores pointer input and accessibility. Panels and sheets remain excluded. There is no key-window, title or desktop fallback.

The new identifier-change regression failed on the old code with zero dimensions and an unavailable window. It passes with the fix. Tests also verify identity preservation on attachment, removal/reparenting, replaced content, spoofed identifiers and marked sheets/panels.

The correction passes 34 native checks, with one root-only ownership skip, and all 21 extension checks. The native batch used the focused command above with `-only-testing:PiRemoteMacTests/MacInterfaceModeTests` added. The unsigned product build passes. Logs: `/tmp/pi-remote-debug-window-tests.log`, `/tmp/pi-remote-debug-window-extension-tests.log` and `/tmp/pi-remote-debug-window-build.log`.

A separate temporary, locally built SwiftUI `WindowGroup` fixture used the product views and debug service in a private home. The actual registered-tool probe returned 900 × 682 status and a valid 70,086-byte PNG, with scene identity unchanged. No image file was saved. This is additional window-lifecycle evidence, not a user-consent or full product acceptance check. The first temporary-home attempt failed to start the endpoint; a second run with a private home under the user's home directory passed. The running user app was not stopped or replaced and must be rebuilt/relaunched before retesting.

## App-only interaction checkpoint

On 2026-10-18, the expanded implementation passes:

- 41 focused native tests; one additional foreign-owner fixture skips because it requires root. The batch covers the debug controller, service and interaction tests.
- 40 existing editor routing/history/completion/native tests in a separate batch. Native insertion preserves draft text and undo; stale text/session views reject input.
- All 28 extension tests, including actual installed Pi RPC execution before/after reload against a fixture service, strict action/value validation, encoded-record limits, fixed results, cancellation and no retries.
- The unsigned Mac product build and `git diff --check`.

The focused batch uses the command above without the optional Quit test. Editor regression filters are `PiEditorRoutingTests`, `PiEditorHistoryTests`, `PiEditorCompletionTests` and `PiEditorNativeTests`. These are configured test classes, not a `PiEditorTests` class.

Hosted product tests operate Settings/Devices navigation, the real inspector hook, ordinary-panel open/close and identified page scrolling. Other native tests cover append/undo, scroll bounds, protected flags/secure fields, foreign confirmation-sheet rejection, actual socket interaction and queued-request disable/re-enable without later navigation. Independent source review found the stale-editor and panel-ownership gaps; the corrections pass these checks. Actual user-driven identity-replacement/revocation/Stop-and-Close confirmations and physical pointer/keyboard behavior remain unverified.

A registered-tool probe against the existing normally launched app returned `Pi Remote debug operation is unsupported.` for `interact navigate settings`. It did not navigate. This proves that app still runs the older service, not that the new controls pass normal-launch acceptance. The user app and its Pi child were not stopped or replaced. Quit/reopen the rebuilt app and enable debug mode again before the live review. The current unsigned build is `/tmp/pi-remote-debug-mac/Build/Products/Debug/PiRemoteMac.app`; this is a local artifact, not an installation or release.

Temporary logs: `/tmp/pi-debug-interaction-final-tests.log`, `/tmp/pi-debug-interaction-editor-tests.log`, `/tmp/pi-debug-interaction-extension-tests.log` and `/tmp/pi-debug-interaction-final-build.log`. No review screenshots or binaries were added to Git.

## Saved-consent checkpoint

The user requested persistent debug mode. Confirmed Enable now saves `macDebugEnabled` in the app's local preferences. Model initialization restores it. Disable clears it; Quit only closes the current service. No token is stored in preferences. Restart uses a fresh private endpoint capability, and unsafe endpoint guards remain unchanged.

The focused debug/controller/interaction/Quit batch passes 44 tests with one root-only ownership skip. Restart tests create successive production models with the same support directory, preferences and socket path: fresh installation off → Enable → shutdown removes endpoint → restart on with different capability → Disable → restart off. Failed automatic startup retains a visible error and can be explicitly disabled. Existing consent-Cancel and native Disable tests verify saved consent too. Log: `/tmp/pi-debug-persistence-tests.log`.

The unsigned product build, all 28 extension tests and the separate-process `build-for-testing` pass. The UI test now expects saved consent and token rotation after Quit, then restart-off after Disable. Its normal-launch execution remains unverified; compiling it is not a passing live restart check. Logs: `/tmp/pi-debug-persistence-build.log`, `/tmp/pi-debug-persistence-extension-tests.log` and `/tmp/pi-debug-persistence-interface-build.log`.

## Normally launched interaction smoke check

After commit `06a8d14` was pushed, the actual registered-tool probe operated the user's normally launched app:

- Navigation to Overview, Devices, conversation and Settings returned `applied`; status and rendered captures confirmed destinations and Pi/Desktop mode changes.
- Sidebar hide/show, inspector Activity/Files and identified Devices/Settings page scrolling returned `applied`. A Settings capture showed the changed scroll position.
- Hotkeys opened and closed through ordinary-panel controls. While open, both capture and navigation were rejected. The fixed capture error was preserved after correcting the probe's overly narrow safe-error filter; all 29 extension tests pass, including the new regression.
- Editor focus was rejected because no session was loaded. No prompt was sent, no draft text was inserted, and no Pi process/session/listener was started. Final status remained no loaded session, idle, six saved sessions, zero messages/dialogs and listener off.
- The app was returned to Desktop/Settings with the sidebar shown and Files inspector selected.

The captured disclosure still said debug turns off on app exit, which identifies the running app as the earlier interaction build, not the saved-consent build. Therefore this check does not prove persistent consent in the live app. Relaunch the latest rebuilt app, enable once, then verify another quit/relaunch restores access. No consent preference was injected and no user app was terminated by the agent.

## Remaining acceptance

The [focused separate-process check](../Tests/MacDebugInterfaceTests/README.md) uses unchanged app sources, a separate bundle identity and a private home. Its locally ad-hoc signed app and runner build and pass signature verification. **Neither dedicated UI runner attempt reached test entry or launched the check app.** The first unsigned runner awaited Gatekeeper execution consent; the corrected-signing attempt also timed out, with its exact setup blocker unresolved. No permission was granted. The existing user app and its Pi process were not stopped.

An attended Mac run must resolve runner setup and confirm off → consent → status/capture in Pi and Desktop light/dark → Quit/relaunch restores debug access → disable → restart off. Actual window coverage, live editor/Stop responsiveness and the real project-extension-to-product flow remain open. Do not treat build results, fixture images or runtime mode tests as this acceptance. The feature plan remains incomplete until these checks pass.
