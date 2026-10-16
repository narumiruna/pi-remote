# Pi Remote

A planned native iOS app to control [Pi](https://github.com/earendil-works/pi) on a MacBook or Mac mini, with a Swift macOS companion called **Pi Remote for Mac**.

Start a coding task from your iPhone, watch streamed output and tool activity, send more instructions, and stop work. Pi, project files, tools, and model credentials stay on the Mac. Pi sends model requests to its configured provider; this is not an offline AI system.

## Status

**Early implementation; the complete plan is blocked.** Local Swift RPC and secure WebSocket spikes, shared-package tests, and an iOS diagnostic test host are available. There are no Pi Remote product apps or production pairing service yet.

The RPC spike passed against Pi 1.3.0. The secure transport spike passes local and iOS simulator tests; an Xcode-signed build now launches on the physical iPhone, but its network connection fails before TLS verification. See [RPC verification](docs/verification.md) and [secure transport verification](docs/secure-transport-spike.md) for commands, limits, and remaining checks; this is not a supported app release.

See [PLAN.md](PLAN.md) for the proposed architecture, implementation steps, validation checks, and open decisions.

## Planned first version

- Pair an iPhone with a Mac through local approval.
- Browse any directory accessible to the Mac companion from the iPhone and choose where to start Pi, without per-project registration.
- Create, resume, and switch companion-managed sessions, with the working directory shown for each session.
- Target the complete Pi workflow, including commands and installed extensions, through a clean native interface without an embedded terminal; compatibility gaps require investigation and user approval before reducing scope.
- Read streamed Markdown, code blocks, tool activity, and errors.
- Send prompts, steer active work, queue follow-up messages, and stop work.
- Select configured models and supported thinking levels, and answer supported extension dialogs.
- Reconnect after a connection loss without sending accepted prompts twice.
- Use a Mac menu-bar app to manage pairing, projects, and Pi, with local session controls.

The first version will support one active session per Mac. The iPhone can save multiple Mac connections but control only one Mac at a time.

## Planned architecture

| Component | Technology | Responsibility |
| --- | --- | --- |
| iOS app | Swift, SwiftUI | Connection, transcript, and controls |
| macOS companion | Swift, SwiftUI, Foundation Process | Pairing, project access, session storage, and Pi process management |
| Shared package | Swift Package Manager, Codable | Transport messages, client state, and test fixtures |
| Pi runtime | Installed Pi CLI | Agent execution, tools, and provider access |

The iPhone will connect to the Mac companion through an authenticated secure WebSocket. The companion will manage a separate Pi process through local JSON RPC. No TypeScript backend is planned.

## Network and security limits

- Both local-network and off-site Tailscale access are required for the first personal build; neither has been implemented or validated yet.
- No hosted relay, public internet listener, or router port forwarding is part of the first version.
- A paired device is a trusted controller: Pi can change files and run commands with the Mac user's permissions. Directory-access rules are not a security sandbox.
- Folder selection is limited by macOS permissions, not an approved-root list; the app will not bypass system protections.
- Pairing will require local approval, verified server identity, and a separate revocable credential for each device.
- Local protection will require Face ID or the device passcode on launch and return from the background; hardware behavior is not yet validated.
- The companion is intended to keep Pi running when the phone disconnects. A sleeping Mac is unavailable; remote wake is not planned.

## Outside the first version

- Attaching to an existing Pi terminal session.
- Remote desktop, a general-purpose terminal, or a full mobile code editor.
- Concurrent active sessions or automatic Git worktrees.
- Custom voice features, push notifications, or continuous iOS background connectivity.
- Unverified compatibility with terminal-only extensions.

Session branching, history navigation, attachments, and file or diff views are part of the complete-workflow review, not verified capabilities. Any reduction in scope needs user agreement.

## Build and distribution direction

Start with a personal build for iPhone 16 Pro and the current Mac, then prepare TestFlight distribution later. Minimum OS versions, signing, and compatibility remain unverified.

A later phase will add account registration and a public connection service so an iPhone can connect to its user's Mac without Tailscale. Authentication, encryption, and routing for that service still require design.

## License

[GNU Affero General Public License v3.0](LICENSE).