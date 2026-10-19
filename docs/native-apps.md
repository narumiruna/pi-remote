# Native app implementation and verification

## Status

The repository now contains SwiftUI iOS and macOS apps and an authenticated Mac host. This is a development implementation, not a supported release. `PLAN.md` remains open. The physical transport spike is not evidence that the product apps pass a physical-device coding task.

The [minimal Desktop workflow](desktop-minimal-ui.md) supersedes earlier duplicate controls, sidebar destinations, Session form order and closed-history presentation. Native verification passes; normal-app review and user acceptance remain open. Reviewed native light/dark fixture captures at 900/1104/1300 points are not normal-launch/provider or user acceptance. Earlier test counts below remain historical checkpoints; use the linked record for final tests of the current changes.

Earlier checkpoint, verified on macOS 26.6.2 with Xcode 26.6 and the iOS/macOS 26.5 SDKs (later Mac UI/path checks are recorded [separately](mac-interface.md)):

- The macOS app and iOS app build without signing, including the physical iOS SDK build.
- All 72 root package tests pass, including production TLS pairing, LAN/Tailscale binding and fake-Pi integration tests.
- All 27 shared package tests pass, also with Thread Sanitizer.
- All 72 root tests pass with Thread Sanitizer.
- Twenty-nine iOS app tests pass on the iPhone 17 Pro simulator, iOS 26.5, with the explicit provider fixture on both LAN and Tailscale. The integration flow checks coding, reconnect, Stop and idle/active host restart. Without the fixture, that one test skips. The other twenty-eight tests check clipboard expiry, image decoding, attachment scope/persistence, QR encode/decode, invalid and stale pairing scans, bounded directory paging, stale/cancelled browse responses, launch/background protection, denied/failed and stale unlock results, denied secret access, draft retention, editor offers, context boundaries, error acknowledgement, color contrast and hosted UIKit rendering in light/dark appearance with large text.
- Eleven separate interface UI tests pass on a compact iPhone SE simulator with large text, including native usage, image output, Mac text attachment, copy, settings confirmation and close/reopen. The original six pass repeated real-keyboard and reading-position checks. Requested label/target audits and capture review pass; see [interface verification](interface-verification.md). These checks do not establish hardware behavior.
- Three macOS tests pass: two cover shared local/remote state, new-storage listener setup, local approval, device persistence, restart and revocation; the third tests isolated clipboard writes. See [runtime checks](runtime-controls.md) and [clean setup controls](workflow-verification.md#clean-setup-controls).
- The installed Pi passes an isolated native-host metadata/dialog check without inference. A separate explicit provider check passes synthetic image input, live streaming, steering/follow-up delivery, active Stop, fork/clone, real manual compaction, session statistics and nonempty history restoration after coordinator restart; see [workflow evidence](workflow-verification.md#native-provider-check).

See the commands below for repeatable checks. Physical product-app signing, Face ID/passcode behavior, folder permissions, accessibility, and off-site Tailscale operation remain unverified. The provisional deployment floors are iOS 18 and macOS 15; these are build settings, not tested support claims.

## Source ownership

| Path | Responsibility |
| --- | --- |
| `Apps/iOS/` | Local authentication, privacy cover, saved Macs, attachments, connection and draft state |
| `Apps/macOS/` | Menu-bar controls, local pairing approval, listener settings, local session controls |
| `Apps/Shared/` | Conversation, folder picker, native session controls and dialogs |
| `Packages/PiRemoteCore/` | Versioned messages, bounded transcript state, replay and request journal |
| `Packages/PiRPC/` | Local JSONL subprocess transport, promoted from the RPC spike |
| `Packages/PiRemoteHost/` | Directory capabilities, sessions, Pi supervision, TLS server and pairing authority |
| `Packages/PiRemoteClient/` | Pairing, authenticated connection, state recovery and request correlation |
| `Packages/PiRemoteConnection/` | Certificate-pinned Network.framework WebSocket |
| `Packages/PiRemoteSecurity/` | Keychain storage and private metadata files |
| `Tests/InterfaceFixture/` | Separate in-memory UI review app; not included in product targets |
| `Tests/InterfaceTests/` | Compact simulator, keyboard, reading-position and accessibility checks |
| `project.yml` | XcodeGen source for product apps, app tests and the interface review targets |

The generated `PiRemote.xcodeproj` is ignored. No TypeScript backend, terminal, hosted service, or release workflow was added.

## Implemented behavior

- The authenticated folder picker starts at the Mac home directory and can navigate to `/`. It has no approved-root list. Listings use opaque IDs, 100-entry pages, and canonical filesystem identities. Selection identity and read/search permissions are checked again before creation or resumption, before replacing the current Pi process. Checks run again after process shutdown and executable inspection, before RPC launch. Executable selection is blocked during these operations. Inaccessible entries, broken links and symbolic-link loops are reported. File previews are separate from folder selection.
- The companion owns one upstream Pi core RPC process. Sessions use private storage under `~/Library/Application Support/PiRemote/`, not the user's terminal session directory. A process lock prevents two companions from writing the catalog. Resume checks the saved directory identity, session path, session header ID, and header working directory. Missing populated sessions fail instead of starting an empty replacement.
- Local and remote controls use the same coordinator. Incompatible actions return a conflict or busy error. Stop clears queues, cancels pending dialogs, aborts work, and checks Pi's idle state. It cannot undo file changes.
- Native controls include prompts/queues/Stop, model/thinking selection and cycling, normalized names, reviewed custom-instruction compaction, retry controls, command discovery, authoritative tree/fork inspection, clone, image/text input, file previews, diff, copy, settings, export/import and idle close. [Same-directory upstream Pi core lifecycle](session-lifecycle.md) and the [earlier local acceptance checkpoint](core-rpc-acceptance.md) pass. Mac upstream shell controls now have [new isolated checks](pi-like-mac-verification.md); phone shell entry and attended Mac checks remain open. All 27 compact-interface tests passed in the earlier accepted batch set.
- The working directory uses a compact folder label in the header and the complete path in Session controls. The folder picker scrolls long paths horizontally. Short error banners open full recovery instructions. Editor actions remain above the keyboard.
- Final messages and completed content blocks replace deltas. Only `agent_settled` indicates completion of automatic work. Thinking and tool output are expandable. The display retains 100 messages and 256 KiB of UTF-8 text, with 16 KiB shared by text and thinking per message. Redacted thinking and signatures are not displayed. Pi keeps the full managed session on the Mac.
- Published state events are authoritative display snapshots with an epoch and sequence. Replay keeps a contiguous suffix of at most 32 events and 2 MiB. A stale cursor or changed epoch requires a fresh snapshot. Registration of a state observer and its initial snapshot occur in the same actor operation. Slow clients retain only the latest pending state; they do not block Pi stdout.
- The request journal saves a payload fingerprint and unknown outcome before dispatch. It does not store prompt text. Duplicate accepted requests do not run again. A previous host epoch is rejected. Neither client nor host automatically retries an uncertain mutation.
- The bounded transcript uses an eager stack to avoid a reproduced lazy-layout stall during live updates. User scrolling pauses live following; layout and keyboard changes do not. Latest restores following. A 100-message fixture remains usable.
- Phone drafts are stored per Mac and session. Mac drafts are held per session during the app lifetime. Conversation and sheet actions are bound to the displayed host, epoch and session. An extension prefill does not overwrite a nonempty draft without an explicit Replace decision. Session changes clear old host prefill state.
- Disconnecting or locking the phone does not stop accepted Mac-side work. Returning to the foreground requires local authentication before reconnection. Companion exit stops its owned child. Interrupted sessions require review; no prompt is resumed automatically.

## Security

Pairing uses a two-minute high-entropy code scanned or copied from the Mac. Select **Pair iPhone** on the Mac to display its QR code. On the phone, use **Connections → Pair a host → Scan QR code**, review the Mac name and address, then select **Request pairing**. The in-app scanner requires camera permission; it does not use the system Camera app or a web service. Copy and paste remain available if scanning is unavailable or the code exceeds QR capacity. This interaction is implemented and simulator-tested, but physical camera scanning remains unverified.

The phone pins the certificate in that code before sending the pairing grant. The Mac user must approve the displayed device ID. Codes permit at most five attempts, and the host accepts at most 16 paired devices. A code is sensitive: do not put it in logs or share it through an untrusted channel.

Connections require a fresh nonce and a per-device HMAC proof. The host rejects unauthenticated browsing and commands. Revocation closes active authorization leases before deleting credentials. If persistence fails, the listener stops and the UI reports an error; do not treat a failed revocation as durable success.

SwiftNIO and NIOSSL provide the production listener. The Network.framework client checks the exact approved leaf certificate, its URL hostname and explicit validity dates. This replaces the prototype listener and URLSession client after local Tailscale failures; see [transport correction](workflow-verification.md#transport-correction). There are no broad ATS exceptions or trust-all callbacks. The listener binds one selected loopback, private IPv4, or Tailscale IPv4 address, normally on port 7443. IPv6, public listeners and router port forwarding are not implemented.

The server identity and device secrets use Keychain. The phone uses `WhenPasscodeSetThisDeviceOnly` with `userPresence` and an authenticated `LAContext`; it has no unauthenticated fallback. The app covers inactive content and invalidates the context on background entry. Three simulator tests inject authentication results: denial and errors retain the lock, background return requires a new decision, and an old success cannot unlock the app or finish a newer attempt. The default evaluator still uses `deviceOwnerAuthentication`; no runtime bypass flag was added. Production TLS tests also prove that revocation closes phone access while Pi keeps working and the Mac can still Stop it. Hardware denial, device-lock and passcode-removal behavior still need physical tests. Saved public connection metadata and drafts use the phone's app storage, not the credential Keychain.

A paired phone has Pi control with the Mac user's permissions. Folder selection is not a tools sandbox. The companion does not bypass macOS permissions and does not expose arbitrary RPC forwarding. Native upstream Pi core shell controls are approved but not yet implemented; an embedded terminal or PTY remains outside scope. Provider credentials remain on the Mac. Routine diagnostics do not record prompts, tool output, pairing codes or secrets.

## Resource and recovery limits

- App frames are limited to 4 MiB; Pi JSONL records are limited to 8 MiB. Pi stdin retains at most 64 queued/in-progress writes and 8 MiB of encoded write data. Cancellation does not release queued-byte admission before consumption/discard. Oversized live state falls back to a bounded error snapshot that retains Stop. A Pi record beyond the adapter limit interrupts the process; large-history recovery still needs validation.
- The directory picker displays one 100-entry page and retains at most eight other pages for back/forward navigation. Forward navigation reuses cached pages instead of consuming the host cursor twice. Folder changes clear the cache and preview; stale or cancelled replies cannot replace the selected directory, preview, error or loading state.
- There are at most eight in-flight requests per connection, 16 queued replies, 16 connections, eight folder cursors, and 4,096 registered path IDs. Each connection retains at most eight unread messages and 8 MiB; overflow closes access instead of blocking Pi. TLS/WebSocket setup has a ten-second deadline. Cursors expire after 60 seconds. Browse again if an ID expires or a folder moves.
- Text prompts are limited to 256 KiB. One image is limited to 2 MiB. The phone downsizes selected photos. Text previews and diffs are limited to 256 KiB. Paged history returns 100 entries with 512-byte summaries and bounded entry previews. Older clients retain the 1,000-entry history operation. Native Markdown, thinking and bounded raster-image viewing are implemented. Images use session-bound references, a 32-image/8 MiB cache and explicit 2 MiB/dimension limits; original-resolution viewing and history recovery pass. Animation beyond the first frame and unsupported formats remain limits; see [image evidence](output-images.md). Custom terminal renderers and in-place branch navigation have no upstream Pi core RPC mapping and are outside the accepted scope. See [history limits](workflow-verification.md#history).
- A bounded Pi event-stream overflow retains child ownership, installs a fresh event subscription and refreshes state/history. Lost dialogs cannot be replayed. The app keeps an uncertain recovery state until explicit Stop and reopening; it does not resend prompts. See [event-stream recovery checks](core-event-verification.md#event-stream-gaps).
- [Tree inspection](session-inspection.md) retains at most 10,000 nodes/options, 100-node pages, two snapshots, 32 opaque cursors and two cached offset indexes. Indexes use one bounded 32 MiB scan per unchanged file revision. IDs, labels and previews have explicit byte limits. Visible custom-message entry previews retain text/images; hidden content stays suppressed.
- Model and command discovery display the first 256 options from Pi's order. Names and descriptions have bounded display lengths. These are native display limits, not claims of an unlimited resource inventory.
- Dialogs are retained on the Mac during a disconnection. The phone can close the local sheet, reconnect and explicitly reopen an unanswered request; local Close does not answer or cancel it. Answers show inline failures, and acknowledged requests cannot be answered again from a delayed snapshot. Expired answers are rejected. Oversized dialogs offer cancellation only; truncated choices are never approved. Up to eight dialogs can remain pending.
- The request journal accepts at most 10,000 mutations in one host epoch. It fails closed at capacity instead of discarding deduplication records. Restart creates a new epoch; old requests remain invalid.
- Network requests time out after 150 seconds. A longer operation, such as compaction, can continue on the Mac with an unknown client outcome. Inspect the session before retrying.
- Utility processes have a 15-second deadline and bounded output. Cancellation also bounds reads when descendants retain pipe descriptors. Pi shutdown uses an orderly attempt followed by termination and a kill deadline. Cleanup runs independently of caller cancellation. An unconfirmed stop retains child ownership and a recovery state instead of deleting its session.
- A certificate is valid for 365 days and includes addresses available when it was generated. After expiry or an address change, use **Replace connection identity** on the Mac. This stops the listener and revokes devices without stopping Pi or deleting sessions. Start the listener again and pair each phone with a new code. The recovery UI is compiled, but not physically tested.
- To change from LAN to Tailscale, stop the listener, select the Mac's Tailscale address, and start it again. Edit the saved phone URL while retaining the certificate pin. The certificate must cover that address. This path still needs an off-site phone test.
- A sleeping Mac is unavailable. There is no remote wake, login item, continuous phone background connection, public account service or TestFlight release.

## Mac setup and folder paths

The [UI/UX corrections](uiux-review-fixes.md) add local-first Settings, optional iPhone access with address refresh, context-aware inspectors and unavailable pre-session input. Phone offline recovery preserves cached reading, and warning/error notices keep explicit severity. Forget requires a named confirmation before local credential deletion.

Pi mode follows the supplied dark-theme references with a persistent startup/resource header, native transcript, compact growing editor and footer in one scroll flow. Desktop uses a compact title/path/phase header, centered message cards and a persistent rounded composer below independent history. An empty loaded Desktop session shows one short input hint; unloaded guidance offers Resume and names New session in the toolbar. Files and Pi commands have primary toolbar controls; Session controls are in the Session menu, without header, welcome or composer duplicates. See [mode behavior](mac-interface-modes.md).

Desktop Session controls put Model and Thinking level first. Details and Advanced start collapsed. Context/Skills/Prompts are read-only in Details; loaded context paths remain unavailable through RPC. Infrequent controls remain in Advanced. Desktop Cycle buttons are removed, not their actions/shortcuts. Pi version and Pi changelog are in Settings → Pi and folder access. Pi's legacy Session form retains version/changelog/Cycle controls; iPhone controls are unchanged.

Standard extension widgets retain above/below-editor placement; status entries use the footer. Desktop generic diagnostics show severity/count summaries with View details opening Activity without changing the central page. Reserved host recovery instructions remain fully visible. Exact legacy mirrors of typed notices, widgets and statuses are not counted again; unmatched legacy notices report unavailable severity. Pi retains its diagnostic presentation. Custom TUI factories are unavailable through upstream RPC.

The workspace sidebar starts hidden; **Sidebar** reveals workspaces/sessions and a Settings footer in both Mac modes. There are no Pi, Overview or Devices root rows. Conversation and loaded-session aliases select the same row. Selecting saved history previews only; explicit Open/Reopen activates Pi. **Actions** retains Overview, workspace actions, Settings and iPhone access. Devices is under **Settings → iPhone access (optional)**; the palette retains a secondary direct route. Local sessions do not need a listener. Actions → iPhone access opens listener and authenticated-device details; remote access off does not prevent local Pi work. Enter submits, Shift-Enter/Control-Enter adds a newline, Option-Enter sends follow-up while busy, and Return/Tab with suggestions completes only. Option-Up recovers queued text only to the requesting editor; Escape recovers and stops after dismissing suggestions. Explicit Stop still clears queues. `!`/`!!` open shell execution review. Mac sheets remain bounded; session-bound sheets close when the context changes. See [current behavior, checks, differences and open acceptance](pi-like-mac-verification.md).

The Session inspector, Session menu, Command-Shift-W and row context menus use the same guarded **Close Session** workflow, including working-session consent and draft preservation. Desktop has no ordinary row Close button; Pi retains its sidebar hover Close, including for the loaded-conversation alias. Overview's **View conversation** opens the loaded conversation during work without a runtime mutation. Overview groups closed history in an initially collapsed **Closed sessions (count)** disclosure. The loaded session stays in the normal group even if local closed metadata is stale. Closed Overview rows offer Reopen without a disabled Close control. The palette also provides Add workspace, Settings, Devices and displayed-loaded-idle Rename session. Ordinary Quit asks before interrupting active, waiting or uncertain work; Cancel leaves work and phone connections unchanged. Consent is checked against authoritative host state before action admission closes. Forced termination is outside this confirmation guarantee. See [review follow-up evidence and live-check limits](mac-interface.md#mac-review-follow-up).

The folder picker accepts an absolute Mac path or `~/folder`. On Mac, select **Edit path** to show the field; the iPhone field remains visible. The Mac browser also has a resolved-folder breadcrumb and **Copy full path**. **Go** opens a validated canonical directory and does not start Pi. **Start Pi Here** remains separate and is disabled while edited path text is unvalidated. Read/search permissions, symbolic-link checks, authenticated access and opaque launch IDs remain in force. Missing paths are not created; shell variables, relative paths and `~otheruser` are not expanded. See [current UI/path checks](mac-interface.md).

## Automated checks

Run from the repository root. XcodeGen 2.46.0 generated the tested project. The `DEVELOPER_DIR` override leaves the global Command Line Tools selection unchanged.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate --spec project.yml
swift test --no-parallel
swift test --package-path Packages/PiRemoteCore
swift test --no-parallel --sanitize=thread --scratch-path /tmp/pi-remote-native-tsan
xcodebuild -quiet -project PiRemote.xcodeproj -scheme PiRemoteMac \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/pi-remote-apps-mac CODE_SIGNING_ALLOWED=NO build
xcodebuild -quiet -project PiRemote.xcodeproj -scheme PiRemote \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/pi-remote-apps-ios CODE_SIGNING_ALLOWED=NO build
xcodebuild -quiet -project PiRemote.xcodeproj -scheme PiRemote \
  -destination 'platform=iOS Simulator,id=6622EB8D-23E3-4E92-9262-21CF896CD300' \
  -derivedDataPath /tmp/pi-remote-apps-ios CODE_SIGNING_ALLOWED=NO test
```

The [complementary isolated batches](mac-interface-structure.md#repeat-the-complete-mac-checks) document complete configured Mac coverage at the earlier structure checkpoint. See the [minimal Desktop verification record](desktop-minimal-ui.md) for current native test results and open normal-app/user acceptance. The legacy combined capture/menu host remains order-dependent; its failed runs and the clean-host constraint are recorded there.

Do not run the `PiRemoteInterface` compact iPhone SE suite as a current development gate. The user removed that device from the active matrix. Its [commands and results](interface-verification.md#repeat-the-review) are historical records only. During early development, prioritize normal Mac launch and focused checks; use the primary iPhone 17 Pro simulator for relevant phone smoke checks, not broad UI/E2E runs.

The simulator ID is local to this Mac. Use `xcrun simctl list devices available` to select an available simulator elsewhere. These commands do not install a signed personal build on an iPhone. An additional unsigned device-SDK build passed with destination `generic/platform=iOS` and derived-data path `/tmp/pi-remote-native-device`.

The host tests exercise a controlled fake Pi. They verify local approval, certificate and hostname rejection, unauthenticated access rejection, authenticated control, a dialog while its command remains pending, active-run reconnection without duplicate dispatch, Stop, revocation, stale IDs, file IDs used as folders, traversal-path decoding rejection, folder replacement/removal, symbolic links and loops, read/search permission loss, bounded output, unknown outcomes, replay fallback, injected stale/wrong-identity client states, session restoration, changed session headers, expired/oversized dialogs and bounded utility cancellation. The fake Pi does not prove real-provider behavior. The separate optional provider exercise verifies one native-host workflow with real saved history; it does not replace physical product acceptance.

## Failure record and remaining gates

- The first native identity test used an EC PKCS#12 identity. The macOS Security importer raised an exception while importing it. The implementation now generates RSA-2048 identities; the production TLS integration test passes with this identity.
- An incremental SwiftPM build did not discover a new source file. A clean package build discovered it and passed the tests.
- The second iOS test run failed before launch with simulator `Busy` preflight errors. After simulator boot completed, the retry passed all three tests with no skips. Local result bundles are `/tmp/pi-remote-phone-tests-1`, `/tmp/pi-remote-phone-tests-2` and `/tmp/pi-remote-phone-tests-3`. The initial native-app checkpoint also passed three tests in `/tmp/pi-remote-phone-tests-reviewed`, with zero failures and zero skips. Current 14-test evidence is in [workflow verification](workflow-verification.md). These bundles are temporary, not committed artifacts.
- A fresh product signing retry still fails with `errSecInternalComponent` in the Background session. The older signed diagnostic app is not a signed build of these product apps; see [current gates](workflow-verification.md#failures-and-external-gates).
- LAN and Tailscale authenticated transport and simulator coding checks now pass locally. Off-site operation remains unverified; it is not a plan-completion gate.
- The current [upstream Pi core RPC review](native-compatibility.md) separates host/protocol coverage from the newer native Pi-like Mac presentation target and its remaining acceptance checks. Historical isolated checks found working generic RPC menus and terminal-only extension rejections. Those package-specific limits are diagnostic evidence, not required integrations or completion blockers.
- Compact keyboard, large-text, label and recovery checks now have simulator UI-test evidence. Physical VoiceOver, dictation, TCC and sleep/wake behavior remain unverified, not completion gates. Missing-provider-credential and process-crash host checks now pass locally; see [failure evidence](workflow-verification.md#host-failure-matrix).
- The first pull-request creation attempt failed with HTTP 401. The user restored GitHub CLI authentication; `gh auth status` now passes. SSH Git access alone did not authorize pull-request creation.
