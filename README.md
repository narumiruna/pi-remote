# Pi Remote

Native Swift apps to control [Pi](https://github.com/earendil-works/pi) on your Mac from an iPhone, without an embedded terminal. The macOS companion is **Pi Remote for Mac**.

Choose a Mac directory from your phone, start a managed session, watch output and tool activity, send instructions, and stop work. Pi, files, tools and provider credentials stay on the Mac. Pi still sends model requests to its configured provider; this is not an offline AI system.

## Status

**Development implementation; `PLAN.md` is not complete.** Both native app targets build without signing. Package tests cover the host, client, protocol and process adapter. Thirty-one iOS simulator app tests pass with the explicit local provider fixture on LAN and Tailscale, including coding, image output, reconnection and host restart. Eighteen compact-interface tests have passing evidence across bounded checkpoints; see [system sharing checks](docs/session-export.md#system-sharing-checkpoint). The older secure transport diagnostic also passed on a physical iPhone 16 Pro.

The core RPC coverage audit remains open. The app targets the protocol supplied by Pi's core packages, not terminal-feature parity or compatibility with individual extensions. Local model/transport setup checks pass; signed installation remains unverified. Compact simulator checks now cover the real keyboard, large text, readable controls, error recovery and live scroll position. Signed physical-device coding, off-site Tailscale and hardware unlock are unverified limits, not completion gates for the current local plan. This is not a supported release. See [workflow verification](docs/workflow-verification.md), [native app verification](docs/native-apps.md), [RPC evidence](docs/verification.md), [transport evidence](docs/secure-transport-spike.md) and the remaining checks in [PLAN.md](PLAN.md).

## Implemented foundation

- A minimal conversation screen with a header, transcript and composer; secondary controls use menus and sheets.
- Authenticated Mac folder browsing with no approved-root list or per-project registration. macOS permissions still apply.
- One active companion-managed Pi session per Mac, with its working directory saved and checked on resume.
- Streamed text and thinking, native Markdown blocks, fenced code, expandable tool output and authenticated native image viewing.
- Native prompts, steering, follow-up, Stop, model/thinking controls, confirmed queue/compaction settings, command discovery and supported extension dialogs.
- Paged, read-only [installed Pi release notes](docs/release-notes.md), without starting Pi or opening links.
- Explicit last-response copy and idle-session close/reopen controls; copying uses local-device clipboard options.
- Consent-based HTML (full tree) and JSONL (active branch) export through the native file picker, plus separately reviewed system sharing with no automatic upload; see [export limits and checks](docs/session-export.md).
- Explicit reviewed JSONL import (versions 1–3) into companion-owned storage with Pi-managed legacy migration, with validated saved or explicitly chosen directories and no prompt replay; see [import limits and checks](docs/session-import.md).
- Paged session history and entry inspection, fork/clone controls, real manual compaction, image/text input, explicit Mac-file text attachment, bounded file previews, working-tree diff and native session-usage statistics.
- Saved Mac connections, QR-code or pasted-code pairing, explicit local approval, per-device credentials and revocation.
- Bounded state replay and snapshot recovery, request deduplication, retained drafts and explicit unknown outcomes. Accepted prompts are not automatically resent.
- Session-bound UI actions and attachments. Editor text replaces a nonempty draft only after an explicit decision.
- Local Mac session controls and menu-bar status. Disconnecting the phone does not stop accepted work.

These controls do not prove complete core RPC coverage. The app supports extension commands and interactions generically where Pi's core protocol exposes them; it must not depend on individual extensions such as `pi-btw`. Terminal-only UI, custom extension protocols and terminal commands without core RPC equivalents are outside scope. They do not require adapters or block app completion. The [current compatibility review](docs/native-compatibility.md) records the remaining core audit. [Image output](docs/output-images.md), text and thinking retain their documented limits. Physical-device checks remain unverified, not current completion gates.

## Security and network limits

- A paired phone is a trusted Pi controller. Pi can change files and run commands with the Mac user's permissions. Folder selection is not a tools sandbox.
- Pairing requires a short-lived code scanned or copied from the Mac and explicit approval on the Mac. TLS checks the pinned certificate, hostname and validity. Each connection requires device authentication.
- Credentials use Keychain. The phone requires Face ID or its device passcode before access after launch or background return. Hardware behavior remains unverified.
- The listener binds one selected private IPv4, loopback or Tailscale IPv4 address. No public listener, router port forwarding, hosted relay or account service is included.
- LAN and off-site Tailscale are required for the first personal build. Authenticated local LAN and Tailscale tests pass, including a simulator coding flow. Only the older diagnostic has passed a physical LAN test; off-site access remains unverified.
- The companion owns separate Pi session files. It cannot attach to an existing terminal Pi session. Do not open its managed files for writing in another Pi process.
- Companion exit stops its child. A sleeping Mac is unavailable. Interrupted work is not automatically repeated; inspect uncertain outcomes before retrying.
- Routine diagnostics exclude credentials, pairing codes, prompts and tool output. Output and history views have explicit size limits; see [limits and recovery](docs/native-apps.md#resource-and-recovery-limits).

## Local development setup

Pi **1.3.0** is the tested development runtime. Other Pi versions are unverified. Complete core RPC coverage is still unverified; this is not a supported release.

1. Install and configure Pi on the Mac before using the companion. Provider credentials stay in Pi's Mac configuration. Check `pi --version` and use a status-only authentication check for your provider. This laptop passes `pi auth check --provider openai-codex --model gpt-6.1-sol --json --no-refresh`. Do not use credential-printing commands or copy keys to the phone.
2. Generate and build the apps with the [verified commands](docs/native-apps.md#automated-checks). Launching a signed personal build is separate and remains unverified. The simulator checks below use injected authentication results and memory credentials, not a production unlock bypass.
3. In **Pi Remote for Mac**, select **Pi executable** if the detected path is wrong. Pi's Node.js runtime must also be on the companion process's `PATH`; selecting a script does not install its runtime. Use the same configured environment as the successful Pi command.
4. Select a private LAN or Tailscale **Listen address**, then **Start listener**. Port 7443 must be reachable. Keep the Mac awake. For Tailscale, both peers must be connected and access policy must allow the connection. Local checks do not prove off-site operation.
5. Select **Pair a device**. On the unlocked phone, open **Connections → Pair a Mac**, scan or paste the code, review the Mac address and select **Request pairing**. Compare the displayed device identity and select **Allow** on the Mac. A request alone does not grant access. Keep the code private; it expires after two minutes.
6. Open **Sessions → New session**, browse the Mac folders, review the absolute path and select **Start Pi Here**. No project registration is required. Use **Session controls** for the complete path, model, thinking level, commands, usage, last-response copy and runtime settings. Runtime changes require confirmation and can affect future Pi terminal sessions. **Close Pi session** keeps saved history and the listener. To add Mac text, open **Mac files**, read the file preview and select **Attach text**. This changes the draft only; review it before sending.
7. Send an instruction. While working, choose steering or follow-up explicitly before sending another instruction. **Stop** clears pending instructions and aborts work; it cannot undo file changes. Closing or locking the phone does not stop accepted work.
8. After a disconnection, unlock and reconnect to recover state. After a host restart, select the saved session explicitly. Review interrupted work before sending anything again. Unknown outcomes are not safe to resend automatically.

The companion catalog and managed sessions use `~/Library/Application Support/PiRemote/`. Do not open managed session files for writing in another Pi process. To remove access, select **Revoke** beside the device on the Mac. To change interfaces, stop the listener, select the new address and restart it; update the saved phone address without changing its certificate pin. If the certificate does not cover the new address, use **Replace connection identity** and pair again. Do not disable TLS checks.

Clean setup evidence: two Mac-model tests pass with new private support storage and isolated preferences, including Start listener, local approval, persisted devices, listener restart and revocation. Thirty-one simulator tests pass with fresh phone preferences and a private local provider fixture, including product-model pairing, saved connections, nested directory selection and coding. These are local model/transport and simulator checks, not signed installation, hardware authentication, camera or off-site evidence. [Repeat the checks](docs/workflow-verification.md#clean-setup-controls).

## Development

`project.yml` defines the SwiftUI app targets and iOS app tests. The root `Package.swift` defines the host, client and integration tests; `Packages/PiRemoteCore` holds the shared protocol. Platform-specific process and network code stays outside that package. There is no TypeScript backend.

Verified unsigned build and test commands are in [native app verification](docs/native-apps.md#automated-checks). Compact-interface checks are recorded in [interface verification](docs/interface-verification.md). Personal signing and installation remain unverified; they are not current plan-completion requirements. The build settings use iOS 18 and macOS 15 as provisional floors, not tested supported versions. Pi 1.3.0 passes the recorded development checks; no broader supported-version range or complete terminal-parity claim is established.

Start with personal builds for iPhone 16 Pro and the current Mac. TestFlight comes later. A future phase can add accounts and a public connection service; its authentication, encryption and routing still require design.

## License

[GNU Affero General Public License v3.0](LICENSE).
