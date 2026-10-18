# Mac reference UI/UX refinements

## Goal

Improve Pi Remote for Mac with the useful interaction patterns found in the six local UI references. Preserve the Pi-like native layout, editor shortcuts, optional navigation, one active runtime and existing execution safeguards.

## Context

Base: `main` at `ec446d0`. The working tree was clean. The read-only comparison inspected PI-Desktop `e219a3e4c`, Jan `a86d87ebc`, Cherry Studio `d01b83d2cc`, LibreChat `e081b566a`, Open WebUI `91ea4e342` and AnythingLLM `d7d68e75` under `/Users/narumi/src/ui-references`.

Useful references are compact process/tool headings, explicit execution states, scroll-anchored disclosure, code-block controls and searchable model groups. Their application dashboards, executable artifacts and backend-owned job controls do not fit this task.

## Architecture

- Keep presentation in `Apps/macOS` with SwiftUI/AppKit. Add no dependency, web view, terminal or TypeScript runtime.
- Preserve bounded tool display metadata in the shared transcript only where needed to distinguish known outcomes from interrupted work. New optional fields must decode older snapshots and leave phone presentation unchanged.
- Copy code only after an explicit user action through the existing local clipboard policy. Tests inject copy handling; they must not change the user's clipboard.
- Treat all tool names, paths, output and code as untrusted display text. Do not execute or log them.

## Plan

- [x] Preserve tool name, bounded target and authoritative outcome through live events and saved history; test successful, failed, interrupted, legacy and bounded cases without replay or credential access. Evidence: 15 new Core functions cover metadata and final-result semantics; all 76 Core tests pass normally and with Thread Sanitizer.
- [x] Replace generic Mac tool rows with compact action/target/state headings and tool-appropriate previews; retain visible errors and truncation evidence. Verify live/final/error/unknown fixtures and user-controlled expansion. Evidence: 11 tool-row tests and synthetic 900/1300-point captures pass; the full Mac scheme passes 181 tests.
- [x] Anchor tool disclosure to its header and enter reading mode; verify expansion and collapse preserve the viewport while streaming does not pull the reader away. Keep Latest and manual-bottom resume. Evidence: the hosted conversation test measures the header before/after expansion, streaming and collapse; the nine follow-state tests pass.
- [x] Add native code blocks with language labels, explicit copy feedback and bounded lexical colors for supported languages; preserve exact code, selection, plain fallback and incomplete/Unicode input. Test copy through an injected action with no clipboard write. Evidence: 12 code-block tests and the actual Markdown-to-copy fixture pass without changing the real clipboard. Capture review and a viewport test confirm leading alignment.
- [x] Group model choices by provider, identify the current model/thinking level and preserve search/keyboard navigation. Test empty/no-match, current selection, busy restrictions, context changes and failed apply without dispatch on presentation. Evidence: 13 picker tests pass, including native Search arrow/Return routing, failed apply and stale completion.
- [x] Run focused Mac/Core checks first, then relevant complete Mac, root and Core checks. Run a focused primary-phone smoke check for shared transcript changes. Review synthetic narrow/wide captures without replacing the user's running app. Evidence: final sequential root 201, Mac 181, Core 76 normal/TSAN and primary-phone smoke three pass. Earlier failures and limits remain recorded.
- [x] Update README, relevant PLAN requirements and a focused verification record with actual results, limits and reference paths. Verify local links and `git diff --check`; review the complete diff for correctness, security, lifecycle safety, compatibility and scope. Evidence: README/PLAN and docs/mac-reference-uiux.md are updated; local links, reference paths and whitespace checks pass. The complete diff and new files were reviewed.
- [ ] Commit and push the verified changes on `narumi/feat/mac-reference-uiux`; deliver a pull request with check evidence and remaining attended-review limits.

## Non-Goals

- No new dashboard, multi-model comparison, runtime, provider setup, background-job registry or extension adapter.
- No executable HTML artifacts, arbitrary custom terminal components or remote reference app execution.
- No new theme/settings system or full language parser. Unsupported code languages remain plain text.
- No claim of final user visual acceptance, normal-launch testing or full VoiceOver verification from hosted fixtures.

## Risks

- Shared transcript changes can affect old snapshots and the phone. Keep new fields optional and test backward decoding and byte limits.
- Display updates and disclosure can race with streaming. Use stable message identities, preserve explicit user choices and test viewport geometry.
- Do not infer successful execution from an ended stream. Retain unknown/interrupted states when there is no final result.
- Lexical coloring must preserve code bytes and stay bounded; fall back to plain text rather than guess unsupported grammars.

## Rollback / Recovery

No session, credential, pairing, workspace or draft migration is added. Older clients ignore optional display metadata. Revert the in-scope presentation/projection changes if needed; do not rewrite saved sessions or replay uncertain input. Keep the existing local-only clipboard and execution-consent policies.

## Completion Checklist

- [ ] Every implementation task has passing named evidence or a stated external limit.
- [x] Native Pi input, draft consent, visible Stop, session binding and no automatic replay remain intact. Evidence: complete Mac/root regressions and source review; no host process or authentication logic changed.
- [x] Relevant tests, synthetic captures, local links and `git diff --check` pass; review finds no unresolved in-scope defect. The earlier intermittent shell-close check is recorded as a test-reliability limit after five isolated passes and a full sequential pass.
- [ ] Published commit and pull request are recorded. Attended normal-launch/accessibility and final visual acceptance remain separate product gates, not claims of this task.
