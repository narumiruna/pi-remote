# Core event and queue verification

## Result

Core queue, transcript, name and standard UI handling have additional local checks against Pi 1.3.0. Lifecycle and inspection also pass their linked checks. Shell controls remain open.

The initial event checkpoint passed 103 root tests normally and with Thread Sanitizer. The later [acceptance checkpoint](core-rpc-acceptance.md) passes 135 root tests, including write admission, custom previews and lifecycle regressions. A later shared checkpoint passes all 50 tests normally and with Thread Sanitizer, including explicit settlement boundaries, opaque custom-entry handling and branch-summary retry phases. Native session-inspection integration has separate checks in the acceptance record. Evidence:

- `/tmp/pi-remote-core-semantics-root.log`
- `/tmp/pi-remote-parent-root-tsan.log`
- `/tmp/pi-remote-parent-shared-normal.log`
- `/tmp/pi-remote-parent-shared-tsan.log`

## Pushed foundation checkpoint

Commits `fce396a` and `0a85994` contain the event reducer, bounded subscription replacement and pure inspection DTO/mapper changes. An exact `git archive` snapshot of `0a85994` passes 98 root tests and 49 shared tests, both normally and with Thread Sanitizer. This verifies the pushed subset independently of the larger, still-changing host/app integration.

Evidence: `/tmp/pi-remote-foundation-{root,root-tsan,shared,shared-tsan}.log`. Snapshot: `/tmp/pi-remote-foundation-ADMfO3`, with its exact commit in `verified-revision`.

## Queue delivery

Explicit steering and follow-up actions use `steer` and `follow_up`, not `prompt` with a streaming option. This prevents a queued extension command from executing immediately. It also prevents a queue submission from starting a new run if the previous run settles before dispatch.

Discovered extension commands remain available during active work through the standard `prompt` command path. Templates and skills remain idle-only. No extension names or custom protocol formats are required.

`queue_update` replaces the pending count from both complete arrays. Queue text is not copied into the snapshot. A nonempty queue keeps the session busy even after settlement. Stop clears the queue before aborting, then confirms idle. The host regression checks command rejection on queue paths, immediate extension dialogs, a settlement race and exactly one actual prompt dispatch.

## Transcript and compaction

- Completed assistant messages replace streamed blocks. Tool-call blocks show names and serialized arguments within the display budget.
- A completed tool message replaces the execution row, with the same row identity and final image references. It does not create a second provisional row.
- Automatic compaction and retries do not declare an active run idle before `agent_settled`.
- A failed or cancelled standalone manual compaction returns to idle. Failure text is bounded; cancellation does not invent an error.
- Successful compaction schedules an authoritative history refresh after settlement. The refresh reserves the mutation slot and checks the child generation, session and run revision before applying its result. Completed custom messages also advance the revision, even without an agent run. A superseded refresh can make one additional read, not an unlimited retry loop. Regressions preserve the custom message exactly once and bound refresh reads to two.
- Summarization retry events restore the previous compaction phase between attempts. Final assistant retry errors use `finalError`.

Pure reducer cases cover these rules and UTF-8, block, message and aggregate display limits. A host regression covers failed manual compaction and successful automatic history replacement. Real provider-backed manual compaction has separate [workflow evidence](workflow-verification.md).

## Bounded stdin writes

The process transport now admits at most 64 queued/in-progress writes and 8 MiB of encoded write data, independently of pending responses. Cancellation or timeout ends response tracking but does not release queued-byte admission until the writer consumes or discards the item. Cancelled queued requests are not sent later. This prevents a blocked stdin pipe and repeated cancellation from creating an unlimited queue of retained closures.

A blocked-write shutdown regression exposed `SIGPIPE` when the child closed stdin. The transport now sets `F_SETNOSIGPIPE` on that descriptor so a broken pipe reports an unknown outcome rather than terminating the companion. It does not change the process-wide signal policy.

Backpressure regressions verify both bounds, unknown outcomes, no delayed replay and bounded shutdown. They pass normally and with Thread Sanitizer in the 135-test [acceptance checkpoint](core-rpc-acceptance.md).

## Event-stream gaps

The process reader continues draining stdout after a bounded event-buffer overflow. `resumeEvents()` creates a fresh subscription with the original capacity; it does not replay events or restart Pi. Replacing a subscription terminates the previous subscription explicitly.

The host subscribes before reading authoritative state and history again. It keeps ownership of the child and reports uncertain work. Core RPC cannot replay a lost dialog or identify every outstanding retry wait. The app therefore keeps the session in recovery and rejects new mutations except Stop. It never approves a lost dialog or resends a prompt.

Stop shuts down the uncertain child and retains the saved session for explicit reopening. Failed shutdown retains control for another Stop attempt. Repeated stream gaps are bounded to three recovery attempts per child before controlled shutdown.

The host regression forces a capacity-one overflow, checks that the child remains alive and queryable, rejects a model mutation, stops the exact child and reopens the saved session without replaying work. Transport tests also cover concurrent resubscription, original buffer capacity and rejection after shutdown.

## Names and standard UI state

Session renaming reads back Pi's normalized name. An omitted name in `session_info_changed` clears the custom title and restores the directory-based title. Thinking changes arrive through `thinking_level_changed` without requiring a settings refresh.

Status and widget keys use separate namespaces. Replacing or clearing one does not remove the other, even with the same raw key. Keys and notice content are bounded. Notifications and titles appear as native notices; terminal title behavior, severity styling and widget placement are not reproduced.

`NativeUIStateCheck` uses installed Pi and a private test-only extension to verify normalized names, clearing, thinking events, independent status/widget replacement and clearing, notification/title notices and Stop cancellation of an input dialog. It checks exactly ten command invocations and zero user messages, provider calls, tokens or cost. Real settings remain unchanged; the child and private directory are removed.

Parent normal and sanitizer reruns: `/tmp/pi-remote-parent-state.log` and `/tmp/pi-remote-parent-state-tsan.log`. Worker normal and sanitizer runs: `/tmp/pi-remote-worker-ui-state-{normal,tsan}.log`. These fixtures are tests, not product dependencies or shipped adapters.

A focused host regression also checks `extension_error` mapping without exposing the supplied path or error text. An unknown UI method creates no dialog and sends no automatic response. Evidence: `/tmp/pi-remote-parent-extension-events.log`.

## Active retry cancellation

`NativeRetryCheck` supplies a private synthetic provider that reports an overloaded error without network access. The check observes a real Pi retry wait, cancels it before the next attempt and observes beyond the original retry deadline. A second explicit prompt with retry disabled does not schedule a retry.

The check verifies exactly two synthetic provider attempts and two user messages, with zero tokens or cost. Real settings remain unchanged; the child and private directory are removed. This proves active retry behavior, unlike an idle cancellation acknowledgement alone.

Parent normal and sanitizer reruns: `/tmp/pi-remote-parent-retry.log` and `/tmp/pi-remote-parent-retry-tsan.log`. Worker normal and sanitizer runs: `/tmp/pi-remote-worker-retry-{normal,tsan}.log`.

## Commands

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test --no-parallel --scratch-path /tmp/pi-remote-core-semantics-root
swift test --no-parallel --sanitize=thread --scratch-path /tmp/pi-remote-core-semantics-tsan
swift test --package-path Packages/PiRemoteCore
swift run NativeRetryCheck "$(command -v pi)"
swift run NativeUIStateCheck "$(command -v pi)"
```

These are local development checks, not hardware, off-site or release-support claims. Native session inspection, core session switching and final app regressions also pass their separate checks in the [acceptance record](core-rpc-acceptance.md).

During parallel integration, one build saw a newly declared target before its source file was created. Another rejected a source file changed during compilation. Neither attempt executed its intended checks. Final acceptance must use a stable source tree; these attempts are not passing evidence.
