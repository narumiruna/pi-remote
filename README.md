# Pi Remote

A planned native iOS app to control [Pi](https://github.com/earendil-works/pi) on a MacBook or Mac mini, with a Swift macOS companion called **Pi Remote for Mac**.

Start a coding task from your iPhone, watch streamed output and tool activity, send more instructions, and stop work. Pi, project files, tools, and model credentials stay on the Mac. Pi sends model requests to its configured provider; this is not an offline AI system.

## Status

**Planning only. Implementation has not started.** This repository contains the first-version plan, not working apps. Installation instructions, build commands, supported OS versions, and tested Pi versions are not yet available.

See [PLAN.md](PLAN.md) for the proposed architecture, implementation steps, validation checks, and open decisions.

## Planned first version

- Pair an iPhone with a Mac through local approval.
- Select projects registered on the Mac and create or resume companion-managed sessions.
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

- Local-network access comes first. Access through a user-managed private network, such as Tailscale, requires validation before it is supported.
- No hosted relay, public internet listener, or router port forwarding is planned.
- A paired device is a trusted controller: Pi can change files and run commands with the Mac user's permissions. Registered project folders are not a security sandbox.
- Pairing will require local approval, verified server identity, and a separate revocable credential for each device.
- The companion is intended to keep Pi running when the phone disconnects. A sleeping Mac is unavailable; remote wake is not planned.

## Outside the first version

- Attaching to an existing Pi terminal session.
- Remote desktop, a general-purpose terminal, or a full mobile code editor.
- Concurrent active sessions, session branching, or automatic Git worktrees.
- Image attachments, file uploads, or a separate file or diff browser.
- Custom voice features, push notifications, or continuous iOS background connectivity.
- Full compatibility with terminal-only extensions.

## License

[GNU Affero General Public License v3.0](LICENSE).