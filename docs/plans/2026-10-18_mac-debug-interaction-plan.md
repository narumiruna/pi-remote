# App-only debug interaction

## Goal

Extend the local Mac debug tools so Pi can navigate and inspect the app during a UI review. Keep process execution, authentication, pairing and destructive actions outside this channel.

## Scope and boundaries

- Keep explicit opt-in, private Unix transport, token rotation, bounded records and immediate revocation. The later user request saves consent across app restarts; Disable clears it, and Quit closes only the current capability.
- Add semantic UI actions: navigate, select interface mode, show/hide sidebar, select/hide inspector, open/close ordinary panels, append native editor text, focus the editor, and scroll identified app content.
- Use existing presentation state and native editor/scroll views. Do not claim these actions simulate physical pointer or keyboard input.
- Reject interactions while pairing, extension requests, modal surfaces or ambiguous windows are present. Only an ordinary app panel can be closed through the channel.
- Never submit prompts, execute commands, start/stop Pi or networking, answer dialogs, approve/revoke devices, change credentials, or operate another app.
- Do not replace existing draft text. Native text insertion must retain undo. Never echo input text in results or routine logs.
- Update consent text. The running old app cannot gain new controls without a rebuild/relaunch and fresh user opt-in.

## Plan

- [x] Save confirmed debug consent across restarts. The focused debug/controller/interaction/Quit batch passes 44 tests with one ownership skip, including production model restart, capability rotation, Disable persistence and failed automatic startup. Normal-launch restart remains unverified.
- [x] Add strict interaction request validation and fixed responses to the Swift debug service; preserve old status/capture calls. The focused service/controller/interaction batch passes 41 tests with one root-only skip.
- [x] Add guarded app-only handlers and native editor/scroll integration. Hosted product navigation/panels/inspector/page scroll and native text/undo, stale context, protected/foreign sheets and revocation tests pass. No physical input simulation is claimed.
- [x] Add the Pi interaction tool and client validation. All 28 extension tests pass, including bounds, strict input/results, cancellation, lifecycle and installed Pi fixture execution before/after reload.
- [x] Run focused native and extension tests, an unsigned Mac build and `git diff --check`. The 41-test debug batch, separate 40-test editor regression batch, 28 extension tests, unsigned build and whitespace check pass. One root-only debug fixture skips.
- [ ] Finish normally launched verification. After push, the actual registered tool passed navigation, mode, sidebar/inspector, ordinary-panel and page-scroll checks; captures/status confirmed visible changes. Protected panels rejected capture/navigation, and an editor without a loaded session rejected focus. The running earlier interaction build still needs replacement for live saved-consent restart. Native draft insertion needs a user-loaded session. No app/child was stopped or consent bypassed; these limits remain open.
- [x] Update README.md, PLAN.md and debug operation documentation with verified behavior and limits. Local reference targets and `git diff --check` pass.

## Completion Checklist

- [x] Supported UI actions pass focused tests without Pi/session/network mutations.
- [x] Revocation, protected surfaces, invalid requests and text privacy checks pass in the stated focused fixtures. Full user-driven confirmation workflows remain outside these fixtures.
- [x] The extension and unsigned app build pass the recorded focused checks.
- [ ] Complete live saved-consent restart and native draft insertion after the user opens the latest build and a session. The passing normal-launch smoke check and remaining limits are recorded in `docs/mac-debug-mode.md`; this plan remains open.

## Rollback / Recovery

Disable debug mode to revoke access. Return to the previous build if needed; no catalog or protocol-storage migration is required. UI preferences can change through navigation and mode controls. Draft text changes only through explicit native insertion and remains undoable.
