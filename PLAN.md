# Pi Remote — First-Version Plan

## Goal

Build a native iOS app in Swift that lets one user talk to and control Pi running on a MacBook or Mac mini. Build a Swift macOS companion that manages the connection and Pi process.

The user can start a coding task on their iPhone, watch Pi work on their Mac, send more instructions, stop work, and return to the conversation after a connection loss.

Product name: **Pi Remote**. The macOS companion is **Pi Remote for Mac**.

Status: proposed plan. Implementation has not started.

## Context

- This repository currently contains a README, a license, and a Git ignore file. There is no app code or build configuration.
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

## First-Version Scope

### iOS app

- Pair with a Mac through an explicit approval step.
- Save multiple Mac connections, but control one Mac at a time.
- Show connection status, Mac availability, selected project, and session status.
- Select a project that the user registered on the Mac.
- Create a session or resume a session managed by the companion.
- Send text prompts and render streamed Markdown, code blocks, tool activity, and errors.
- Send a steering instruction or queue a follow-up while Pi is working.
- Stop current work and clear queued instructions through one explicit Stop action.
- Select from Pi's configured models and supported thinking levels.
- Answer supported extension selection, confirmation, text-input, and editor dialogs.
- Reconnect and restore the current transcript without sending a prompt twice.
- Support standard keyboard dictation for text entry. Do not require a custom speech service.

### macOS companion

- Provide a menu-bar app with connection, pairing, project, and Pi status controls.
- Let the user select the installed Pi executable and register project folders.
- Start and supervise a Pi RPC child process in the selected project.
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
- Concurrent active sessions on one Mac, session branching, and automatic Git worktrees.
- Importing all existing Pi history or full compatibility with terminal-only extensions.
- Image attachments, file uploads, and a separate file or diff browser.

## Architecture

### Components and ownership

| Component | Technology | Responsibility |
| --- | --- | --- |
| iOS client | Swift, SwiftUI, URLSession | Connection management, transcript, input, and native controls |
| macOS companion | Swift, SwiftUI, Foundation Process | Pairing, project access, session ownership, and Pi process supervision |
| Shared package | Swift Package Manager, Codable | Versioned transport messages, client state, and test fixtures |
| Pi runtime | Existing installed Pi CLI | Agent execution, tools, provider access, and persistent Pi sessions |

Use one repository with `Apps/iOS/`, `Apps/macOS/`, and `Packages/PiRemoteCore/`. Keep platform-specific process and networking code outside the shared package.

The intended data path is iOS client → authenticated secure connection → Mac companion → local JSON RPC → Pi. Responses and events return along the same path.

### Swift transport

- Use an authenticated secure WebSocket connection for commands, responses, and events.
- Prototype an Apple Network.framework server on macOS and URLSession WebSocket client on iOS before building the screens. Verify TLS trust and WebSocket interoperability on physical devices.
- If the prototype cannot meet those requirements, record the reason and select a maintained Swift server library before implementation continues. Do not add a Node.js or TypeScript service.
- Start with a manually entered address. Add local discovery only if setup tests show that it is necessary.
- Support the same local network first. Validate access over a user-managed private network such as Tailscale before calling access away from home supported.
- Do not require router port forwarding. Do not use an unencrypted public listener.

### Pi process and session lifecycle

- Use Foundation Process with an executable URL and an argument array. Do not construct a shell command from remote input.
- Launch Pi in RPC mode with persistent sessions enabled. Resolve the exact startup arguments from the selected Pi version.
- Maintain one active Pi process and one active session per Mac in the first version. Reject project or session switches while work is active.
- Only the companion writes to its managed sessions. Do not open the same session for writing in a separate terminal Pi process.
- Persist the mapping between app session IDs, project IDs, and Pi session files. Remote clients use opaque IDs, not arbitrary Mac paths.
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
- Rate-limit pairing attempts. Reject unpaired, expired, replayed, and revoked credentials.
- Bind only to intended interfaces and document firewall and private-network setup. A private network is not a substitute for application authentication.
- Register projects through a Mac folder picker. Resolve remote project IDs only to locally registered folders.
- Project registration limits app selection; it is not a security sandbox for Pi's tools. Explain this limit during setup.
- Keep provider credentials on the Mac. Exclude secrets, pairing data, prompt text, and tool output from routine diagnostic logs.
- Do not assume Pi asks for approval before every tool call. Supported extension dialogs are not a complete command-permission system.
- Start with a directly distributed macOS companion because it launches a CLI and accesses development folders. Validate signing, notarization, folder permissions, and login-item behavior before promising distribution support.
- Request required iOS local-network permissions and define a deliberate certificate-trust flow. Do not add broad App Transport Security exceptions as a workaround.

## Plan

### 1. Resolve implementation blockers

- [ ] Confirm the first-version scope, minimum iOS/macOS versions, distribution method, and local/private-network access requirements; record accepted decisions in this file.
- [ ] Inspect the target Mac's Pi version, executable, authentication setup, and extensions; capture a compatibility report with supported commands and known RPC limitations.
- [ ] Build a Swift command-line spike that launches Pi, sends a prompt, streams output, stops work, and resumes a persisted session; verify behavior with recorded events and an actual installed Pi.
- [ ] Build a physical iPhone-to-Mac secure WebSocket spike with server-identity verification; prove pairing, authenticated reconnection, and rejection of an untrusted identity on the local network.
- [ ] Test the same spike over the chosen private network; record setup instructions and whether access away from home is supported for this release.

### 2. Establish the Swift workspace and contract

- [ ] Create the two app targets and shared Swift package; prove both targets build and shared package tests pass with documented noninteractive commands.
- [ ] Define versioned app messages, capability negotiation, errors, and session state; prove round-trip decoding and rejection of unsupported versions with fixtures.
- [ ] Implement the Pi JSONL adapter and process supervisor; test partial UTF-8 records, Unicode separators inside JSON, malformed output, stderr load, startup failure, backpressure, and unexpected exit.

### 3. Build the Mac host

- [ ] Implement Pi selection, project registration, and companion-owned session storage; demonstrate create, switch while idle, restart, and resume without changing unrelated Pi sessions.
- [ ] Implement pairing, credential storage, authentication, and revocation; prove an unpaired or revoked device cannot read transcripts or issue commands.
- [ ] Implement prompt, steering, follow-up, Stop, model selection, and thinking-level controls; validate their state transitions against the installed Pi.
- [ ] Implement snapshot synchronization, event replay, request deduplication, and bounded buffers; prove reconnection does not lose completed messages or resend accepted prompts.
- [ ] Implement menu-bar status and local session controls; prove local and remote actions share the same serialized session state.

### 4. Build the iOS client

- [ ] Implement pairing, saved Mac connections, project selection, and session selection; complete setup on a physical iPhone without developer tools on the phone.
- [ ] Implement a streamed transcript with Markdown, code blocks, expandable tool output, and clear run states; verify recorded success, retry, compaction, failure, and cancellation cases.
- [ ] Implement the composer, steering/follow-up choice, Stop, model controls, and supported extension dialogs; verify actions against the Mac host, including expired dialogs.
- [ ] Implement foreground reconnection, draft retention, disconnected status, and snapshot replacement; verify phone lock, app suspension, Wi-Fi changes, and host restart without duplicate prompts.
- [ ] Verify Dynamic Type, VoiceOver labels, keyboard use, and standard dictation; record physical-device results for the main coding-task flow.

### 5. Validate and prepare the first release

- [ ] Add automated protocol and integration tests with a fake Pi process; cover rejected commands, unknown outcomes, stale events, invalid credentials, large output, and connection loss during an active run.
- [ ] Run a real-device test from local pairing through a coding task, phone disconnection, reconnection, Stop, and session restoration; record the result and remaining defects.
- [ ] Test Mac sleep/wake, lost project access, missing model credentials, and Pi crashes; verify actionable errors and no automatic re-execution of interrupted work.
- [ ] Prepare signed iOS test builds and a signed/notarized Mac build using the selected distribution route; verify installation and connection outside the development environment.
- [ ] Document supported Pi versions, setup, security limits, network requirements, session ownership, and recovery in README.md; validate the instructions on a clean test setup.

## Risks and Recovery

- **Pi interface changes:** record tested versions, keep decoding fixtures, and reject unsupported capabilities with an upgrade message.
- **Extension differences:** test the user's installed extensions early. Report unsupported terminal-only UI rather than promising full parity.
- **Connection loss:** work can continue on the Mac. Preserve the phone draft and resynchronize before accepting new commands.
- **Companion crash:** preserve Pi session files and report uncertain command outcomes. Do not claim exactly-once execution across a process crash.
- **Interrupted tools:** a saved conversation does not prove a tool completed. Require review before resuming an interrupted task.
- **Conflicting filesystem edits:** local editors can still modify the project. The first version does not isolate work or merge conflicting changes.
- **Credential compromise:** revoke the device on the Mac, close its connections, and require new pairing.
- **Failed app upgrade:** retain session files and avoid destructive migrations. Back up companion metadata before a format change and document downgrade compatibility.
- **Removal:** stop the companion, revoke devices, and remove its login item if enabled. Do not delete project files, provider credentials, or Pi sessions automatically.

## Completion Checklist

- [ ] Both apps and all app-owned service code are written in Swift; no TypeScript backend is required.
- [ ] A physical iPhone can securely connect to a MacBook or Mac mini and complete a coding task through Pi.
- [ ] Text streaming, tool activity, steering, follow-up, Stop, and supported extension dialogs pass the recorded test cases.
- [ ] A phone disconnect does not stop Pi; reconnection restores the correct state without duplicate prompts.
- [ ] Session restoration works after a companion restart, with interrupted work clearly identified.
- [ ] Unpaired and revoked devices cannot access the host; certificate changes fail closed.
- [ ] Build commands, automated tests, physical-device checks, and installation instructions have recorded passing results.
- [ ] Network limits, Mac sleep behavior, supported Pi versions, and exclusions are documented and accepted for release.
