# App-only debug UI controls

## Goal

Let the repository debug tools click supported Pi Remote controls, append native draft text and switch app screens. Restore the saved opt-in behavior that was left on the earlier debug branch. Preserve the merged UI/UX fixes.

## Boundaries

- Act only in the one marked, visible Pi Remote window after explicit consent.
- Use native accessibility press for a fixed list of ordinary control IDs. Do not inject desktop coordinates, arbitrary keys or events into other apps.
- Keep pairing, secure fields, modal consent and extension requests protected. Never send prompts, start/stop Pi or networking, select sessions, approve devices or change credentials through debug controls.
- Append text through the visible native prompt editor without replacing existing text or a selection. Preserve native undo, IME and session context checks. Reject input without a loaded session.
- Save confirmed opt-in across launches. Disable clears consent; each launch uses a fresh capability. Never inject consent into the user's preferences.

## Plan

- [x] Restore the existing semantic interaction service/client and saved consent on top of current main. Keep local-first Settings, address refresh, no-session input guards and inspector routing; 43 native UX/editor regressions pass.
- [x] Add 12 fixed click targets with native button/AX dispatch, ownership/visibility/ambiguity checks and safe fixed results. Client/server input validation and fixed responses pass focused tests.
- [x] Verify focused controls and safety checks: 51 native debug/controller/service/Quit tests pass with one root-only ownership skip; all 41 extension tests pass. Native fixtures cover real toolbar clicks, append/undo, stale contexts, virtual AX ownership/clipping/duplicates, lookup cancellation/budget and saved-consent restart.
- [x] Build the unsigned Mac app and the separate-process UI-runner target. Independent review identified target-ownership/cancellation gaps and uncertain server timeouts; corrections pass regressions. Local path and whitespace checks pass.
- [x] Update documentation and open a separate pull request so restored changes are not left on an already merged branch. Implementation commit 287268a is pushed on narumi/feat/debug-ui-controls; PR #15 is open against main: https://github.com/narumiruna/pi-remote/pull/15.
- [ ] BLOCKED: verify live native clicks, loaded-session append and saved-consent restart after user relaunch and consent. The actual registered-tool probe reaches the current older app but gets unsupported_operation. No user app was stopped and no consent was injected. The rebuilt app is /tmp/pi-remote-debug-mac/Build/Products/Debug/PiRemoteMac.app.

## Completion Checklist

- [x] Supported native clicks, text insertion and screen changes pass the focused checks. In-process AX cannot expose every visible SwiftUI control; unavailable targets fail, and semantic routes remain available.
- [x] Protected actions, no-session input and stale contexts fail without mutation.
- [x] Saved consent, Disable, fresh capability and bounded transport checks pass.
- [x] Documentation separates passing fixtures/builds from live acceptance.
- [x] PR #15 is open. Live checks are explicitly blocked by user relaunch/consent, not marked passed. Keep this plan until the live task above passes.

## Rollback / Recovery

Disable debug mode to revoke access and clear automatic startup. Revert this change if necessary; no catalog, session or credential migration is required. UI preferences and explicitly appended draft text can persist. Native undo can remove appended text.
