# Mac inspector review corrections

## Behavior

The debug-mode review found six issues in Files, Session and Activity. The implementation changes only native presentation and debug inspector selection. It does not change RPC, authentication or session storage.

1. Files uses neutral full-width Mac rows instead of bordered blue file buttons. File preview, folder navigation and path/Finder context actions remain available.
2. Non-selecting Mac Files uses one navigation row: parent, resolved folder, Edit path and More actions. More actions contains Copy full path, Show hidden files and Full path. Folder selection still shows the resolved canonical path before session or workspace creation.
3. Non-selecting Mac Files hides dotfiles by default. Show hidden files applies to the current browser. Filtering does not remove error rows or pagination. An all-hidden page explains the filter instead of claiming that the folder is empty. Changed page/filter rows reset the native list position so this explanation remains visible.
4. Session shows the selected saved session's name, directory and Saved / Not loaded state. If another session is loaded, it shows that session separately and offers View active session. Empty states use compact text.
5. Activity can open without a loaded session and explains the requirement. It does not load saved activity or start Pi. A loaded session without tools shows No tool activity yet.
6. Switching Files, Session or Activity does not change the central destination. Files follows the selected workspace/session directory, or the loaded directory on global pages. Activity is explicitly labeled Loaded session activity and names its session and directory. View active session is the explicit navigation action. Mutable Session controls remain available only while viewing the loaded conversation.

The iPhone directory browser keeps its existing controls and hidden-file behavior. The Mac folder-selection flow keeps its canonical-path review and unresolved-path selection guard.

## Verification

All **48 focused Mac tests pass in three serialized batches**, with zero failures or skips. Unsigned Mac and iOS simulator builds pass. Final logs contain no compiler warnings or errors. This is not a full-suite run.

| Check | Passed | Evidence under `/tmp/pi-mac-inspector-review/` |
|---|---:|---|
| `MacInterfaceStructureTests`, `MacDebugInteractionTests` | 36 | `verified-context.log`, `verified-context-summary.json` |
| Seven existing inspector/folder presentation regressions | 7 | `verified-presentation.log`, `verified-presentation-summary.json` |
| `MacFilesInspectorTests` | 5 | `verified-files.log`, `verified-files-summary.json` |
| Unsigned Mac build | — | `verified-mac-build.log` |
| Unsigned iOS simulator build | — | `verified-ios-build.log` |

The seven presentation methods are `testSessionControlsRemainScrollableInANarrowInspector`, `testFolderPathEditorNavigatesOnlyAndBlocksSelectionAfterFailure`, `testFolderParentAndCopyUseResolvedPaths`, `testCompactFolderNavigationAtInspectorWidths`, `testReviewSessionInspectorLabelsAndCloseControlAtBothSizes`, `testSecondaryToolbarKeepsChatAndOpensSingleFilesInspectorDestination` and `testUsabilityDiagnosticsSummaryAndInActivity`.

Checks use the `PiRemoteMac` scheme from `project.yml`, generated with `xcodegen generate`, with `platform=macOS,arch=arm64`, disabled parallel testing and unsigned builds. The iOS build uses `PiRemote`, `iphonesimulator` and `generic/platform=iOS Simulator`. See [configured build commands](native-apps.md#automated-checks).

Native checks cover unchanged destination, host snapshot and draft across tab changes; explicit navigation; saved-only and loaded-session metadata; typed Activity outcomes; full-width rows and readable folder identity at 260/320 points; menu path copying; hidden-file filtering; visible access faults; Retry and cached pagination; filtered-empty pixels; canonical-path review at both scroll ends; preview/content/Done and repeated ordinary preview; native context-menu labels; and arrow/Return navigation without session creation.

Final captures under `captures/` were reviewed for Files at 260/320 points, the filtered-empty explanation, saved Session/Activity at 900/1104-point window widths and loaded Session/Activity at 1104 points. The filtered-empty check includes an OCR assertion that the first line remains visible. Independent final source review found no actionable defects. `git diff --check` passes and all 98 local documentation paths in the affected documents exist. The unrelated `Package.swift` edit remains unchanged.

### Earlier failures and limits

Earlier runs exposed missing in-process accessibility nodes, a native menu label/identifier gap, a folder breadcrumb clipped at 260 points and a retained native-list offset that hid the start of the filtered-page message. Native List hosting, label semantics, compact controls and list identity corrected these issues. Final assertions retain the corresponding behavior and pixel checks.

A mixed native test attempt also overlapped two test processes and produced menu focus/tracking failures. Final UI batches run serially. The synthetic context-menu-cancellation-then-sheet sequence remains order-dependent in the private host, even with dismissal waits. Tests retain all acceptance checks by exercising repeated ordinary preview before native context tracking, then folder/parent navigation. The preview sheet and path-change implementation are unchanged. No product preview fix is claimed for that fixture limit.

The initial review used the opted-in normal app in Desktop mode at 1104 × 829. It had a saved session but no loaded session. Debug captures verified the original Files and Session states; Activity correctly rejected selection in that older build. These captures are not evidence for the new implementation.

Hosted fixtures use private state and do not connect to a provider or start iPhone access. No captures enter Git. The [active plan](plans/2026-10-19_mac-inspector-review-plan.md) stays open for the remaining live loaded-session acceptance checks.

## Normal-app debug-mode check

The running opted-in app showed the revised UI on 2026-10-18, 17:45:40–17:47:04 UTC. No rebuild, process replacement or restart was needed during this check. The window was 1104 × 829 with one saved session selected and no loaded session. The listener was off, the phase was idle, and message/dialog counts were zero.

Verified through the registered debug tools and app-only captures:

- Files shows neutral full-width rows, one compact navigation row and no dotfiles by default. The folder name and edit/more icons remain visible.
- Session shows the selected saved session's name, working directory and Saved / Not loaded status, with compact explanatory text.
- Activity now accepts selection without a loaded session. It retains saved-session metadata and explains that activity requires an opened session.
- All three states were reviewed in Desktop and Pi modes. Central selection and the open-saved-session screen stayed unchanged across tab and mode changes.
- The native allowlisted inspector toggle hides the pane. The native toolbar Files control restores it without changing the central destination.
- The app was restored to Desktop/Files. The complete bounded status matches its starting value. No Pi, prompt, listener or dialog-answer actions were dispatched.

Evidence: `/tmp/pi-mac-inspector-review/live-debug-summary.json` and debug captures in the tool history. The Files capture immediately after switching in Pi mode showed loading; a later capture at 17:46:28 UTC verified the populated list. These are app-content captures, not physical desktop-input or window-chrome checks.

Not verified in this normal-app pass:

- Loaded Session controls, actual tool Activity and context changes while another session is loaded: no loaded session was present. A user must open a session before these checks can continue; debug controls cannot start Pi.
- More actions, hidden-file toggling, path copying/editing and file previews: the current native-click allowlist does not expose these controls. Their earlier native-fixture evidence still applies, but is not normal-app evidence.
- Live window resizing, physical pointer/keyboard traversal, VoiceOver and provider operation.

No new visual defect was found in the available saved-session states. This check does not establish full UI acceptance.
