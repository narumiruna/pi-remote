# Headless CLI verification

Date: 2026-10-19. Base: `d51221d` (`main`, including PR #23). Handoff: [PR #24](https://github.com/narumiruna/pi-remote/pull/24). This record covers the reduced CLI milestone, not the unfinished native-app plan or complete upstream Pi RPC coverage.

Full-gate checkpoints and later focused review checks are recorded below. The packed local/global npm artifact passes on both platforms. Required skips are identified below; no failing acceptance check remains.

## Environments

| Check host | Verified tools |
| --- | --- |
| macOS 26.6.2, arm64 | Bun 1.4.0; Node.js 26.10.0; npm 11.19.1; Pi 1.3.0; Xcode 26.6 (17F113) |
| Debian 12 Linux container, aarch64, glibc 2.36 | Bun 1.4.0; Node.js 26.12.0; npm 11.20.0; Pi 1.3.0; disposable unlocked D-Bus Secret Service |
| iPhone 17 Pro simulator, iOS 26.5 | Production app/client source, unsigned test builds, injected local unlock result |

Other architectures, runtime versions and Linux secret-store providers were not checked. Linux tests ran in an actual Linux container, not a Darwin platform mock. The test image is `scripts/linux/Dockerfile`; `scripts/linux/session.sh` creates an isolated test keyring. Its fixed test password is not product unlock behavior.

## Results

| Check | Result |
| --- | --- |
| macOS `PI_REMOTE_TEST_OS_SECRETS=1 npm run ci` at `285a058` | 170 Bun tests pass; two Linux-only tests skip; seven hook tests pass; build and local/global tarball installation pass |
| Linux equivalent full gate at `285a058` | 171 Bun tests pass; one root-only permission skip; seven hook tests, build and local/global installation pass |
| Linux non-root storage/directory/identity/secret subset | 36 pass, no skips; includes the permission case skipped as root |
| Current Swift JSON encoder versus `src/fixtures/wire-v1.json` | Parsed values match |
| TypeScript packet encoding decoded with production Swift types | Pass, including the minimal CLI snapshot |
| Installed Pi subprocess probes, macOS and Linux | Bun launch with empty `PATH`, isolated settings, state/messages, persisted session creation, explicit resume and confirmed exit pass; no provider prompts |
| Production Swift client to macOS CLI host | Full controlled flow passes on the laptop's LAN and Tailscale addresses |
| Production Swift client to Linux CLI host | Full controlled flow passes through a mapped local port, with real OS secret storage and persistent authentication across host restart |
| Product iOS hosted checks after integrating PR #23 | Six pass: live `PhoneModel` pairing/project/coding/reconnect, CLI/native capability checks and four retained Session controls checks |
| Focused iOS interface checks | Three pass: typed-path recovery/explicit Start, empty Spaces and folder-only Space creation |
| Native Mac directory controls | Two pass; unsigned Mac test build passes |
| `git diff --check` | Pass |

The controlled flow uses the production `RemoteClient` and pinned TLS channel. It pairs with request-bound fixture-local approval, browses parent/nested/explicit paths, selects a project before starting Pi, writes `acceptance.txt`, verifies one accepted coding prompt after disconnect, displays thinking/tool activity, changes model/thinking, answers a dialog, sends steering/follow-up, clears input with Stop, closes/resumes, restarts the host, explicitly resumes interrupted work, revokes access and confirms denial on reconnect. The provider-free Pi fixture writes the file; this is not real-provider coding evidence.

`src/fixtures/host.ts` is an explicit test harness. Its memory store and private fixture control files are not product arguments or authentication exceptions. The Linux cross-language run also exercises the actual Secret Service integration. Fixture code and credentials are excluded from the npm artifact.

## PR #24 review corrections

The first three review findings were reproduced with failing tests before the fixes. At `285a058`, the focused coordinator suite passed 46 tests. Fifteen tests covered those review cases and their related boundaries. Both full CLI gates above pass. The installed-Pi managed creation/resume probe also passes without provider prompts. The original Swift/iPhone checks remain evidence from the first milestone; they were not rerun for these TypeScript-only fixes.

| Finding | Verified outcome |
| --- | --- |
| [R1: select response values](https://github.com/narumiruna/pi-remote/pull/24#discussion_r4315848256), P2 | Valid values, including a 512-byte UTF-8 value, reach Pi unchanged. Oversized, sanitized, non-string, excessive or duplicate options are cancelled with a notice. Unicode-equivalent Swift identifiers are also rejected. Unoffered answers do not consume the pending dialog. |
| [R2: Stop after receipt-write failure](https://github.com/narumiruna/pi-remote/pull/24#discussion_r4315848265), P1 | Persistent `ENOSPC`/`EACCES` cannot block an admitted, authorized Stop. Tests confirm the managed PID is gone and `storageFailure` remains visible. A failed final receipt write does not erase confirmed idle or repeat abort on a duplicate request. Unauthorized/stale-session requests remain rejected. Unconfirmed termination still returns `unknownOutcome`. |
| [R3: cross-session editor offers](https://github.com/narumiruna/pi-remote/pull/24#discussion_r4315848272), P2 | Create, resume and Close clear `draft` and `draftID` before the new context is published. Current-session snapshots and replay contain no prior-session offer. Phone-local saved drafts are not deleted. |

No review item was deferred or left for clarification. The submitted review receipt and status comment contain no separate code proposal. Their findings are accounted for above. Hosted checks were absent at the review checkpoint; the reported gate results are local checks on macOS and the actual Linux runner.

### Receipt-capacity follow-up

[R4: Stop at receipt capacity](https://github.com/narumiruna/pi-remote/pull/24#discussion_r4316032019), P2, was reproduced at `285a058`: a streaming runtime remained active because Stop returned `capacity`. The new emergency path preserves all 10,000 existing receipts and adds none. It terminates the runtime and prevents new work until restart. Earlier request results still use normal deduplication. Repeated emergency Stop requests do not grow the table or repeat an abort after the runtime is gone.

The updated coordinator suite passes 53 tests, including seven capacity cases. Coordinator and WSS checks pass 65 tests with no skips on each of macOS and Linux. Both platforms also pass Biome, full TypeScript typecheck, build and clean local/global package installation. Tests cover repeated requests, old receipt retention, authorization/epoch/session checks, unavailable storage, unconfirmed termination, pending-admission fencing and explicit recovery after restart. The earlier full-gate and native-app results above were reused; no new provider, Swift/iPhone or hardware check was needed for this TypeScript-only change.

R1–R3 remain addressed. R4 is addressed by the bounded emergency path. No item is deferred or needs clarification.

### Interactive-command deadline follow-up

[R5: command wait versus dialog lifetime](https://github.com/narumiruna/pi-remote/pull/24#discussion_r4316195503), P2, was reproduced at `1d7974c`. Two tests reduced only the initial private RPC deadline to 200 ms, kept a valid dialog open for 350 ms, and received `unknownOutcome` before an answer. The fix resets only pending prompt-response timers from host-validated dialog lifetimes. After the last dialog is answered or expires, the 30-second completion bound applies. Sequential dialogs renew the wait. Unrelated requests, future defaults, abort signals and Stop deadlines are unchanged.

The coordinator, RPC and WSS suites pass 105 tests without skips on each of macOS and Linux. Nine new tests cover command and slash-prompt routes, sequential dialogs, expiry, Stop, missing completion, cancellation and timer bounds. Both platforms pass Biome, full TypeScript typecheck, build and local/global npm installation. A separate probe kept the unmodified 30-second RPC deadline, answered after 31 seconds, confirmed command completion and idle, then sent another prompt successfully. This was a provider-free host probe, not an iPhone or real-provider result. The shared Swift client's existing request timeout was not changed or revalidated.

R1–R5 are addressed. No item is deferred or needs clarification. Earlier checks above remain their recorded checkpoints; unchanged native checks were not rerun.

## Negative and lifecycle checks

- Wrong certificate, hostname, expired/corrupt/missing identity and changed catalog fingerprint fail closed. Public and wildcard binding are rejected.
- Pairing requires an open grant and the exact displayed request. Wrong/stale grants, denial, cancellation, expiry, rate limits, replay and revoked live/reconnection access are checked.
- Unsafe ownership/modes, symlinks, hard links, oversized/corrupt metadata, FIFOs and concurrent catalog writers are rejected. `flock` ownership releases after process death.
- Directory tests cover initial `src`/`projects` folders, parents, explicit paths, symlinks, denied/deleted/moved/replaced folders, independent bounded cursors and registry limits. Linux filesystems without `statx` birth time fail explicitly.
- RPC tests cover split UTF-8, CRLF, literal Unicode separators, strict LF framing, invalid/oversized output, response IDs, child crash, deadlines, blocked input, cancellation and event pressure. Default child SIGINT/SIGTERM dispositions pass on both platforms.
- Stop is fenced against durable-admission and pre-child activation races. Unresolved prompt/steering/follow-up preflight cannot start later work after confirmed process cleanup. Malformed settlement cannot report idle.
- Failed receipt persistence after Pi acceptance stays `unknownOutcome`. Catalog write failure cannot make active Pi idle or permit Close. Unknown work requires explicit Stop before session changes.
- Extension-answer writes and Stop control requests have a one-second deadline. A stalled pipe releases interrupt admission and forces confirmed child cleanup instead of leaving Stop permanently busy.
- Native secret-store calls use killable Bun workers. Startup cancellation also reaps the certificate generator before releasing the catalog. Generated private keys use bounded anonymous output pipes, not scratch key files.
- Nine real-CLI lifecycle tests cover quit, EOF, SIGINT/SIGTERM/SIGHUP, a drained PTY control, unread pipe/PTY output and SIGTERM during blocked PTY output. Each verifies the active Pi PID is absent when the CLI exits, then reacquires the catalog and port. Output writes have a 250 ms deadline; test cleanup has a two-second bound. Failed termination is not treated as confirmed cleanup.
- Encoded JSON budgeting covers ordinary and escape-heavy full histories, heartbeat reads, replay and reconnection. Oversized structural metadata produces a bounded recovery snapshot. Bun WebSocket `send() === -1` means buffered, not failed; the eight-MiB buffer remains bounded.

## Reproduction

These checks require the repository source; fixture files are not shipped in the npm artifact. On a configured Mac or Linux host with an unlocked native secret store:

```sh
npm ci
PI_REMOTE_TEST_OS_SECRETS=1 npm run ci
```

`PI_REMOTE_TEST_OS_SECRETS` is read only by tests and fixture tooling. It is not a CLI security setting. Tests use isolated catalog UUIDs and remove their OS-store records.

For the disposable Linux runner:

```sh
docker build -f scripts/linux/Dockerfile -t pi-remote-cli-check .
docker run --rm -v "$PWD:/source:ro" pi-remote-cli-check sh -c '
  cp -R /source/src /source/scripts /source/.husky /source/docs /work/
  cp /source/package.json /source/package-lock.json /source/tsconfig.json /source/biome.json /source/.gitignore /source/LICENSE /source/README.md /work/
  git init -q
  npm ci --ignore-scripts
  PI_REMOTE_TEST_OS_SECRETS=1 npm run ci
  runuser -u nobody -- dbus-run-session -- /usr/local/bin/pi-remote-test-session sh -c "PI_REMOTE_TEST_OS_SECRETS=1 bun test src/host/storage.test.ts src/host/directories.test.ts src/host/identity.test.ts src/host/secrets.test.ts"
'
```

Installed-Pi probes require its absolute JavaScript entry. Both probe files create private temporary settings and do not submit model prompts:

```sh
bun src/fixtures/rpc-installed-probe.ts "$PI_ENTRY"
bun src/fixtures/managed-installed-probe.ts "$PI_ENTRY"
```

Cross-language fixture operation is documented in `Spikes/CLIClientCheck/README.md`. The iOS tests are in `Tests/PhoneTests/CLIHostCapabilitiesTests.swift`. `project.yml` defines the existing `PiRemote`, `PiRemoteMac` and `PiRemoteInterface` schemes. Only the iPhone 17 Pro simulator was used; the retired compact-device matrix was not run.

## Scope and recovery

The approved Swift CLI prototype was backed up under `/tmp/pi-remote-paused-swift-cli.bd2jo5` with `/tmp/pi-remote-paused-swift-cli.patch`. Only its CLI files and prototype-specific shared changes were removed or reverted. Native host/protocol source is unchanged; the Swift package adds only the explicit client-check executable. The language-rule removal remains. PR #23's model-first controls, collapsed Details and delivery layout are retained.

The CLI has its own catalog and OS-store namespace. No GUI catalog, terminal Pi history or provider configuration was migrated or deleted. The npm artifact contains only the command, bounded OS-store worker, license and focused documentation. Registry publication was not performed.

Limits: no new real-provider coding requests, signed installation, hardware unlock/camera or off-site Tailscale checks were run. The installed-Pi probes are narrower than the controlled coding fixture. Local LAN/Tailscale connections do not prove off-site routing. SIGKILL, host sleep and tools that escape the managed process cannot provide graceful cleanup or undo external effects. Inspect interrupted outcomes before retrying. Private metadata and Pi history use file permissions, not encryption.
