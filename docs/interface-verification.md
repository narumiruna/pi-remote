# Simulator interface verification

## Historical record — not an active development gate

The user removed iPhone SE (3rd generation), iOS 26.5, and PiRemoteCompact from the active test matrix. Do not run this suite during current early feature development unless explicitly requested. Keep the test source, commands and results below as historical records. Prioritize real Mac usability and focused checks; use the primary iPhone 17 Pro simulator only for relevant smoke checks.

## Result

All 27 current interface tests pass in 14 accepted batches, with zero failures or skips in that set; see the [current acceptance checkpoint](core-rpc-acceptance.md#delegated-compact-interface-audit). Earlier failed attempts and test-navigation fixes remain recorded. The original six also passed twice in sequence before usage, image-output, text-attachment and runtime-control checks were added. They run the production phone views in a separate test app on an iPhone SE (3rd generation) simulator, iOS 26.5, at 375 × 667 points with accessibility-extra-large text. Captures were inspected in light and dark appearance.

The product app suite also passes all 31 tests with the explicit provider fixture on this Mac's LAN and Tailscale interfaces. All 135 root tests and 50 shared tests pass, also with Thread Sanitizer. The unsigned Mac and iOS device-SDK builds pass. This is local evidence, not hardware or distribution evidence.

## Test boundary

`PiRemoteInterfaceFixture` includes `PhoneRoot`, `PhoneModel` and the shared production views. It supplies in-memory connection state and authentication results. It opens no sockets, reads no provider credentials and does not run Pi. Neither its entry point nor its fixture inputs are part of either product target. `PhoneConnection` is an internal test seam; the product initializer still creates `RemoteClient` with `ProtectedSecrets`.

The separate [simulator coding flow](workflow-verification.md#simulator-coding-and-recovery) tests production TLS, pairing, Pi execution and restart. A UI fixture does not replace that transport evidence.

## Checks

- The primary screen contains the header, transcript and composer. Sessions, models, thinking, files, connections and other secondary controls use menus or sheets.
- With the real software keyboard open, prompt text remains intact and Send and Stop are hittable, at least 44 × 44 points, inside the app bounds and above the keyboard. Stop returns the fixture to idle.
- Opening the keyboard retains the latest output. A user scroll away from the bottom retains its position while new output arrives. Latest returns to the bottom.
- A 100-message fixture within the 256 KiB display budget remains usable. Session controls remain reachable after expanding its final tool result.
- Tool error text is visible without opening its disclosure. A short error banner opens complete recovery instructions. Dismiss hides an acknowledged host error; unit tests verify that a new failure or host/session context shows it again.
- Background return retains the draft. Unlock denial and stale results remain covered by the separate authentication tests; the UI fixture does not test real biometric decisions.
- Directory selection starts with the conversation keyboard open, navigates nested folders and starts a new fixture session. The path field scrolls horizontally so a long path cannot displace Start Pi Here. It shows the selected folder end by default and marks an omitted prefix with an ellipsis. Session controls show the complete absolute path.
- Session controls use a scrollable native form. Editor dialogs retain Submit and Cancel above the keyboard. Their title remains in the navigation bar.
- The disconnected screen, Reconnect, saved connections and connection settings remain reachable with large text. Long recovery content scrolls rather than removing controls.
- Critical icon controls have explicit accessibility labels. The saved server URL has a readable label and retains the exact address as its accessibility value.
- Requested accessibility audits pass for touch regions and sufficient element descriptions. No requested findings were excluded. The final full runs contain no unrequested audit findings.
- `ContrastTests` resolves app text, secondary text, tint and prominent-label color pairs against light/dark system backgrounds. Each tested pair meets a 4.5:1 ratio. Captures also verify the rendered colors. Native system materials and inactive controls are not exhaustively pixel-tested.
- Last-response review copies only after an explicit action. Runtime settings require Apply/Cancel, and idle close retains a session that can be reopened. Captures and tests pass at large text; see [runtime evidence](runtime-controls.md).
- Mac file previews append selected text to the draft without sending it. Both Attach text and Done remain reachable with large text; the original draft and complete fixture content remain. See [attachment evidence](workflow-verification.md#mac-text-file-attachment).
- Native session usage opens and refreshes with large text. Image output opens a fit preview, enables the visible Full resolution switch, retains a 44-point Done action and removes the sheet after background return; see [image evidence](output-images.md).
- Reviewed HTML/JSONL exports, versions 1–3 import, explicit import-directory choice and installed-release-note paging pass at large text size; see [export](session-export.md), [import](session-import.md) and [release-note](release-notes.md) evidence.
- Input remains a standard text control. The simulator keyboard shows its standard dictation control; no custom speech service or hardware dictation claim is included.

## Fixes found during review

The first checks found undersized primary targets, hidden tool errors, clipped recovery text, unclear URL accessibility text and keyboard scroll movement. The fixes put target sizes inside button labels, use readable adaptive colors, show tool errors directly, provide a recovery sheet, use inline sheet titles and keep editor actions in a keyboard-safe inset.

Whole-window contrast and clipping audits also examined text outside SwiftUI scroll viewports. A fixed Dynamic Type override in the first test app prevented the font-size audit from changing sizes. The final review uses the dedicated simulator's content-size setting, actual keyboard/element frames, resolved-color tests and capture inspection. It does not claim that the full pixel or all-size audit passed.

A new live-output test then found an intermittent lazy-stack layout stall. Sampling showed main-thread SwiftUI layout work and high memory use, not a provider or socket wait. Changing scroll anchors alone did not fix it. The bounded transcript now uses an eager stack and separates user scrolling from layout changes. Four repeated focused reading tests and two complete six-test runs pass after that change. The 100-message fixture checks that this fix remains usable at the message-count limit.

## Repeat the review

Use the repository root and the installed Xcode path on this laptop:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate --spec project.yml
xcrun simctl ui B0BF2720-C60E-4B7F-B57B-CE16F9B8A443 content_size accessibility-extra-large
xcodebuild -quiet -project PiRemote.xcodeproj -scheme PiRemoteInterface \
  -destination 'platform=iOS Simulator,id=B0BF2720-C60E-4B7F-B57B-CE16F9B8A443' \
  -derivedDataPath /tmp/pi-remote-interface CODE_SIGNING_ALLOWED=NO \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 90 test
```

This ID belongs to the dedicated `PiRemoteCompact` simulator, not a physical phone. To create an equivalent simulator with this installed runtime:

```sh
xcrun simctl create PiRemoteCompact \
  com.apple.CoreSimulator.SimDeviceType.iPhone-SE-3rd-generation \
  com.apple.CoreSimulator.SimRuntime.iOS-26-5
```

Use the returned ID in the commands above. Boot it with `xcrun simctl boot <id>` and wait with `xcrun simctl bootstatus <id> -b`. Do not change the global developer directory or another simulator's settings. The interface scheme needs no provider fixture. The product scheme's optional provider test needs the separate deliberate setup in the workflow record.

## Local artifacts

Current artifacts are under `/tmp/pi-remote-worker-interface-final-hXEQ2M/`: `REPORT.md`, `accepted-results.json`, `verified-tests.json`, all per-batch summaries/result bundles and 39 reviewed captures. Parent verification matched every current test to the accepted set. UI/fixture hashes stayed unchanged; the fixture app and runner were removed. Earlier attempts had 12 failed executions across ten bundles; see `earlier-failures.json`. These records do not claim one uninterrupted passing suite.

Historical passing summaries: `/tmp/pi-remote-interface-verified-1-summary.json`, `/tmp/pi-remote-interface-verified-2-summary.json` and the final `/tmp/pi-remote-interface-final-summary.json`. Product summaries use `/tmp/pi-remote-interface-product-<address>.json`. Build and package logs use `/tmp/pi-remote-interface-{mac,device,root,core}.log`.

Xcode result bundles are under `/tmp/pi-remote-interface/Logs/Test/`. Reviewed captures are exported to `/tmp/pi-remote-interface-final-reviewed-attachments/`. The failed layout sample is `/tmp/pi-remote-reading-hang-1.log`. These are temporary local artifacts. No screenshots, recordings, transcripts or binary test artifacts are committed.

The approved upstream Pi core shell controls still need implementation and interface verification in `PLAN.md`. Individual-extension compatibility and terminal-only behavior are outside the accepted scope. The following smaller checkpoints are historical evidence. Clean setup controls now have local model/transport and simulator evidence. The eight-test image checkpoint is recorded in `/tmp/pi-remote-output-ui-verified-summary.json`. The nine-test attachment checkpoint is recorded in `/tmp/pi-remote-attachment-ui-summary.json`. The current eleven-test runtime run is recorded in `/tmp/pi-remote-runtime-ui-full-summary.json`, with reviewed captures in `/tmp/pi-remote-runtime-ui-full-attachments/`.
