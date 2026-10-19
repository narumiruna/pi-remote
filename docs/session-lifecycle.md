<a id="managed-core-session-lifecycle"></a>

# Managed upstream Pi core session lifecycle

## Behavior

Native session changes now use upstream Pi core RPC when the working directory can remain unchanged:

- Creating another session in the current directory calls `new_session`.
- **New in current directory** in Session controls offers explicit confirmation and optional parent tracking. On iPhone, the Space's **New session options** opens the same flow and explains **Current folder · Optional parent link**. The separate **New session** route reviews or changes the folder before Start Pi Here. The parent is the current managed session, never a phone-supplied path. Parent tracking records ancestry; it does not copy messages.
- Resuming a persisted managed session or importing reviewed JSONL in the same directory calls `switch_session`.
- Changing directories replaces the child process. Upstream Pi core can change its session cwd without changing the OS process cwd; process replacement keeps both directories consistent.
- Reopening an allocated but unwritten session also replaces the process explicitly, using its saved ID. It does not invent a conversation or resend a prompt.

All operations require idle state and validated directory/file identities. Native IDs remain opaque. The host serializes mutations and records request outcomes. Repeating an acknowledged New, fork or clone request cannot create another session. A stale new request cannot target another selected context.

<a id="core-hooks-and-ui-events"></a>

## Upstream Pi core hooks and UI events

Same-child operations preserve upstream Pi core cancellation hooks. A cancelled change retains the catalog, selected session and history. Standard hook dialogs remain answerable. Stop during an unresolved replacement stops the owned child and fences late replies; it does not claim that an uncertain replacement completed.

Upstream Pi core UI records have no session ID. During replacement, the host retains bounded notification, title, status, widget and editor updates and applies them to the resolved context, including the retained context after cancellation. These are transition-generated updates, not proof of their originating session. The buffer retains at most 64 records and 512 KiB of encoded data. Oversized editor text is rejected, not silently truncated. Overflow has an explicit warning.

The event subscription remains active so queued UI records are not discarded at the response boundary. Authoritative name read-back prevents delayed outgoing name events from changing the wrong catalog title. Session, child and generation checks fence asynchronous results. Standard editor updates still require consent before replacing a nonempty phone draft.

Cross-directory process activation has startup/shutdown behavior, not same-child hook equivalence. No extension-specific adapter or package is required.

## Branches and configuration

Fork eligibility is rechecked through `get_fork_messages`. Successful fork/clone adoption refreshes the actual name, model, thinking levels, commands, runtime settings and history. Retry acknowledgement remains process-scoped: same-child changes retain it; process replacement resets it to unknown.

A successful fork can return more text than the native draft budget. The host always adopts the completed branch. It offers the complete draft only when it fits within 256 KiB. Otherwise it leaves no partial draft and reports that the fork succeeded but the text exceeded the limit. The source remains unchanged. The host does not report failure or repeat the fork.

## Empty sessions and ancestry

Pi 1.3.0 does not create a file for setup-only sessions. Some custom context can also remain in memory until a user or assistant conversation causes persistence. An in-memory message array alone is not evidence that a file must exist. A confirmed handled metadata-only prompt restores the previous empty-file expectation only when the session is idle and unchanged and no persisted file exists. Unknown accepted outcomes retain their recovery guard; nothing is replayed.

The catalog retains confirmed parent tracking for an empty child. On explicit reopen, **after the previous child has stopped**, the host can create its missing empty header with the recorded session ID, cwd, parent and catalog update timestamp. Creation uses exclusive access and mode `0600`. It never replaces an existing file, reconstructs populated history or edits a leaf while Pi owns the file.

Observed persisted history and accepted prompts retain the missing-history guard. A missing populated file fails instead of becoming an empty replacement. Custom messages without an agent run also preserve this guard when their file was actually persisted. Setup-only or otherwise unpersisted custom state is not claimed as saved conversation history.

## Verified checkpoint

The current acceptance run passes 135 root tests and 50 shared tests, normally and with Thread Sanitizer. Lifecycle cases cover typed actions, same PID, cancellation, directory replacement, file identity, unknown outcomes, pending-hook Stop/shutdown races, full catalogs, oversized fork text and empty-child ancestry across a host restart.

`NativeSessionLifecycleCheck` passes against installed Pi 1.3.0 normally and with Thread Sanitizer, without network inference or prompt replay. It verifies:

- Upstream Pi core new/switch operations in one PID and new/resume cancellation.
- Host new/import/resume/fork/clone and four cancelled hooks.
- Incoming and cancelled-hook prefill, status, widget, notification and title updates.
- Parent metadata without history copying, including explicit empty reopen.
- A real 257 KiB imported fork, one dispatch, retained branch and explicit draft warning.
- Empty reopen and cross-directory activation in new PIDs; all three host-owned PIDs stop.
- Zero provider calls, tokens or cost, unchanged real settings and removed private fixtures.

The real provider exercise also passes image input, streaming, clone/fork, explicit restoration, queues, Stop and custom-instruction compaction. The final compact-interface suite is recorded separately when complete.

Evidence:

- `/tmp/pi-remote-acceptance-{root,root-tsan,shared,shared-tsan}.log`
- `/tmp/pi-remote-acceptance-lifecycle-verified.log`
- `/tmp/pi-remote-acceptance-NativeSessionLifecycleCheck-tsan.log`
- `/tmp/pi-remote-acceptance-provider.log`

Two regressions were found during integration. Empty-child ancestry was lost on reopen; a direct installed-Pi assertion failed before header retention was added and passed afterward. A provider-backed fork before the first prompt had no persisted file but was incorrectly marked populated from in-memory context; explicit restoration failed until presence tracking used the actual file. Neither failure caused automatic prompt replay.
