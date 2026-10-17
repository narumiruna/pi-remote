# Pi Remote — First-Version Plan

## Goal

Build a native iOS app in Swift that lets one user talk to and control Pi running on a MacBook or Mac mini. Build a Swift macOS companion that manages the connection and Pi process.

The user can choose a working directory on the Mac from their iPhone, start Pi there, watch its work, send more instructions, stop work, and return after a connection loss.

Provide native controls for the RPC protocol supplied by Pi's core packages, not an embedded terminal or terminal-feature parity. Support extension commands and interactions generically only where that core protocol exposes them. Do not add dependencies on individual extensions.

Product name: **Pi Remote**. The macOS companion is **Pi Remote for Mac**.

Status: native iOS and macOS apps build without signing. Host/client integration, 86 root tests, 36 shared tests and 31 iOS app tests pass at the [cycle/retry checkpoint](docs/runtime-controls.md#core-model-cycling-and-retry-checkpoint). The product E2E suite passes on LAN and Tailscale through a separate Herdr Pi agent. Sixteen compact-interface UI tests pass at the [release-note checkpoint](docs/release-notes.md). The two added sharing checks and both existing export checks also pass at the [system-sharing checkpoint](docs/session-export.md#system-sharing-checkpoint). The overall plan remains incomplete: core RPC coverage and acceptance still need an explicit audit. Terminal-only and extension-specific workflows are not completion requirements. Clean setup controls now have local model/transport and simulator evidence. Verification is limited to the iOS simulator and this laptop. See [workflow verification](docs/workflow-verification.md), [native app verification](docs/native-apps.md), [RPC verification](docs/verification.md) and [secure transport verification](docs/secure-transport-spike.md).

## Context

- This repository contains native SwiftUI apps, shared protocol code, an authenticated Mac host, a phone client, local RPC and secure WebSocket spikes, and an iOS diagnostic test host.
- Swift is the implementation language for the first version, including both apps and shared code.
- Pi already provides a bidirectional JSON RPC interface over a subprocess's stdin and stdout. A TypeScript backend is not required.
- Pi, project files, tools, model credentials, and command execution stay on the Mac. Pi still sends model requests to its configured provider; this is not an offline AI system.
- RPC mode supports prompts, streaming output, steering, follow-up messages, cancellation, model selection, session state, and supported extension dialogs.
- RPC starts a separate Pi process. It does not attach to an arbitrary Pi terminal session that is already running.

References for implementation:

- [Pi RPC protocol](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md)
- [RPC commands](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc-commands.md)
- [Event stream](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/json.md)
- [Extension UI](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc-extension-ui.md)
- [Session format](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/session-format.md)

These references describe the current interface. Confirm behavior against the installed Pi version before implementation.

## Accepted product decisions

- Allow selection of any folder accessible to the Mac companion; do not require approved roots or per-project registration, and do not bypass macOS permissions.
- The user-confirmed compatibility boundary is the RPC protocol provided by Pi's core packages: core operations, responses, events and the standard extension UI subprotocol.
  - Discover and invoke extension commands through the standard protocol without extension-specific imports, required packages, name-based adapters or custom message formats.
  - Do not require installed-extension compatibility, terminal-only built-in commands, custom terminal components, a bundled Pi-side adapter or upstream modifications for completion.
  - This replaces the earlier complete-terminal/installed-extension parity requirement; it does not establish that every core RPC operation is implemented or tested.
- Require both local-network access and access away from home through Tailscale for the first personal build.
- Target iPhone layouts in the iOS simulator; deployment settings are build requirements, not claims of tested hardware compatibility.
- Use this Mac as the initial development host: `sw_vers` reports macOS 26.6.2, build 25G83; this is an observed environment, not a tested support claim or minimum deployment version.
- Deliver a personal build first and prepare TestFlight distribution later; check build and signing configuration on this laptop without requiring device installation.
- Add accounts and a public connection server in a later phase so users can connect their iPhones to their own Macs without requiring Tailscale; do not implement that service in the first version.

## Verification scope

- Run all implementation, build, test and review work in the iOS simulator or on this laptop.
- Do not require a physical iPhone, another computer, device installation, hardware unlock, camera use or an off-site network test for plan completion.
- Test authentication, camera results, permissions, app suspension, network loss and host unavailability with simulator controls, local integration tests or injected fixtures. Do not require hardware interaction or put this laptop to sleep.
- Keep LAN and Tailscale support in the product scope. Verify configuration, listener binding and authenticated transport locally; do not require a remote peer or travel to another network.
- Preserve TLS validation, device authentication, local approval, credential revocation and directory-access rules. Changing the verification environment does not remove these product requirements.
- Record the limits of simulator and local evidence. Do not claim that these checks establish hardware compatibility, off-site reliability or distribution readiness.
- Earlier device-test records are historical evidence only. Requirements in this plan take precedence over device-test gates in linked verification records.

## First-Version Scope

### iOS app

- Pair with a Mac through an explicit approval step.
- Save multiple Mac connections, but control one Mac at a time.
- Show connection status, Mac availability, working directory, and session status.
- Browse Mac directories from the iPhone and select where to start Pi; do not require each project to be registered on the Mac first.
- Show the selected absolute Mac path before starting a session and keep it visible in session details.
- Create, resume, and switch companion-managed sessions while idle; associate each session with its working directory.
- Provide native command discovery and controls for supported Pi workflows, not only text prompts; use the compatibility review below to define the release scope.
- Send text prompts and render streamed Markdown, code blocks, tool activity, and errors.
- Send a steering instruction or queue a follow-up while Pi is working.
- Stop current work and clear queued instructions through one explicit Stop action.
- Select from Pi's configured models and supported thinking levels.
- Answer supported extension selection, confirmation, text-input, and editor dialogs.
- Reconnect and restore the current transcript without sending a prompt twice.
- Support standard keyboard dictation for text entry. Do not require a custom speech service.

### macOS companion

- Provide a menu-bar app with connection, pairing, project, and Pi status controls.
- Let the user select the installed Pi executable and manage directory-access permissions.
- Serve authenticated directory listings so the iPhone can select a working directory under the accepted access policy.
- Start and supervise a Pi RPC child process with the selected directory as its working directory.
- Keep Pi running when the iPhone disconnects or locks.
- Store sessions on the Mac and resume them after a companion restart.
- Show paired devices and let the user revoke access.
- Show actionable errors for missing Pi, missing credentials, lost folder access, and process failures.
- Provide a local session view and the same basic prompt and Stop controls for use at the Mac.

### Excluded from the first version

- Attaching to, mirroring, or controlling an existing Pi terminal UI.
- Remote desktop, a general-purpose terminal, or a full mobile code editor.
- Custom audio recording, live voice conversations, or spoken responses.
- Public internet exposure, a hosted relay, account registration, and multi-user access.
- Push notifications or a promise of continuous iOS background connectivity.
- Concurrent active sessions on one Mac and automatic Git worktrees.
- Automatic import of all existing Pi history.
- Extension-specific integrations, custom extension RPC protocols, terminal-only UI and built-in terminal commands without a core RPC equivalent.

Retain the implemented session, attachment, file, diff, import/export and sharing features; this scope correction does not authorize their removal. Review Pi-backed behavior against core RPC, not terminal parity. The authenticated Mac directory picker remains required and is separate from file-content browsing.

## Interface design

### Design principles

- Use a clean, minimal native interface with the conversation as the primary screen; do not reproduce the terminal layout or add a dashboard.
- Use system typography, consistent spacing, restrained color, and standard SwiftUI controls; reserve monospaced text for code, paths, and tool output.
- Support light and dark appearance, Dynamic Type, VoiceOver, sufficient contrast, and touch targets of at least 44 × 44 points.
- Show secondary controls only when needed, without removing supported Pi capabilities or hiding errors, connection loss, or active work.
- Use clear text labels for unfamiliar actions; do not rely on color or unexplained icons to communicate state.

### Main conversation

- Keep the main screen to a compact header, transcript, and composer.
- Show the session title, a compact working-directory label, and connection or run status in the header; make the full Mac path available in session details.
- Open session selection from the header and group model, thinking-level, and other secondary controls in a session menu or sheet rather than a permanent toolbar.
- Keep the composer and Send action available while idle; while working, keep Stop visible and make the steering or follow-up choice explicit before submitting another instruction.
- Show concise tool activity in the transcript with expandable output; keep errors and pending extension dialogs visible without requiring users to expand a tool result.
- Keep the reader's scroll position when new output arrives; follow live output only when already at the bottom and offer a return-to-latest action otherwise.

### Directory and session selection

- Use a native directory-picker sheet with the current Mac path, parent navigation, folder rows, and one clear action to start Pi in the selected directory.
- Distinguish opening a folder from selecting it as the working directory; show loading, empty, and access-denied states in place.
- Show session titles and working directories in the session list so sessions in different folders are easy to distinguish.
- Keep pairing and connection settings outside the normal coding flow after setup; show recovery actions when the connection fails.

## Architecture

### Components and ownership

| Component | Technology | Responsibility |
| --- | --- | --- |
| iOS client | Swift, SwiftUI, Network.framework | Connection management, transcript, input, and native controls |
| macOS companion | Swift, SwiftUI, Foundation Process | Pairing, project access, session ownership, and Pi process supervision |
| Shared package | Swift Package Manager, Codable | Versioned transport messages, client state, and test fixtures |
| Pi runtime | Existing installed Pi CLI | Agent execution, tools, provider access, and persistent Pi sessions |

Use one repository with `Apps/iOS/`, `Apps/macOS/`, and `Packages/PiRemoteCore/`. Keep platform-specific process and networking code outside the shared package.

The intended data path is iOS client → authenticated secure connection → Mac companion → local JSON RPC → Pi. Responses and events return along the same path.

### Core RPC coverage and compatibility

- Inventory the operations, responses, events and standard extension UI methods documented by the selected Pi core runtime; map each to app behavior and direct verification evidence.
- Keep unimplemented or unverified core RPC behavior open. Do not treat a scope change or passing tests for a subset as proof of complete protocol coverage.
- Support discovered command names and arguments through `get_commands` and `prompt`; do not hardcode individual extensions or assume that discovery proves a command works in RPC.
- Render standard extension dialogs and supported notifications, text widgets, status and editor updates generically; verify cancellation, expiry and stale-answer rejection with controlled fixtures.
- Treat terminal-only commands, custom terminal rendering and extension-specific protocols as outside scope, not as adapter approval blockers.
- Use native forms, menus, transcript views and dialogs. Keep raw Pi RPC behind the authenticated companion and preserve session ownership, typed app actions and bounded data handling.
- Audit core `bash`/`abort_bash` coverage against the no-general-terminal constraint before implementing controls; this documentation change does not authorize an arbitrary shell endpoint.

### Working-directory selection

- The iPhone browses the Mac filesystem, not the iPhone filesystem; browsing selects an existing directory and does not execute a shell command.
- Allow browsing and launch selection across all directories accessible to the companion; do not add an approved-root restriction or request elevated privileges to bypass macOS permissions.
- Return directory names, display paths, parent navigation, and opaque directory IDs through authenticated, bounded listings; file-content access is a separate capability.
- Resolve directory IDs and symbolic-link targets on the Mac and validate access again before launch; allow accessible targets and report broken links, loops, and permission failures.
- Set the child process working directory explicitly and persist it with the session; restoring a session must not silently move it to another directory.
- Reject directory and session switches while Pi is working; require the user to stop work and reach idle first.
- Show actionable errors for inaccessible, deleted, or moved folders; do not start Pi in a fallback directory.

### Swift transport

- Use an authenticated secure WebSocket connection for commands, responses, and events.
- Prototype an Apple Network.framework server on macOS and URLSession WebSocket client on iOS before building the screens. Verify TLS trust and WebSocket interoperability with local integration tests and the iOS simulator.
- If the prototype cannot meet those requirements, record the reason and select a maintained Swift server library before implementation continues. Do not add a Node.js or TypeScript service.
- Start with a manually entered address. Add local discovery only if setup tests show that it is necessary.
- Support both the local network and Tailscale in the first version; verify address selection, listener binding and authenticated connections on this laptop. Document that off-site behavior is not established by local tests.
- Do not require router port forwarding. Do not use an unencrypted public listener.

### Later public connection service

- After the personal build, plan account registration and a public service that connects an iPhone to its user's Mac; the Mac companion remains responsible for Pi execution and local permissions.
- Decide account authentication, device enrollment, relay routing, end-to-end encryption, recovery, abuse controls, and hosting before implementation; do not treat account sign-in alone as authorization to control a Mac.
- Evaluate passkeys for account sign-in during that phase; do not add an account service or speculative transport abstraction to the first version.
- Keep direct and Tailscale connections available as the first implementation; the future service must not require exposing the Mac directly to the public internet.

### Pi process and session lifecycle

- Use Foundation Process with an executable URL and an argument array. Do not construct a shell command from remote input.
- Launch Pi in RPC mode with persistent sessions enabled. Resolve the exact startup arguments from the selected Pi version.
- Maintain one active Pi process and one active session per Mac in the first version. Reject project or session switches while work is active.
- Only the companion writes to its managed sessions. Do not open the same session for writing in a separate terminal Pi process.
- Persist the mapping between app session IDs, working-directory IDs, resolved Mac directories, and Pi session files. Remote clients use opaque IDs for commands; display paths do not authorize access.
- A phone disconnection does not terminate the process. A companion exit stops its managed process after an orderly shutdown attempt.
- After a Mac or companion restart, offer session restoration. Do not automatically repeat an interrupted prompt or claim that an interrupted tool completed.
- Treat Mac sleep as an interruption to availability. The first version does not promise to wake a sleeping Mac or keep a closed MacBook running.

### Protocol and synchronization

- Define an app protocol with a version, request ID, session ID, host epoch, event sequence, and typed payload. Keep raw Pi RPC behind the companion boundary.
- Negotiate the app protocol version and report the selected Pi version and supported capabilities during connection setup.
- Allow only commands that the app implements. Do not expose arbitrary RPC forwarding, arbitrary session paths, or a general shell endpoint.
- Parse Pi stdout as UTF-8 JSONL split only on LF; support partial records and CRLF. Keep stderr separate and continuously drain both streams.
- Correlate RPC responses by request ID. A successful prompt response means acceptance, not completion.
- Build live text from deltas and replace it with the authoritative completed message at `message_end`.
- Use `agent_settled`, not just `agent_end`, to determine that automatic work has ended. A prompt reported as handled does not necessarily start a run.
- Serialize state-changing commands from the iPhone and Mac controls. Show conflicts instead of applying incompatible actions at the same time.
- For Stop, clear queued instructions before aborting active work. Confirm the resulting idle state; stopping does not undo file changes or external side effects.
- Record client request IDs and outcomes for reconnect deduplication. If the companion crashes between dispatch and recording acceptance, report an unknown outcome rather than automatically resending.
- Maintain an authoritative companion snapshot and a bounded event buffer. Establish a snapshot and event cursor without a gap; replay later events in sequence.
- On a reconnect, replay buffered events when possible. If the cursor expired or the host epoch changed, replace client state with a fresh snapshot built from Pi state and managed history.
- Retain pending extension dialogs on the Mac while disconnected. Reject stale answers after a dialog expires or resolves. Do not automatically approve a request.
- Bound frame sizes and output buffers. A slow phone must not stop the companion from reading Pi stdout. On overflow, require snapshot recovery rather than keeping an unlimited queue.

### Security and permissions

Remote access to Pi can lead to file changes and shell execution with the Mac user's permissions. Treat a paired device as a trusted remote controller, not as a read-only chat client.

- Pair only while the Mac user has opened a short-lived pairing window. Require local confirmation of the device and server identity.
- Verify TLS server identity during initial pairing and pin it for later connections. Never silently trust a changed certificate or disable certificate validation globally.
- Generate a separate high-entropy credential for each paired device. Store credentials in Keychain, authenticate each connection, and support immediate revocation.
- Require Face ID or the iPhone device passcode before exposing transcripts, directory listings, or remote controls after app launch or return from the background; verify access-control settings and denied-access behavior with simulator and local tests.
- Keep local app unlocking separate from Mac authentication; blocking the phone UI must not cancel work already running on the Mac.
- Rate-limit pairing attempts. Reject unpaired, expired, replayed, and revoked credentials.
- Bind only to intended interfaces and document firewall and private-network setup. A private network is not a substitute for application authentication.
- Validate directory IDs and macOS access on the Mac for every listing and launch; reject stale IDs and malformed requests without assuming that a directory is forbidden merely because it is outside a project.
- Require authentication for directory listings because folder names and paths can expose private information.
- Directory-access rules limit app browsing and launch selection; they are not a security sandbox for Pi's tools. Explain this limit during setup.
- Keep provider credentials on the Mac. Exclude secrets, pairing data, prompt text, and tool output from routine diagnostic logs.
- Do not assume Pi asks for approval before every tool call. Supported extension dialogs are not a complete command-permission system.
- Start with personal iOS and macOS builds; check build configuration, folder permissions and implemented lifecycle behavior in the simulator and on this laptop. Device provisioning and installation are not completion requirements.
- Before later distribution, validate TestFlight requirements for iOS and signing and notarization for the directly distributed macOS companion.
- Request required iOS local-network permissions and define a deliberate certificate-trust flow. Do not add broad App Transport Security exceptions as a workaround.

## Plan

### 1. Resolve implementation blockers

- [x] Check iOS/macOS deployment settings and personal-build configuration against the local SDKs; unsigned macOS, iOS simulator and iOS device-SDK builds pass with automatic signing configured and provisional iOS 18/macOS 15 deployment floors. No team or installation is required for this local configuration check. See [local audit](docs/workflow-verification.md#local-plan-audit).
- [ ] Audit this laptop's Pi version, executable and authentication setup against the core RPC protocol; inventory every documented operation, event and standard extension UI method with implementation status and verification evidence. Installed-extension parity is not a gate.
- [x] Validate directory access on this laptop, including symbolic-link targets and permission-denial fixtures; local filesystem tests pass read/search denial, broken links, loops, removed/replaced selections and canonical alias launch. No approved roots or privacy-grant changes were added. See [directory evidence](docs/workflow-verification.md#directory-browsing-and-launch-protection).
- [x] Select Keychain protection settings for the Face ID or device-passcode unlock policy; `WhenPasscodeSetThisDeviceOnly` plus `userPresence` remains selected. Three simulator tests pass denied/failed unlock, background return and delayed success after simulated lock; locked secret tests fail closed. Production TLS revocation closes access without cancelling Pi, which local Stop still controls. See [local unlock evidence](docs/workflow-verification.md#local-unlock-and-revocation).
- [x] Build a Swift command-line spike that launches Pi, sends a prompt, streams output, stops work, and resumes a persisted session; Pi 1.3.0 passed streaming, settlement, active-run Stop, working-directory, and saved-session assertions, with 15 RPC tests and seven shared-package tests; see [verification evidence](docs/verification.md).
- [x] Build a secure WebSocket implementation with server-identity verification; local production TLS tests pass certificate/hostname rejection, pairing, authenticated reconnection and revoked-access rejection; see [local integration evidence](docs/native-apps.md#automated-checks).
- [x] Test Tailscale address selection and listener binding with a local client on this laptop; production tests pass exact loopback, LAN and Tailscale binding, authenticated control, one-dispatch reconnection, Stop and revocation. Twenty-five simulator tests also pass with the provider fixture on LAN and Tailscale. See [transport correction and simulator evidence](docs/workflow-verification.md#local-plan-audit).

### 2. Establish the Swift workspace and contract

- [x] Create the two app targets and shared Swift package; both unsigned targets build and shared package tests pass with the commands in [native app verification](docs/native-apps.md#automated-checks). Personal-build configuration remains a separate local check.
- [x] Define versioned app messages, capability negotiation, errors, and session state; protocol tests verify typed round trips and rejection of unsupported versions. Version 1 is required; authenticated state reports the Pi version and implemented capabilities.
- [x] Implement the Pi JSONL adapter and process supervisor; shared framing and root RPC tests pass for partial UTF-8, Unicode separators, malformed records, stderr load, startup failure, backpressure and unexpected exit. The adapter now lives in `Packages/PiRPC/`.

### 3. Build the Mac host

- [x] Implement Pi selection, directory listing and validation, and companion-owned session storage; the installed-Pi checks and simulator coding fixture pass creation and restoration in the selected canonical directory. The fixture uses private session storage and confirms unchanged agent settings; see [simulator coding and recovery](docs/workflow-verification.md#simulator-coding-and-recovery).
  - Verified: private-catalog tests cover creation, restart, header IDs and directory aliases. Installed-Pi checks pass creation, idle restoration and nonempty provider-history restoration after coordinator restart in the selected directory, without changing agent settings.
- [x] Test directory-access enforcement with unauthenticated requests, stale IDs, inaccessible folders, symbolic links, traversal attempts, and a folder removed between selection and launch; production TLS and filesystem tests pass. Rejected creation requests start no process or session; lost read/search permissions reject resume before replacing Pi. Local permission-denial coverage remains in step 1; see [directory evidence](docs/workflow-verification.md#directory-browsing-and-launch-protection).
- [x] Implement pairing, credential storage, authentication, and revocation; production TLS integration tests pass local approval, certificate/hostname rejection, unauthenticated request rejection and revoked reconnection rejection. Registry tests verify persistent credentials and fail-closed secret-deletion failure.
- [x] Implement prompt, steering, follow-up, Stop, model selection, and thinking-level controls; Pi 1.3.0 passes isolated model/thinking changes and the native-provider exercise passes live text, steering/follow-up delivery and active Stop with queued instructions. These are local host checks; see [provider evidence](docs/workflow-verification.md#native-provider-check).
- [x] Implement snapshot synchronization, event replay, request deduplication, and bounded buffers; tests pass active-run reconnection with identical final messages and one dispatch, contiguous state replay, expired-cursor/epoch fallback, unknown outcomes and UTF-8 output limits.
- [x] Implement menu-bar status and local session controls; prove local and remote actions share the same serialized session state. The unsigned Mac app builds, and `PiRemoteMacTests` passes the production `CompanionModel` against a paired TLS client: shared transcript/run state, local Send/follow-up/Stop, remote steering, cross-client mutation exclusion, dialog completion and stale-action rejection.

### 4. Build the iOS client

- [x] Create and review a small SwiftUI interface prototype covering directory selection, an idle conversation, streaming with tool output, Stop, session controls, and reconnection; six compact-simulator UI tests pass twice, and captures confirm the header/transcript/composer layout. See [interface evidence](docs/interface-verification.md).
- [x] Implement pairing, saved Mac connections, the Mac directory picker, and session selection; use simulator and local integration tests to navigate nested folders and start Pi in a selected directory without prior project registration. The production `PhoneModel` now pairs, saves and reloads Mac/device metadata, starts the selected nested session and sends the coding task in the simulator integration test. All 25 app tests pass on both LAN and Tailscale; bounded picker, session and stale-selection tests pass separately.
  - Verified: six simulator tests cover bounded picker pages, cached back/forward navigation, stale/cancelled requests, stale previews and retry after denied navigation. QR-code display and an in-app scanner are now implemented. Five additional tests cover QR encode/decode and invalid, expired and stale scans; all 19 iOS tests pass. Verify camera-result and permission handling with injected inputs, not a physical camera; see [QR evidence](docs/workflow-verification.md#qr-code-pairing).
- [ ] Complete the native controls and generic protocol handling identified by the core RPC audit; verify them against the installed Pi RPC runtime with controlled fixtures and report unsupported core behavior explicitly.
- [x] Implement a streamed transcript with Markdown, code blocks, expandable tool output, and clear run states; shared tests pass authoritative text/thinking reconstruction, error visibility, retry, compaction and cancellation settlement. Hosted UIKit fixtures cover idle, working, retrying, compacting and interrupted states; see [workflow evidence](docs/workflow-verification.md).
- [x] Implement the composer, steering/follow-up choice, Stop, model controls, and supported extension dialogs; verify actions against the Mac host, including expired dialogs. Installed-Pi `NativeWorkflowCheck` passes select, confirm, input, editor and actual dialog expiry/late-answer rejection. Provider, Mac integration and simulator checks cover active steering/follow-up/Stop and model controls; see [workflow evidence](docs/workflow-verification.md).
- [x] Implement foreground reconnection, draft retention, disconnected status, and snapshot replacement; simulator tests pass protected background/lock state, retained drafts after Home/activate, disconnected recovery and stale-state rejection. Production TLS and simulator provider tests pass connection loss and idle/active host restart without prompt redispatch. These are local and injected-policy checks, not hardware suspension claims; see [interface](docs/interface-verification.md) and [recovery](docs/workflow-verification.md#simulator-coding-and-recovery) evidence.
  - Verified: simulator tests cover retained per-session drafts, protected background state, stale editor offers and resend confirmations. TLS tests reject wrong-host, wrong-epoch and stale-session contexts before dispatch.
- [x] Verify light and dark appearance, Dynamic Type, VoiceOver labels, contrast, touch targets and keyboard use in simulator tests and local view inspection; six UI tests pass requested target/description audits, real-keyboard frame checks and capture review at accessibility-extra-large text. Color-pair tests pass 4.5:1. Native text input and its standard dictation control remain; see [scope and limits](docs/interface-verification.md).
- [x] Test a compact iPhone simulator layout with the keyboard open and large text enabled; iPhone SE simulator checks at 375 × 667 points pass folder selection from a keyboard-open conversation, intact prompt entry, Stop, recovery, session controls and editor Submit/Cancel above the keyboard. Long paths scroll instead of displacing controls. See [interface checks](docs/interface-verification.md#checks).

### 5. Validate and prepare the first release

- [x] Add automated protocol and integration tests with a fake Pi process; 59 root tests and 18 shared-package tests pass. Coverage includes rejected commands, unknown outcomes, directly injected stale/wrong-identity client states, epoch/cursor fallback, invalid credentials, bounded output, malformed WebSocket frames, invalid certificate dates and active-run TLS reconnection without duplicate dispatch on LAN and Tailscale. All 59 root tests also pass with Thread Sanitizer.
- [x] Run a simulator-to-local-host coding flow through pairing, a coding task, client disconnection, reconnection, Stop and session restoration; the production client/host fixture passes on LAN and Tailscale with Pi 1.3.0. It verifies exact tool-written file contents, one user-prompt delivery, preserved working directory, idle restoration and explicitly marked interruption after active host restart. It does not claim full UI or installed-extension acceptance. See [simulator evidence](docs/workflow-verification.md#simulator-coding-and-recovery).
- [x] Test simulated host unavailability, lost project access, missing model credentials and Pi crashes on this laptop; verify actionable errors and no automatic re-execution of interrupted work. All 61 root tests pass normally and with Thread Sanitizer. The isolated installed-Pi `NativeFailureCheck` passes real missing-credential rejection and empty-session restoration; see [failure evidence](docs/workflow-verification.md#host-failure-matrix).
- [x] Document supported Pi versions, setup, security limits, network requirements, session ownership, and recovery in README.md; validate the instructions with a clean simulator setup and local companion storage on this laptop. Pi 1.3.0 is the only tested development runtime, not a complete-workflow support claim. Two Mac-model tests pass new-storage listener setup, approval persistence, restart and revocation. The fresh-preferences simulator/provider flow passes product-model pairing, saved Mac metadata, selected-directory launch and coding. See [clean setup evidence](docs/workflow-verification.md#clean-setup-controls); signed installation and hardware behavior remain outside this local verification scope.

## Remaining work and verification limits

- Core model/thinking cycling, acknowledged automatic-retry requests and retry-wait cancellation now pass package, installed-Pi and four focused UI checks. Active real-retry lifecycle verification remains open; see [cycle/retry evidence](docs/runtime-controls.md#core-model-cycling-and-retry-checkpoint).
- Complete the [core RPC coverage audit](docs/native-compatibility.md). Existing test checkpoints do not establish coverage of every documented operation, event or standard extension UI method. Record direct evidence before closing the remaining plan items.
- Terminal-only extension rejection no longer blocks this plan. The user confirmed a core-RPC-only boundary. Do not add a bundled adapter, modify upstream packages or require the user's extension inventory to satisfy acceptance.
- Keep the existing verified features and evidence: directory access, authenticated LAN/Tailscale transport, pairing/revocation, synchronization, managed sessions, prompts/queues/Stop, model/thinking controls, generic dialogs, resources, compaction, history, images, attachments, import/export, release notes and native system sharing. Their linked checkpoints remain limited to the checks actually run.
- Xcode checks use a command-local `DEVELOPER_DIR` override; do not change the user's global developer-directory selection. Signed installation, hardware authentication and off-site operation remain unverified and are not current completion gates.
- `AGENTS.md` still says that no app build/test configuration exists. `project.yml` now provides it; the instruction file needs a separate reviewed maintenance change.

## Risks and Recovery

- **Pi interface changes:** record tested versions, keep decoding fixtures, and reject unsupported capabilities with an upgrade message.
- **Extension differences:** verify generic core RPC interactions with controlled fixtures. Report terminal-only or custom-protocol limits without adding extension-specific dependencies or promising compatibility with individual packages.
- **Connection loss:** work can continue on the Mac. Preserve the phone draft and resynchronize before accepting new commands.
- **Companion crash:** preserve Pi session files and report uncertain command outcomes. Do not claim exactly-once execution across a process crash.
- **Interrupted tools:** a saved conversation does not prove a tool completed. Require review before resuming an interrupted task.
- **Conflicting filesystem edits:** local editors can still modify the project. The first version does not isolate work or merge conflicting changes.
- **Credential compromise:** revoke the device on the Mac, close its connections, and require new pairing.
- **Failed app upgrade:** retain session files and avoid destructive migrations. Back up companion metadata before a format change and document downgrade compatibility.
- **Removal:** stop the companion, revoke devices, and remove its login item if enabled. Do not delete project files, provider credentials, or Pi sessions automatically.

## Completion Checklist

- [x] Both apps and all app-owned service code are written in Swift; no TypeScript backend is required. See `Apps/`, `Packages/`, root `Package.swift` and `project.yml`.
- [x] Simulator interface review confirms the minimal conversation layout, directory picker and secondary controls remain readable and reachable with large text and the keyboard open; six UI tests and reviewed captures pass, including live scroll retention and the bounded 100-message transcript.
- [x] The iOS simulator securely connects to the production host on this laptop, browses permitted directories and starts Pi in the selected directory; the explicit provider fixture passes on LAN and Tailscale.
- [x] Session details use the session's canonical directory. Installed-Pi, package and simulator restart checks verify that restoration preserves it without a silent fallback; changed or inaccessible directories are rejected.
- [x] Any companion-accessible folder can be selected without prior project registration; access-denial, stale-selection, and symbolic-link tests pass without bypassing macOS permissions. The simulator browses from home through `/` into a new nested fixture directory.
- [x] Simulator and local tests verify that the unlock policy protects transcripts, directory browsing and remote controls, and that device revocation closes access without cancelling Mac-side work; injected denial/background/stale-success cases and active-run TLS revocation pass. Hardware claims remain excluded.
- [ ] The core RPC audit covers every documented operation, event and standard extension UI method for the tested runtime; in-scope behavior passes direct checks and remaining core gaps are resolved. No installed-extension or terminal-parity gate applies.
- [x] Text streaming, tool activity, steering, follow-up, Stop, and supported extension dialogs pass the recorded test cases. Installed-Pi checks cover all four supported dialog methods and expiry; simulator provider tests cover tool-written results and stream/recovery controls.
- [x] A simulated client disconnect does not stop Pi; production fake-Pi tests verify one dispatch and restored active state, and the simulator provider flow verifies one prompt and the completed coding result after reconnection.
- [x] Session restoration works after a host restart. Simulator checks pass idle and active restart, retained working directories, an interrupted-session flag and unchanged idle messages after explicit restoration, without resending a prompt.
- [x] Unpaired and revoked devices cannot access the host; production TLS tests pass unauthenticated browsing rejection, active revocation, revoked reconnection, changed-certificate rejection, hostname rejection and expired/future certificate rejection.
- [x] Build commands, automated tests, simulator execution and local setup instructions have recorded passing results. Current evidence includes 86 root tests (also Thread Sanitizer), 36 shared tests (also Thread Sanitizer), three macOS tests, 31 product simulator tests with the local provider fixture, sixteen prior compact-interface regressions plus two new sharing checks and repeated export checks in bounded batches, and unsigned Mac/simulator/device-SDK builds. This does not close the separate compatibility acceptance gate.
- [ ] Audit local evidence for LAN/Tailscale selection, listener binding, authenticated transport and simulated host unavailability; confirm that setup/version guidance and documented protocol limits match the accepted core RPC scope without off-site or hardware claims.
