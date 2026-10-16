# Native Pi compatibility review

## Result

The review is incomplete. Pi Remote does not yet provide the complete accepted workflow. No feature exclusion has been approved. Passing discovery, menu cancellation or an explicit unsupported notification does not establish feature parity.

The current installed runtime is Pi 1.3.0 at `/Users/narumi/.bun/bin/pi`. The executable is a Node.js entry point. `pi auth check --provider openai-codex --model gpt-6.1-sol --json --no-refresh` reports ready with OAuth, without exposing credentials. This is the only runtime version exercised here; it is not a supported-version range.

## Evidence

- `NativeWorkflowCheck`: selected-directory launch, models, thinking, rename, all four RPC dialog methods, actual dialog timeout and late-answer rejection, prefill and idle restoration. No provider request.
- `NativeProviderCheck`: real image input, live streaming, steering, follow-up, queue-clearing Stop, clone, fork, real manual compaction and nonempty restoration. Resources and tools are disabled.
- `NativeFailureCheck`: installed-Pi missing-credential rejection, deduplication and empty-session restoration in an empty home/environment.
- `NativeExtensionCheck`: the currently configured package set loaded together in an empty home/environment, command discovery, safe menu cancellation and explicit terminal-only rejection. This does not test provider/account operations, configuration changes, sync transfers or normal credential-backed startup behavior.
- Package, Mac-model, simulator and interface checks: [workflow evidence](workflow-verification.md) and [interface evidence](interface-verification.md).

`NativeExtensionCheck` loads explicit package entry points with extensions otherwise disabled. Its inventory matches `pi list` at this checkpoint, not every package left on disk. It does not invoke `/herdr` or control Herdr. It sends no inference prompt, retains no real credentials and makes no deliberate external write. Private fixture files are removed after shutdown.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift run NativeExtensionCheck "$(command -v pi)" \
  /Users/narumi/.pi/agent/npm/node_modules/@narumitw
```

The check passes in `/tmp/pi-remote-installed-extensions.log`. Its three `GAP` records are expected unsupported results, not passing implementations of those workflows.

## Installed extensions

| Package | Version | Current local evidence | Remaining native gap or check |
| --- | --- | --- | --- |
| `pi-accounts` | 0.53.2 | Main RPC selection menu opens and cancels | Account listing, sign-in, switching and deletion require isolated operation tests; credentials must remain on the Mac. |
| `pi-btw` | 0.61.1 | Command explicitly reports its interactive-TUI requirement | Side-thread creation, streaming, history and bring-to-editor require a native adapter. No RPC side-thread transport exists in this package. |
| `pi-caffeinate` | 0.49.11 | Main RPC selection menu opens and cancels | Mode/settings changes and lifecycle ownership remain untested. Do not put the laptop to sleep to test them. |
| `pi-stamp` | 0.53.0 | Main RPC selection menu opens and cancels | Configuration dialogs need operation tests; transcript stamps are TUI-only. |
| `pi-sync` | 0.54.3 | Main RPC selection menu opens and cancels | RPC preferences are read-only/manual-path guidance. Native editing and isolated transfer/recovery tests remain. No real remote transfer was attempted. |
| `pi-file-context` | 0.54.3 | Command explicitly reports its interactive-TUI requirement | Native context selection, range selection and prompt insertion need an adapter. A read-only file preview is not equivalent. |
| `pi-tool` | 0.3.2 | Main RPC selection menu opens and cancels | Tool/detail and widget-setting operation tests remain. |
| `pi-herdr` | 0.3.1 | Loads outside Herdr; no command is registered in that environment | Environment-specific behavior remains untested. No terminal control was requested or attempted. |
| `pi-usage` | 0.66.0 | Main RPC selection menu opens and cancels | Provider reports, fast-mode operations and settings remain untested; RPC settings only report a manual path. |
| `pi-progress` | 0.6.0 | Main RPC selection menu opens and cancels | Status/help/settings and live progress need operation tests. RPC settings report a manual path; widget snapshots use fixed dimensions. |
| `pi-starship` | 0.59.0 | RPC command produces notification rather than a terminal menu | Footer, preset/module inspection, sharing/import and native settings remain gaps. |
| `pi-inspect` | 0.2.2 | Command explicitly reports its TUI requirement | Native inspection equivalent is missing; the Mac-local private browser URL cannot simply be exposed to a phone. |
| `pi-codex-compact` | 0.56.1 | RPC configuration command produces a notification | Native settings and credential-backed extension compaction remain untested. Generic real compaction passes separately with extensions disabled. |
| `pi-notify` | 0.2.0 | RPC configuration command produces a notification | Native configuration remains a gap. Delivery tests need isolated providers; no real notification was sent. |

The earlier review incorrectly treated direct `custom()` references as proof that whole packages lacked RPC support. Current runtime evidence shows functional RPC menus in accounts, usage and progress. The remaining terminal-only cases above are explicit mode guards in the installed package sources, also verified at runtime.

## Built-in and resource workflows

The installed `docs/slash-commands.md` lists built-in commands; `get_commands` intentionally excludes them. Pi Remote must map their behavior to typed native actions rather than forward arbitrary RPC.

| Workflow or terminal commands | Native state | Remaining requirement |
| --- | --- | --- |
| Directory choice | Implemented; nested simulator navigation, canonical cwd and permission/replacement checks pass | None for the accepted accessible-folder policy. |
| `/new`, `/resume`, `/name` | Implemented for companion-owned sessions; local and simulator checks pass | Manual import is separate; terminal-session attachment remains excluded. |
| `/model`, `/thinking` | Implemented and checked against installed Pi | No tested runtime-version range beyond 1.3.0. |
| Prompt, streaming, tools, steering, follow-up, Stop | Provider and simulator checks pass | Extension renderers remain a gap; bounded native raster-image viewing now passes separately. |
| `/fork`, `/clone` | Implemented; real provider checks pass | Fork is limited by Pi to eligible active-branch user messages. |
| `/tree` | Paged entry inspection only | In-place navigation is missing from RPC; extension command contexts expose `navigateTree`, but no app-owned adapter exists. Do not edit JSONL leaf state externally while Pi owns it. |
| `/compact` | Real summarization, compacting state, persisted entry and restart restoration pass | Extension-specific compaction remains separate. |
| `/session` | Native session-usage view shows validated token, cost, message and context statistics from `get_session_stats`; installed-Pi empty and post-compaction checks pass | Provider totals are estimates, not an invoice; unavailable post-compaction context is explicit. |
| Commands, skills, templates | Discovery and named command dispatch implemented | Actual skill/template expansion and the normal loaded-resource set still need checks. |
| Dialogs, notifications, text widgets/status | All four supported dialogs and expiry pass | Terminal custom components, terminal input and custom renderers are not transported. |
| Attachments and files | Image input, original raster-image retrieval/viewing, text/file preview and Git diff implemented; [image checks](output-images.md) pass on LAN and Tailscale with restart restoration | Image format/size and first-frame limits remain explicit. Native Mac-file/context attachment remains incomplete; phone text-file input is already available. |
| `/settings`, `/scoped-models` | Not implemented | Native settings/model-scope controls and a supported persistence interface are needed. |
| `/login`, `/logout` | Missing-credential recovery directs the user to the Mac | This is not a native authentication-management workflow. Secrets must not move to the phone. |
| `/llama` | Not implemented | Inspect configured router capabilities and design native management. |
| `/copy` | Transcript text is selectable | A direct last-assistant copy action remains. |
| `/export`, `/share`, `/bug` | Not implemented | Typed export/share/report controls need explicit sensitive-data review before external publication. |
| `/import` | Not implemented | Explicit import must validate a session's cwd and companion ownership; automatic history import remains excluded. |
| `/trust`, `/reload` | Not implemented | Native trust/resource review and reload controls remain. |
| `/hotkeys`, `/changelog` | Not implemented | Native equivalents need an explicit compatibility decision; terminal keybindings cannot be copied as mobile controls. |
| `/quit` | Companion shutdown stops its child | No separate native idle-session close action exists. |

## Adapter investigation

Pi 1.3.0's RPC UI contract explicitly returns `undefined` for `custom()`. Terminal input registration is a no-op. Footer/header/editor-component overrides and custom renderers do not become serializable native UI records. The installed btw and file-context commands reject RPC before entering their terminal components; inspect also rejects browser opening in RPC. Swift cannot recover an interaction that the subprocess does not emit.

The following alternatives require further work or approval; none is silently accepted:

1. Add RPC-native workflows to the upstream extensions and expose missing core commands through a maintained Pi interface. Changes to installed packages or upstream repositories are external writes and require approval.
2. Add a bundled Pi extension/SDK adapter and native Swift screens. That changes the current all-Swift app-owned-service boundary and requires an explicit architecture decision. It must not embed a terminal, forward arbitrary RPC, expose credentials or mutate session files behind Pi. Authorization for a bundled adapter was requested; no explicit decision has been received.
3. Obtain explicit agreement to exclude the named terminal-only/configuration workflows. No such agreement exists; this would reduce the current objective and cannot be assumed.

Independent Swift work can continue, including copy/export controls, native Mac-file attachment and other built-in workflows. Session statistics, bounded raster output and clean setup controls are now implemented and verified. These gaps are not a reason to mark the plan complete or to stop all implementation work.
