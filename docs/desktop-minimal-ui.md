# Minimal Desktop workflow

## Status

Implementation and native verification are complete. **Normal-app review, live VoiceOver traversal and user visual acceptance remain open.** Keep the [implementation plan](plans/2026-10-19_desktop-minimal-ui-plan.md) until its remaining checks pass or the user accepts a limit. This is not a release or full UI acceptance claim.

## Behavior

1. **One primary route.** Files and Pi commands stay in the toolbar. Session controls opens from the Session menu. Desktop no longer repeats these actions in its header, loaded welcome or composer. New session stays in the toolbar; the unloaded view retains explicit Resume guidance. Existing shortcuts and secondary menus remain available.
2. **Conversation first.** An empty loaded conversation shows one short input hint instead of the large hero. Context/Skills/Prompts move to Session → Details. Generic diagnostics show typed severity/counts and View details, which opens Activity without changing the conversation. Full notice text stays selectable there.
   - Host-owned recovery instructions remain fully visible, independently of Activity or pending-dialog access. Blocking errors, tool failures, queued work and Stop stay visible.
   - Extension widgets and footer status entries retain their placement. Exact legacy mirrors of typed notices/widgets/statuses are not counted again as unknown diagnostics. Unknown legacy text does not acquire an inferred severity.
3. **Session navigation.** The sidebar contains workspace/session rows and Settings. Both live conversation aliases select the loaded session row. Selecting a saved row previews it; explicit Open/Reopen or the existing session switcher activates it. Overview is in Actions; Devices is under Settings → iPhone access. Duplicate device identity and revocation consent are unchanged.
4. **Compact Session controls.** Desktop puts Model and Thinking level first. Directory, usage and output follow. Details and Advanced start collapsed. Advanced retains export, runtime, lifecycle and command routes. Desktop Cycle buttons are removed; cycling shortcuts remain. Pi version/changelog is in Settings. Pi/iPhone retain their standard form order and controls.
5. **Closed history.** Overview shows the loaded and non-closed sessions first. Closed sessions are under one collapsed count group with explicit Reopen, not disabled Close buttons. Row Close actions use context menus; global Close/shortcut and consent remain. Pi keeps its existing sidebar hover/current-row Close control for both live aliases.

The host, protocol, credentials, pairing, catalog/JSONL formats and single-active-session boundary are unchanged. No setting or feature flag was added.

## Lifecycle and protection

- Inspector changes do not activate a session or redirect the central destination. Files attachment and mutable controls retain their existing context checks.
- Command arguments, pending state and errors are owned above the Advanced disclosure. Collapse/reopen does not reset guards, cancel or replay accepted work. Pending/error feedback remains visible while collapsed. A context generation prevents an old completion from changing a new request's state.
- Close still uses the existing admission and Stop and Close confirmation. Failed Close stays visible; history and drafts remain available for explicit reopen.
- Removed Desktop debug click IDs remain accepted inputs but fail closed when their visible target is absent. They are not redirected. No arbitrary click access was added.
- Commands is an ordinary app panel, but product capture intentionally rejects every non-nil `model.panel`. Private native fixtures inspect Commands and separately verify that this protection remains enforced. Protected normal-app captures are not treated as evidence.

## Original minimal-workflow verification

At that checkpoint, the configured Mac test enumeration contained **366 tests**. Six serialized, disjoint batches reported **365 passed, zero failed and one skipped**. This is not a single-process full-suite pass.

| Batch | Passed | Skipped | Log under `/tmp/pi-minimal-desktop/` |
|---|---:|---:|---|
| Desktop chrome, minimal conversation/Session and command lifetime | 29 | 0 | `final-components.log` |
| Interface structure and native menu/keyboard routes | 18 | 0 | `final-structure.log` |
| Remaining Mac model/editor/IME/mode/files/debug regressions | 245 | 1 | `final-other-mac.log` |
| Minimal navigation, lifecycle and capture matrix | 14 | 0 | `verified-navigation.log` |
| Existing presentation checks, excluding two isolated menu methods | 57 | 0 | `verified-presentation.log` |
| Two legacy native-menu methods in a clean host | 2 | 0 | `verified-legacy-menus.log` |

Matching `*-summary.json` files retain the results. `configured-mac-tests.json` and `coverage-by-selectors.json` match the enumeration to the disjoint batch selectors and result counts. The skip is the pre-existing `MacDebugServerTests.testForeignOwnershipRejectedWhenPrivilegeAllows`; changing a fixture's owner requires root. No privilege escalation or security-check bypass was used.

Additional checks:

- **The full configured iPhone 17 Pro / iOS 26.5 simulator target reports 49 passed, zero failed and one skipped.** Evidence: `verified-phone.log`, `verified-phone-summary.json` and `verified-phone-tests.json`. The pre-existing `LocalHostIntegrationTests.testSimulatorCodingReconnectStopAndHostRestoration` requires an explicitly started provider fixture; it was not started. The earlier six focused checks also pass, including three new Session form tests, draft preservation, old-host-epoch rejection and notice severity/fallback. Native tests verify legacy form order, capability absence, explicit Cycle actions and disabled action buttons. In-process UIKit does not expose the menu Picker's actionable node; its rendered labels/values are checked, not actual menu selection.
- **Seven host Close-confirmation tests pass:** `host-close-xcode.log`. These cover stale work/context, pending dispatch/dialogs and explicit cancellation/Stop behavior.
- **Unsigned Mac and iOS simulator builds pass:** `verified-mac-build.log`, `verified-ios-build.log`. The Mac output is `/tmp/pi-remote-pi-like-mac/Build/Products/Debug/PiRemoteMac.app`.
- Independent complete source review found and verified the recovery and Advanced-state corrections below. No actionable source defect remains in that review.
- `git diff --check` and local documentation path checks pass. The user's staged whitespace-only `Package.swift` change is preserved and excluded from the intended commit.

Tests use the schemes/source lists in [project.yml](../project.yml), generated with XcodeGen. Commands use command-local `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, unsigned builds and disabled native parallel testing. See [configured build checks](native-apps.md#automated-checks). Native test processes must not compete for focus.

## Visual evidence

Private captures under `/tmp/pi-minimal-desktop/captures/` cover Desktop light/dark at 900 × 600, 1104 × 829 and 1300 × 800. All 24 combinations of empty-loaded, unloaded, populated and working/error states were reviewed. They include long titles/drafts, visible input, failed tools, queue/recovery feedback and diagnostic summaries. Overview collapsed/expanded captures verify the seven-row/two-open/five-closed example.

The existing mode captures `pi-dark-conversation-900.png` and `pi-dark-empty-900.png` under `/tmp/pi-mac-interface-structure/captures/` were also compared; Pi retains its terminal-style transcript/resources/footer.

`session-initial-260.png` and `session-initial-320.png` verify Model/Thinking without scrolling. Details/Advanced captures verify the relocated content. The tall Advanced fixture proves native grouping and capability reachability, not minimum-window usability. Conversation captures verify complete recovery text beyond three lines, including when Activity access is blocked by a pending dialog. No images or binaries enter Git.

Native keyboard and accessibility checks cover menu selection, sidebar selection, form labels, selectable diagnostics, disclosure state and disabled guards. Transient AppKit cells can omit SwiftUI IDs initially; tests use exact native roles/values and measured label associations, or rendered-text checks. These checks do not prove spoken VoiceOver traversal.

## Earlier failures and corrections

- Final complete-diff review found that two new artifact helpers assumed `/tmp/pi-minimal-desktop` already existed. They now create it. Focused Session (11) and navigation (14) runs pass with that directory absent at each run's start; original evidence was moved aside and retained. Evidence: `session-clean.log`, `session-clean-summary.json` and the final navigation log/summary. The 29-test component batch also passes after the fix.
- Initial compile/test attempts exposed a missing test import and weak native accessibility lookups. These were corrected without relaxing product debug guards. One synthetic pointer fixture timed out while waiting for mouse-up; fixtures now provide release for both tracking and nontracking controls. The failed logs remain in the temporary evidence directory.
- Nested Form sections inside Advanced produced malformed native grouping and inherited disclosure identifiers. Expanded sections now remain Form-level siblings of the disclosure header.
- Source review found that count-only diagnostics hid required host recovery instructions. Full recovery text is now visible outside the generic summary. Typed status/widget mirrors no longer inflate the unknown-notice count.
- Source review found that conditional Advanced content discarded command input/pending/error state while its task continued. Parent-owned operation state and context-generation checks correct this; continuation-backed native tests verify collapse/reopen, failure, explicit retry and stale completions.
- Pi alias selection initially omitted its current-row Close affordance. Both live aliases now share the same visibility rule.
- Old tests expected Devices in Actions and closed rows always expanded with disabled Close. Tests now verify the approved Settings route, collapsed group and explicit expansion, retaining the status/consent/history assertions.
- An initial host-test command used the system Command Line Tools and could not load Testing macros. The command-local Xcode toolchain passes all seven selected tests; the global developer-tool selection was not changed.

## Debug-banner footer clipping follow-up

A later normal-app capture at 1104 × 829 confirmed that the usage/model/thinking row was partly covered by the debug banner. Sidebar Settings was also below the visible workspace. Earlier capture matrices used debug off and did not cover this state.

`CompanionWindow` now lays out the workspace and debug banner as vertical siblings. Its `GeometryReader` measures only the space above the banner, rather than using the full window height behind a bottom safe-area inset. The banner and its Disable control remain visible; no fixed-height padding or debug-protection change is used.

Verification under `/tmp/pi-footer-clipping/`:

- The new native regression fails before the fix: footer controls overlap the banner by 25 points (`reproduce.log`, `reproduce-summary.json`).
- It passes at 900 × 600, 1104 × 829 and 1300 × 800 while toggling debug on/off/on. Controls remain inside the viewport and above the banner; native editor identity, draft and session state remain unchanged.
- All 41 selected debug-controller, conversation-mode/layout and interface-structure tests pass (`focused.log`, `focused-summary.json`). A test-helper actor annotation was then corrected; the final isolated regression passes without that compiler warning (`final-regression.log`). The unsigned Mac build and `git diff --check` pass. iPhone/host code is unchanged; their suites were not repeated for this layout-only fix.
- Reviewed native captures with debug on at the minimum and reported sizes, and debug off at the reported size. The complete footer and Settings are visible. Six private captures are under `captures/`; no image enters Git.

These corrected captures use private native fixtures. The user's running app was inspected but not stopped or replaced. The corrected build must be relaunched before its normal-app appearance can be verified. This follow-up does not complete the separate user/VoiceOver acceptance gates.

## Remaining acceptance

Normal-app debug was unavailable at the original minimal-workflow checkpoint. It was available for the later clipping report above, but that inspection did not exercise the full revised workflow. The agent did not replace/restart the user's app, submit a prompt or change Pi/network state through debug controls. Continue review after the corrected build is running with user-enabled debug mode.

Normal-app review must still check the primary workflow and relocated controls, including a populated conversation and active/error states where available. Actual provider work, live streaming, full keyboard/VoiceOver traversal and the user's minimalist visual acceptance are not established by private fixtures. Full host/shared-package suites, signed builds and physical-device checks were not repeated. Do not mark these checks passed from the captures above. The active plan remains open.
