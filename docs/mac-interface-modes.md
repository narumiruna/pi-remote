# Pi and Desktop modes for Mac

## Behavior

Use the **Pi / Desktop** switch in the Mac toolbar. Pi is the default. The choice is saved on this Mac under `macInterfaceMode`. Missing or unknown values use Pi without rewriting the saved value. The preference does not sync to iPhone or send a Pi request.

| Area | Pi | Desktop |
|---|---|---|
| Appearance | Fixed dark, compact monospace text | Native light/dark appearance and system text |
| Startup | Pi logo, help and resource sections | Loaded empty session: short input hint. Unloaded: Resume and guidance to toolbar New session |
| Conversation | Full-width continuous output | Centered column, up to 880 points, with role labels and rounded message cards |
| Session information | Directory and phase in the footer | Fixed title/path/phase header; Context/Skills/Prompts in Session Details |
| Input | Compact ruled editor that follows content | Persistent rounded composer below history, with Send/Steering controls; no duplicate Commands button |
| Tools | Compact dark rows | Native panel colors and rounded rows; paths stay monospace |
| Code | Dark code surface | The same dark code surface with rounded corners |

Both modes use the same native editor and session. Pi places the dock at its content anchor. Desktop pins that same dock below an independent history viewport; it does not add a second editor. Oversized dock content has internal scroll access. See [structure corrections and current verification](mac-interface-structure.md). Switching does not change the session context, submit text, recover queues, answer dialogs or stop work. Existing keyboard, shell review, draft-replacement consent and no-replay rules remain in effect.

Tool disclosure choices, code-copy feedback and model/thinking picker input remain mounted across mode changes. Extension widgets keep their above/below-editor positions. Status entries stay in the footer. Standard extension dialogs use the active mode's text and surface colors. Arbitrary extension components remain outside the RPC contract.

## Minimal Desktop workflow

The minimal Desktop implementation intentionally replaces the earlier welcome hero, repeated Files/Commands/Session controls, resource disclosure in the conversation and row Close buttons. The historical checkpoints below describe the earlier implementation, not final verification of these changes. See the [current behavior and verification record](desktop-minimal-ui.md). Native verification passes; normal-app review and user acceptance remain open.

- Files and Pi commands are primary toolbar controls. Session controls are in the Session menu. The header, composer and loaded empty-session hint do not repeat them. New session stays in the toolbar.
- Desktop Session controls show Model and Thinking level first. Details and Advanced start collapsed. Details contains read-only Context/Skills/Prompts from the current snapshot; context paths remain unavailable through RPC. Advanced retains infrequent controls. Desktop omits Cycle buttons; existing cycling actions/shortcuts remain. Settings → Pi and folder access contains Pi version and Pi changelog. Pi's legacy Session form retains version, changelog and Cycle buttons; iPhone controls are unchanged.
- Desktop generic diagnostics show severity/count summaries. View details opens Activity without changing the central destination. Reserved host recovery instructions remain fully visible. Exact legacy mirrors of typed notices, widgets and statuses are excluded from duplicate counts; unmatched legacy notices report unavailable severity. Widgets and footer statuses retain their existing presentation.
- Both Mac modes share a sidebar with workspaces/sessions and a Settings footer, without Pi, Overview or Devices root rows. Conversation and loaded-session aliases select the same session row. Selecting saved history previews only; explicit Open/Reopen activates Pi. Overview is in Actions. Devices is under Settings → iPhone access (optional); the palette retains a secondary direct route.
- Overview starts Closed sessions (count) collapsed. The loaded session stays in the normal group even with stale closed metadata. Closed Overview rows offer Reopen, not disabled Close. Desktop row Close uses context menus; global Close and Command-Shift-W retain the same consent. Pi keeps its sidebar hover Close control, including for the loaded-conversation alias.

## Implementation boundaries

- `MacInterfaceMode.swift` defines the two cases and their colors.
- `CompanionModel.swift` stores only the local preference in the injected `UserDefaults`.
- `CompanionWindow.swift` supplies the native segmented switch and local SwiftUI color scheme. It does not change the app-wide appearance. Desktop restores the inherited scheme after Pi mode.
- `MacDesktopChrome.swift` contains the header, empty-session guidance, read-only Session resources and diagnostic summary. Presentation callbacks use existing routes; resources send no RPC.
- `Apps/Shared/SessionViews.swift` selects the reordered form only for Mac Desktop. Pi and iPhone retain the standard form. `CompanionConnectionViews.swift` supplies Settings routes for Pi version/changelog and Devices.
- `PiConversationView.swift` keeps one dock subtree in a stable overlay. Pi follows a measured content placeholder; Desktop reserves the dock's height outside the history viewport. The editor does not move between view branches.
- `PiEditor.swift` changes native attributes in place. It restores marked-text attributes without replacing characters or ending composition. Native undo/redo completion reconciles the binding when AppKit restores storage without a text-change callback.

Host, shared packages, iPhone, authentication, catalog and RPC formats are unchanged. No preference migration is needed. A rollback can remove these presentation changes without deleting session data or resending input.

## Initial mode checkpoint

The initial two-mode implementation passed **207 Mac tests, 0 failures**, before the later structure corrections. The unsigned Mac build passed. Logs are `/tmp/pi-mac-interface-modes/mac-final-all.log` and `/tmp/pi-mac-interface-modes/mac-final-build.log`. All 30 Mac source/test/project hashes before and after validation match. `git diff --check` passes.

The test log contains hosted `SceneStorage` lifecycle messages, AppKit CA-commit warnings, `linkd.autoShortcut` connection diagnostics, and an AppIntents metadata warning. There are no compilation errors or failed tests. That build had no compiler warnings or errors. These results do not establish live accessibility or normal-launch acceptance.

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

The configured Mac scheme and source lists come from `project.yml`. Generate the ignored Xcode project with `xcodegen generate`. The commands below belong to the initial mode checkpoint. The [isolated test batches](mac-interface-structure.md#repeat-the-complete-mac-checks) document the later structure checkpoint; its legacy combined capture/menu host is order-dependent. See the [minimal Desktop verification record](desktop-minimal-ui.md) for current native test results and open normal-app/user acceptance. Use command-local Xcode selection:

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

Phone, host and shared-package suites were not repeated at the initial Mac-only mode checkpoint. That scope statement does not cover the later minimal Desktop changes to shared app views; see their [verification record](desktop-minimal-ui.md). The Mac scheme includes its existing local/remote model integration checks. No claim is made about a new supported release or full terminal/extension parity. See [the Pi reference](pi-like-mac-reference.md), [extension boundaries](pi-extension-native-display.md) and [earlier UI refinements](mac-reference-uiux.md).
