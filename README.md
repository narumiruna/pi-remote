# Pi Remote

Native Swift apps to control [Pi](https://github.com/earendil-works/pi) on your Mac from an iPhone, without an embedded terminal. The macOS companion is **Pi Remote for Mac**.

Choose a Mac directory from your phone, start a managed session, watch output and tool activity, send instructions, and stop work. Pi, files, tools and provider credentials stay on the Mac. Pi still sends model requests to its configured provider; this is not an offline AI system.

## Status

**Development implementation; `PLAN.md` is not complete.** Both native app targets build without signing. Package tests cover the host, client, protocol and process adapter. Fourteen iOS simulator app tests pass. The older secure transport diagnostic also passed on a physical iPhone 16 Pro.

The product apps have not passed a signed physical-device coding task, off-site Tailscale testing, hardware unlock testing or the full Pi workflow review. This is not a supported release. See [workflow verification](docs/workflow-verification.md), [native app verification](docs/native-apps.md), [RPC evidence](docs/verification.md), [transport evidence](docs/secure-transport-spike.md) and the remaining checks in [PLAN.md](PLAN.md).

## Implemented foundation

- A minimal conversation screen with a header, transcript and composer; secondary controls use menus and sheets.
- Authenticated Mac folder browsing with no approved-root list or per-project registration. macOS permissions still apply.
- One active companion-managed Pi session per Mac, with its working directory saved and checked on resume.
- Streamed text and thinking, native Markdown blocks, fenced code and expandable tool output.
- Native prompts, steering, follow-up, Stop, model/thinking controls, command discovery and supported extension dialogs.
- Paged session history and entry inspection, fork/clone controls, compaction, image/text input, bounded file previews and working-tree diff.
- Saved Mac connections, explicit local pairing approval, per-device credentials and revocation.
- Bounded state replay and snapshot recovery, request deduplication, retained drafts and explicit unknown outcomes. Accepted prompts are not automatically resent.
- Session-bound UI actions and attachments. Editor text replaces a nonempty draft only after an explicit decision.
- Local Mac session controls and menu-bar status. Disconnecting the phone does not stop accepted work.

These are implemented controls, not proof of complete terminal parity. Real-Pi and physical-device checks remain open for several paths. Terminal-only extension UI, in-place branch switching, custom renderers and full image output still have gaps. Text and thinking displays have explicit size limits. No reduction of the accepted workflow scope has been approved.

## Security and network limits

- A paired phone is a trusted Pi controller. Pi can change files and run commands with the Mac user's permissions. Folder selection is not a tools sandbox.
- Pairing requires a short-lived code copied from the Mac and explicit approval on the Mac. TLS checks the pinned certificate, hostname and validity. Each connection requires device authentication.
- Credentials use Keychain. The phone requires Face ID or its device passcode before access after launch or background return. Hardware behavior remains unverified.
- The listener binds one selected private IPv4, loopback or Tailscale IPv4 address. No public listener, router port forwarding, hosted relay or account service is included.
- LAN and off-site Tailscale are required for the first personal build. Only the older diagnostic has passed a physical LAN test; off-site access remains unverified.
- The companion owns separate Pi session files. It cannot attach to an existing terminal Pi session. Do not open its managed files for writing in another Pi process.
- Companion exit stops its child. A sleeping Mac is unavailable. Interrupted work is not automatically repeated; inspect uncertain outcomes before retrying.
- Routine diagnostics exclude credentials, pairing codes, prompts and tool output. Output and history views have explicit size limits; see [limits and recovery](docs/native-apps.md#resource-and-recovery-limits).

## Development

`project.yml` defines the SwiftUI app targets and iOS app tests. The root `Package.swift` defines the host, client and integration tests; `Packages/PiRemoteCore` holds the shared protocol. Platform-specific process and network code stays outside that package. There is no TypeScript backend.

Verified unsigned build and test commands are in [native app verification](docs/native-apps.md#automated-checks). Personal signing and installation instructions still need a clean physical-device validation. The build settings use iOS 18 and macOS 15 as provisional floors, not tested supported versions. Pi 1.3.0 passed the earlier RPC spike; a supported-version matrix does not exist yet.

Start with personal builds for iPhone 16 Pro and the current Mac. TestFlight comes later. A future phase can add accounts and a public connection service; its authentication, encryption and routing still require design.

## License

[GNU Affero General Public License v3.0](LICENSE).
