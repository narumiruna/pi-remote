# Mac interface and folder-path verification

## Implemented behavior

The Mac app uses a persistent workspace/session sidebar, a conversation area and an optional Files/Tools/Activity inspector. The native split panes resize independently; the conversation stays wider than either secondary pane. The minimum window is 900 × 600 points. White surfaces, native controls and the existing blue accent remain; there is no theme setting.

Use **Workspaces + → Add workspace** to browse, enter a path or use the native folder chooser. Adding a workspace does not start Pi. Select the workspace, then use the toolbar's **New session** action or the workspace context menu. There is no standalone New session row under each workspace. Import is in **Workspaces +**; Devices and Settings remain pinned below the scrolling workspace list. With no workspace selected, New session offers a directory picker and recent workspaces. Expand a workspace to select a saved session. Full canonical paths identify groups; identical final directory names do not merge unrelated folders. Confirmed Remove workspace hides only the sidebar entry, not files, saved sessions or active work. Re-adding the directory reveals its sessions again.

The toolbar has one compact **iPhone access** summary; off means remote connections are disabled, not that local Pi is unavailable. Select it to read listener state, authenticated device connections and the secure endpoint, or to open Settings/Devices. The displayed session header shows Pi execution; other destinations keep active-session status in the global header. Pi version is available in Settings and session controls, not the global header. Local work requires neither listener nor pairing. **Settings** contains network, Pi executable, folder-access and Advanced identity-replacement controls. **Devices** contains pairing, live authenticated connection status and confirmed revocation. Pairing alone does not indicate a live connection. Stopping the listener disconnects phones without stopping Pi.

The backend supports one active Pi child. UI selection is separate from the loaded session. Selecting another saved session while Pi works shows that session's metadata and explains why activation is unavailable; it never shows the active session's messages under another title or stops work implicitly. When idle, opening a session restores its saved conversation through the existing lifecycle APIs, without replaying prompts. An exited session retains displayed output and offers explicit Open session recovery. The composer is disabled when execution is unavailable.

The inspector reuses the paged directory browser, session controls and tool transcript. Files is the single Mac file-browser destination; the composer shortcut opens that inspector without replacing Chat. The conversation tabs contain Chat and History. Files supports directory navigation, relative-path copying and validated Finder reveal. A dedicated Commands sheet opens directly from the composer and shares command arguments, dispatch and error handling with session controls. Tools retains model, thinking, usage, runtime settings, export and lifecycle controls. History retains fork/clone inspection. Activity displays actual tool results/errors and notices, not invented durations. Session context menus expose Open, ID copy and loaded-session controls/history actions. The loaded, idle session also has a direct **Rename** sheet using the existing scoped Pi rename action. Saved sessions must be opened before renaming; no local alias store is added. No session deletion action is added because its semantics are not defined.

Workspace visibility, expansion, selected metadata and inspector visibility use existing local preferences. Sidebar/inspector widths and sidebar visibility use scene storage. Unsent drafts are saved per session with a 400 ms debounce and shutdown flush, limited to 256 KiB each and 8 MiB total; an oversized draft stays in memory with a copy-before-close warning. No credentials enter these stores. Restored UI selection does not automatically start Pi. Command-N creates a session; Command-Option-S and Command-Option-I toggle the sidebar and inspector.

Mac sheets have a bounded viewport based on the parent window, with a visible Close action outside the scrolling content. Grouped forms scroll instead of expanding the sheet to the full intrinsic content height. This fixes the session-controls overflow shown in the reported screenshot.

## Mac usability refinement verification

The Mac refinement keeps the existing architecture and light appearance:

- Session rows and the header use display labels, not rewritten persisted names. Priority is a non-default stored name, a confirmed Pi JSONL name, the first meaningful textual user instruction, then a stable session ID. An explicit Pi name equal to the workspace basename is retained when confirmed by metadata. Blank/image-only messages do not become labels. Labels are bounded to 70 characters, with stable suffixes for all same-workspace collisions, including collisions with generated labels. Middle truncation keeps distinguishing suffixes visible; tooltips expose the longer label, path and session ID.
- A local-only host API reads coordinator-owned JSONL files without activating Pi. It opens every path component with no-follow descriptors and validates the managed session header on the same descriptor used for parsing and cache lookup. A scan reads at most 2 MiB; a cache hit rereads at most 64 KiB for header validation. Metadata strings are bounded to 4,096 UTF-8 bytes. The identity/size/mtime cache retains at most 256 entries; five-minute expiry is checked on metadata reads. A partial scan can supply a first instruction but never a confirmed latest name. Missing, invalid, inaccessible or symlink-redirected files use the stable fallback. Names and prompt previews are not routine diagnostics or new persisted fields.
- UI reads are asynchronous and publish per-session results. Unchanged reads continue when another session changes. A cached, workspace-scoped label map avoids repeated whole-catalog scans for each row. The complete live transcript can provide an instruction before the first file update; a bounded transcript with older messages cannot claim its first visible message is the session's first instruction.
- The toolbar has one prominent New session action. Workspace menus provide contextual creation, Add workspace and Import. Devices/Settings use a separate pinned native list. Session selection/expansion, busy activation rejection and draft persistence remain.
- The compact header shows the session title, workspace/model/thinking metadata, actual Pi lifecycle status and Conversation/History tabs without a visible Session view label. The overflow menu contains controls, Rename, Commands, Files, diagnostics and path copy. The full working directory remains in tooltips and session controls.
- Mac messages use a bounded readable width and 15-point system text. Tool results, thinking, Markdown, code, images, errors and copy remain available. The composer is a native multiline TextEditor with a 76–180-point viewport, a subtle border and labelled Files/Commands/Stop/Send controls. Return inserts a newline; Command-Return sends. Empty/whitespace, unavailable and pending Send are disabled. Steering/follow-up remains explicit while working. There is no nonfunctional Attach control; Files retains preview-based text attachment.
- Extension notices move to Activity. They are not removed, and faults/dialogs remain visible through their existing recovery and request paths. Opening, unavailable and load-failure views retain next actions without claiming readiness. Empty workspaces direct the user to New session in the toolbar.

Verified results:

- All 35 Mac tests pass, with zero failures/skips: `/tmp/pi-remote-usability-final-35.xcresult`, log `/tmp/pi-remote-usability-final-35.log`. A saved-session fixture starts with three identical raw names and real private JSONL files. It verifies instruction-based labels and an image-only ID fallback, unchanged catalog/JSONL bytes and no Pi activation. Other tests cover name precedence/collisions, native sidebar selection, pinned navigation, rename scope and explicit display-name refresh when a confirmed name equals the old directory fallback. Composer typing, Return/newline, Command-Return dispatch, measured growth within 76–180 points, empty Send, busy controls, diagnostics, starting/stopping/recovery/input-wait states, loading/error states, stale actions, draft persistence and no replay also pass.
- All 16 focused host metadata/history tests pass: `/tmp/pi-remote-usability-host-verified.log`. They cover partial scans, cache invalidation, bounded reads, blank/image-only input, managed-header validation before cache access, foreign-file replacement, symlink-parent rejection before reading any bytes, and unchanged session files/state without starting Pi.
- Unsigned Mac and iOS simulator builds pass: `/tmp/pi-remote-usability-mac-build-final.log` and `/tmp/pi-remote-usability-ios-build-final.log`.
- All three focused iPhone 17 Pro, iOS 26.5 UI checks pass with zero failures/skips: keyboard/Stop/draft, directory/Commands/editor access and Mac-file preview/attachment. Commands, result bundles and four captures are in `/tmp/pi-remote-usability-phone/run-20261017-191124-qARJVV/`. No retired compact-device or broad E2E matrix was run.
- Parent review confirms 900 × 600 and 1300 × 800 layouts, real saved-instruction labels, readable headers, the bounded composer, complete busy controls at a 400-point conversation width, and Activity diagnostics. Captures are in `/tmp/pi-remote-mac-ux-captures/usability-*.png`; the saved-name examples are `usability-saved-instruction-names-900.png` and `usability-saved-instruction-names-1300.png`. Shared capture filenames are refreshed by later tests, not immutable historical artifacts.
- `project.yml` and `PiRemote.xcodeproj/project.pbxproj` retain their pre-change hashes. No project regeneration, protocol fields, catalog/JSONL format, pairing, TLS or lifecycle changes were required.

Repeat checks with the existing Mac commands below. For host coverage, run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --no-parallel --filter 'displayMetadata|localDisplayMetadata|history'`.

Failures and limits:

- The initial vertical TextField did not insert a newline on Return. It was replaced with TextEditor; real native key-event assertions now pass. Command-Return tests use the native window key-equivalent path. The first greedy height constraint also reserved the maximum editor size for short text; measured, bounded growth replaced it. A busy narrow capture revealed a truncated Commands label; smaller native controls and a separate delivery row resolve it.
- Transient empty states now distinguish starting, stopping, uncertain recovery and waiting for input, rather than incorrectly asking the user to reopen Pi. Hosted ContentUnavailableView text is not exposed through this AX harness; tests verify its presentation values and disabled Send, and parent review checks the rendered captures.
- Hosted AX identifiers can propagate through SwiftUI containers. Tests use native controls, public accessibility selectors and visible labels where necessary; the composer now has a containing accessibility group. Transient scanner compilation and fixture-path failures were corrected. Final pass results above include the corrections.
- A rename to the existing directory fallback can leave the raw catalog title unchanged. Confirmed Rename now forces a local metadata refresh; the model test first waits for the old hint cache, then verifies the accepted Pi name. The test fixture initially tried to extract a JSON scalar with `plutil`, which does not support that format; its controlled UUID-name read-back was corrected. The failed bundle is retained at `/tmp/pi-remote-usability-mac-verified.xcresult`.
- The metadata implementation was reviewed for descriptor races, refresh starvation and generated-name collisions. The final implementation uses one validated descriptor, incremental refresh, bounded collision resolution and cached label lookup; regression tests cover the corrected cases.
- These are controlled hosted/model/file-fixture checks. Live Accessibility and Screen Recording preflight checks remain false. The running debug app and privacy permissions were not changed. Normal GUI startup, real-provider operation, live system colors/contrast and full VoiceOver/keyboard-only navigation remain unverified. This checkpoint does not close the separate normal-launch gate.

## UI/UX correction verification

The five reviewed corrections are implemented: direct Commands access, one Files destination, native Mac density, consolidated header status and compact folder navigation.

Earlier focused results, before the usability refinement above:

- All 22 Mac tests pass with zero failures/skips in `/tmp/pi-remote-uiux-mac-final.xcresult`. Tests exercise rendered Commands/Files actions, the real Commands sheet, command arguments and error display, immediate duplicate activation while a request is pending, busy/missing-session restrictions, stale-context rejection, independent remote-access states, the remote-details popover and folder edit/Go/failure/recovery/explicit selection. Parent navigation and canonical-path copying also pass with an isolated pasteboard through the existing clipboard-writer environment; the user's clipboard is unchanged. Existing local Send/Stop, busy-switch, draft persistence and no-replay checks also pass.
- The final unsigned Mac and iOS simulator builds pass. Logs: `/tmp/pi-remote-uiux-mac-build-final.log` and `/tmp/pi-remote-uiux-ios-build-final.log`.
- Parent review confirms the Commands sheet has visible commands without Tools scrolling and a pinned Close action. Updated 900 × 600 and 1300 × 800 workspace captures retain the conversation and composer; the 260/320-point folder inspectors retain navigation and file-list space. Tools still scrolls with native row sizes. Captures: `/tmp/pi-remote-mac-ux-captures/uiux-*.png`, `active-workspace-minimum.png`, `active-workspace-session.png`, `busy-workspace-minimum.png` and `session-tools-inspector.png`.
- On iPhone 17 Pro, iOS 26.5, the unsigned product build and all nine directory-browser model tests pass. Three focused UI tests pass for keyboard/Stop/draft, Commands/editor access and file preview/attachment. The typed-path UI test passes separately after migration to the active 402 × 874 viewport and explicit Select All input replacement. All path, no-start-on-Go, recovery, explicit-start and 44-point checks remain. Evidence: `/tmp/pi-remote-uiux-iphone-evidence/{build,directory-model,interface,path-select-all}.xcresult`. Parent review confirms the complete path error and keyboard captures in `path-captures/`.
- `project.yml` and `PiRemote.xcodeproj/project.pbxproj` retain their pre-change SHA-256 hashes. No project regeneration, signing change, broad UI/E2E run or inactive compact-device run was used.

Repeat the Mac checks from the repository root:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodebuild -quiet -project PiRemote.xcodeproj -scheme PiRemoteMac \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/pi-remote-mac-ux -parallel-testing-enabled NO \
  -resultBundlePath /tmp/pi-remote-uiux-mac-repeat.xcresult \
  CODE_SIGNING_ALLOWED=NO test
xcodebuild -quiet -project PiRemote.xcodeproj -scheme PiRemoteMac \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/pi-remote-mac-ux CODE_SIGNING_ALLOWED=NO build
```

Use a new result-bundle path for each run. The phone commands and initial results are in `/tmp/pi-remote-uiux-iphone-evidence/commands.sh`; the final path run uses the same interface scheme, destination and derived data with only `DirectoryPathInterfaceTests/testTypedPathNavigationInvalidPathRecoveryAndExplicitStart` selected.

Verification limits and failures:

- Hosted SwiftUI AX nodes were initially absent, and the first test build used the wrong accessibility protocol type. The final harness enables the public SwiftUI accessibility environment and performs a hit test before traversal. It reads synthetic nodes through public Objective-C accessibility selectors. Grouped Forms can replace child identifiers; tests use visible labels where necessary. The real Commands sheet is checked through its title, native editable field, routing state and capture; a direct command fixture verifies dispatch. No privacy permission or production accessibility setting changed.
- The original phone path run stopped at an obsolete 375 × 667 assertion. After the viewport correction, triple-tap replaced only part of the path. Explicit Select All fixes the test input; the exact field-value assertion and all safety checks remain. Failed runs are retained in `interface.xcresult` and `path-primary.xcresult`.
- Breadcrumb-menu selection remains a manual check. Two attempts inspected an unopened, lazily populated menu; a native tracking attempt then reached the 300-second command timeout. Those failures are retained under `/tmp/pi-remote-uiux-mac-folder-actions*`. The final test verifies parent navigation and isolated copying without opening a tracking menu; it does not claim ancestor-selection coverage.
- Native key events verify text-field focus and input. These checks do not establish full keyboard-only navigation, VoiceOver behavior, live colors or contrast. AppKit foreground caches establish layout only.
- Normal app launch remains unverified. An existing companion was running under Xcode, and the agent process reported `AXIsProcessTrusted() == false`. That instance and privacy permissions were left unchanged. Close the existing instance, launch the rebuilt app normally, and verify local folder selection, installed Pi startup, Send/reply and Stop without a listener or phone pairing. Keep this check open until observed.

## Local Pi runtime discovery

A GUI-style PATH reproduced the reported launch failure: `/usr/bin/env` could not find Node.js, although Pi worked in the terminal. The terminal used an fnm multishell path that the app did not inherit.

The host now checks the Pi executable directory, existing Homebrew/PATH entries and installed fnm default aliases, including `FNM_DIR` when inherited. It uses stable defaults, not arbitrary installed versions or expiring multishell directories. Existing PATH entries take precedence over the fnm fallback. It does not execute shell startup files, install software or change the user's environment, account or certificates.

Missing Node.js and failed Pi startup have specific errors rather than the connection-unavailable message. An explicit session retry clears the previous local launch fault. Local Pi use does not require the network server.

Focused verification: four runtime-discovery/error regressions pass; the installed-Pi missing-credential probe passes under `/usr/bin/env -i` with a minimal system PATH and no real credentials or provider inference. The local Mac model test also verifies failed-launch recovery, session creation, Send and Stop before a listener starts. Evidence: `/tmp/pi-remote-launch-focused.log`, `/tmp/pi-remote-launch-installed-pi.log` and `/tmp/pi-remote-launch-local-model-3.xcresult`. No broad UI suite or simulator was run. The open Xcode project and `project.yml` hashes stayed unchanged. Confirmation of the rebuilt app's normal GUI flow remains open.

## Manual Mac folder paths

The directory picker supports typed or pasted paths when the host advertises `directory-path`:

1. On Mac, select **Edit path**. On iPhone, the path field is already visible.
2. Enter an absolute Mac path, `~` or `~/folder` and select **Go** to open the folder.
3. Review its resolved canonical path and select **Start Pi Here**.

Mac Files uses a compact resolved-folder breadcrumb with ancestor navigation, a parent action and **Copy full path**. **Full canonical path** expands selectable path text. Folder-selection sheets always show the resolved canonical path for review; long paths scroll horizontally within a bounded row. Mac controls use native sizes; iPhone controls retain their 44-point minimum touch targets.

Go never creates a folder, launches Pi or sends a prompt. Editing a path disables session selection until that path is opened. Invalid or pending navigation clears the old selectable folder. Retry uses the exact attempted path, and stale or cancelled responses cannot replace newer navigation.

The authenticated `directoryAtPath` action returns the existing bounded directory page and opaque directory ID. Session launch still uses that ID and revalidates its filesystem identity and permissions. The Mac expands only its own home prefix; it does not invoke a shell or expand environment variables, relative paths, `~otheruser` or shell expressions. Literal spaces and shell punctuation in valid filenames remain literal. Paths over 4,096 UTF-8 bytes or containing NUL are rejected. Existing read/search permissions and symbolic-link handling remain in force. Folder selection is not a tools sandbox.

## Workspace redesign verification

The earlier workspace-redesign checks passed before the UI/UX corrections above:

- All 12 Mac tests pass, with zero failures/skips, in `/tmp/pi-remote-workspace-final-14.xcresult`. Model checks cover canonical grouping, same-basename directories, add without process creation, sidebar-only removal, missing/inaccessible paths, saved selection/expansion/inspector preferences, local Send/Stop before listener startup, shared paired-client state, authenticated connection tracking/revocation, busy activation rejection, history restoration without replay, stale actions and per-session drafts. A reconstructed model restores a draft from persisted preferences and a private catalog copy.
- Native hosted-view checks select actual workspace/session rows through `NSOutlineView` and click the rendered Inspector control. Active captures at 1300 × 800 and 900 × 600 points show all three panes and the complete composer. A busy-workspace capture at 900 × 600 keeps Stop and Active session visible; narrow windows put status on a second header row. Tools scroll in a 320-point inspector. Folder sheets remain bounded with Close visible. Captures are in `/tmp/pi-remote-mac-ux-captures/`; AppKit foreground caches verify layout, not exact system colors or contrast.
- All 142 root tests pass using `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --no-parallel`; evidence is `/tmp/pi-remote-workspace-root-final.log`. These include streaming ordering/bounds, session restoration, connection recovery, authentication, revocation and no replay.
- The unsigned iOS simulator build passes using scheme `PiRemote`, destination `generic/platform=iOS Simulator` and derived data `/tmp/pi-remote-workspace-ios`. Evidence: `/tmp/pi-remote-workspace-ios.log`. No phone simulator, compact suite or broad E2E matrix was run for this redesign.
- Both `PiRemote.xcodeproj/project.pbxproj` and `project.yml` match the pre-change SHA-256 record. No XcodeGen regeneration or signing-setting change was made.

Verification failures were investigated rather than suppressed. The initial fake Pi parsed escaped JSON paths with shell text matching, which lost saved history; it now decodes the core sessionPath using `plutil`. The restart fixture also needed the core `--session` launch argument. Initial native split navigation placed the inspector over conversation content; the final `HSplitView` gives each pane its own space. Offscreen SwiftUI accessibility export did not expose logical rows, and macOS denied screen capture; native outline selection, mouse events and AppKit layout caches provide the focused alternative without changing privacy permissions. A root run used an incompatible Command Line Tools macro plugin; the explicit Xcode toolchain works. Two old missing-executable assertions expected a generic connection error; they now require the specific `piLaunchFailed` error from the earlier runtime fix. Final passing results above include these corrections.

These are controlled model, native hosted-view and build checks, not a normally launched real-provider workflow, signed installation or a full iPhone runtime retest. The existing one-child limit and bounded history/output remain. The unrelated core shell-control plan remains incomplete.

## Earlier folder-path checks

These are results from the earlier verification work. The user has since removed iPhone SE/PiRemoteCompact from the active matrix and deferred broad UI/E2E runs during early development. Do not repeat these suites as a routine development gate. Normal Mac launch and basic local Pi operation remain the priority; these model/layout results do not prove that workflow works.

- All 138 root tests pass with explicit serial scheduling, normally and with Thread Sanitizer. New cases cover canonical direct paths, aliases, spaces/literal shell punctuation, home prefixes, malformed/missing/non-directory/loop targets, read-only typed protocol round trips and lookup without starting Pi. Production TLS tests reject unauthenticated direct-path requests.
- All 50 shared-package tests pass normally and with Thread Sanitizer.
- All 11 Mac tests pass with no failures or skips. Eight presentation cases cover independent server/session status, stopped/listening empty states, an active session, paired-access settings, large-text environment input and real folder/control sheet bounds. The controls test finds the form's scroll viewport and scrolls toward its lower controls. The existing model tests still cover approval, persistence, revocation and shared local/remote control.
- Layout captures were reviewed for the minimum 540 × 560-point window, 700 × 680-point large-text environment input, 900 × 720-point active state, connection settings and the actual bounded sheets. AppKit foreground caches are composited over an opaque white background for layout review. They are not evidence of system-material colors, contrast or all-size macOS text scaling.
- All nine phone directory-browser model tests pass with no failures or skips on the dedicated iPhone SE simulator. New cases cover exact typed-path retry, stale replies after new navigation and cancellation without enabling selection.
- Two focused compact-interface tests pass with no failures or skips at 375 × 667 points and accessibility-extra-large text. A separate Herdr Pi agent verified typed tilde/absolute paths, Go without session creation, invalid-path clearing, disabled selection for edited paths, recovery and explicit Start with the canonical directory. The existing folder/editor real-keyboard regression also passes. Parent review confirmed the final keyboard, complete error and recovered-folder captures. These are focused checks, not a rerun of the complete product or interface suites.

Evidence:

- `/tmp/pi-remote-mac-ux-root-2.log`
- `/tmp/pi-remote-mac-ux-root-tsan-2.log`
- `/tmp/pi-remote-mac-ux-shared.log`, `/tmp/pi-remote-mac-ux-shared-tsan.log`
- `/tmp/pi-remote-mac-ux-summary-release-check.json`, `/tmp/pi-remote-mac-ux-tests-release-check.xcresult`
- `/tmp/pi-remote-mac-ux-captures/`
- `/tmp/pi-remote-directory-path-15WUrV/final2-summary.json`, `final2.xcresult`, `final2-captures/`
- `/tmp/pi-remote-directory-path-15WUrV/browser-model-summary-parent.json`, `browser-model.xcresult`
- `/tmp/pi-remote-directory-path-15WUrV/REPORT.md`, `FINAL2-REVIEW.md`, `final2-cleanup.log`

## Failures and limits

The first capture harness allowed NSHostingView to resize its hidden window to intrinsic content height. Four frame assertions failed. The harness now uses an explicitly sized hosting viewport and verifies actual presented sheet bounds. Initial transparent foreground captures were not accepted as visual proof; final layout captures use explicit opaque compositing. Close is pinned inside the sheet content, not dependent on an external toolbar capture.

One root sanitizer run overlapped a fresh simulator build and had five startup issues in two existing fixture tests. A later full serial run passes all 138 tests without changing process deadlines or assertions. The failed run remains in `/tmp/pi-remote-mac-ux-root-tsan.log`.

The first phone UI attempts failed because the test did not replace the whole field value, did not reliably reach Select All or counted both a session row and its navigation title. One run reported an older replacement helper; the cause was not established. The final test replaces the full field through native triple tap and scopes the catalog count to collection-view rows; semantic checks remain. Earlier bundles and failure records remain in the worker artifact directory. Parent capture review then found real helper/error truncation despite the passing assertions. The helper is now short and vertically fixed; errors are inside the scrolling list. Both UI cases pass again in `final2.xcresult`, and the final error capture shows the complete message without an ellipsis.

No provider inference, user credential changes or production-session replay is required for these checks. They do not establish signed installation, physical device behavior, complete core shell-control acceptance. Live authenticated-device tracking now has the separate workspace-checkpoint evidence above.
