# Native workflow verification

## Result

The native workflow implementation has advanced, but `PLAN.md` is not complete. Normal installed-extension compatibility, accessibility review and several workflow checks remain open. Plan completion requires simulator and laptop evidence, not physical-device installation or off-site testing.

Verified on this Mac with Pi 1.3.0, Xcode 26.6 and the iOS/macOS 26.5 SDKs:

- 59 root package tests pass, also with Thread Sanitizer. Earlier shared-suite Thread Sanitizer evidence remains separate.
- 18 shared-package tests pass.
- Twenty-three iOS app tests pass with the explicit provider fixture on the iPhone 17 Pro simulator, iOS 26.5, with zero failures or skips; see the local audit below.
- Both unsigned app builds pass. The unsigned iOS device-SDK build is a compile check, not an installed personal build.
- An isolated check using the installed Pi passes model and thinking changes, input/editor dialogs, editor prefill, idle Stop, directory launch and idle session restoration. It sends no inference prompt.
- An explicit provider check through the native host passes synthetic image input, observed live text, steering/follow-up delivery, active Stop, fork/clone and nonempty history restoration after coordinator restart. Tools and installed resources are disabled.

## Local plan audit

The current completion scope is simulator and laptop verification, as defined in `PLAN.md`. Historical physical-device and off-site gates below are not required for plan completion. They remain limits on hardware and distribution claims.

The latest local run verifies:

- Unsigned Mac, iOS simulator and iOS device-SDK builds. `project.yml` sets automatic signing, iOS 18 and macOS 15 deployment floors. The installed SDKs are version 26.5. These checks do not establish minimum-version compatibility or signed installation.
- All 59 root tests, also with Thread Sanitizer, and 18 shared-package tests.
- Twenty-three iOS simulator tests with the explicit provider fixture, with zero failures or skips. The full suite passed on both the Mac's LAN and Tailscale interfaces. Xcode result summaries confirm the counts. Without the fixture, the provider integration test skips; normal app tests make no provider requests.
- The isolated `NativeWorkflowCheck` with Pi 1.3.0. Directory launch, models, thinking, dialogs, Stop and idle restoration pass without inference or global-settings changes.

### Transport correction

The Network.framework listener prototype could bind the local Tailscale address, but accepted self-connections failed with `EADDRINUSE`. Separate-process and simulator clients reproduced the failure. Plain BSD TCP self-connection passed. Endpoint reuse and local-only mode did not fix it; those experiments were removed.

The production listener now uses SwiftNIO 2.104.0 and NIOSSL 2.37.5 with socket-based TLS and WebSockets. This follows the plan's maintained-library fallback. The old diagnostic remains unchanged. The URLSession client then failed TLS on the simulator's Tailscale path. The production client now uses Network.framework with an explicit Security trust evaluation. It requires the approved leaf, the URL hostname and valid certificate dates. No broad ATS exception, trust-all callback, VPN change or routing change was added.

Production integration tests now pass exact-interface binding, rejection of loopback access to a non-loopback listener, approval, authentication, active-run reconnection with one dispatch, Stop and revocation on all three local interfaces. Public, wildcard, link-local, IPv6 and hostname listener selections are rejected. Additional tests pass fragmented messages with interleaved ping, invalid masking/reserved bits/fragmentation, frame and receive-queue limits, pending-receive cancellation, expired certificates and future-dated certificates. Invalid-date fixtures verify their own dates before connecting. The initial `openssl req -days -1` fixture silently produced a valid 30-day certificate; it was replaced with explicit `openssl ca` dates and was not treated as expiry evidence.

### Local unlock and revocation

The selected iOS Keychain policy remains `WhenPasscodeSetThisDeviceOnly` with `userPresence` and an authenticated `LAContext`. Locked secret operations fail closed. The app's default evaluator uses `deviceOwnerAuthentication`, which permits Face ID or the device passcode. A test-only initializer dependency supplies authentication results without changing Keychain protection or adding a runtime bypass flag.

Three simulator tests pass denial and authentication-error handling, inactive privacy covering, fresh authentication after background return, and a delayed success from before simulated lock. The delayed result cannot unlock the app or clear a newer attempt's progress. Denial leaves transcripts absent and browsing/Send unavailable. A false authentication result now shows an actionable message instead of silently returning. The production TLS test also revokes a device during active Pi work, verifies that access closes while work continues, then stops it with the local coordinator. This is simulator/injected-policy and local transport evidence, not hardware-biometric or passcode-removal evidence.

### Simulator coding and recovery

`SimulatorHostFixture` runs the production host with the installed Pi, tools limited to read/write, and extensions, MCP and project resources disabled. This is test isolation, not a tools security sandbox. It uses a new mode-0700 temporary directory, memory-only test credentials and a short-lived pairing grant. Only the named simulator test receives injected local approval. No production authentication bypass was added.

The simulator pairs, authenticates, browses from the Mac home directory through `/` into a new nested directory, and starts Pi without project registration. Pi writes the requested Swift file. The test disconnects during active work, reconnects, checks one user-message dispatch and exact file contents, and reads the file through authenticated preview. It then sends steering/follow-up, stops work, restarts the host, authenticates again and restores the same session and working directory. A second restart interrupts active work: the saved session is marked interrupted, requires no automatic prompt dispatch, and remains idle with unchanged messages after explicit restoration. The fixture confirms that agent settings remain unchanged and removes its private data after shutdown.

The first simulator run found that parent navigation at `/` could loop because Foundation represented the parent as `/../`. The host now detects the canonical root path. A root-navigation regression and the simulator flow pass after the fix.

Run the fixture deliberately: it sends synthetic prompts to the configured provider and can incur usage. Build the apps with the commands in [native app verification](native-apps.md#automated-checks), then run from the repository root:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build --product SimulatorHostFixture
.build/debug/SimulatorHostFixture "$(command -v pi)" "$(tailscale ip -4)" --exercise-model &
fixture=$!
xcodebuild -quiet -project PiRemote.xcodeproj -scheme PiRemote \
  -destination 'platform=iOS Simulator,id=6622EB8D-23E3-4E92-9262-21CF896CD300' \
  -derivedDataPath /tmp/pi-remote-apps-ios CODE_SIGNING_ALLOWED=NO \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 160 \
  -maximum-test-execution-time-allowance 180 test
wait "$fixture"
```

Wait for `READY` before starting Xcode tests. For the LAN check on this Mac, use `$(ipconfig getifaddr en0)` instead of `$(tailscale ip -4)`. Resolve an eligible address and simulator ID on other hosts. The fixture refuses an existing `/tmp/pi-remote-simulator-fixture`; do not remove a directory owned by another running check. It stops after the integration test or a 15-minute safety deadline. These checks do not establish off-site reliability, physical-device behavior, normal installed-extension compatibility or complete UI accessibility.

Latest local logs are `/tmp/pi-remote-network-final.log`, `/tmp/pi-remote-network-final-tsan.log`, `/tmp/pi-remote-network-final-mac.log`, `/tmp/pi-remote-network-final-device.log`, `/tmp/pi-remote-final-simulator.log`, `/tmp/pi-remote-final-simulator-host.log` and `/tmp/pi-remote-final-simulator-summary.json`. They are temporary evidence, not release artifacts.

## QR-code pairing

The Mac now displays a QR code when a pairing window opens. The code contains the existing version-1 pairing text, including the pinned certificate, one-use grant, host identity, address and expiry. It disappears on approval, denial, expiry or listener shutdown. The QR sheet closes when a pairing request arrives so that the Mac approval controls are visible. Text copying remains available. Codes over 2,953 UTF-8 bytes use the paste fallback; no payload is truncated.

The iPhone uses an in-app VisionKit QR scanner. It requests camera access only when selected. Unsupported hardware, denied access and camera failures offer the paste fallback. Scanning stops when inactive or dismissed. Scan results must pass the existing pairing-code validation and belong to the current unlocked pairing form. A valid scan fills the form; it does not contact the Mac until the user selects Request pairing. Mac approval, TLS certificate checks and device authentication remain unchanged. No pairing code or camera image is logged or saved by the scanner.

Five new simulator tests pass for exact QR encode/decode, certificate and grant preservation, empty/oversized encoding, invalid/expired/unsupported inputs, oversized scans, form-only acceptance and lock/Mac/panel/pairing boundaries. All 19 iOS tests pass with zero failures or skips. Both unsigned platform builds and the unsigned physical-iOS-SDK build pass. The 51 root tests and 18 shared tests also pass; the 51 root tests pass again with Thread Sanitizer. Local build and test artifacts use `/tmp/pi-remote-qr-*` paths and are not committed.

The first QR decode test used Vision, which could not create an inference context on the simulator. The test now uses the Core Image QR decoder and passes. This is image encode/decode evidence, not evidence of physical camera scanning. Physical checks remain open for camera permission approval/denial, cancellation, background return, expiry while scanning and scan-to-approved-pairing. The full first-version acceptance gates below remain open.

## History

The new `history-pages` capability adds typed page and entry-preview requests. The older history request remains available. The UI uses paged requests only when the host reports that capability.

History reads companion-owned JSONL files, not remote paths and not an unbounded `get_entries` response. It reads backward in bounded blocks and returns at most 100 entries per page, newest first. Tests visit all 1,205 fixture entries without duplicates, including CRLF and an incomplete trailing append. Parent IDs remain visible. Newer-page navigation caches at most eight pages; reload returns to the newest entries.

Page cursors and preview IDs are opaque, bound to the session and filesystem identity, and expire after five minutes. The host retains at most eight cursors and 2,000 preview references. Repeating a valid read cursor returns the same entry IDs. File replacement, truncation that invalidates a cursor or entry, unknown IDs, malformed records and records over 8 MiB fail closed. Reads check cancellation and do not modify session files. Preview-reference limits also apply when malformed pages fail partway through a read; a regression test exercises repeated failures.

A summary is limited to 512 UTF-8 bytes; an entry preview is limited to 256 KiB and reports truncation. This is paged history inspection, not in-place branch switching. Pi's documented RPC interface cannot navigate to an arbitrary tree entry. Fork remains limited to active-branch user messages and can be rejected by Pi. Terminal-only entry renderers and full image output are not reproduced.

## Transcript and interface

Thinking and text use `contentIndex` during streaming. Completed block content replaces deltas; `message_end` replaces the full partial message. Only `agent_settled` ends automatic work. Thinking signatures and redacted blocks never enter the display DTO. Thinking and answer text share the existing 16 KiB per-message and 256 KiB aggregate budgets. Oversized content is marked as truncated. Empty assistant error messages retain their error text, and custom messages with `display: false` stay hidden.

Foundation parses Markdown. Native views render headings, paragraphs, lists, quotes, tables, code blocks and rules while retaining inline formatting. Tests cover nested lists, incomplete fences and a complete raw-source fallback for oversized tables. Remote images are not fetched, code has no syntax highlighting, and custom terminal renderers remain unsupported. Links open only for `http`, `https` and `mailto` schemes after a user action.

Thinking uses a disclosure. New conversations start at the latest output. Transcript content is clipped to its viewport so it cannot cover the header or composer. The composer limits accessibility-size input to two visible lines to preserve control space.

The app tests host real UIKit-backed SwiftUI views for idle, working, retrying, compacting and interrupted fixtures in light/dark appearance with accessibility text sizes. They also use a reduced 375 × 367-point viewport. The final four working-state captures are retained in the local result bundle for review. A reduced viewport is not a real keyboard or a tested minimum-device claim. Directory/session sheets, VoiceOver, actual keyboard and dictation, and the complete physical coding flow still need review.

## Directory browsing and launch protection

The picker displays one page of at most 100 entries and caches at most eight other pages. Previous/next navigation reuses cached pages because host directory cursors advance on read. Returning beyond the cache requires a fresh listing. Folder changes clear the cache and preview. Six simulator tests cover bounded paging, cached forward navigation, stale successes and failures, cancelled loads, stale previews and failed-navigation retry. A failed navigation leaves no folder selected for launch.

The host checks directory identity and read/search permissions before creation and resumption, before replacing an existing process. Parameterized tests cover unknown IDs, file IDs, removed/replaced folders and read/search permission loss; each verifies that Pi never starts and no session is created. A separate resume test proves that permission loss does not replace the active process. Two activation-race cases replace the folder while the old process shuts down or executable inspection waits. Both initially launched RPC in the replacement folder. Revalidation after each wait now rejects the stale selection before RPC launch. Session headers are also rechecked after executable inspection, and executable changes are rejected while activation or inspection is active. Tests also reject traversal strings in typed directory IDs and report broken links and symbolic-link loops. The native-host dispatch test launches through an accessible symbolic-link alias and records the canonical selected directory. Production TLS tests reject unauthenticated directory requests.

These are automated filesystem and simulator checks, not physical protected-folder/TCC acceptance. The isolated installed-Pi check also passes after the permission change without a provider request. The complete real-device coding flow remains open.

## Session and lifecycle protection

The production TLS integration test also injects client snapshots through the internal state receiver. An older sequence cannot replace newer text. A wrong host or epoch closes the connection and blocks further requests. The receiver remains internal; no public injection API or runtime bypass was added.

All conversation and sheet actions are bound to the displayed host, epoch and session. The client checks that context before dispatch, and the host still checks its epoch and selected session. Stale UI actions, attachments and resend confirmations cannot silently target a newer session. Tests reject wrong-host, wrong-epoch and stale-session actions without dispatch. Sheets reset their local state at a context change.

Mac selection and phone lock invalidate earlier asynchronous callbacks. Old connection-task cleanup cannot change a newer connection's progress state. Phone lock clears pending previews, offers and pairing UI, cancels connection work, and leaves accepted Pi work on the Mac.

Editor prefill never overwrites a nonempty draft without an explicit Replace decision. Offers are session-bound; keeping the existing draft sends nothing. Session activation and clone clear old host prefill state. Phone drafts survive session changes and background entry. Tests use isolated preferences and do not overwrite real app drafts. No runtime authentication-bypass flag was added.

Resume compares the session header's absolute working directory with the stored canonical directory and filesystem identity. An accessible symbolic-link alias of that same directory is valid; a different or replaced directory is not. Session paths must still belong to companion storage. This does not make directory selection a tools sandbox.

## Repeat the real Pi check

Run from the repository root on this Mac:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift run NativeWorkflowCheck "$(command -v pi)" \
  /Users/narumi/.bun/install/global/node_modules/@earendil-works/pi-coding-agent/examples/extensions/rpc-demo.ts
```

The second argument is the checked demo extension bundled with the installed Pi. Resolve its path for other installations. The Swift check creates a private temporary wrapper and an isolated Pi config/session directory. It loads only that demo, disables tools, MCP, context files and other resources, and uses offline mode. A dummy, nonfunctional OpenAI key permits local model-selection checks; it is never used for a provider request. The wrapper records the subprocess working directory inside its private fixture. The check verifies that the user's global settings file is unchanged and removes its fixture after shutdown. It does not copy provider credentials or print transcripts, dialog answers or tool output.

This metadata-only check does not exercise provider work. The separate provider check below covers active-run controls, synthetic image input and nonempty native-host restoration. Normal installed-extension compatibility, real compaction and physical product-app acceptance remain open. See [the original RPC exercise](verification.md#installed-pi-exercise) for its separate, earlier provider-run evidence.

### Native provider check

The following command sends synthetic prompts and a generated white 64 × 64 PNG to the configured provider. It can incur provider usage. It is not part of `swift test`; run it deliberately:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift run NativeProviderCheck "$(command -v pi)" --exercise-model
```

The check starts three initial prompts, sends steering/follow-up instructions during active work, and stops the final run with queued instructions. It verifies visible streaming, delivery of both queue types, idle Stop with no later user-message delivery, history paging, clone/fork, return to the original session and nonempty restoration after a new coordinator acquires the same private catalog. Restored text, thinking and display flags must match; display-only message IDs can change. The working directory must remain unchanged.

The check disables tools, extensions, MCP, skills, templates and project context. `--offline` disables Pi's automatic network activity, not these explicit provider requests. It uses Pi's existing credentials in place without copying or printing them. Session files and the nested working directory stay in a private temporary fixture, removed after shutdown. The effective agent settings file must remain unchanged. The check never resends an accepted prompt. Failures report only an assertion location or typed app fault, not model text or provider diagnostics.

This is a native-host exercise, not a signed product-app, physical-device or normal installed-extension test. It does not test real compaction, full image output, in-place tree navigation, hardware unlock, sleep/wake or off-site access.

## Failures and external gates

1. The first real-host check compared path strings and rejected a `/var` alias of the same directory. The check now compares canonical filesystem identities. The new resume regression first failed because equivalent directory URLs had different trailing-slash hints. Registered paths now compare canonical paths and filesystem identities rather than URL hints. The test passes valid header aliases and still rejects a different directory.
2. `ImageRenderer` produced blank transcript regions and unsupported-control markers for UIKit-backed controls. The harness now captures a hosted UIKit hierarchy. Fixture safe areas and appearance settings were corrected before review. These failures were not treated as passing visual evidence.
3. A fresh signed Mac build on this branch still fails in CodeSign with `errSecInternalComponent` (`/tmp/pi-remote-plan-signing.log`). The session is a Background launch context. No Keychain ACL, password or certificate check was changed. The product apps still need foreground Xcode signing and physical installation; the older diagnostic signature cannot sign this source revision.
4. The branch recheck reports the iPhone 16 Pro connected by USB, iOS 26.7.1 (23H30), with DDI available. Tailscale reports that phone offline. Off-site acceptance needs the phone connected to Tailscale from a different network; no VPN or routing configuration was changed.
5. Full workflow compatibility remains blocked by terminal-only extension APIs and missing in-place tree navigation. No scope reduction or feature deferral has been accepted.

The branch checkpoint passed 14 iOS tests with zero failures or skips in `/tmp/pi-remote-apps-ios/Logs/Test/Test-PiRemote-2026.10.16_21-47-58-+0800.xcresult`. Its first test build failed because the pending-request test helper lacked main-actor isolation; adding that isolation fixed the compile error. The activation-race regression first failed both cases before the path-revalidation fix; the full suite now passes. An initial provider-image check build used the wrong attachment type name; it was corrected to the shared `ImageAttachment` before the passing run. The earlier visual-review result bundle is `/tmp/pi-remote-workflow-phone-reviewed`. Captures and result bundles are temporary and are not committed. Build/test commands for the package and apps remain in [native app verification](native-apps.md#automated-checks).
