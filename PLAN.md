# Pi Remote — First-Version Plan

## Goal

Build a native iOS app in Swift that lets one user talk to and control Pi running on a MacBook or Mac mini. Build a Swift macOS companion that manages the connection and Pi process.

The user can choose a working directory on the Mac from their iPhone, start Pi there, watch its work, send more instructions, stop work, and return after a connection loss.

Support every documented operation, response, event and standard extension UI method supplied by the tested version of upstream Pi core packages, including `bash` and `abort_bash`, through native controls. The no-embedded-terminal rule is a UI constraint; it must not exclude native upstream Pi core RPC functionality. Support extension commands and interactions generically only where that upstream protocol exposes them. Do not add dependencies on individual extensions.

Product name: **Pi Remote**. The macOS companion is **Pi Remote for Mac**.

Status: unsigned Mac, iOS simulator and device-SDK builds pass. The [earlier upstream Pi core RPC acceptance checkpoint](docs/core-rpc-acceptance.md) passes 135 root tests and 50 shared tests, both with and without Thread Sanitizer, three Mac-model tests and all 31 product simulator tests on each of LAN and Tailscale. A separate Herdr Pi agent ran the product E2E checks and verified unchanged source/settings and child/listener cleanup. Installed-Pi checks verify generic UI, resources, retry, authoritative inspection and same-child lifecycle; the real provider workflow also passes. The plan remains incomplete. The Mac shell controls now have isolated host/runtime checks and native fixtures; iPhone shell entry and attended Mac workflow acceptance remain open. Terminal-only and individual-extension workflows are not completion requirements. These results establish local simulator/laptop behavior, not signed installation, hardware or off-site support. Later Mac UI and manual path-entry changes have [separate verification](docs/mac-interface.md); earlier suite counts are not evidence for those changes.

## Context

- This repository contains native SwiftUI apps, shared protocol code, an authenticated Mac host, a phone client, local RPC and secure WebSocket spikes, and an iOS diagnostic test host.
- Swift is the implementation language for the first version, including both apps and shared code.
- Pi already provides a bidirectional JSON RPC interface over a subprocess's stdin and stdout. A TypeScript backend is not required.
- Pi, project files, tools, model credentials, and command execution stay on the Mac. Pi still sends model requests to its configured provider; this is not an offline AI system.
- RPC mode supports prompts, streaming output, steering, follow-up messages, cancellation, model selection, session state, and supported extension dialogs.
- RPC starts a separate Pi process. It does not attach to an arbitrary Pi terminal session that is already running.

References for implementation:

- [Upstream Pi core RPC protocol](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md)
- [RPC commands](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc-commands.md)
- [Event stream](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/json.md)
- [Extension UI](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc-extension-ui.md)
- [Session format](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/session-format.md)

These references describe the current interface. Confirm behavior against the installed Pi version before implementation.

## Accepted product decisions

- Allow selection of any folder accessible to the Mac companion; do not require approved roots or per-project registration, and do not bypass macOS permissions.
- The user-confirmed compatibility boundary is the RPC protocol supplied by upstream Pi core packages: operations, responses, events and the standard extension UI subprotocol.
  - Discover and invoke extension commands through the standard protocol without extension-specific imports, required packages, name-based adapters or custom message formats.
  - Do not require installed-extension compatibility, terminal-only built-in commands, custom terminal components, a bundled Pi-side adapter or upstream modifications for completion.
  - This replaces the earlier complete-terminal/installed-extension parity requirement; it does not establish that every upstream Pi core RPC operation is implemented or tested.
- Upstream Pi core `bash`/`abort_bash` support is required, not an unresolved approval decision. Provide native command, output and cancellation controls. The restriction is against an embedded terminal or PTY, not shell execution through upstream Pi core RPC.
  - Keep execution on the Mac through typed, authenticated, session-bound actions. Require execution confirmation, bound output and preserve unknown-outcome/no-replay handling.
- Require both local-network access and access away from home through Tailscale for the first personal build.
- Target iPhone layouts in the iOS simulator; deployment settings are build requirements, not claims of tested hardware compatibility.
- Use this Mac as the initial development host: `sw_vers` reports macOS 26.6.2, build 25G83; this is an observed environment, not a tested support claim or minimum deployment version.
- Deliver a personal build first and prepare TestFlight distribution later; check build and signing configuration on this laptop without requiring device installation.
- Add accounts and a public connection server in a later phase so users can connect their iPhones to their own Macs without requiring Tailscale; do not implement that service in the first version.

## Verification scope

- During early development, prioritize a usable Mac app over broad UI/E2E coverage. Reproduce and fix failures in the normally launched app before expanding automation.
- Use this Mac for local Pi operation and focused host checks. Use only the iPhone 17 Pro simulator, iOS 26.5, for a minimal phone smoke check when a change affects the phone workflow.
- Remove iPhone SE (3rd generation), iOS 26.5, and the `PiRemoteCompact` simulator from the active verification matrix. Do not run its compact-layout or large-text suites as current development gates. Existing tests and results remain historical records; they do not require deleting the installed simulator.
- Run focused checks that match each change. Defer broad UI/E2E suites and device/layout matrices until the basic workflows are usable or the user explicitly requests them. Preserve security checks for changed authentication, permissions and process boundaries.
- Run implementation, build, test and review work in the primary iOS simulator or on this laptop.
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
- Execute commands through upstream Pi core `bash`, display bounded streamed output and final results, and cancel through upstream Pi core `abort_bash`, using native controls without an embedded terminal.
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
- Start and supervise an upstream Pi core RPC child process with the selected directory as its working directory.
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
- Extension-specific integrations, custom extension RPC protocols, terminal-only UI and built-in terminal commands without an upstream Pi core RPC equivalent.

Retain the implemented session, attachment, file, diff, import/export and sharing features; this scope correction does not authorize their removal. Review Pi-backed behavior against upstream Pi core RPC, not terminal parity. The authenticated Mac directory picker remains required and is separate from file-content browsing.

## Interface design

### Pi-like Mac presentation

The user requested a native Swift recreation of the terminal Pi interface, not only equivalent controls in a workspace-first app. Follow the [Pi-like Mac interface plan](docs/plans/2026-10-18_pi-like-mac-interface-plan.md) for reference review, implementation and acceptance. The native transcript/editor/footer, keyboard editor, generic dialogs and reviewed shell controls are implemented. Focused fixture evidence is recorded in [Mac redesign verification](docs/pi-like-mac-verification.md); live terminal capture comparison and user acceptance remain open. This Mac direction replaces the earlier light workspace-first presentation. Existing RPC, security, session and iPhone requirements remain; protocol gaps need an approved alternative or explicit exclusion, not an implicit adapter requirement.

The reference-driven Mac refinements add compact tool outcomes, scroll-anchored disclosure, native code-copy controls with bounded lexical colors, and provider-grouped model selection. See [implementation, reference choices and check evidence](docs/mac-reference-uiux.md). These changes retain the Pi-like layout and do not close the separate normal-launch, full accessibility or user visual-acceptance checks.

### Design principles

- Use a native interface with the conversation as the primary work area; do not embed a terminal or web dashboard.
  - On Mac, reproduce the installed Pi terminal layout and interaction with SwiftUI and AppKit. Use the selected dark reference and monospaced text, not a general theme system. Start with the workspace sidebar hidden; retain it and the Files/Session/Activity inspector as secondary controls.
  - Keep the iPhone conversation-first layout and existing upstream Pi core RPC contracts.
- Use Pi's UI terms consistently in both apps: prompt, steering, follow-up, thinking level, steering mode, follow-up mode, assistant message and changelog. Keep instructions for system and compaction instructions. Preserve app-specific workspace, connection and device terms.
- Keep system typography and touch controls on iPhone. On Mac, use compact monospaced typography and Pi-like semantic colors, while preserving native text selection, IME and accessible controls.
- Support light and dark appearance, Dynamic Type, VoiceOver and sufficient contrast. Use touch targets of at least 44 × 44 points on iPhone and native system control sizes on Mac.
- Show secondary controls only when needed, without removing supported Pi capabilities or hiding errors, connection loss, or active work.
- Use clear text labels for unfamiliar actions; do not rely on color or unexplained icons to communicate state.

### Main conversation

- Keep the main screen to a compact header, transcript, and composer.
  - On Mac, keep the Pi startup logo/help and Context/Skills/Prompts sections in the content flow. Derive skill/prompt names from RPC discovery; state explicitly that context paths are unavailable through RPC. Use one scroll flow through output, the one-line-growing editor and footer, without a fixed empty gap before input. Preserve generic extension slots; custom TUI factories require a separate protocol decision, not guessed native content.
- On iPhone, show session identity and connection/run status in the header. On Mac, show the working directory, available usage, model, thinking and execution phase in the footer; retain session identity and management in the optional sidebar and Session controls.
- On iPhone, open session selection from the header. On Mac, select sessions beneath their workspace in the sidebar. Group model, thinking-level and other secondary controls in a session menu or inspector rather than a permanent toolbar.
- Resolve Mac display labels from actual Pi names, first meaningful user instructions or stable IDs without changing persisted names. Disambiguate collisions within each workspace, including generated suffix collisions. Read saved metadata through a bounded, local-only, validated file path; do not activate Pi to obtain a label.
- Keep one prominent Mac New session action in the toolbar, with contextual creation in workspace menus. Keep Add workspace and Import in the workspace actions menu and pin Devices/Settings below the workspace list.
- Use a bounded native Mac editor between thinking-colored rules. Enter submits; Shift-Enter/Control-Enter inserts a newline. Option-Enter submits follow-up while busy and a prompt while idle. Up/Down selects suggestions, Return/Tab completes and Escape dismisses; completion never executes commands. Disable empty/unavailable submission and protect IME composition. Keep standard widgets in their upstream above/below-editor slots and status entries in the footer. Informational diagnostics start collapsed in Activity; warnings/errors remain visible. Do not flatten all extension UI into a message block.
- Keep the Mac conversation visible without Conversation/History tabs. `/resume`, `/tree` and `/history` open bounded native workflows; discovered commands use the existing scoped `.command` action and uncertain-outcome guards. Preserve ordinary text and absolute paths. Do not forward terminal-only navigation commands as Pi prompts.
- Keep the iPhone composer and Send action available while idle, with an explicit steering/follow-up choice while working. On Mac, keep keyboard delivery and visible Stop available. Escape can recover queued input before stopping; Option-Up recovers without abort. Offer recovered text only to the requesting editor and never resend it.
- Show concise tool activity in the transcript with expandable output; keep errors and pending extension dialogs visible without requiring users to expand a tool result.
  - On Mac, show the reported action, bounded target and known outcome. Preserve the heading position during disclosure and keep the reader in reading mode while output arrives. Distinguish interrupted/unconfirmed work from completed results; final upstream outcome flags replace provisional errors.
  - Keep Mac code blocks selectable and leading-aligned. Copy only the displayed code after an explicit action, with visible success/failure feedback. Use bounded lexical coloring with a plain-text fallback; do not execute code or imply full syntax/artifact support.
  - Group Mac model choices by the reported provider and identify the current choice. Search and arrow navigation must not apply a change; only explicit Apply/Return dispatches a context-bound request.
- Keep the reader's scroll position when new output arrives; follow live output only when already at the bottom and offer a return-to-latest action otherwise.

### Directory and session selection

- Use a native directory-picker sheet with the current Mac path, parent navigation, folder rows, and one clear action to start Pi in the selected directory.
- Distinguish opening a folder from selecting it as the working directory; show loading, empty, and access-denied states in place.
- Support typed or pasted absolute Mac paths and `~/folder` with an explicit Go action. Resolve and validate on the Mac without shell expansion or folder creation. Go must not start Pi; require explicit selection of the resolved folder. An edited, failed or pending path must not start a session in the previous folder.
- Show session titles and working directories in the session list so sessions in different folders are easy to distinguish.
- Keep pairing and connection settings outside the normal coding flow after setup; show recovery actions when the connection fails.
- In the Mac app, show Pi execution beside the displayed session and expose listener/authenticated-device details through one remote-access summary. Show active-session status on other destinations. Local work does not require a listener. Put network, executable and folder access in Settings, pairing/revocation in Devices, and identity replacement under Settings → Advanced.
- On Mac, expose Commands and Files through the secondary Actions menu; slash completion remains in the editor. Use the inspector as the single Files destination. Show a resolved-folder breadcrumb with explicit Edit path and Copy full path actions; keep canonical-path review before folder selection.
- Bound Mac sheets to the parent window, scroll long forms and keep Close visible. Before Mac session selection, show compact Pi startup hints and explicit New session/Resume controls; the prompt cannot submit until a session is loaded. Persist workspace visibility, expansion, selected metadata, inspector/layout preferences and bounded unsent drafts. UI selection must not activate a saved session while another is working.

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

<a id="core-rpc-coverage-and-compatibility"></a>

### Upstream Pi core RPC coverage and compatibility

- Inventory the operations, responses, events and standard extension UI methods documented by the tested version of upstream Pi core packages; map each to app behavior and direct verification evidence.
- Keep unimplemented or unverified upstream Pi core RPC behavior open. Do not treat a scope change or passing tests for a subset as proof of complete protocol coverage.
- Support discovered command names and arguments through `get_commands` and `prompt`; do not hardcode individual extensions or assume that discovery proves a command works in RPC.
- Render standard extension dialogs and supported notifications, text widgets, status and editor updates generically; verify cancellation, expiry and stale-answer rejection with controlled fixtures.
- Treat terminal-only commands, custom terminal rendering and extension-specific protocols as outside scope, not as adapter approval blockers.
- Use native forms, menus, transcript views and dialogs. Keep raw upstream Pi core RPC behind the authenticated companion and preserve session ownership, typed app actions and bounded data handling.
- Implement and verify upstream Pi core `bash`, `abort_bash` and `bash_execution_update` with native controls. Do not embed a terminal, PTY or interactive shell session.

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

- Launch the Pi process with Foundation Process, an executable URL and an argument array; do not build its launch command by shell interpolation.
- Send user-entered shell commands to the managed Pi process through upstream Pi core `bash`. Do not replace this operation with a companion-owned shell process or terminal session.
- Launch Pi in RPC mode with persistent sessions enabled. Resolve the exact startup arguments from the selected Pi version.
- Maintain one active Pi process and one active session per Mac in the first version. Reject project or session switches while work is active.
- Only the companion writes to its managed sessions. Do not open the same session for writing in a separate terminal Pi process.
- Persist the mapping between app session IDs, working-directory IDs, resolved Mac directories, and Pi session files. Remote clients use opaque IDs for commands; display paths do not authorize access.
- A phone disconnection does not terminate the process. A companion exit stops its managed process after an orderly shutdown attempt.
- After a Mac or companion restart, offer session restoration. Do not automatically repeat an interrupted prompt or claim that an interrupted tool completed.
- Treat Mac sleep as an interruption to availability. The first version does not promise to wake a sleeping Mac or keep a closed MacBook running.

### Protocol and synchronization

- Define an app protocol with a version, request ID, session ID, host epoch, event sequence, and typed payload. Keep raw upstream Pi core RPC behind the companion boundary.
- Negotiate the app protocol version and report the selected Pi version and supported capabilities during connection setup.
- Allow only typed commands that the app implements, including the approved upstream Pi core `bash`/`abort_bash` actions. Do not expose arbitrary RPC forwarding, arbitrary session paths, an embedded terminal or a PTY.
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
- [x] Audit this laptop's Pi version, executable and authentication setup against the upstream Pi core RPC protocol; the [inventory](docs/native-compatibility.md) accounts for all 33 operations, 24 events and nine standard UI methods, with evidence and explicit open shell mappings. Pi 1.3.0 and `/Users/narumi/.bun/bin/pi` are verified; the status-only OAuth check reports ready. This inventory does not close implementation acceptance or require installed-extension parity.
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
- [ ] Verify local use in the normally launched Mac app: choose a folder, start installed Pi, send an instruction, view its reply and stop work without starting the server or pairing a phone. The reported GUI-PATH failure is reproduced and the fnm runtime-discovery fix passes focused installed-Pi and local-model checks; the normally launched GUI flow still needs confirmation after rebuilding. Model tests and hosted-view captures do not complete this check.
- [x] Implement menu-bar status and local session controls; prove local and remote actions share the same serialized session state. The unsigned Mac app builds, and `PiRemoteMacTests` passes the production `CompanionModel` against a paired TLS client: shared transcript/run state, local Send/follow-up/Stop, remote steering, cross-client mutation exclusion, dialog completion and stale-action rejection.

### Mac workspace redesign checkpoint

- [x] Group managed sessions by canonical working directory; add, expand, select and remove workspace entries without deleting files or sessions.
- [x] Create sessions in the selected workspace; offer native/manual folder choice and recent workspaces otherwise. Reuse existing opaque-directory and lifecycle APIs.
- [x] Restore saved conversations without prompt replay; keep UI selection separate from execution and reject activation while work is active. Preserve per-session drafts across switches and app restarts.
- [x] Provide resizable sidebar/inspector panes, Files/Tools/Activity, keyboard shortcuts, native selection, context menus and separate Settings/Devices pages. Keep the light appearance and existing security confirmations.
- [x] Verify 12 focused Mac tests, 142 root tests and an unsigned iOS simulator build. Review active 1300 × 800 and minimum 900 × 600 layouts. Verify unchanged project/signing hashes. See [workspace evidence and limits](docs/mac-interface.md#workspace-redesign-verification).

### Mac UI/UX review follow-up

- [ ] Finish acceptance for the five Mac UI/UX corrections. Direct Commands access, one Files destination, native Mac control density, consolidated header status and compact folder navigation are implemented. All 22 Mac tests, nine phone directory-model tests, four focused phone UI checks and unsigned Mac/iOS builds pass. [Evidence and limits](docs/mac-interface.md#uiux-correction-verification) distinguish automated/layout checks from normal launch. The [tracked plan](docs/plans/2026-10-17_mac-uiux-plan.md) remains open for normal local Mac operation, manual breadcrumb-menu selection and full Mac keyboard/accessibility review.

### Mac review follow-up: Quit and session actions

- [ ] Complete the [review follow-up plan](docs/plans/2026-10-17_mac-review-follow-up-plan.md): guard ordinary Quit with authoritative consent, unify Mac Close Session, keep Overview access to active work, rename the inspector tab to Session and add common palette actions. Implementation passes 81 Mac tests, 168 root tests, 19 focused host tests with Thread Sanitizer, three primary-phone product checks and unsigned Mac/iOS simulator builds. The required normal-launch/provider, live keyboard/VoiceOver and actual Session controls menu checks remain open because an attended desktop review is unavailable. The plan is not complete; see [evidence and limits](docs/mac-interface.md#mac-review-follow-up).

### Mac usability refinement

- [x] Refine the existing Mac interface: read-only Pi-name/instruction display labels with stable collision handling, one global New session action, pinned management navigation, a compact session header, readable bounded-width messages, a 76–180-point multiline composer and Activity diagnostics. Existing names/IDs, catalog/JSONL formats, RPC actions, lifecycle, authentication and iPhone layouts remain unchanged. Verification: 35 Mac tests, 16 focused host tests, three primary-phone UI smoke checks and unsigned Mac/iOS builds pass. Real JSONL fixtures verify asynchronous display labels without activating Pi or changing session files. See [behavior, checks and limits](docs/mac-interface.md#mac-usability-refinement-verification). Hosted captures do not complete the separate normal-launch or live accessibility gates.

### Herdr-inspired Mac session management

- [ ] Complete the [session-management implementation plan](docs/plans/2026-10-17_mac-session-management-plan.md). Non-destructive Close Session, grouped Overview, searchable saved-session switching and a native action palette are implemented on the feature branch; verification and limits are recorded in [Mac interface checks](docs/mac-interface.md#session-management-verification). The full plan is not complete.
  - Concurrent runtimes and split conversations remain gated on the explicit change from shared Mac/iPhone runtime selection to independent device selection. The [proposed runtime design](docs/mac-session-runtime-design.md) defines one catalog/journal owner, per-session process state, per-device replay and a two-process admission bound. This is not implemented behavior and does not change the current single-active-Pi boundary.
  - Normal-launch/provider/VoiceOver checks and untested close failure paths remain separate from hosted/native fixture evidence. Keep the detailed plan until all agreed checks pass.

### Mac slash-command navigation

- [x] Implement inline slash completion and native navigation after removing the Mac Conversation/History tabs. `/resume`, `/tree` and `/history` open native sheets; discovered commands use existing scoped Send and request tracking. Completion edits the draft only. Verification: 48 Mac tests, three primary-phone UI checks and unsigned Mac/iOS builds pass. Native input, IME, undo, path handling, pending-dialog guards and narrow/wide popup hit testing pass. [Evidence and limits](docs/mac-interface.md#mac-slash-command-verification) distinguish hosted/model checks from unverified live operation; the normal-launch gate remains open.

### 4. Build the iOS client

- [x] Create and review a small SwiftUI interface prototype covering directory selection, an idle conversation, streaming with tool output, Stop, session controls, and reconnection; six compact-simulator UI tests pass twice, and captures confirm the header/transcript/composer layout. See [interface evidence](docs/interface-verification.md).
- [x] Implement pairing, saved Mac connections, the Mac directory picker, and session selection; use simulator and local integration tests to navigate nested folders and start Pi in a selected directory without prior project registration. The production `PhoneModel` now pairs, saves and reloads Mac/device metadata, starts the selected nested session and sends the coding task in the simulator integration test. All 25 app tests pass on both LAN and Tailscale; bounded picker, session and stale-selection tests pass separately.
  - Verified: six simulator tests cover bounded picker pages, cached back/forward navigation, stale/cancelled requests, stale previews and retry after denied navigation. QR-code display and an in-app scanner are now implemented. Five additional tests cover QR encode/decode and invalid, expired and stale scans; all 19 iOS tests pass. Verify camera-result and permission handling with injected inputs, not a physical camera; see [QR evidence](docs/workflow-verification.md#qr-code-pairing).
- [ ] Complete the native controls and generic protocol handling identified by the upstream Pi core RPC audit; verify them against the installed upstream Pi core RPC runtime with controlled fixtures and report unsupported upstream Pi core behavior explicitly.
  - [x] Implement typed, session-bound upstream Pi core `bash` and `abort_bash` actions through the existing authenticated action path. Controlled host and isolated Pi 1.3.0 checks pass execution, final results, cancellation, explicit correlation, no replay and uncertain outcomes; see [new evidence](docs/pi-like-mac-verification.md).
  - [x] Handle `bash_execution_update` with 64 KiB output and coalesced snapshot publication. Focused tests verify command correlation, truncation and retained cancellation access; the existing latest-state observer path keeps slow clients off Pi stdout. [Evidence and limits](docs/pi-like-mac-verification.md).
  - [ ] Add native command entry, execution confirmation, output and cancellation controls; verify basic input, output and cancellation in the usable native workflow without a terminal or PTY. Do not add an iPhone SE verification gate.
  - [ ] Verify stale-session rejection, reconnect deduplication, unknown outcomes and no automatic command redispatch; record direct evidence in the upstream Pi core RPC coverage audit.
- [x] Implement a streamed transcript with Markdown, code blocks, expandable tool output, and clear run states; shared tests pass authoritative text/thinking reconstruction, error visibility, retry, compaction and cancellation settlement. Hosted UIKit fixtures cover idle, working, retrying, compacting and interrupted states; see [workflow evidence](docs/workflow-verification.md).
- [x] Implement the composer, steering/follow-up choice, Stop, model controls, and supported extension dialogs; verify actions against the Mac host, including expired dialogs. Installed-Pi `NativeWorkflowCheck` passes select, confirm, input, editor and actual dialog expiry/late-answer rejection. Provider, Mac integration and simulator checks cover active steering/follow-up/Stop and model controls; see [workflow evidence](docs/workflow-verification.md).
- [x] Implement foreground reconnection, draft retention, disconnected status, and snapshot replacement; simulator tests pass protected background/lock state, retained drafts after Home/activate, disconnected recovery and stale-state rejection. Production TLS and simulator provider tests pass connection loss and idle/active host restart without prompt redispatch. These are local and injected-policy checks, not hardware suspension claims; see [interface](docs/interface-verification.md) and [recovery](docs/workflow-verification.md#simulator-coding-and-recovery) evidence.
  - Verified: simulator tests cover retained per-session drafts, protected background state, stale editor offers and resend confirmations. TLS tests reject wrong-host, wrong-epoch and stale-session contexts before dispatch.
- [x] Verify light and dark appearance, Dynamic Type, VoiceOver labels, contrast, touch targets and keyboard use in simulator tests and local view inspection; six UI tests pass requested target/description audits, real-keyboard frame checks and capture review at accessibility-extra-large text. Color-pair tests pass 4.5:1. Native text input and its standard dictation control remain; see [scope and limits](docs/interface-verification.md).
- [x] Not applicable to the current development gates: iPhone SE compact-layout and large-text verification was removed from the active matrix by the user. Earlier 375 × 667-point results remain [historical evidence](docs/interface-verification.md#checks); do not rerun this suite as a requirement for current feature work.

### 5. Validate and prepare the first release

- [x] Add automated protocol and integration tests with a fake Pi process; 59 root tests and 18 shared-package tests pass. Coverage includes rejected commands, unknown outcomes, directly injected stale/wrong-identity client states, epoch/cursor fallback, invalid credentials, bounded output, malformed WebSocket frames, invalid certificate dates and active-run TLS reconnection without duplicate dispatch on LAN and Tailscale. All 59 root tests also pass with Thread Sanitizer.
- [x] Run a simulator-to-local-host coding flow through pairing, a coding task, client disconnection, reconnection, Stop and session restoration; the production client/host fixture passes on LAN and Tailscale with Pi 1.3.0. It verifies exact tool-written file contents, one user-prompt delivery, preserved working directory, idle restoration and explicitly marked interruption after active host restart. It does not claim full UI or installed-extension acceptance. See [simulator evidence](docs/workflow-verification.md#simulator-coding-and-recovery).
- [x] Test simulated host unavailability, lost project access, missing model credentials and Pi crashes on this laptop; verify actionable errors and no automatic re-execution of interrupted work. All 61 root tests pass normally and with Thread Sanitizer. The isolated installed-Pi `NativeFailureCheck` passes real missing-credential rejection and empty-session restoration; see [failure evidence](docs/workflow-verification.md#host-failure-matrix).
- [x] Document supported Pi versions, setup, security limits, network requirements, session ownership, and recovery in README.md; validate the instructions with a clean simulator setup and local companion storage on this laptop. Pi 1.3.0 is the only tested development runtime, not a complete-workflow support claim. Two Mac-model tests pass new-storage listener setup, approval persistence, restart and revocation. The fresh-preferences simulator/provider flow passes product-model pairing, saved Mac metadata, selected-directory launch and coding. See [clean setup evidence](docs/workflow-verification.md#clean-setup-controls); signed installation and hardware behavior remain outside this local verification scope.

## Remaining work and verification limits

- Upstream Pi core model/thinking cycling, acknowledged retry settings and active retry cancellation pass package, installed-Pi and focused UI checks. Same-child new/switch/import/fork/clone, standard lifecycle UI, empty-child ancestry, oversized fork handling and authoritative tree inspection also pass direct checks; see [acceptance evidence](docs/core-rpc-acceptance.md). All 27 compact-interface tests pass in the final accepted batch set.
- Finish native shell acceptance: Mac command review, `bash`/`abort_bash` and bounded output are implemented with isolated host/runtime and native fixture checks. Add iPhone shell entry, and verify attended normal Mac operation. The [Pi-like Mac plan](docs/plans/2026-10-18_pi-like-mac-interface-plan.md) remains open for actual terminal captures, retained-difference review and user acceptance. No embedded terminal or PTY is permitted.
- Complete the [upstream Pi core RPC coverage audit](docs/native-compatibility.md). Existing test checkpoints do not establish coverage of every documented operation, event or standard extension UI method. Record direct evidence before closing the remaining plan items.
- Terminal-only extension rejection no longer blocks this plan. The user confirmed an upstream Pi core RPC-only boundary. Do not add a bundled adapter, modify upstream Pi core packages or require the user's extension inventory to satisfy acceptance.
- Keep the existing verified features and evidence: directory access, authenticated LAN/Tailscale transport, pairing/revocation, synchronization, managed sessions, prompts/queues/Stop, model/thinking controls, generic dialogs, resources, compaction, history, images, attachments, import/export, release notes and native system sharing. Their linked checkpoints remain limited to the checks actually run.
- Xcode checks use a command-local `DEVELOPER_DIR` override; do not change the user's global developer-directory selection. Signed installation, hardware authentication and off-site operation remain unverified and are not current completion gates.
- `AGENTS.md` still says that no app build/test configuration exists. `project.yml` now provides it; the instruction file needs a separate reviewed maintenance change.

## Risks and Recovery

- **Pi interface changes:** record tested versions, keep decoding fixtures, and reject unsupported capabilities with an upgrade message.
- **Extension differences:** verify generic upstream Pi core RPC interactions with controlled fixtures. Report terminal-only or custom-protocol limits without adding extension-specific dependencies or promising compatibility with individual packages.
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
- [ ] The upstream Pi core RPC audit covers every documented operation, event and standard extension UI method for the tested runtime; in-scope behavior passes direct checks and remaining upstream Pi core gaps are resolved. No installed-extension or terminal-parity gate applies.
- [x] Text streaming, tool activity, steering, follow-up, Stop, and supported extension dialogs pass the recorded test cases. Installed-Pi checks cover all four supported dialog methods and expiry; simulator provider tests cover tool-written results and stream/recovery controls.
- [x] A simulated client disconnect does not stop Pi; production fake-Pi tests verify one dispatch and restored active state, and the simulator provider flow verifies one prompt and the completed coding result after reconnection.
- [x] Session restoration works after a host restart. Simulator checks pass idle and active restart, retained working directories, an interrupted-session flag and unchanged idle messages after explicit restoration, without resending a prompt.
- [x] Unpaired and revoked devices cannot access the host; production TLS tests pass unauthenticated browsing rejection, active revocation, revoked reconnection, changed-certificate rejection, hostname rejection and expired/future certificate rejection.
- [x] Build commands, automated tests, simulator execution and local setup instructions have recorded passing results. The earlier upstream Pi core RPC checkpoint includes 135 root tests and 50 shared tests, both normally and with Thread Sanitizer, three Mac-model tests, 31 product simulator tests on each network, installed-Pi metadata and real-provider checks, all 27 compact-interface tests and unsigned Mac/simulator/device-SDK builds. This does not close the separate compatibility acceptance gate.
- [x] Audit local LAN/Tailscale selection, exact listener binding, authenticated transport and simulated host unavailability; root tests and all 31 product tests pass on each network. Parent verification confirms both host PASS logs, unchanged 93-file source hashes/settings, stopped child identities and closed listeners. Setup guidance names only tested Pi 1.3.0 and local evidence, without hardware/off-site claims. The separate approved upstream Pi core shell implementation and verification remain open; see [acceptance evidence](docs/core-rpc-acceptance.md).
