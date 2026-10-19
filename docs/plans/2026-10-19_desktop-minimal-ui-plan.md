# Minimal Desktop interface

## Goal

Make the normal workflow clear: select a session, write an instruction, read the result. Remove repeated actions and secondary information from the conversation surface. Keep supported capabilities reachable.

**Status: implementation and native verification pass; normal-app review and user acceptance remain open.** This plan covers all five findings from the normal-app debug review. See the [current verification record](../desktop-minimal-ui.md). The normal-app debug service is unavailable; the revised build must run with user-enabled debug mode to continue. Native accessibility checks do not prove live VoiceOver traversal.

## Evidence and scope

- The reviewed Desktop window was 1104 × 829 with an idle loaded session and no messages. Main conversation, Session inspector, Overview, Settings and Devices were inspected. Both side panes were temporarily hidden to compare the conversation surface.
- Files/Commands appeared in several places. The welcome, resource disclosure and raw warning competed with the editor. Sidebar destinations repeated session navigation. The Session form placed Changelog before Model and repeated pickers with Cycle buttons. Overview showed seven sessions, including five closed rows with disabled Close buttons.
- Commands-panel capture was blocked by debug protection. Its content, live streaming and populated conversation behavior were not reviewed. The debug banner is development tooling, not a product UI finding.
- Change Desktop presentation and shared Mac navigation where needed. Preserve the Pi-mode transcript/editor/footer layout, iPhone behavior, host RPC and single-active-session limit.
- Do not change credentials, pairing, catalog/JSONL formats, session activation, close consent or warning severity. Do not add settings, feature flags or new navigation systems for this cleanup. Preserve the unrelated `Package.swift` edit.

## Design decisions

One primary visible action per feature is sufficient. Inspector tabs, standard menus, slash navigation and existing keyboard shortcuts remain valid secondary routes. Minimalism must not make actions icon-only or keyboard-only.

| Finding | Approved change | Acceptance evidence |
|---|---|---|
| 1. Repeated entry points | Keep Files and Pi commands in the toolbar. Keep Session controls in the existing Session menu. Remove the loaded welcome's Files/Commands buttons, the composer Commands button and the header Session controls button. Keep New session in the toolbar. | Native control-tree checks prove one primary action per feature; all retained routes open the existing destination without dispatching work. |
| 2. Conversation noise | Replace the loaded-session hero with one short input hint. Move Context/Skills/Prompts resources to Session details. Replace raw generic diagnostic blocks with one severity/count summary and View details, opening Activity without navigation. | Empty and populated captures prioritize the editor/messages; warning text remains visible and full diagnostics remain available. |
| 3. Repeated navigation | Sidebar contains workspace/session rows and one Settings destination. Remove its Pi/Overview root rows. Keep Overview in Actions. Put Devices under Settings → iPhone access; remove its sidebar and Actions duplicates. | Active conversation aliases select the same session row. Overview, Devices and workspace actions remain reachable without starting or stopping Pi. |
| 4. Session form order | Put Model and Thinking level first. Remove visible Cycle buttons, retaining existing cycling shortcuts/actions. Group directory, usage, output and session operations below; put resource metadata and infrequent controls in collapsed Details/Advanced groups. Move Pi version/changelog to Settings's existing Pi section. | Model/Thinking are visible without scrolling at 260/320-point widths; every relocated capability retains a route and its existing guards. |
| 5. History clutter | Overview shows loaded and non-closed sessions first. Put closed rows in a collapsed Closed sessions (count) group. Show Reopen for closed rows, not disabled Close. Move ordinary row Close actions to context menus; keep global Close and its shortcut. | The reviewed seven-row fixture initially shows two normal rows plus a five-item closed group. Explicit expansion/reopening works without losing history or drafts. |

## Route checklist

Source mapping and native route checks pass. Normal-app traversal remains open; private fixtures do not establish user acceptance.

| Action | Retained route and identifier | Guard / state owner |
|---|---|---|
| Files / Pi commands | Toolbar `mac-files` / `mac-commands`; existing inspector / Commands sheet | Existing context and scoped request; opening is not execution |
| Session controls / model / thinking | Session menu → Session inspector; `mac-session-model`, `mac-session-thinking` | Displayed loaded context; busy and capability rules unchanged |
| Diagnostics | `desktop-diagnostics-details` → `openControls("activity")` → Activity | No destination change; typed notices plus unmatched legacy text |
| Context / Skills / Prompts | Session Details `mac-session-details`; `MacDesktopSessionResources(state:)` | Read-only snapshot and discovered command names; no new request |
| Pi version / changelog | Settings Pi section; `mac-settings-pi-changelog` → existing `changelog` panel | `pi-release-notes` capability; existing scoped `ReleaseNotesView` request |
| Overview / saved work | Actions → Overview; `mac-overview-closed-sessions`; existing switcher shortcut | Sidebar selection previews; explicit Open/Reopen activates through existing lifecycle |
| Close Session | Session menu/global shortcut and row context menus; Pi sidebar keeps its existing hover Close control | Existing `beginClose` admission, Stop and Close consent, draft/history retention |
| Devices | Settings → iPhone access → `mac-settings-devices` | Existing Devices view, full duplicate identity and revocation consent |

`MacDebugController.captureWindow` rejects any non-nil `model.panel`, including Commands. The earlier capture rejection is intentional protection, not proof of a Commands UI defect. Native private fixtures must inspect that sheet without changing this product guard. Removed Desktop debug click IDs retain fail-closed unavailable behavior; do not redirect them to other controls.

## Plan

- [x] Map current routes and guards before editing. Inspect `CompanionWindow.swift`, `MacDesktopChrome.swift`, `PiConversationView.swift`, `SessionViews.swift` and `CompanionConnectionViews.swift`; list relocated actions and their native test/debug identifiers.
  - Confirm how resource metadata and Pi changelog use existing state/requests. Do not add a provider request or start Pi just to display them.
  - Resolve the protected Commands capture through source/native tests or attended review. Do not weaken debug protection to obtain a capture.
  - Evidence: a route checklist in this plan with no supported action left without an accessible destination.
- [x] Implement finding 1's single-entry Desktop surface in `CompanionWindow.swift`, `MacDesktopChrome.swift` and `PiConversationView.swift`.
  - Retain visible New session and working-state Stop. Preserve no-session/unavailable guidance and explicit saved-session opening; do not duplicate New session in the welcome.
  - Keep menu/shortcut ownership outside lazy menu content where required. Completion, palette search and opening panels must not execute commands.
  - Evidence: native action-count, routing and keyboard tests; update intentional duplicate-control expectations rather than disabling their tests.
- [x] Implement finding 3's navigation before moving information into it.
  - Preserve workspace grouping, folder disambiguation, Add workspace and Import through existing menus. Do not replace saved display names or rewrite stable IDs.
  - Map `.conversation` and `.session(loadedID)` to the same sidebar selection. Viewing another saved session must not activate it or redirect controls to the loaded session.
  - Evidence: tests from conversation, Overview, Settings and another saved selection preserve host context, draft and active work. Devices retains full identity and revocation consent.
- [x] Implement finding 2's conversation simplification and finding 4's Session organization using the existing data owners.
  - Warning/error summaries use existing typed severity and counts, not provider-specific parsing or AI-generated text. Keep unknown-severity legacy notices discoverable without assuming success.
  - View details opens Activity and preserves the central page. Full diagnostic text remains selectable there. Keep blocking errors, pending dialogs, tool failures and Stop visible; do not collapse required recovery/consent into generic diagnostics.
  - Preserve extension widgets in their existing positions and keep extension status entries available. Move only the app-owned resource presentation.
  - Keep mutable Session actions bound to the viewed loaded context, with current busy/capability checks. Do not create a separate RPC/settings implementation for Desktop. If shared views change, verify Pi mode and iPhone explicitly.
  - Evidence: notice severity/detail routing, resource access, compact Session geometry and capability/idle/stale-context tests; compare Desktop light/dark and Pi captures.
- [x] Implement finding 5's closed-session grouping in `CompanionWindow.swift` using existing closed-session state.
  - Keep the loaded session visible even if local closed metadata is stale. Closed grouping is presentation only; it must not delete, close, activate or replay a session.
  - Keep Reopen explicit. Preserve Close confirmation, failure visibility and draft/history retention. Keep empty/error states visible outside the collapsed group.
  - Evidence: seven-row fixture; all-closed/empty cases; failed and working Close; cached draft and reopen checks. Update `MacDesktopSessionActionTests` for the intentional removal of disabled Close rows.
- [ ] Verify the combined implementation with configured focused checks and normal-app review.
  - Use `project.yml`'s Mac test scheme and the verified commands in [native app checks](../native-apps.md#automated-checks). Run relevant Desktop chrome, structure, presentation, session-action, editor/IME, notice and debug-routing regressions serially; native test windows must not compete for focus.
  - Build the unsigned Mac app. Build iOS and run affected phone regressions if shared views change. Run `git diff --check` and verify local documentation paths.
  - Review Desktop light/dark at 900 × 600, 1104 × 829 and 1300 × 800; check 260/320-point Session panes, long names/drafts, empty/unloaded states, populated history, working state and warnings/errors. Use private fixtures for states unavailable in the live app and label that evidence separately.
  - Check keyboard/VoiceOver access to relocated actions. Update the fixed debug identifier tests when controls move; do not add arbitrary click/input access. If live checks are blocked, record the required user action or explicit acceptance; do not mark them passed.
  - Passed: 365 Mac tests with one pre-existing ownership skip across disjoint serialized batches; 49 iPhone simulator tests with one optional provider-fixture skip and seven host Close-consent tests; both unsigned builds; the native capture review, diff check and local path checks. Enumeration and result counts match all 366 configured Mac tests.
  - Blocked: normal-app debug is unavailable. Run the revised build and enable debug mode to continue. Live VoiceOver and user visual acceptance remain unverified. Actual iPhone Picker menu selection is outside the in-process fixture's evidence.
- [x] Update current-behavior documentation after implementation and verified checks. Keep the product overview in `README.md`; update affected navigation/design rules in `PLAN.md` and mode/interface documentation. Record exact test results, reviewed captures and limitations in a durable verification document. Do not edit unrelated plans or present this proposal as current behavior.

## Completion Checklist

- [x] All five finding rows have passing native behavior and visual evidence, with no orphaned capability or new permanent UI duplication. Normal-app acceptance remains separate below.
- [x] The conversation emphasizes session identity, messages and the editor. Raw generic diagnostic blocks, the loaded hero and the composer resource/Commands duplicates are absent.
- [x] Warning summaries, tool errors, blocking recovery, active work and required consent remain visible and truthful in native checks.
- [x] Sidebar aliases, inspector context, draft/IME/undo/reading position and current session lifecycle/security guards pass regression checks.
- [x] Focused native tests, required builds, `git diff --check` and documentation path checks pass, with the recorded pre-existing ownership and optional provider-fixture skips. Results distinguish fixtures from the normal app.
- [ ] The normal app's revised primary workflow and relocated controls pass attended/debug review within tool limits, and the user accepts the minimalist result. Blocked captures are not treated as evidence.
- [x] Documentation describes implemented behavior and remaining limits. Keep this plan until every required check passes or the user explicitly accepts a remaining limit; then remove the completed plan.
