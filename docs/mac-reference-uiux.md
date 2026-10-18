# Mac reference UI/UX refinements

## Result and scope

Pi mode in Pi Remote for Mac keeps the native Pi-like startup, transcript, editor and footer in continuous placement. Desktop later adds an independent history viewport and persistent composer; see [structure corrections](mac-interface-structure.md). This earlier refinement adds compact tool headings, clearer execution states, native code-block controls, stable disclosure and grouped model selection. It does not add a dashboard, web renderer, runtime or extension adapter.

The base is `main` at `ec446d0`. The user requested improvements from the six local desktop/web references after a read-only source and image comparison. The references inform interaction details, not a replacement for the terminal Pi layout.

## Reference choices

The source checkouts are under `/Users/narumi/src/ui-references`. These are inspected commits, not supported-version or release claims. Bundled images include older interfaces; no reference application was launched.

| Reference | Inspected commit | Pattern used or retained |
| --- | --- | --- |
| PI-Desktop | `e219a3e4c` | Compact action/target/outcome headings and explicit disclosure choices; see `apps/desktop/src/features/chat/transcript/TurnProcess.tsx` |
| Jan | `a86d87ebc` | Tool-specific summaries and secondary controls, without replacing Pi's content flow; see `web-app/src/containers/message/ToolCallCard.tsx` |
| Cherry Studio | `d01b83d2cc` | Preserve the tool heading's reading position during disclosure; see `src/renderer/components/chat/messages/tools/shared/ToolDisclosure.tsx` |
| LibreChat | `e081b566a` | Distinct running, completed, failed and interrupted states; see `client/src/utils/toolCallPhase.ts` |
| Open WebUI | `91ea4e342` | Keep inspectors explicitly opened and retain visible queue/recovery controls; see `src/lib/components/chat/ChatControls.svelte` |
| AnythingLLM | `d7d68e75` | Keep details behind compact activity rather than large output panels; see `frontend/src/components/WorkspaceChat/ChatContainer/ChatHistory/StatusResponse/index.jsx` |

No source code or assets from these products were copied into the app. No reference dependencies, providers or services were installed or run.

## Implemented behavior

### Tool headings and outcomes

- Native tool headings show an action, a bounded path/command when reported, and a text status. Icons and color supplement the words; they do not replace them.
- Known read results stay compact. Bash previews retain the last five lines. Other tools use a small bounded preview. Failed output remains visible without expansion. Edit output remains literal text, not an inferred file diff.
- Opening a row reveals its exact retained display text. Images and truncation warnings remain in the transcript. Individual expansion choices survive streaming and final updates; an explicit global Control-O change can reset them.
- New optional `TranscriptMessage.tool` metadata retains the tool name, target and outcome. Live start arguments supply targets. Saved history matches preceding assistant tool calls by exact `toolCallId`; custom or malformed arguments do not become guessed paths.
- Names are limited to 128 UTF-8 bytes and targets to 1,024. Metadata consumes the existing 16 KiB message and 256 KiB aggregate display budgets. The message count remains 100. No filesystem access is added to obtain a target.
- A final `tool_execution_end.isError` flag includes upstream hook overrides. It takes priority over a result object's own flag. Final `message_end` content and status replace provisional state. Partial errors cannot permanently turn a later successful final result into failure.
- Settlement without a final result marks an unfinished tool interrupted. If the child stops before the reducer receives settlement, the Mac view uses the interrupted/unavailable phase rather than leaving the heading Running. A recovering runtime shows Unconfirmed. Known final results keep their outcome.
- Older snapshots without metadata remain readable. Legacy output without a confirmed outcome uses the neutral label Output, not an invented success.

### Reading position

Tool disclosure captures the heading's viewport position before expansion or collapse, then restores that anchor after layout. It also pauses live following. New output must not pull the reader away. Latest restores following; a user scroll that ends near the bottom also resumes it. Layout changes alone do not resume it. A new user scroll cancels a pending disclosure anchor, and context changes discard it.

### Code blocks

- Code blocks have a language label, selectable text, horizontal/vertical scrolling and an explicit native Copy code button. Short code aligns to the leading edge; long blocks have a bounded viewport.
- Copy uses the existing current-Mac-only clipboard policy. It runs only after an explicit action. Success and failure have visible text. Raw error details are not displayed or logged.
- Copy preserves the **displayed code** supplied by the existing Foundation Markdown parser. It is not a byte-for-byte export of the original fenced Markdown: parsing can normalize line endings or Markdown indentation. A native integration test verifies this contract without changing the real clipboard.
- A small display-only lexer colors keywords, strings, comments and numbers for Swift, JavaScript/TypeScript, Python and JSON. It preserves input text; it does not validate, interpret or execute it. It has no dependency or configurable grammar system.
- Unknown languages, shell code, Swift raw-string syntax, input over 32 KiB, or more than 2,048 token runs use plain text. JavaScript template strings remain one string run; interpolation is not parsed. No full syntax-parser, math, Mermaid or artifact-execution parity is claimed.

### Model and thinking selection

Models are grouped by the provider order reported by Pi. Search matches provider, model ID and display name. The current model or thinking level has an explicit Current label and initial selection. Up/Down in Search moves through the filtered choices; Return or Apply is explicit. Presentation, search and navigation do not dispatch requests.

Busy or unavailable selection remains disabled. Requests and their completion are bound to the displayed context and mode. A stale completion cannot close another picker. Failed application stays visible for correction. No favorites, extra provider setup or model-comparison controls were added.

## Validation

All checks use private fixture storage, fake or injected requests and synthetic output. No real clipboard write, installed extension execution, provider request or normally launched product session is used. Commands use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and the existing project/package configuration.

| Check | Verified result | Local log |
| --- | --- | --- |
| Root, `swift test --no-parallel` | 201 passed in the final sequential run | `/tmp/pi-mac-reference-uiux/root-sequential-final.log` |
| Core, normal | 76 passed | `/tmp/pi-mac-reference-uiux/core-final.log` |
| Core, Thread Sanitizer, no parallel tests | 76 passed, no race diagnostics | `/tmp/pi-mac-reference-uiux/core-tsan-final.log` |
| Unsigned Mac scheme, no parallel tests | 181 passed, no failures or skips | `/tmp/pi-mac-reference-uiux/mac-all-final.log` |
| iPhone 17 Pro iOS 26.5 smoke | Three passed: drafts, old-epoch actions, conversation rendering | `/tmp/pi-mac-reference-uiux/phone-smoke-final.log` |

The final verification checked unchanged source/project/manifest hashes. The installed-runtime opt-in was unset; a root pass does not prove that check executed. Focused selections overlap the complete checks and must not be summed as distinct tests. Platform logs include existing AppKit transaction/SceneStorage, AppIntents extraction and simulator launch warnings; they are not evidence of a full accessibility or normal-launch pass.

Synthetic 900/1300-point captures are under `/tmp/pi-like-mac-captures/reference-refinements-{900,1300}.png`. Visual inspection confirms leading-aligned code, compact outcomes and visible failure details. Native tests measure disclosure geometry during streaming; screenshots alone do not prove that behavior. No image or binary is committed.

Focused native checks cover lexical limits, injected copy/retry feedback, actual Markdown-to-copy routing, tool previews and disclosure state, viewport stability during streaming, runtime interruption, grouped selection and native search-key routing. Core checks cover live/history correlation, authoritative final outcomes, older readers and UTF-8/aggregate budgets. A focused iPhone smoke check covers shared metadata compatibility without changing the phone layout.

### Failures found during implementation

- Plain SwiftUI controls did not expose usable identifiers in the hosted hierarchy. Tool headings and Copy now use native buttons with explicit accessibility data. Tests invoke real native controls and assert visible results; they do not substitute internal action calls.
- Search Down initially left the model selection unchanged under normal window key dispatch. Explicit Search key handling fixes it; the native test passes.
- Capture review found short code centered in a wide scroll area. Leading alignment and a native viewport geometry regression correct it.
- The new metadata initially kept partial error flags after an authoritative successful final result. A focused test reproduced five failed expectations. The reducer now follows the upstream final flag and final message; unfinished partial errors remain interrupted, not final failures.
- The initial root build did not find the new source type. Refreshing SwiftPM's manifest timestamps rebuilt its graph and the next run passed; no manifest content or dependency changed.
- A compiler exclusivity error in the final-outcome assignment initially prevented tests from starting. Using a local error value before assigning the message fixes it. Those failed build logs remain in `/tmp/pi-mac-reference-uiux/failed-exclusivity/`.
- One concurrent verification run failed `bashStopAndCloseConfirmation` with four expectations; all other root functions passed. Core, Mac and phone checks in that batch passed. Five isolated shell-close reruns and the full final sequential run of 201 tests passed with unchanged source. The cause is not established; the earlier failure remains a test-reliability limit, not a passing concurrent batch. The failed run is retained in `/tmp/pi-mac-reference-uiux/root-final.log`; final sequential root evidence is recorded separately above.

## Review outcomes

The complete code/test diff was reviewed for correctness, security, lifecycle safety, compatibility and scope. The runtime-interruption heading finding was fixed at the Mac display boundary and tested without changing process control. The request to copy original CRLF fence bytes was not adopted: this action copies displayed code after the existing Markdown parse, not raw Markdown export. The integrated copy test proves that contract, and the line-ending limit is explicit above. The final-outcome precedence regression was fixed against upstream's explicit event flag and covered by a failing-then-passing Core case. No authentication, certificate, execution-confirmation or replay guard changed. Local documentation links, the six referenced source paths and `git diff --check` pass.

## Rollback and data safety

The changes do not migrate sessions, credentials, pairing, workspace preferences or drafts. Older readers ignore optional tool metadata and older snapshots omit it. A rollback can revert presentation and metadata projection without rewriting saved sessions or replaying input. Keep full history in the managed session files; display bounds are not data deletion.

## Publication

Implementation commit: `a3b3f93`, on `narumi/feat/mac-reference-uiux`. Delivered as [pull request #9](https://github.com/narumiruna/pi-remote/pull/9). The tested source/project hash is unchanged through final sequential validation. The completed task plan `docs/plans/2026-10-18_mac-reference-uiux-plan.md` is removed; this document retains its outcome, checks and limits. The broader Pi-like interface plan remains open for attended product acceptance.

## Limits

These source checks, hosted windows and synthetic captures do not prove normal-launch operation, full VoiceOver behavior or final user visual acceptance. The [original Pi-like interface plan](plans/2026-10-18_pi-like-mac-interface-plan.md) remains open for those product checks. No personal running app was replaced or stopped.

The app still has one active managed Pi runtime. There is no arbitrary custom extension panel/footer transport, concurrent background-job registry, executable artifact preview, automatic command execution from completion or automatic prompt replay. Pi's native keyboard and draft-consent contracts remain intact.
