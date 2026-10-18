# Focused Mac debug UI check

Status: **the separate-process native-click script passes; the XCTest UI-runner consent/restart flow remains blocked before test entry**. These are separate checks.

## Native-click script

`check-desktop-controls.py` launches the dedicated app directly with unchanged product sources, a private home and process-local debug-consent arguments. It uses the actual registered extension, not a hosted accessibility override. It verifies native Sidebar/Pi commands clicks, protected-panel rejection, ordinary-panel Close and unchanged empty-runtime status. Only its own child process is stopped; no image files are saved. It rejects the production bundle identity.

Use the [verified build and script command](../../docs/desktop-uiux-follow-up.md#normally-launched-native-click-check). This passed without the UI runner or a global Accessibility grant. It is not an attended Enable-dialog, restart-persistence, provider, loaded-editor or physical-input check. The UI-runner blockers below remain open.

## Scope

`Spikes/MacDebugInterfaceCheck/project.yml` builds unchanged product sources with a separate bundle identifier, `dev.narumi.PiRemote.MacDebugCheck`. The test launches that app as a separate process, not a hosted view. It never targets the user's `dev.narumi.PiRemote.Mac` app.

The one test is intended to check:

- A fresh private home has debug access off, with both project tools rejecting requests.
- Settings requires an explicit Enable action and confirmation. The endpoint, socket and visible indicator appear.
- The actual registered project tools return allowlisted empty-app status and bounded AppKit-view PNG metadata.
- GUI mode changes produce different Pi/Desktop captures. Process-local appearance arguments request Desktop light and dark. PNG hashes and mean luminance must differ; these checks are not visual acceptance.
- Disable removes the endpoint/socket and rejects both tools.
- Ordinary Quit while enabled closes access. Relaunch restores debug mode with a fresh capability. After Disable, relaunch stays off.

`HOME` and `CFFIXED_USER_HOME` point to the same new directory under `/private/tmp`. Foundation home, Application Support and cache paths were separately verified with `CFFIXED_USER_HOME`. The app must create `Library/Application Support/PiRemote/host.json` in that home. The test never starts Pi, the iPhone listener or pairing.

The `.pi/tests/debug-probe.ts` helper loads the real project extension and invokes its registered tool definition. It returns only status or PNG dimensions, size, hash and luminance. It does not save images, start inference or create Pi history. It does **not** establish a live interactive/RPC Pi-session check. That acceptance remains separate.

## Verified build

Run from the repository root. XcodeGen 2.46.0 and Xcode 26.6 were used. Generate beside the spec; relocating the generated project with `--project /tmp/...` did not relocate its relative Swift package reference correctly.

```sh
xcodegen generate --spec Spikes/MacDebugInterfaceCheck/project.yml
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun xcodebuild -quiet \
  -project Spikes/MacDebugInterfaceCheck/MacDebugInterfaceCheck.xcodeproj \
  -scheme MacDebugInterfaceCheck -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/pi-remote-debug-interface build-for-testing
```

The final spec uses normal local ad-hoc signing. Both the app and runner passed `codesign --verify --strict`. Do not override it with `CODE_SIGNING_ALLOWED=NO`: the initial unsigned runner retained an Apple runner identity with an unbound Info.plist and reached a Gatekeeper consent prompt.

## UI execution requires attended authorization

Do not run unattended while these nonprompt checks report false:

```sh
osascript -e 'tell application "System Events" to get UI elements enabled'
xcrun swift -e 'import ApplicationServices; print(AXIsProcessTrusted())'
```

An attended user must resolve the macOS runner execution prompt and authorize the actual automation host/runner in **System Settings → Privacy & Security → Accessibility**. Do not change global TCC settings, approve unrelated prompts, disable Gatekeeper or weaken certificate checks. A host preflight does not prove runner authorization. The test also skips before GUI interaction if the runner is untrusted, but runner setup can block before the test starts.

Before a later authorized run, set the generated `.xctestrun` fields below. Xcode regenerates this file during each build. `SystemAttachmentLifetime` and `UserAttachmentLifetime` use the installed `xcodebuild.xctestrun(5)` value `keepNever`. The screenshot format prevents test screen recording; no test calls a screenshot API.

```sh
uv run python - <<'PY'
import os, pathlib, plistlib
root = pathlib.Path('/tmp/pi-remote-debug-interface/Build/Products')
paths = list(root.glob('MacDebugInterfaceCheck_*.xctestrun'))
assert len(paths) == 1
path = paths[0]
data = plistlib.loads(path.read_bytes())
test = data['MacDebugInterfaceTests']
test['SystemAttachmentLifetime'] = 'keepNever'
test['UserAttachmentLifetime'] = 'keepNever'
test['PreferredScreenCaptureFormat'] = 'screenshots'
test['ParallelizationEnabled'] = False
test['EnvironmentVariables']['PATH'] = os.environ['PATH']
path.write_bytes(plistlib.dumps(data))
print(path)
PY
```

The test environment `PATH` must find the installed Node.js 26 and Pi CLI for the probe. The attempted focused command was:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun xcodebuild -quiet \
  test-without-building \
  -xctestrun /tmp/pi-remote-debug-interface/Build/Products/MacDebugInterfaceCheck_macosx26.5-arm64.xctestrun \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  -maximum-test-execution-time-allowance 60 -collect-test-diagnostics never \
  -resultBundlePath /tmp/pi-remote-debug-interface-ui-signed.xcresult
```

Use an outer 90-second process timeout too: the XCTest allowance does not bound runner setup. The attempted command ran through `subprocess.run(..., timeout=90)` in `uv run python`. Use a new result-bundle path for a later authorized run. On a timeout, stop only the dedicated check runner; never terminate a product app by name.

## Observed results

- Final `build-for-testing` passed. The one UI test compiled.
- The initial unsigned attempt timed out before test entry. Unified logs recorded a Gatekeeper prompt for `dev.narumi.PiRemote.MacDebugInterfaceTests.xctrunner`, waiting for a response.
- One corrected-signing attempt also timed out before test entry at 90 seconds. Its exact setup blocker was not established. No test passed or skipped; the app under test did not launch.
- Both dedicated runners were stopped by their verified PIDs. The user's app PID 19988 stayed running. No permission was granted, no system preferences were changed, and no screenshot files were produced in either result directory.
- Build logs: `/tmp/pi-remote-debug-interface-build-final.log`. Attempt logs: `/tmp/pi-remote-debug-interface-ui-once.log` and `/tmp/pi-remote-debug-interface-ui-signed.log`. The corresponding `.xcresult` directories are incomplete text-diagnostic staging directories, not completed test reports.

Normal-launch enablement, project-tool captures, appearance comparison, saved-consent restoration, disablement and restart-off remain unverified. The test expectation was updated for saved consent; the updated UI flow has not run. Do not mark the acceptance gate complete from this target's build result.
