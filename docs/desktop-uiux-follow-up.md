# Desktop UI/UX follow-up verification

## Outcome

All five findings from the 2026-10-18 Desktop review are corrected. This checkpoint covers those findings, not full product acceptance. It does not change the shared protocol, iPhone UI, session ownership or credential format.

| Finding | Correction | Evidence |
| --- | --- | --- |
| Visible native debug targets returned `target_unavailable` | The product exposes its SwiftUI accessibility tree while debug is enabled. System accessibility remains enabled when required independently of debug. No global permission is requested. | Both failures were reproduced in the running app. Sidebar and Pi commands now pass through the registered extension in a separately launched product-source app, without a hosted accessibility override. |
| Closed saved rows offered Close | Overview offers Reopen and disables Close with a reason. Shared presentation guards also protect contextual/header/menu routes. Core Close retries remain idempotent. | Three new session-action tests and existing model/structure close, confirmation, stale-target, draft and reopen regressions pass. |
| Duplicate device names were indistinguishable | Collapsed duplicate-name rows include the full existing UUID. Revocation confirmation identifies the captured name and UUID; removed or changed targets are rejected. | Seven private device tests include IDs with matching first 35 characters, reordered rows, dismissal-before-action, Cancel, removal, changed names and chosen-device-only revocation. Existing integration coverage also verifies that revocation leaves a working private Pi child running. |
| Executable guidance treated an idle child as available | A local coordinator readiness stream derives availability from child, mutation, utility and shutdown ownership. An idle child requires explicit Close, not just Stop. Settings links to existing session controls. | Seven Mac tests and eight host tests cover idle, work, startup, stop, mutation/utility cleanup, picker-open races, cancellation, shutdown and child-free unavailable/interrupted metadata recovery. |
| Sidebar width changed after hide/show | A sidebar-local AppKit marker restores the preferred width. Only native divider dragging saves it; temporary split allocation does not. | A private before-fix fixture reproduces 235 → 210 points at fixed 1104 × 829. Nine native tests pass for drag, repeated navigation/toggle, constraints, invalid preferences, restart and observer/monitor cleanup. |

## Safety and lifecycle

- Native clicks retain fixed targets, window ownership, visible/enabled checks, clipping checks, lookup bounds and cancellation. There is no coordinate-input fallback or automatic retry.
- Protected panels still block capture and interaction. Closing an identified ordinary panel remains a separate semantic action.
- Executable admission stays authoritative in the host actor after a file picker returns. Cancellation before admission cannot change the executable. After an accepted actor reply, model preferences record the accepted change rather than discard its receipt.
- Executable errors clear when readiness changes, so resolved restrictions do not leave stale Close guidance. Saved-session selection alone does not block child-free recovery.
- The readiness stream is local-only because existing snapshot publication can precede mutation/utility cleanup. Its observers finish on shutdown and release on cancellation; no wire field or polling timer is added.
- The sidebar marker does not replace SwiftUI's split delegate or editor host. It removes its notification observer and local event monitor on detach. Automatic constraints preserve the preferred width; the existing SceneStorage key and bounds remain.
- Device tests use memory secrets and private metadata. No production pairing or connection identity was changed. The user's loaded app and Pi session were not stopped or replaced.

## Verified checks

Final Mac results use three separate test processes. These are focused checks, not a complete-suite claim.

| Check | Result | Evidence under `/tmp/` |
| --- | --- | --- |
| Debug controller/service/interaction and four new Desktop regression classes | 76 passed; one existing ownership fixture requires root and skipped | `pi-desktop-controls-verified.xcresult` |
| Companion model, setup UX, structure, interface mode and native editor | 48 passed | `pi-desktop-regressions-verified.xcresult` |
| Six matching Overview, empty/recovery, settings and narrow-inspector presentation checks | 6 passed | `pi-desktop-presentation-verified.xcresult` |
| Host executable readiness | 8 passed | `pi-desktop-host-final.log` |
| Host executable readiness with Thread Sanitizer | 8 passed | `pi-desktop-host-tsan.log` |
| Unsigned Mac product build | Passed | `pi-desktop-build.log` |
| Dedicated product-source check-app build and native-click script | Passed | `pi-desktop-check-build.log`, `pi-desktop-live-check.log` |
| Independent complete-diff source review | No actionable findings | Reviewed correctness, security, lifecycle, compatibility, regressions and scope |
| Local documentation/source references and whitespace | Passed | Checked after documentation updates |

The three Mac batches contain **130 passing tests**, with the one root-only skip reported separately. The ownership check was not run with elevated privileges.

Initial test compilation found an awaited XCTest autoclosure and a fixture closure missing MainActor isolation. Both were corrected. Earlier mixed and structure-only runs also failed one inspector tab fixture: its window was not key, so a window-level click activated it instead of selecting the tab. The fixture now selects only a visible owned control, checks that Session is selected first, and exercises native `NSSegmentedControl.mouseDown` tracking with a queued mouse-up. It does not call the model action to simulate success. The final 48-test regression batch passes; first-click window activation remains outside that fixture's claim.

The first private-launch attempts lacked the `Library/Caches` parent and correctly failed endpoint startup. The script now creates that parent in its private home. No service path or permission check was relaxed.

### Repeat focused checks

Use the configured `PiRemoteMac` scheme and [native test/build commands](native-apps.md#automated-checks). The final test filters were:

- Controls: `MacDebugInteractionTests`, `MacDebugControllerTests`, `MacDebugServerTests`, `MacDesktopSessionActionTests`, `MacDeviceIdentityTests`, `MacExecutableReadinessTests`, `MacSidebarWidthTests`.
- Regressions: `CompanionTests`, `MacSetupUXTests`, `MacInterfaceStructureTests`, `MacInterfaceModeTests`, `PiEditorTests`.
- Presentation methods in `CompanionPresentationTests`:
  - `testManagementOverviewShowsTruthfulRuntimeAndClosedOnlyStates`
  - `testStoppedServerAndEmptySessionAtMinimumWindowSize`
  - `testSessionControlsRemainScrollableInANarrowInspector`
  - `testConnectionSettingsSeparatePairedAccessFromLiveStatus`
  - `testUsabilityDuplicateTitlesPiFooterAndOptionalPinnedNavigation`
  - `testUsabilityEmptyOpeningUnavailableAndFailureCaptures`

Each class/method uses the `-only-testing:PiRemoteMacTests/` prefix. Use `-parallel-testing-enabled NO` and run the three batches separately.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --scratch-path /tmp/pi-executable-readiness-tests --no-parallel \
  --filter ExecutableReadinessTests
swift test --scratch-path /tmp/pi-desktop-host-tsan --sanitize=thread --no-parallel \
  --filter ExecutableReadinessTests
```

### Normally launched native-click check

[The dedicated check target](../Tests/MacDebugInterfaceTests/README.md) compiles unchanged product sources with a separate bundle identity. Run the app directly as a separate process through this script; no XCTest UI runner or global Accessibility permission is needed:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate --spec Spikes/MacDebugInterfaceCheck/project.yml
xcodebuild -quiet \
  -project Spikes/MacDebugInterfaceCheck/MacDebugInterfaceCheck.xcodeproj \
  -scheme MacDebugInterfaceCheck -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/pi-remote-debug-interface build
uv run python Tests/MacDebugInterfaceTests/check-desktop-controls.py \
  /tmp/pi-remote-debug-interface/Build/Products/Debug/PiRemoteMacDebugCheck.app
```

The script accepts only that check bundle, creates a private home, seeds process-local debug-consent arguments and invokes the real registered extension through `debug-probe.ts`. Native Sidebar changes rendered content; native Pi commands opens a protected panel. Capture and clicks are rejected while it is open, and semantic Close restores access. Final bounded status matches initial status: no sessions, messages, dialogs or listener activity. Only the script's child process is stopped. No image or Pi history file is saved.

## Remaining limits and recovery

The private-launch script does not verify the attended Enable dialog or production preference persistence. Loaded-session debug insertion, real-provider streaming, physical keyboard/trackpad input, VoiceOver and final user visual acceptance remain separate checks. Native sidebar drag/restoration evidence uses in-process events in private fixture windows at 900 × 600 and 1104 × 829; it is not a physical-desktop gesture check. Signed installation remains unverified.

The running user app is unchanged and needs a rebuild/relaunch to adopt these corrections. Review active work before closing it. To roll back, revert the affected code; no data migration is needed. Disable debug to revoke its capability. Preserve sessions, drafts, pairing records and existing layout preferences; do not reset identity or preferences as a recovery shortcut.
