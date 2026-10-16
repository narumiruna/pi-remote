# Local spike verification

## Status

The local Pi RPC spike passes its focused checks. The complete app plan is **blocked and incomplete**. There are no iOS or macOS app targets, remote listener, pairing service, or production credentials in this change.

## Environment evidence

- `sw_vers`: macOS 26.6.2, build 25G83.
- Xcode: 26.6, build 17F113; iOS SDK 26.5 and macOS SDK 26.5.
- The active global developer directory is Command Line Tools; the verified commands below select Xcode for that command only.
- Swift: 6.4; package manifests use Swift tools 6.0.
- `pi --version`: 1.3.0.
- `pi auth check --provider openai-codex --model gpt-6.1-sol --json --no-refresh`: ready; no credentials were printed or copied.
- `devicectl` found a paired iPhone 16 Pro running iOS 26.7.1, build 23H30, with Developer Mode enabled, but could not mount its developer disk image.
- Tailscale 1.102.4 reported `BackendState: Stopped`, offline, and no peers; no Tailscale configuration was changed.

The package deployment floors, iOS 18 and macOS 15, are provisional compiler settings, not tested OS support claims.

## Reproduce the focused checks

Run these commands from the repository root with Xcode installed at `/Applications/Xcode.app`:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --package-path Packages/PiRemoteCore
swift test
swift test --sanitize=thread
swift build --package-path Packages/PiRemoteCore \
  --triple arm64-apple-ios18.0-simulator \
  --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"
```

Passing results:

- Seven shared-package test functions, including five invalid-record cases, cover UTF-8 split at every byte boundary, Unicode separators, CRLF, multiple records, invalid JSON and UTF-8, size limits, truncated EOF, and unknown fields.
- Fifteen RPC test functions cover concurrent and reversed responses, command rejection, response mismatch, missing executable, malformed stdout, stderr load, unknown outcomes, cancellation, queue clearing before abort, event overflow, reserved fields, blocked stdin, and a child that ignores termination.
- The RPC tests also pass with Thread Sanitizer enabled.
- The shared package compiles for the iOS simulator; this does not prove that an iOS app builds or runs.

The first RPC test run exposed a pipe-read stall and a missing separator in the test fixture. Both were fixed before the passing run. Shutdown tests also verify that a blocked stdin writer cannot prevent the shutdown deadline.

## Installed Pi exercise

Metadata-only mode sends no model prompt:

```sh
swift run PiRPCSpike "$(command -v pi)" "$PWD"
```

To exercise the configured model, explicitly select model-exercise mode:

```sh
swift run PiRPCSpike "$(command -v pi)" "$PWD" --exercise-model
```

Model-exercise mode sends two small prompts to the configured provider and can incur provider usage. It disables tools, extensions, MCP, skills, prompt templates, and project context for this subprocess. It does not test the normal installed extension set. It keeps sessions in a private temporary directory and removes that directory after the run. It does not write to existing Pi sessions or change Pi settings.

The installed Pi exercise passed with:

- 139 configured models and six available thinking levels reported by RPC.
- An accepted prompt, streamed text deltas, and `agent_settled` observed.
- A persisted session header whose working directory matches the selected directory.
- A second run confirmed active before `clear_queue`, `abort`, and an idle-state check.
- Process shutdown and resumption of the same session ID with nonempty saved history.

The spike does not print raw transcripts, provider errors, credentials, or tool output. A timeout or cancellation has an unknown outcome; the spike never automatically resends a prompt. Event-buffer overflow ends the local subscription while stdout continues to drain. Remote snapshot recovery is not implemented.

## Preliminary workflow compatibility review

Evidence comes from the installed Pi 1.3.0 documentation and the exercise above. Documentation support is not runtime validation or a completed native implementation.

| Workflow | Installed interface and evidence | Remaining work |
| --- | --- | --- |
| Working directory | `Process.currentDirectoryURL`; session header checked in the exercise | Authenticated directory IDs, listing, permission and stale-selection tests, and native picker |
| Create and resume | `--session-id`, `--session-dir`, `--session`; exercised with private temporary sessions | Companion metadata, session selector, restart and recovery behavior |
| Prompts and streaming | `prompt`, delta events, authoritative `message_end`, `agent_settled`; streaming and settlement exercised | Native transcript, Markdown and code rendering, final-message replacement |
| Stop | `clear_queue`, then `abort`, then `get_state`; exercised and fake-process order tested | Shared serialized state for Mac and phone controls |
| Steering and follow-up | Documented `steer`, `follow_up`, queue modes and events | Native controls and actual-run state-transition tests |
| Model and thinking | Model and thinking-level queries exercised | Native selection, changes, and capability tests |
| Commands, skills, templates | Documented `get_commands` and slash prompts | Discover and test the normal resource set; native command picker |
| Extension dialogs | Documented select, confirm, input, editor, notifications, widgets, and status records | Native adapters, dialog expiration, cancellation, and stale-answer tests |
| Branching and history | Documented fork, clone, entries, tree, and fork-message queries | Native controls; investigate tree navigation because a read-only tree query is not branch switching |
| Compaction and retry | Documented commands and lifecycle events | Native state, failure handling, real-run tests |
| Attachments | Documented image content in prompts; RPC rejects CLI `@file` prompt arguments | Native image input, size limits, and an explicit text-file attachment design |
| File and diff inspection | Tool events can include results; no dedicated file/diff browser contract was established | Define host operations and native views without arbitrary RPC forwarding |
| Built-in terminal commands | `get_commands` excludes built-in TUI commands | Map each workflow to a native action or investigate a missing interface |
| Terminal-only extension UI | `custom()` returns `undefined`; terminal input and several rendering methods are unavailable or no-ops in RPC | Investigate adapters or upstream protocol changes; do not claim parity or defer without user agreement |

Configured package inventory from `pi list` and package manifests:

| Package | Version |
| --- | --- |
| `@narumitw/pi-accounts` | 0.53.1 |
| `@narumitw/pi-btw` | 0.61.1 |
| `@narumitw/pi-caffeinate` | 0.49.11 |
| `@narumitw/pi-stamp` | 0.53.0 |
| `@narumitw/pi-sync` | 0.54.2 |
| `@narumitw/pi-file-context` | 0.54.3 |
| `@narumitw/pi-tool` | 0.3.2 |
| `@narumitw/pi-herdr` | 0.3.1 |
| `@narumitw/pi-usage` | 0.66.0 |
| `@narumitw/pi-progress` | 0.6.0 |
| `@narumitw/pi-starship` | 0.59.0 |
| `@narumitw/pi-inspect` | 0.2.2 |
| `@narumitw/pi-codex-compact` | 0.56.1 |

None of these packages has passed a remote native-client compatibility test. Static inspection found direct `ctx.ui.custom()` calls in the shipped accounts, btw, usage, and progress packages, and terminal-input handling in sync. These are concrete investigation targets, not proof that every command in those packages fails. Do not change the installed packages as part of this spike.

## Blockers and next evidence

1. Provide an Xcode/device-support combination that can mount the iPhone developer disk image; verify installation and launch on that phone.
2. Start and authenticate Tailscale through the user's normal setup, then make the iPhone available on a different network for the off-site test.
3. Validate the Face ID or device-passcode unlock policy and matching Keychain access behavior on the physical phone.
4. Build the secure WebSocket spike and prove pairing, server-identity rejection, credential revocation, and reconnection on the physical phone over local and Tailscale connections.
5. Complete the installed-command and extension review, including adapters for missing RPC behavior, without silently reducing the complete-workflow requirement.

Keep the physical transport gate in `PLAN.md` open. Do not continue into screen implementation or report the overall plan complete on the basis of these local tests.
