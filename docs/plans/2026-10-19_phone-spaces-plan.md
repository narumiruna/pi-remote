# Phone Spaces navigation

## Goal

Show Spaces first and Sessions second on iPhone. A Space groups managed sessions by their canonical Mac directory. Do not change the protocol, session storage or Mac navigation.

## Plan

- [x] Inspect the current list, scoped actions and existing local changes. `SessionInfo.directory` supplies the group key; selecting a group needs no host request.
- [ ] Add Spaces → Sessions navigation with directory labels, counts and current-session state. Keep global creation/import, folder review, same-directory lifecycle consent and interrupted-session consent.
- [ ] Update affected UI tests and add focused coverage for grouping, same-name directories, browsing without activation and working-state guards.
- [ ] Run focused iPhone 17 Pro simulator checks, an unsigned phone build and `git diff --check`. Record actual results in `PLAN.md` and update `README.md`.

## Completion Checklist

- [ ] Each directory appears once at the Spaces level; only its sessions appear at the second level.
- [ ] Browsing never activates Pi. Resume and creation keep existing scoped actions and guards.
- [ ] Focused checks pass; document unverified live/provider and accessibility behavior separately.
