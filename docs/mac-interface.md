# Mac interface and folder-path verification

## Implemented behavior

The Mac app uses a persistent workspace/session sidebar, a conversation area and an optional Files/Tools/Activity inspector. The native split panes resize independently; the conversation stays wider than either secondary pane. The minimum window is 900 × 600 points. White surfaces, native controls and the existing blue accent remain; there is no theme setting.

Select **Add workspace** to browse, enter a path or use the native folder chooser. Adding a workspace does not start Pi. Select **New session** in that workspace to start a conversation. With no workspace selected, New session offers a directory picker and recent workspaces. Expand a workspace to select a saved session. Full canonical paths identify groups; identical final directory names do not merge unrelated folders. Confirmed Remove workspace hides only the sidebar entry, not files, saved sessions or active work. Re-adding the directory reveals its sessions again.

The header distinguishes server state, authenticated device connections and Pi execution. Local work requires neither listener nor pairing. **Settings** contains network, Pi executable, folder-access and Advanced identity-replacement controls. **Devices** contains pairing, live authenticated connection status and confirmed revocation. Pairing alone does not indicate a live connection. Stopping the listener disconnects phones without stopping Pi.

The backend supports one active Pi child. UI selection is separate from the loaded session. Selecting another saved session while Pi works shows that session's metadata and explains why activation is unavailable; it never shows the active session's messages under another title or stops work implicitly. When idle, opening a session restores its saved conversation through the existing lifecycle APIs, without replaying prompts. An exited session retains displayed output and offers explicit Open session recovery. The composer is disabled when execution is unavailable.

The inspector reuses the paged directory browser, session controls and tool transcript. Files supports directory navigation, relative-path copying and validated Finder reveal. Tools retains model, thinking, usage, runtime settings, export and lifecycle controls. History retains fork/clone inspection. Activity displays actual tool results/errors and notices, not invented durations. Session context menus expose Open, ID copy and loaded-session rename/history actions. No session deletion action is added because its semantics are not defined.

Workspace visibility, expansion, selected metadata and inspector visibility use existing local preferences. Sidebar/inspector widths and sidebar visibility use scene storage. Unsent drafts are saved per session with a 400 ms debounce and shutdown flush, limited to 256 KiB each and 8 MiB total; an oversized draft stays in memory with a copy-before-close warning. No credentials enter these stores. Restored UI selection does not automatically start Pi. Command-N creates a session; Command-Option-S and Command-Option-I toggle the sidebar and inspector.

Mac sheets have a bounded viewport based on the parent window, with a visible Close action outside the scrolling content. Grouped forms scroll instead of expanding the sheet to the full intrinsic content height. This fixes the session-controls overflow shown in the reported screenshot.

## Local Pi runtime discovery

A GUI-style PATH reproduced the reported launch failure: `/usr/bin/env` could not find Node.js, although Pi worked in the terminal. The terminal used an fnm multishell path that the app did not inherit.

The host now checks the Pi executable directory, existing Homebrew/PATH entries and installed fnm default aliases, including `FNM_DIR` when inherited. It uses stable defaults, not arbitrary installed versions or expiring multishell directories. Existing PATH entries take precedence over the fnm fallback. It does not execute shell startup files, install software or change the user's environment, account or certificates.

Missing Node.js and failed Pi startup have specific errors rather than the connection-unavailable message. An explicit session retry clears the previous local launch fault. Local Pi use does not require the network server.

Focused verification: four runtime-discovery/error regressions pass; the installed-Pi missing-credential probe passes under `/usr/bin/env -i` with a minimal system PATH and no real credentials or provider inference. The local Mac model test also verifies failed-launch recovery, session creation, Send and Stop before a listener starts. Evidence: `/tmp/pi-remote-launch-focused.log`, `/tmp/pi-remote-launch-installed-pi.log` and `/tmp/pi-remote-launch-local-model-3.xcresult`. No broad UI suite or simulator was run. The open Xcode project and `project.yml` hashes stayed unchanged. Confirmation of the rebuilt app's normal GUI flow remains open.

## Manual Mac folder paths

The directory picker supports typed or pasted paths when the host advertises `directory-path`:

1. Enter an absolute Mac path, `~` or `~/folder`.
2. Select **Go** to open the folder.
3. Review its resolved canonical path and select **Start Pi Here**.

Go never creates a folder, launches Pi or sends a prompt. Editing a path disables session selection until that path is opened. Invalid or pending navigation clears the old selectable folder. Retry uses the exact attempted path, and stale or cancelled responses cannot replace newer navigation.

The authenticated `directoryAtPath` action returns the existing bounded directory page and opaque directory ID. Session launch still uses that ID and revalidates its filesystem identity and permissions. The Mac expands only its own home prefix; it does not invoke a shell or expand environment variables, relative paths, `~otheruser` or shell expressions. Literal spaces and shell punctuation in valid filenames remain literal. Paths over 4,096 UTF-8 bytes or containing NUL are rejected. Existing read/search permissions and symbolic-link handling remain in force. Folder selection is not a tools sandbox.

## Workspace redesign verification

Current focused checks pass:

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
