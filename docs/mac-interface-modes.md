# Pi and Desktop modes for Mac

## Behavior

Use the **Pi / Desktop** switch in the Mac toolbar. Pi is the default. The choice is saved on this Mac under `macInterfaceMode`. Missing or unknown values use Pi without rewriting the saved value. The preference does not sync to iPhone or send a Pi request.

| Area | Pi | Desktop |
|---|---|---|
| Appearance | Fixed dark, compact monospace text | Native light/dark appearance and system text |
| Startup | Pi logo, help and resource sections | Centered welcome with explicit Files/Commands or New session/Resume actions |
| Conversation | Full-width continuous output | Centered column, up to 880 points, with role labels and rounded message cards |
| Session information | Directory and phase in the footer | Fixed title/path/phase header; resources behind a disclosure |
| Input | Compact ruled editor | Rounded composer with Commands and Send/Steering controls |
| Tools | Compact dark rows | Native panel colors and rounded rows; paths stay monospace |
| Code | Dark code surface | The same dark code surface with rounded corners |

Both modes use the same conversation flow, native editor and session. The composer remains in that flow; Desktop does not add a second, pinned editor. Switching does not change the session context, submit text, recover queues, answer dialogs or stop work. Existing keyboard, shell review, draft-replacement consent and no-replay rules remain in effect.

Tool disclosure choices, code-copy feedback and model/thinking picker input remain mounted across mode changes. Extension widgets keep their above/below-editor positions. Status entries stay in the footer. Standard extension dialogs use the active mode's text and surface colors. Arbitrary extension components remain outside the RPC contract.

## Implementation boundaries

- `MacInterfaceMode.swift` defines the two cases and their colors.
- `CompanionModel.swift` stores only the local preference in the injected `UserDefaults`.
- `CompanionWindow.swift` supplies the native segmented switch and local SwiftUI color scheme. It does not change the app-wide appearance. Desktop restores the inherited scheme after Pi mode.
- `MacDesktopChrome.swift` contains callback-only header and welcome views.
- `PiConversationView.swift` changes presentation without changing editor/message identity or moving the editor between branches.
- `PiEditor.swift` changes native attributes in place. It restores marked-text attributes without replacing characters or ending composition. Native undo/redo completion reconciles the binding when AppKit restores storage without a text-change callback.

Host, shared packages, iPhone, authentication, catalog and RPC formats are unchanged. No preference migration is needed. A rollback can remove these presentation changes without deleting session data or resending input.

## Verification

The final configured Mac test run passed **207 tests, 0 failures**, after the last source change. The unsigned Mac build passed. Logs are `/tmp/pi-mac-interface-modes/mac-final-all.log` and `/tmp/pi-mac-interface-modes/mac-final-build.log`. All 30 Mac source/test/project hashes before and after validation match. `git diff --check` passes.

The test log contains hosted `SceneStorage` lifecycle messages, AppKit CA-commit warnings, `linkd.autoShortcut` connection diagnostics, and an AppIntents metadata warning. There are no compilation errors or failed tests. The final build has no compiler warnings or errors. These results do not establish live accessibility or normal-launch acceptance.

Focused checks cover:

- Private-preference default/fallback, round trips, and no unrelated preference or runtime-state changes.
- Native pointer/arrow selection at 900 and 1300 points, visible management controls, and system appearance restoration.
- The same mounted editor, draft, UTF-16 selection, undo manager, marked text, history and completion snapshots across mode changes.
- Closed-group native undo/redo, including binding updates after a run-loop turn.
- Busy, waiting, recovering and unavailable model states; retained extension metadata and a pending confirmation sheet.
- Tool disclosure, exact expanded output, code feedback and explicit copy callbacks. Tests do not write the real clipboard.
- Model/thinking search and selection retention without an appearance-triggered request.
- Desktop text, muted text, accent and warning contrast of at least 4.5:1 against native surfaces in Aqua and Dark Aqua. Existing Pi colors remain unchanged.
- Standard extension selection/editor dialogs in both appearances, retained editor text/selection and no automatic answer.

Initial focused runs found and corrected preference-load rewrites, low muted-text contrast, compressed header controls and a native undo binding gap. A completion fixture incorrectly reused results while undo selected text; it now checks that selection and requests a fresh exact snapshot before testing dismissal. SwiftUI does not expose the expanded scroll wrapper's identifier through its text-selection overlay. The component test checks the accessible exact output and native Expanded state instead.

### Commands

The configured Mac scheme and source lists come from `project.yml`. Generate the ignored Xcode project with `xcodegen generate`. Use command-local Xcode selection:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project PiRemote.xcodeproj -scheme PiRemoteMac \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/pi-remote-pi-like-mac \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project PiRemote.xcodeproj -scheme PiRemoteMac \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/pi-remote-pi-like-mac CODE_SIGNING_ALLOWED=NO
```

### Capture review

`MacConversationModeTests.testPairedModeCapturesAtNarrowAndWideSizes` produces 12 private hosted captures: Pi dark and Desktop light/dark, each with empty/populated synthetic sessions at 900 and 1300 points. Height is 740 points. They are XCTest attachments and local files under `/tmp/pi-mac-interface-modes/captures/`; images are not committed.

The captures were inspected for distinct hierarchy, readable text, centered Desktop content, visible toolbar/input/footer controls and no horizontal overflow. They do not prove a normally launched app, live provider work or final user acceptance. The existing app was not stopped or replaced to obtain these captures.

## Limits

Normal-launch/provider use, live VoiceOver, full keyboard traversal, real IME input during pointer-driven switching, and reading-position behavior during live streaming remain unverified. Extension selection checks inspect accessible choices and theme color pairs, not rendered List-row pixels. Marked-text retention and pointer switching have separate native fixture checks, not a combined live IME check. User visual acceptance remains open.

Phone, host and shared-package suites are not repeated for this Mac-only change. The Mac scheme includes its existing local/remote model integration checks. No claim is made about a new supported release or full terminal/extension parity. See [the Pi reference](pi-like-mac-reference.md), [extension boundaries](pi-extension-native-display.md) and [earlier UI refinements](mac-reference-uiux.md).
