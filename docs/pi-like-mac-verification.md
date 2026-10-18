# Pi-like Mac implementation and verification

## Result

The Mac app now has a SwiftUI/AppKit coding surface based on installed Pi 1.3.0: a compact dark transcript, ruled native editor, completion list, model/thinking controls and directory/usage footer. Workspace and inspector functions remain secondary. Pi still owns execution through JSONL RPC.

**The redesign plan is not complete.** Source inspection, isolated runtime checks and native fixtures do not establish a match to the user's live terminal. The user supplied normal startup and extension-widget/footer reference captures after rejecting the first native layout. The follow-up corrects that structure. A complete normal-launch coding/keyboard review, other terminal states and final user acceptance remain open. The [tracked plan](plans/2026-10-18_pi-like-mac-interface-plan.md) is retained. No release, signing or full terminal-extension compatibility is claimed.

## Implemented behavior

- The selected source reference is Pi 1.3.0, built-in `dark`, `regular` mode, thinking initially collapsed. See [reference evidence](pi-like-mac-reference.md).
- The default coding surface is one column with compact monospaced text. Its startup logo/help and resource sections remain above the conversation after the first prompt. Skills and prompts come from `get_commands`; Context explicitly states that loaded paths are not exposed by RPC. Startup, output, editor and footer share one scroll flow. The empty editor is 34 points and grows to 180; suggestions follow the bottom rule. There is no fixed-height blank band or viewport-sized gap before input. The sidebar starts hidden and remembers explicit changes in local preferences. The optional inspector retains Files, Session and Activity. Compact Files/Commands toolbar buttons retain direct access; Actions also retains settings, devices, import and workspace management.
- User messages, Markdown, thinking, image references, error details and tool output remain native. Tool panels distinguish pending/success/error. Collapsed bash tools show a bounded tail; other generic tools show a bounded preview. Read output stays collapsed until requested; errors retain an excerpt. This is not a port of custom tool renderers.
- Enter sends a prompt while idle or steering while busy. Option-Enter sends follow-up while busy and a prompt while idle. Shift-Enter, Control-Enter and Control-J insert a newline. IME composition owns these keys before application shortcuts.
- Return/Tab with suggestions completes only. Up/Down first navigates suggestions, then local prompt history at the visual text boundaries. History restores the unsent draft. Selection and Command-based native editing remain AppKit behavior.
- Control-L opens model selection; Control-P cycles forward. Reverse cycling opens the selector because upstream RPC has no reverse-cycle operation. Shift-Tab cycles thinking, Control-O expands tools and Control-T shows thinking. Shortcuts apply only while the editor owns focus.
- Slash suggestions combine native controls and discovered Pi commands. Known unsupported terminal workflows produce an error and retain the draft rather than becoming a model prompt. Native commands open reviewed controls; inline arguments are not accepted by those controls. Successful opening clears only the submitted command in the same context. Rejection or a changed draft/context does not clear text.
- Path completion reads bounded directory pages through the existing scoped directory API. It inserts paths only, not file contents. Files still previews and explicitly attaches text. Results bind exact text, caret, revision and session context. Names with quotes, backslashes or control characters are omitted. Mid-token path completion is not offered. Shell drafts disable path completion to avoid interpreting file names as executable syntax.
- Native standard extension select/confirm/input/editor dialogs retain scoped responses, explicit decisions and cancellation. Unknown methods offer cancellation only. Existing host timeout and stale-answer checks remain authoritative. Session-bound sheets close instead of silently changing targets when the loaded context changes.
- Loaded conversations open at the latest content, including after return from Overview. User scrolling pauses live following. Following resumes when the gesture ends near the bottom or Latest is selected; layout changes alone do not resume it.
- The footer uses authoritative session/model/thinking state and idle `get_session_stats` reads. Missing values stay unavailable, not zero. Busy values are identified as last-settled usage. Background read failures do not become foreground action faults. Loaded-resource inventory, git branch and subscription state are not invented.

## Shell execution and queued-input recovery

`!command` and `!!command` open a session-bound execution review. `!!` sets `excludeFromContext`; Pi still stores the shell entry in history. Commands run through upstream `bash`, not an app-owned shell or PTY. Confirmation cannot undo changes or prevent arbitrary effects of a reviewed command.

- Commands are limited to 16 KiB; streamed/final shell output is limited to 64 KiB. Saved transcript rows use the existing 16 KiB per-message/256 KiB aggregate display limits and retain truncation notices. The per-row budget reserves the final exit/cancellation/context-exclusion marker before clipping output. Aggregate clipping omits a shell row instead of removing its outcome. Invalid exit codes stay unavailable, not successful.
- Shell admission returns acknowledgement, not completion. `HostSnapshot.bash` carries running/cancelling/final/unknown state. Updates require the matching wire ID. Ordinary agent settlement cannot settle a running shell or clear its persisted interruption marker.
- Cancellation repeats after early acknowledgement because upstream can delay execution admission in `user_bash` hooks. Requests have one-second attempt limits and a five-second cancellation deadline. New work waits for the cancellation barrier. Unconfirmed cancellation becomes uncertain, not successful.
- A failed shell RPC response can follow side effects or a persistence failure. It stays an unknown outcome. Stop rechecks state after suspension and shuts down an uncertain child. Final shell requests have a 300-second deadline; expiry does not trigger redispatch.
- Explicit wire IDs cannot be reused during a child lifetime. Their bounded history admits at most 4,096 explicit IDs, then rejects further explicit IDs until an explicit runtime restart. This prevents late responses from completing a later request.
- Known-final shells schedule fenced history refresh. Saved `bashExecution` entries preserve command, context exclusion, cancellation, exit status and output in native shell rows. Two sequential shells and seeded-session resume are checked against installed Pi.
- The isolated runtime does not persist a shell-only empty session. The persistence test explicitly imports a synthetic user-message seed; it does not send that seed to a provider. Do not infer shell-only persistence from that test.

Option-Up uses the destructive `clear_queue` result without aborting. Escape, after dismissing completion, recovers queued input and stops work. Stop recovery has priority over pending compaction or extension-command RPCs; recovery without Stop retains ordinary admission. The explicit Stop button retains queue-clearing behavior.

Recovery returns at most 256 KiB directly to the initiating request. It never broadcasts prompt text in snapshots, writes it to routine diagnostics or resends it. A nonempty draft requires replacement consent. Steering text precedes follow-up text, separated by blank lines; mixed arrival order is not reconstructed. Lost, malformed or oversized responses are explicit. If recovery succeeds but Stop fails, recovered text is still returned and uncertain work is stopped or marked interrupted for explicit reopen. Other controllers do not receive a draft offer.

## Verification evidence

Checks use private fixture storage, fake providers/processes or isolated installed Pi. They do not change real credentials, pairing records or personal sessions. Native captures contain synthetic content and are not committed as binary files.

Verified during implementation:

- Unsigned Mac build passed: `/tmp/pi-like-build.log`.
- Shared package: 52 tests passed: `/tmp/pi-like-core-tests.log`.
- Initial PR root checkpoint: 188 test functions passed: `/tmp/pi-like-root-final.log`. This includes recovery after Stop failure/child exit, persisted interruption and non-reserving footer-read regression checks.
- Shell/RPC/lifecycle focused batch: 41 tests passed: `/tmp/pi-shell-final-focused.log`.
- Initial PR sequential Thread Sanitizer checks passed: 19 shell/recovery/footer/correlation functions (`/tmp/pi-like-final-tsan-focused.log`), 28 PiRPC functions (`/tmp/pi-like-final-tsan-rpc.log`), 27 related lifecycle/recovery functions (`/tmp/pi-like-final-tsan-recovery.log`) and 52 shared functions (`/tmp/pi-like-final-core-tsan.log`). These selections overlap; do not sum them as distinct tests. No race diagnostics were reported.
- Final opt-in installed Pi execution, streaming, cancellation, context flags, two shell results and seeded-session resume passed: `/tmp/pi-like-installed-final.log`.
- Initial PR Mac scheme: all 114 tests passed with zero failures/skips, including 24 editor helper/AppKit tests, seven new surface/selector tests and migrated session/management checks. Log: `/tmp/pi-like-all-mac-final.log`; summary: `/tmp/pi-like-all-mac-final-summary.json`. The editor checks cover composition, undo, draft retention, completion precedence, stale text/caret/session results and bounded height.
- Unsigned iOS simulator build passed: `/tmp/pi-like-ios-build.log`.
- Three iPhone 17 Pro, iOS 26.5 product smoke checks passed with no failures/skips: draft retention, old-epoch action rejection and conversation state rendering. Log: `/tmp/pi-like-phone-smoke.log`.
- Native fixture captures are written to `/tmp/pi-like-mac-captures/` by `PiPresentationTests`. They cover startup, active output at 900/1300 points, retry/compaction/interruption/unavailability, root layout, model/thinking selectors and standard dialogs. These are hosted views, not a normally launched product session.

### Screenshot and extension follow-up

The first native layout did not meet the supplied terminal reference. It removed startup information after the first message, expanded the transcript viewport, used a fixed 100-point input, and displayed every extension notice above it. The correction uses content flow and measured input height, with a native Pi logo and resource sections. `PiStartupView.swift` does not read instructions or invent loaded context paths.

Static [extension research](pi-extension-native-display.md) confirms that the installed Progress package emits standard RPC widget lines, while Starship installs its segmented footer only in TUI mode. Native code now uses generic optional `ExtensionDisplayState` data: keyed statuses, placed widgets and severity-bearing notices. Legacy notice strings remain unchanged for older clients. ANSI/control sequences are removed from typed native text, not interpreted as terminal commands. No package-specific adapter or custom component transport was added.

- Root: 193 test functions pass (`/tmp/pi-reference-root-final.log`).
- Shared: 54 tests pass normally and with Thread Sanitizer (`/tmp/pi-reference-core-final.log`, `/tmp/pi-reference-core-tsan.log`).
- Focused metadata sanitizer checks pass: five host and two shared tests (`/tmp/pi-reference-metadata-tsan.log`). The log includes repeated host selections; do not sum repetitions as unique coverage.
- Final integrated Mac run: 127 tests pass with zero failures/skips (`/tmp/pi-reference-mac-all.log`, `/tmp/pi-reference-mac-all-summary.json`). The compact editor has 33 tests, including measured growth/shrink, IME/undo, focus guards, completion below the rule and outer-scroll stability. New fixtures check startup-to-editor geometry, footer placement, generic widget slots and visible error severity. The final unsigned Mac build also passes (`/tmp/pi-reference-mac-build.log`).
- All 142 local links in nine changed Markdown files and `git diff --check` pass.
- Reference captures use synthetic resource and task names, not hardcoded personal configuration. Local captures: `/tmp/pi-remote-mac-ux-captures/terminal-reference-startup.png` and `terminal-reference-extension-slots.png`.
- Initial follow-up runs exposed obsolete popup-scroll selection, inaccessible plain footer controls and undo-sizing timing/cache errors. The tests now select the actual suggestion viewport; footer controls are native buttons; sizing invalidates before binding updates and permits a bounded native render cycle after undo. Close-dialog checks wait for actual presentation after large draft edits. Earlier failing runs are not treated as passing evidence.
- The iPhone uses the unchanged legacy notice surface. The simulator build and three product smoke checks pass after the optional snapshot field change (`/tmp/pi-reference-phone-smoke.log`, `/tmp/pi-reference-phone-summary.json`).

### Failures and limits

- An exploratory Mac build first failed while the queue-recovery API was still being integrated, then failed on an error-variable shadow in the new dialog. Both compile errors were corrected; the Mac build subsequently passed.
- The first full Mac run exposed superseded workspace/header/composer expectations and a real background-statistics fault. Tests are migrated to the new surface, not skipped. Footer reads no longer set global action errors. The final integrated run passes all 114 tests without skips.
- Native Actions-menu test attempts blocked or produced inconsistent sheet attachment in hosted fixtures. Those failed/timed-out runs are not passing evidence. Compact Files/Commands toolbar controls retain direct secondary access; tests exercise those real buttons and their inspector/sheet destinations. The unreliable menu-tracking helper was removed. Actual Actions-menu item selection remains part of the attended review, not an automated pass.
- A broader 69-test sanitizer batch failed with 47 issues beginning at fixture startup/session creation (`/tmp/pi-shell-final-tsan.log`). This run did not pass. Smaller focused sanitizer batches passed; do not describe them as a passing broad run or assume a specific cause without evidence.
- Recovery hardening initially revealed that the shell fixture lacked persisted headers/resume argument handling. The fixture now models these inputs. Stop-rejection and child-exit recovery both pass, including explicit reopen; an unrelated agent-settlement event cannot clear active-shell interruption. A footer-read race with Close was also found and fixed: local footer reads no longer reserve foreground admission, and crossed results are discarded without publishing action faults. Focused log: `/tmp/pi-like-final-concurrency.log`; final root and sanitizer checks include these regressions.
- An existing normally launched Mac app instance was left unchanged. No live terminal inspection, product coding interaction or full VoiceOver review was performed. Hosted views and unsigned builds do not close these gates.

### Pull request review checkpoint

The [PR #8 review ledger](reviews/2026-10-18_pr-8-review.md) records each submitted item and its disposition. The review fixes cover priority Escape recovery during pending RPCs, native-command draft acknowledgement, bounded saved-shell outcomes, and scroll-follow resume. A 60-message hosted regression confirms that the existing initial-scroll task opens loaded conversations at the end, including after Overview return.

- Root: 201 tests pass (`/tmp/pi-pr8-review/root-final.log`).
- Mac: 141 tests pass with no failures or skips (`/tmp/pi-pr8-review/mac-all-final.log`).
- Core: 61 tests pass normally and with Thread Sanitizer (`/tmp/pi-remote-r4-core.log`, `/tmp/pi-pr8-review/core-tsan.log`).
- Focused host recovery/shell/correlation: 25 tests pass with Thread Sanitizer (`/tmp/pi-pr8-review/host-tsan.log`). Selections overlap other counts. No race diagnostics are reported.
- Three iPhone 17 Pro iOS 26.5 smoke tests pass (`/tmp/pi-pr8-review/phone-smoke.log`).

These checks use controlled fixtures and private test storage. They do not execute installed extensions or a provider, or establish normal-launch/user visual acceptance. The ledger retains failed reproduction and fixture attempts separately from passing final checks.

### Repeat the checks

Commands are grounded in `project.yml`, root `Package.swift` and the shared package configuration. Use focused selections during development.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate --spec project.yml
swift test --no-parallel
swift test --package-path Packages/PiRemoteCore
swift test --scratch-path /tmp/pi-remote-native-tsan --sanitize=thread --no-parallel \
  --filter 'bash|recoverQueue|agentSettlement|explicitID|footerRead'
swift test --scratch-path /tmp/pi-remote-native-tsan --sanitize=thread --no-parallel \
  --filter PiRPCTests
swift test --scratch-path /tmp/pi-remote-native-tsan --sanitize=thread --no-parallel \
  --filter 'promptFailuresPreserveRecovery|unexpectedEmptyChildExit|emptyChildAncestry|hostEventOverflow|explicitQueues|workingSessionCannotSwitch|pendingLifecycleHook|lifecycleUnknownOutcome|closeConfirmation|quitConfirmation'
swift test --package-path Packages/PiRemoteCore --sanitize=thread --no-parallel
PI_REMOTE_SHELL_CHECK_EXECUTABLE=/Users/narumi/.bun/bin/pi \
  swift test --no-parallel --filter bashInstalledPiIsolated
xcodebuild -quiet -project PiRemote.xcodeproj -scheme PiRemoteMac \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/pi-remote-pi-like-mac CODE_SIGNING_ALLOWED=NO build
xcodebuild -quiet -project PiRemote.xcodeproj -scheme PiRemoteMac \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/pi-remote-pi-like-mac CODE_SIGNING_ALLOWED=NO test
git diff --check
```

The opt-in installed shell check runs only fixed synthetic commands in private temporary storage with an empty home, disabled extensions/resources/tools and offline Pi startup. It does not send an inference prompt. Without the opt-in environment value, the test returns without exercising installed Pi; a normal root pass alone does not prove the installed-runtime check ran.

## Remaining acceptance and differences

Still required before declaring the redesign plan complete:

1. Extend the user-supplied startup and extension crop references with completion, tools, queues, selectors and errors as needed. The supplied references establish the requested structure, not acceptance of the corrected native app.
2. Run the built Mac app normally and review session creation/resume, real keyboard/IME, scrolling, selectors, Actions-menu item selection, shell review/cancellation and error recovery. Do not replace or stop existing personal work to obtain evidence.
3. Compare paired terminal/Mac captures and obtain user acceptance for the resemblance and retained differences below.

Retained differences needing that review:

- The native view uses one scrolling content flow; it does not implement terminal scrollback storage or ANSI rendering.
- Return on slash completion completes only; terminal Pi completes and submits. Native shell, copy, export and settings retain explicit review/consent.
- Path completion inserts paths only. No shell path completion or automatic `@file` content expansion is claimed.
- Native editor padding, a 13-point font and dark canvas are design choices, not sampled terminal dimensions. Syntax coloring, Mermaid rendering, specialized tool renderers and arbitrary terminal extension components are not reproduced fully.
- Tree inspection is read-only with explicit fork/clone, not in-place terminal navigation. Double-Escape tree, external terminal editor, terminal exit/suspend key sequences and terminal-only auth/trust/reload management are not implemented.
- Native slash controls reject inline arguments and open pickers. Reverse model cycling opens the selector. Some controls retain native forms rather than exact terminal picker geometry.
- Queue recovery is a local unsent offer, not automatic replacement of an existing draft. Recovery text is not durable across a lost response or host restart.
- Context paths, git branch, subscription and routed-model details remain unavailable in the native startup/footer. Skills and prompt names use actual RPC discovery. Usage is read while idle rather than live token accounting.
- Only one managed Pi runtime executes at a time. The app cannot attach to a terminal-owned runtime. iPhone shell-entry UI is not part of this Mac redesign.
