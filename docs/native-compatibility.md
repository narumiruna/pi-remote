# Upstream Pi core RPC coverage and compatibility

## Result

The user confirmed that app compatibility targets only the RPC protocol supplied by upstream Pi core packages. The earlier complete-terminal and installed-extension parity requirement is superseded. The upstream Pi core RPC coverage audit remains incomplete. The newer Mac interface target follows terminal Pi layout and interaction in Swift; it does not add arbitrary terminal extension transport. See the [reference](pi-like-mac-reference.md) and [new implementation evidence](pi-like-mac-verification.md).

## Accepted boundary

- Cover upstream Pi core RPC operations, responses and events, plus its standard extension UI subprotocol.
- Discover extension commands and invoke them through the standard protocol without imports, required packages, name-based adapters or custom extension RPC formats.
- Render standard dialogs, notifications, status, text widgets and editor updates generically. Controlled fixtures can verify this contract without the user's installed extensions.
- Do not require terminal-only built-in commands, custom terminal components, individual extension workflows or custom extension protocols for acceptance.
- Do not add a bundled Pi-side adapter or modify upstream Pi core packages or individual extensions to achieve terminal parity. Such changes are not needed for the accepted scope.
- Retain existing app-owned security, networking, filesystem and session requirements and implemented convenience features.

<a id="core-rpc-audit-inventory"></a>

## Upstream Pi core RPC audit inventory

The following groups list the operations in installed Pi 1.3.0's `docs/rpc-commands.md`. The table separates verified groups from remaining integration work. Passing checks for one group do not close another group.

| Area | Upstream Pi core RPC operations | Acceptance status |
| --- | --- | --- |
| Work and queues | `prompt`, `steer`, `follow_up`, `abort`, `clear_queue` | Native prompt/delivery/Stop controls; installed provider checks and [queue race regressions](core-event-verification.md#queue-delivery) pass |
| Session changes | `new_session`, `switch_session`, `set_session_name`, `fork`, `clone` | Native same-directory upstream Pi core lifecycle, normalized names and authoritative branching; installed [lifecycle checks](session-lifecycle.md) pass normally and with Thread Sanitizer, including cancellation and oversized fork text |
| State and history | `get_state`, `get_messages`, `get_fork_messages`, `get_entries`, `get_tree`, `get_last_assistant_text`, `get_session_stats` | Native state/transcript, authoritative paged tree/fork options, copy and usage; installed-Pi [inspection](session-inspection.md), copy and statistics checks pass. All 27 compact-interface tests and 31 product tests on each local network pass |
| Models and thinking | `set_model`, `cycle_model`, `get_available_models`, `set_thinking_level`, `cycle_thinking_level`, `get_available_thinking_levels` | Native selection/cycling and discovered choices; installed-Pi and compact-interface [checks pass](runtime-controls.md#core-model-cycling-and-retry-checkpoint) |
| Runtime controls | `set_steering_mode`, `set_follow_up_mode`, `compact`, `set_auto_compaction`, `set_auto_retry`, `abort_retry` | Confirmed native settings, compaction and retry cancellation; [settings checks](runtime-controls.md) and [active retry/compaction checks](core-event-verification.md) pass |
| Shell and export | `bash`, `abort_bash`, `export_html` | Reviewed HTML export passes installed, native and product checks. Mac `!`/`!!` review, typed shell actions, bounded streaming, cancellation and saved-result projection are implemented. Controlled and isolated Pi 1.3.0 checks pass; [evidence and limits](pi-like-mac-verification.md). Phone entry and attended normal Mac use remain open; no embedded terminal or PTY is permitted |
| Discovery | `get_commands` | Native generic command list and dispatch; private startup/resource checks and active extension-dialog dispatch pass |

### Event mapping

The 24 event types in Pi 1.3.0's `json.md` have the following app mappings. The new shell-stream checks are recorded separately from older checkpoints.

| Events | App behavior | Direct checks |
| --- | --- | --- |
| `agent_start`, `agent_settled` | Active/settled state and persisted interruption marker | Provider, host, reconnection and reducer checks |
| `agent_end`, `turn_start`, `turn_end` | Do not declare idle or duplicate completed messages | `turnAndAgentEndRecordsCannotDeclareSettlementOrDuplicateMessages` |
| `message_start`, `message_update`, `message_end` | Bounded streamed blocks replaced by final messages | Installed provider, image and reducer checks |
| `tool_execution_start`, `tool_execution_update`, `tool_execution_end` | Correlated tool rows; final tool messages reconcile provisional output | Product coding tests and `finalToolResultReplacesExecutionResultWithStableIdentityAndImages` |
| `queue_update` | Replace pending counts without copying queue text into snapshots | Dedicated queue and Stop regressions |
| `entry_appended` | Retain opaque custom metadata in Pi history; do not invent a chat message | Reducer metadata boundary and [history-inspection checks](session-inspection.md) |
| `session_info_changed`, `thinking_level_changed` | Normalized/cleared title and current thinking state | Installed `NativeUIStateCheck` |
| `compaction_start`, `compaction_end` | Phase/error handling and deferred authoritative history refresh | Installed manual compaction and host automatic-compaction regression |
| `auto_retry_start`, `auto_retry_end` | Retry state, bounded final failure and event-driven settlement | Installed `NativeRetryCheck` and reducer checks |
| `summarization_retry_scheduled`, `summarization_retry_attempt_start`, `summarization_retry_finished` | Retry/compaction phases restored between attempts | Manual-compaction and branch-summary reducer cases |
| `bash_execution_update` | Correlated 64 KiB output with coalesced state, explicit final/cancel/unknown state | New shell correlation, truncation, delayed-admission cancellation and isolated installed-Pi checks pass; [evidence](pi-like-mac-verification.md) |
| `extension_error` | Generic unsupported-feature error without publishing extension paths or supplied error text | `extensionFailuresAndUnknownUIRequestsDoNotExposePathsOrApproveDialogs` |

### Standard extension UI mapping

All nine upstream Pi core UI methods have native mappings. `select`, `confirm`, `input` and `editor` use session-bound dialogs and typed responses. `notify` and `setTitle` use notices. `setStatus` and `setWidget` have independent bounded key namespaces. `set_editor_text` proposes a draft update, with an explicit decision before replacing a nonempty draft. Terminal severity styling, widget placement and terminal titles are not reproduced.

Installed `NativeWorkflowCheck` verifies the four dialog methods, prefill, timeout and late-answer rejection. Installed `NativeUIStateCheck` verifies notices, status/widget replacement and clearing, and Stop-cancelled input. Host and app checks verify oversized-dialog cancellation, stale contexts and draft-replacement consent. This is standard protocol support, not a dependency on the fixture extension.

Keep authenticated typed app actions, opaque filesystem/session identities, deduplication and bounded output; upstream Pi core RPC scope does not mean exposing an arbitrary raw RPC endpoint.

A host regression verifies that an unknown UI method creates no dialog and sends no automatic response. Shell operation/event mappings now have focused host and runtime evidence. Native phone shell entry and attended Mac acceptance remain open.

The current installed runtime is Pi 1.3.0 at `/Users/narumi/.bun/bin/pi`. The executable is a Node.js entry point. `pi auth check --provider openai-codex --model gpt-6.1-sol --json --no-refresh` reports ready with OAuth, without exposing credentials. This is the only runtime version exercised here; it is not a supported-version range.

## Evidence

- `NativeWorkflowCheck`: selected-directory launch, models, thinking, rename, all four RPC dialog methods, actual dialog timeout and late-answer rejection, prefill, idle restoration, reviewed version-3 import and HTML export. No provider request.
- `NativeResourceCheck`: normal private agent-directory discovery, quoted/default template expansion, skill expansion/location, startup trust isolation, project precedence, local-package prompts and native command dispatch. The fixture aborts before provider use and verifies no provider calls, tokens or cost. It does not load real personal resources or installed packages.
- `NativeProviderCheck`: real image input, live streaming, steering, follow-up, queue-clearing Stop, clone, fork, real manual compaction and nonempty restoration. Resources and tools are disabled.
- `NativeFailureCheck`: installed-Pi missing-credential rejection, deduplication and empty-session restoration in an empty home/environment.
- `NativeExtensionCheck`: the currently configured package set loaded together in an empty home/environment, command discovery, safe menu cancellation and explicit terminal-only rejection. This does not test provider/account operations, configuration changes, sync transfers or normal credential-backed startup behavior.
- `NativeInspectionCheck`: private 217-entry imported tree, resolved labels/timestamps/leaf, paged text/image previews, abandoned-message fork and restoration, with OS-level network denial and zero inference; [direct evidence](session-inspection.md).
- `NativeRetryCheck` and `NativeUIStateCheck`: isolated installed-Pi retry cancellation, normalized names, thinking events, independent status/widget namespaces, notification/title projection and Stop-cancelled input; [direct evidence](core-event-verification.md).
- Current 135-test root/50-test shared normal and sanitizer checks, three Mac-model checks, 31 product tests on each local network, installed probes and three unsigned builds: [acceptance checkpoint](core-rpc-acceptance.md). All 27 compact-interface tests pass in the final accepted batch set; earlier [workflow](workflow-verification.md) and [interface](interface-verification.md) checkpoints remain historical evidence.

`NativeExtensionCheck` loads explicit package entry points and `builtin:llama.cpp` with other extensions disabled. Its inventory matches `pi list` at this checkpoint, not every package left on disk. It does not invoke `/herdr` or control Herdr. It sends no inference prompt, retains no real credentials and makes no deliberate external write. Private fixture files are removed after shutdown.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift run NativeExtensionCheck "$(command -v pi)" \
  /Users/narumi/.pi/agent/npm/node_modules/@narumitw
```

The expanded check passes normally and with Thread Sanitizer in `/tmp/pi-remote-builtin-extensions.log` and `/tmp/pi-remote-builtin-extensions-tsan.log`. Its four `GAP` records are expected unsupported results, not passing implementations. The installed llama.cpp handler explicitly rejects RPC before checking configuration or contacting a router. No model download, load/unload, account change or router request was attempted.

## Historical installed-extension audit (not an acceptance gate)

The following package-specific checks came from the superseded terminal-parity scope. They remain diagnostic evidence only. Their unimplemented workflows are not required tasks, dependencies or blockers for this app.

<details>
<summary>Historical package observations</summary>

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

</details>

## Historical terminal workflow comparison (not an acceptance gate)

The installed `docs/slash-commands.md` includes terminal-only commands. Their presence does not put them in upstream Pi core RPC scope. The following table records earlier comparisons, not current implementation requirements. Only corresponding upstream Pi core RPC behavior belongs in the audit above.

<details>
<summary>Historical terminal comparisons</summary>

| Workflow or terminal commands | Native state | Remaining requirement |
| --- | --- | --- |
| Directory choice | Implemented; nested simulator navigation, canonical cwd and permission/replacement checks pass | None for the accepted accessible-folder policy. |
| `/new`, `/resume`, `/name` | Implemented for companion-owned sessions; local and simulator checks pass | Manual import is separate; terminal-session attachment remains excluded. |
| `/model`, `/thinking` | Implemented and checked against installed Pi | No tested runtime-version range beyond 1.3.0. |
| Prompt, streaming, tools, steering, follow-up, Stop | Provider and simulator checks pass | Extension renderers remain a gap; bounded native raster-image viewing now passes separately. |
| `/fork`, `/clone` | Implemented; real provider checks pass | Historical active-branch-only assumption was incorrect. Upstream Pi core `get_fork_messages` also includes eligible messages from abandoned branches; authoritative native integration and installed-Pi checks now pass. |
| `/tree` | Paged entry inspection only | In-place navigation is missing from RPC; extension command contexts expose `navigateTree`, but no app-owned adapter exists. Do not edit JSONL leaf state externally while Pi owns it. |
| `/compact` | Real summarization, compacting state, persisted entry and restart restoration pass | Extension-specific compaction remains separate. |
| `/session` | Native session-usage view shows validated token, cost, message and context statistics from `get_session_stats`; installed-Pi empty and post-compaction checks pass | Provider totals are estimates, not an invoice; unavailable post-compaction context is explicit. |
| Commands, skills, templates | Discovery and named dispatch implemented; installed-Pi [resource checks](workflow-verification.md#native-resource-check) pass normal private-directory discovery, quoted/default template expansion, skill content/location, startup trust isolation, project-over-user template/skill precedence and manifest-selected local-package prompts without provider calls | Real personal resource/package combinations, native trust/reload, remaining resource filter/precedence combinations and model-driven skill selection still need checks. |
| Dialogs, notifications, text widgets/status | All four supported dialogs and expiry pass | Terminal custom components, terminal input and custom renderers are not transported. |
| Attachments and files | Image input, original raster-image retrieval/viewing, phone/Mac text-file attachment, file preview and Git diff implemented; [image checks](output-images.md) and [attachment checks](workflow-verification.md#mac-text-file-attachment) pass | Image format/size, first-frame and combined text-budget limits remain explicit. The terminal file-context extension's range-selection/editor workflow is not implemented. |
| `/settings`, `/scoped-models` | Models/thinking, queue delivery and automatic compaction have native controls; confirmed writes and read-back checks pass | Remaining preferences, current retry-setting inspection and model scopes need a supported interface and native controls. |
| `/login`, `/logout` | Missing-credential recovery directs the user to the Mac | This is not a native authentication-management workflow. Secrets must not move to the phone. |
| `/llama` | Installed built-in command discovery passes, but invoking it explicitly reports that it requires interactive mode; normal and Thread Sanitizer probes confirm the rejection | Native router management remains missing. Terminal source covers current catalog state, load/unload, download/quantization, gated access, cancellation and recovery. These require a native bridge or a Swift router client with Mac-side authentication; forwarding this command does not implement them. |
| `/copy` | Native last-text review and explicit copy pass; iOS expiration and isolated clipboard tests pass | Text beyond 256 KiB is explicitly partial; clipboard restrictions are OS options, not protection from local clipboard managers. |
| `/export`, `/share`, `/bug` | Native reviewed HTML/full-tree and JSONL/active-branch export, system saving and separately consented native service-picker sharing pass [local checks](session-export.md) | Pi's Radius/Gist upload and bug-report workflows remain. Native service delivery is not verified. No automatic upload or redaction is claimed. |
| `/import` | Reviewed versions 1–3 JSONL import and Pi-managed legacy migration pass [host, installed-Pi, transport and native picker checks](session-import.md); sources remain unchanged and no prompt is sent | Explicit directory choice also passes missing-folder, permission, identity and native picker checks. Switch-hook lifecycle equivalence remains. Automatic history import remains excluded. |
| `/trust`, `/reload` | Not implemented | Native trust/resource review and reload controls remain. |
| `/changelog` | Native read-only release-note paging passes [installed-resource and compact-interface checks](release-notes.md); all 644,403 installed bytes match | Selectable source text uses file order rather than terminal Markdown, reverse order and normalized links. No automatic URL opening or last-viewed setting update. |
| `/hotkeys` | Not implemented | Native equivalents need an explicit compatibility decision; terminal keybindings cannot be copied as mobile controls. |
| `/quit` | Native idle-session close stops Pi, keeps the listener/catalog and supports explicit resume without prompt replay | Working state rejects close until Stop reaches idle. |

At the earlier checkpoint, managed-session activation always started a new child. The current [same-directory upstream Pi core lifecycle](session-lifecycle.md) now preserves the standard new/switch/fork hooks and cancellation without an adapter. Cross-directory activation still replaces the process deliberately. In-place tree navigation remains outside upstream Pi core RPC scope.

</details>

## Disposition of the former adapter blocker

Pi 1.3.0's RPC `custom()` returns `undefined`, and terminal-input registration is a no-op. Installed btw, file-context, inspect and llama commands explicitly reject RPC. Those observations remain valid protocol limits, but the user-confirmed scope no longer requires adapting these workflows.

No adapter approval is pending for this plan. Do not treat an extension's unsupported terminal UI as a failed app acceptance check. Remaining work includes the upstream Pi core RPC audit, native phone shell entry and the [Mac interface acceptance checks](plans/2026-10-18_pi-like-mac-interface-plan.md). The Mac presentation target does not require individual terminal extension interfaces.
