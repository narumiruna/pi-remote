# Headless CLI

The TypeScript CLI runs a foreground Pi Remote host on Bun without the Mac GUI. npm manages its package and dependencies. It owns a separate Pi subprocess and session catalog; it cannot attach to an existing Pi terminal session.

This is development software. The npm package is private and has not been published. See the [verification record](headless-cli-verification.md) for completed checks and remaining limits.

## Installation

The checked versions are Bun 1.4.0 and Pi 1.3.0. Other versions are unverified. npm needs Node.js for installation and development tools; the installed CLI, its private workers and Pi execute with Bun. Install and configure Pi separately. macOS needs an accessible Keychain. Linux needs glibc, `libsecret`, an unlocked D-Bus Secret Service and a filesystem with `statx` birth time. Both platforms need `/usr/bin/openssl`.

From the repository root:

```sh
npm ci
npm run build
npm pack --ignore-scripts
npm install --global --prefix "$HOME/.local" --ignore-scripts ./pi-remote-0.0.0.tgz
export PATH="$HOME/.local/bin:$PATH"
```

This installs a local tarball, not a registry release. Use your normal user account, not `sudo` to bypass storage permissions. Keep Bun on `PATH`.

```sh
cd ~/src
pi-remote addresses
pi-remote serve --listen 127.0.0.1
```

Loopback is for local clients and simulators. For a physical phone, select an assigned LAN or Tailscale IPv4 address printed by `addresses`. If Pi detection fails, use `--pi /absolute/path/to/pi/dist/bundle/cli.js`. `--data-dir` selects an independent private catalog; `--port` changes the listener port. Use `pi-remote --help` for the exact options.

## Operation

Run the service from the folder that the phone should browse first. A parent folder such as `~/src` or `~/projects` is valid. Startup does not create or resume a Pi session. Select a project from the iOS directory browser and activate a session explicitly.

The CLI provides `serve`, `addresses` and `--help`. `serve` accepts a selected private IPv4 address, a port, the installed Pi JavaScript entry and a separate private data directory. It does not install Pi, run shell startup files or change provider settings. The CLI executes Pi with Bun, not through its executable shebang.

While serving, enter `help` for local controls. `pair` shows a private two-minute code for the phone's pairing form. Compare the displayed device ID before using `approve REQUEST-ID`. `deny REQUEST-ID` rejects that request; `cancel-pair` closes pairing. `devices` lists IDs and live connection state. `revoke DEVICE-ID` closes that device's connections and rejects later authentication. Free terminal text is never sent to Pi.

Detaching tmux leaves the process running. A phone disconnect does not stop accepted work. Local quit, stdin EOF, SIGINT, SIGTERM and SIGHUP stop the listener and managed Pi. Stopping cannot undo file changes. Forced termination, host sleep and tools that escape the managed process are not cleanup guarantees.

## Security and storage

- A paired device is a trusted Pi controller. Pi tools use the host user's file and command permissions. The initial browsing folder is not a tools sandbox.
- The listener binds one assigned private LAN, Tailscale or loopback IPv4 address. Public, wildcard and ambiguous automatic selection are rejected. No public relay, port forwarding or account service is added.
- TLS uses a persisted, pinned server identity. New certificates include the private IPv4 addresses available at creation. Identity mismatch, missing identity, expiry and uncovered addresses fail closed; identity is not replaced automatically. Select a covered address or explicitly create a new catalog and pair again. Never disable certificate checks.
- macOS uses Keychain. Linux uses an unlocked D-Bus Secret Service. Missing, denied or locked OS secret storage stops startup. There is no plaintext-file or kernel-keyring fallback. Provider credentials remain in Pi's existing host configuration.
- The CLI uses an owned `0700` catalog with `0600` metadata. Persistent TLS private keys and device credentials use the OS store. OpenSSL returns generated key material over a bounded private pipe, not a private-key file. Catalog metadata and Pi JSONL history are private files, not encrypted storage. Symlinks, hard links and unsafe metadata modes are rejected. A kernel `flock` lease rejects a second writer and is released after process death.
- Directory capabilities use canonical paths and filesystem identity, not display paths. Linux needs glibc and a filesystem that reports `statx` birth time. Unsupported filesystems fail explicitly instead of using weaker replacement checks.
- The `@napi-rs/keyring` native addon and Bun FFI calls are runtime dependencies. The Linux host needs `libsecret` and a Secret Service provider. A headless Linux login without an unlocked Secret Service is not a supported setup.
- Routine output excludes pairing grants, credentials, prompts, Pi stderr and tool output. A pairing code appears only on explicit request; terminal capture can still retain it. Keep that output private.
- Native secret-store operations run in bounded, killable Bun workers over private pipes. Secrets are not command arguments or environment variables. A blocked store or unread terminal cannot keep the listener and Pi alive after confirmed shutdown.
- Wire snapshots are budgeted by encoded JSON size. Oversized conversation history is omitted explicitly; structural overflow produces a bounded recovery state instead of a disconnect loop.

The default catalog is `~/Library/Application Support/PiRemoteCLI` on macOS and `~/.local/share/pi-remote` on Linux. Do not point it at the GUI catalog or open its managed Pi files for writing in another process. Closing a session keeps saved history. After restart, select a saved session explicitly; interrupted and unknown outcomes are not automatically replayed.

## First milestone and compatibility

The CLI supports pairing/authentication/revocation; snapshots and synchronization; initial, parent, paged and explicit-path directory browsing; saved-session creation/resume/close; prompts, steering, follow-up and Stop; model/thinking selection; command discovery and standard select/confirm/input/editor dialogs. Text, thinking and generic tool activity stream through the existing version-1 iOS protocol.

Select dialogs keep their response values unchanged. They support at most 100 string options, each at most 512 UTF-8 bytes. Values must survive display sanitization unchanged. Options must have distinct Swift string identifiers, including canonical Unicode comparison. The host cancels unsafe dialogs with a notice instead of changing or removing choices. A select answer must match an offered value unless the request is cancelled.

An admitted, authorized Stop still runs if its receipt cannot be written. If cleanup succeeds, the reply is `ok`; the snapshot reports `storageFailure` and a storage notice. Failed process cleanup remains `unknownOutcome`. Other mutations still require receipt storage before dispatch. Host editor offers (`draft` and `draftID`) are cleared when a session is activated or closed. This does not delete the phone's saved local drafts.

The app contract retains Swift enum envelopes, Base64 bytes, uppercase UUIDs and Foundation dates. Cross-language golden fixtures and the production Swift client check these details. Sequence numbers are limited to JavaScript's safe integer range; input that would lose precision is rejected.

The following actions remain outside this milestone: host-file previews and attachments, image input/output, new-session ancestry, import/export, session trees and fork/clone, queue recovery/settings, model/thinking cycling, compaction/retry settings, usage statistics, diff, last-response copy, release notes and rich extension widgets/status. The host returns `unsupportedFeature`, does not advertise those capabilities, and the native controls are guarded. Existing GUI-host capabilities remain available. This is not complete upstream Pi RPC coverage.

### Action compatibility table

| App actions | CLI behavior | Phone presentation |
| --- | --- | --- |
| `snapshot`, `synchronize` | Bounded snapshot/replay with epoch and sequence checks | Existing conversation and reconnect |
| `directories`, `directoryAtPath` | Initial folder, parents, nested folders, bounded pages and explicit paths | Project picker and Go |
| `createSession`, `resumeSession`, `closeSession` | One managed runtime; explicit activation; idle Close | Spaces, Sessions and Close |
| `prompt` | Text prompt, steering and follow-up; image input rejected | Composer; Photo hidden; local text-file-to-draft input remains available |
| `stop` | Clear queue, abort, confirm idle; stop the child when unresolved work can start later | Stop; interrupted/unknown work remains explicit |
| `model`, `thinking` | Confirmed Pi state read-back | Model and thinking controls |
| `command`, `answer` | Discovered commands and standard dialogs; busy extension commands follow Pi rules | Commands and session-bound dialogs |
| `preview`, `outputImage` | `unsupportedFeature` | Host files and image controls hidden |
| `newSession`, `rename`, `fork`, `clone` | `unsupportedFeature` | Ancestry, rename and tree actions hidden; choose a directory for ordinary creation |
| `importSession`, `importSessionInDirectory`, `exportSession`, `exportJSONL` | `unsupportedFeature` | Import/export controls hidden |
| `history`, `historyPage`, `historyEntry`, `sessionTree` | `unsupportedFeature` | History/tree controls hidden; display omissions are explicit |
| `recoverQueue`, `bash`, `abortBash` | `unsupportedFeature` | No new phone shell or queue-recovery controls |
| `cycleModel`, `cycleThinking`, `compact`, `queueMode`, `autoCompaction`, `autoRetry`, `abortRetry`, `runtimeSettings` | `unsupportedFeature` | Advanced runtime controls hidden |
| `diff`, `statistics`, `releaseNotes`, `lastAssistant` | `unsupportedFeature` | Diff, usage, changelog and copy controls hidden |

## Development checks

Tooling uses npm, Biome, the TypeScript compiler and Bun tests. Husky's hook is exactly one line:

```sh
node ./scripts/pre-commit.mjs
```

The `.mjs` script resolves the repository root and uses installed local tools. It checks staged blobs with Biome in a private temporary index snapshot, then typechecks both that snapshot and the working TypeScript project. Unstaged formatting fixes cannot conceal a malformed staged file. It does not format, migrate configuration, download tools or stage changes. Node.js runs the development hook; Bun runs the CLI and Pi.

Test-only harnesses under `src/fixtures/` use isolated state and explicit fixture-device controls. They are not CLI options and are excluded from the npm artifact. `Spikes/CLIClientCheck` uses the production Swift connection client. Linux checks use the disposable image in `scripts/linux/Dockerfile`; its temporary test keyring does not change production unlock policy.

## Verification record

See the [recorded commands, platform versions, results and limits](headless-cli-verification.md). Tests use controlled fixtures unless explicitly identified as installed-Pi probes. They do not establish real-provider coding, hardware unlock, camera, signed installation or off-site Tailscale behavior.
