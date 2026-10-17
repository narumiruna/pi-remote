# Mac interface and folder-path verification

## Implemented behavior

The Mac companion shows server and session status separately. **Start server** is the primary setup action. Once listening, the window shows its secure address and port and offers **Pair iPhone**. Stopping the server disconnects phones but does not stop Pi work.

**Connection settings** contains Pi executable selection, folder-access controls, paired-device details and an **Advanced** identity-replacement section. Device rows mean saved pairing, not live connections. Live per-device connection status is not available. Revocation requires a separate confirmation.

With no selected session, the window offers **Choose folder and start session** and **Open saved session**. It does not show an inactive composer. A selected empty conversation instead asks for an instruction in that session.

Mac sheets have a bounded viewport based on the parent window, with a visible Close action outside the scrolling content. Grouped forms scroll instead of expanding the sheet to the full intrinsic content height. This fixes the session-controls overflow shown in the reported screenshot.

## Manual Mac folder paths

The directory picker supports typed or pasted paths when the host advertises `directory-path`:

1. Enter an absolute Mac path, `~` or `~/folder`.
2. Select **Go** to open the folder.
3. Review its resolved canonical path and select **Start Pi Here**.

Go never creates a folder, launches Pi or sends a prompt. Editing a path disables session selection until that path is opened. Invalid or pending navigation clears the old selectable folder. Retry uses the exact attempted path, and stale or cancelled responses cannot replace newer navigation.

The authenticated `directoryAtPath` action returns the existing bounded directory page and opaque directory ID. Session launch still uses that ID and revalidates its filesystem identity and permissions. The Mac expands only its own home prefix; it does not invoke a shell or expand environment variables, relative paths, `~otheruser` or shell expressions. Literal spaces and shell punctuation in valid filenames remain literal. Paths over 4,096 UTF-8 bytes or containing NUL are rejected. Existing read/search permissions and symbolic-link handling remain in force. Folder selection is not a tools sandbox.

## Verified checks

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

No provider inference, user credential changes or production-session replay is required for these checks. They do not establish signed installation, physical device behavior, live paired-device connection tracking or complete core shell-control acceptance.
